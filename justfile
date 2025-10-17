# Config
android_kernel_branch := "android-gs-felix-6.1-android16"
debootstrap_release   := "stable"
rootfs_size           := "2GiB"
root_password         := "0000"
_apt_packages         := replace(read(join("rootfs", "packages.txt")), "\n", " ")

# Tools
_repo        := require("repo")
_debootstrap := require("debootstrap")
_fakeroot    := require("fakeroot")
_rsync       := require("rsync")
_fallocate   := require("fallocate")
_mkfs_ext4   := require("mkfs.ext4")
_uniq        := require("uniq")
_mkbootimg   := join(justfile_directory(), "tools", "mkbootimg", "mkbootimg.py")
_bazel       := join(justfile_directory(), "kernel", "source", "tools", "bazel")

default:
  just --list

# Will take around 1hr
[group('kernel')]
[working-directory: 'kernel/source']
clone_kernel_source:
  @echo "Cloning Android kernel from branch: {{android_kernel_branch}}"
  {{_repo}} init \
    --depth=1 \
    -u https://android.googlesource.com/kernel/manifest \
    -b {{android_kernel_branch}}
  {{_repo}} sync -j {{ num_cpus() }}

_kernel_build_dir := join(justfile_directory(), "kernel", "source", "out", "felix", "dist")
_kernel_version   := trim(read(join("kernel", "kernel_version")))

[group('kernel')]
[working-directory: 'kernel/source']
clean_kernel: clone_kernel_source
  {{_bazel}} clean --expunge

[group('kernel')]
[working-directory: 'kernel/source']
build_kernel: clone_kernel_source
  cp -r ../custom_defconfig_mod .
  {{_bazel}} run \
    --config=use_source_tree_aosp \
    --config=stamp \
    --config=felix \
    --defconfig_fragment=//custom_defconfig_mod:custom_defconfig \
    //private/devices/google/felix:gs201_felix_dist
  
  @echo "Updating kernel version string"
  strings {{join(_kernel_build_dir, "Image")}} \
    | grep "Linux version" \
    | head -n 1 \
    | awk '{print $3}' > kernel_version

_sysroot_dir          := join(justfile_directory(), "rootfs", "sysroot")
_fakeroot_config_path := join(_sysroot_dir, ".fakeroot.env")

# Based on https://muxup.com/2024q4/rootless-cross-architecture-debootstrap
[group('rootfs')]
[working-directory: 'rootfs']
_build_rootfs_first_stage:
  rm -rf {{_sysroot_dir}}
  mkdir {{_sysroot_dir}}

  {{_fakeroot}} -s {{_fakeroot_config_path}} -- debootstrap \
    --variant=minbase \
    --include=fakeroot,symlinks \
    --arch=arm64 --foreign {{debootstrap_release}} \
    {{_sysroot_dir}}

# Tried to do this without sudo, but may have to do this on newer Ubuntu
# sudo sysctl kernel.apparmor_restrict_unprivileged_userns=0
[group('rootfs')]
[working-directory: 'rootfs']
_build_rootfs_second_stage: _build_rootfs_first_stage
  {{_fakeroot}} -i {{_fakeroot_config_path}} -s {{_fakeroot_config_path}} -- sh -c \
    "ar p {{_sysroot_dir}}/var/cache/apt/archives/libfakeroot_*.deb 'data.tar.xz' | tar xv -J -C {{_sysroot_dir}}"
  {{_fakeroot}} -i {{_fakeroot_config_path}} -s {{_fakeroot_config_path}} -- sh -c \
    "ar p {{_sysroot_dir}}/var/cache/apt/archives/fakeroot_*.deb 'data.tar.xz' | tar xv -J -C {{_sysroot_dir}}"
  {{_fakeroot}} -i {{_fakeroot_config_path}} -s {{_fakeroot_config_path}} -- sh -c \
    "ln -s fakeroot-sysv {{_sysroot_dir}}/usr/bin/fakeroot"
  
  cp _enter {{_sysroot_dir}}/
  chmod +x {{_sysroot_dir}}/_enter
  
  {{_sysroot_dir}}/_enter debootstrap/debootstrap --second-stage
  {{_sysroot_dir}}/_enter symlinks -cr .
  
  # Set password
  {{_sysroot_dir}}/_enter sh -c "echo "root:{{root_password}}" | chpasswd"

[group('rootfs')]
[working-directory: 'rootfs']
install_apt_packages:
  {{_sysroot_dir}}/_enter sh -c "apt-get -y install {{_apt_packages}}"

[group('rootfs')]
[working-directory: 'rootfs']
build_rootfs: _build_rootfs_second_stage install_apt_packages
  echo "Building rootfs"

_kernel_modules := trim(read(join("rootfs", "kernel_modules")))

_system_dlkm_dir    := "unpack/system_dlkm"
_vendor_dlkm_dir    := "unpack/vendor_dlkm"
_kernel_headers_dir := "unpack/kernel_headers"

# TODO: Download factory image and copy firmware
[group('rootfs')]
[working-directory: 'rootfs']
update_kernel_modules_and_source:
  mkdir -p {{_system_dlkm_dir}} && \
  tar \
    -xvzf {{_kernel_build_dir}}/system_dlkm_staging_archive.tar.gz \
    -C {{_system_dlkm_dir}}
  mkdir -p {{_vendor_dlkm_dir}} && \
  tar \
    -xvzf {{_kernel_build_dir}}/vendor_dlkm_staging_archive.tar.gz \
    -C {{_vendor_dlkm_dir}}
  mkdir -p {{_kernel_headers_dir}} && \
  tar \
    -xvzf {{_kernel_build_dir}}/kernel-headers.tar.gz \
    -C {{_kernel_headers_dir}}

  {{_rsync}} -avK --ignore-existing {{_vendor_dlkm_dir}}/ {{_sysroot_dir}}/
  {{_rsync}} -avK --ignore-existing {{_system_dlkm_dir}}/ {{_sysroot_dir}}/
  
  cp -r {{_kernel_headers_dir}}/kernel-headers {{_sysroot_dir}}/usr/src/linux-headers-{{_kernel_version}}
  
  for ext in dep alias symbols softdep devname; \
  do \
    echo "Merging modules.$ext"; \
    cat \
      {{_system_dlkm_dir}}/lib/modules/{{_kernel_version}}/modules.$ext \
      {{_vendor_dlkm_dir}}/lib/modules/{{_kernel_version}}/modules.$ext \
      | {{_uniq}} \
      > {{_sysroot_dir}}/lib/modules/{{_kernel_version}}/modules.$ext; \
  done
  
  @echo "Copy independent modules"
  cp {{_kernel_build_dir}}/fips140.ko {{_sysroot_dir}}/usr/src/linux-headers-{{_kernel_version}}/

  @echo "Updating module dependencies"
  {{_sysroot_dir}}/_enter depmod -a {{_kernel_version}}

  @echo "Updating kernel modules list"
  find {{_sysroot_dir}}/lib/modules/{{_kernel_version}} -type f -name '*.ko*' -print0 \
    | xargs -0 -I{} modinfo -b {{_sysroot_dir}} -k {{_kernel_version}} -F name "{}" \
    | sort -u | tr '\n' ' ' >> kernel_modules


# Bring up <device> in initramfs, <device> should be the device name
# add_device+=" /dev/mapper/sysvg-home /dev/mapper/sysvg-swap /dev/mapper/hdvg-private "

_initramfs_path := join(_sysroot_dir, "boot", "initrd.img-" + _kernel_version)
_module_order   := replace(read(join("rootfs", "module_order.txt")), "\n", " ")

# -l --keep 

## Get firmware from vendor.boot
[group('initramfs')]
[working-directory: 'rootfs']
update_initramfs:
  {{_sysroot_dir}}/_enter dracut \
    --kver {{_kernel_version}} \
    --lz4 \
    --show-modules \
    --force \
    --add "rescue bash" \
    --kernel-cmdline "rd.shell" \
    --add-drivers "{{_kernel_modules}}" \
    --force-drivers "{{_module_order}}"

# TODO: CHECK PERMISSIONS
[group('rootfs')]
[working-directory: 'boot']
create_rootfs_image:
  rm -f rootfs.img
  {{_sysroot_dir}}/_enter rm -f root/.bash_history
  {{_fallocate}} -l {{rootfs_size}} rootfs.img
  {{_mkfs_ext4}} -d {{_sysroot_dir}} rootfs.img

# TODO: Change cmdline for actual root

[group('boot')]
[working-directory: 'boot']
build_boot_images:
  {{_mkbootimg}} \
    --kernel {{_kernel_build_dir}}/Image.lz4 \
    --cmdline "/dev/disk/by-partlabel/super" \
    --header_version 4 \
    -o boot.img \
    --pagesize 2048 \
    --os_version 15.0.0 \
    --os_patch_level 2025-02

  {{_mkbootimg}} \
    --ramdisk_name "" \
    --vendor_ramdisk_fragment {{_initramfs_path}} \
    --dtb {{_kernel_build_dir}}/dtb.img \
    --header_version 4 \
    --vendor_boot vendor_boot.img \
    --pagesize 2048 \
    --os_version 15.0.0 \
    --os_patch_level 2025-02

# flash?
