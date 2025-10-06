# Config
android_kernel_branch := "android-gs-felix-6.1-android16"
debootstrap_release   := "stable"
rootfs_size           := "1GiB"

# Tools
_repo           := require("repo")
_unpack_bootimg := require("unpack_bootimg")
_debootstrap    := require("debootstrap")
_fakeroot       := require("fakeroot")
_mkbootimg      := join(justfile_directory(), "tools/mkbootimg/mkbootimg.py")
_bazel          := join(justfile_directory(), "kernel/source/tools/bazel") # Must clone kernel source first

default:
  just --list

# Will take around 1hr
[group('kernel')]
[working-directory: 'kernel/source']
clone_kernel_source:
  @echo "Cloning Android kernel from branch: {{android_kernel_branch}}"
  {{_repo}} init -u https://android.googlesource.com/kernel/manifest -b {{android_kernel_branch}}
  {{_repo}} sync -j {{ num_cpus() }}

_kernel_build_dir := join(justfile_directory(), "kernel/source/out/felix/dist")

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

_boot_build_dir := join(justfile_directory(), "boot")
_initramfs_path := join(_boot_build_dir, "initramfs.cpio.lz")

# TODO: Depend on build kernel?
[group('init_boot')]
[working-directory: 'init_boot']
update_initramfs:
  ls lib/modules


[group('init_boot')]
[working-directory: 'init_boot']
build_initramfs:
  find . -print0 | cpio --null -o --format=newc | lz4 -l --best > {{_initramfs_path}}

_sysroot_dir          := join(justfile_directory(), "rootfs/sysroot")
_fakeroot_config_path := join(_sysroot_dir, ".fakeroot.env")
_debootstrap_packages := replace(read("rootfs/packages.txt"), "\n", ",")

# Based on https://muxup.com/2024q4/rootless-cross-architecture-debootstrap
[group('rootfs')]
[working-directory: 'rootfs']
build_rootfs_first_stage:
  rm -rf {{_sysroot_dir}}
  mkdir {{_sysroot_dir}}

  {{_fakeroot}} -s {{_fakeroot_config_path}} -- debootstrap \
    --variant=minbase \
    --include=fakeroot,symlinks,{{_debootstrap_packages}} \
    --arch=arm64 --foreign {{debootstrap_release}} \
    {{_sysroot_dir}}

# Tried to do this without sudo, but may have to do this on newer Ubuntu
# sudo sysctl kernel.apparmor_restrict_unprivileged_userns=0
[group('rootfs')]
[working-directory: 'rootfs']
build_rootfs_second_stage: build_rootfs_first_stage
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

_system_dlkm_dir := join(justfile_directory(), "rootfs/system_dlkm_unpack")
_vendor_dlkm_dir := join(justfile_directory(), "rootfs/vendor_dlkm_unpack")
# TODO: Download factory image and copy firmware
[group('rootfs')]
[working-directory: 'rootfs']
install_kernel_modules:
  rm -rf {{_system_dlkm_dir}} {{_vendor_dlkm_dir}}
  mkdir {{_system_dlkm_dir}} {{_vendor_dlkm_dir}}
  
  tar \
    -xvzf {{_kernel_build_dir}}/system_dlkm_staging_archive.tar.gz \
    -C {{_system_dlkm_dir}}
  tar \
    -xvzf {{_kernel_build_dir}}/vendor_dlkm_staging_archive.tar.gz \
    -C {{_vendor_dlkm_dir}}

  rsync -av --update {{_system_dlkm_dir}}/ {{_sysroot_dir}}/
  rsync -av --update {{_vendor_dlkm_dir}}/ {{_sysroot_dir}}/
  # Append modules.dep
  # echo $(find {{_system_dlkm_dir}} -name "modules.dep")
  # echo $(find {{_sysroot_dir}} -name "modules.dep")
  cat $(find {{_system_dlkm_dir}} -name "modules.dep") >> $(find {{_sysroot_dir}} -name "modules.dep")
  
  # cp -r --parents system_dlkm_unpack/* sysroot/
  # May have to combine modules.dep...
  # tar \
  #   -xvzfk {{_kernel_build_dir}}/system_dlkm_staging_archive.tar.gz \
  #   -C {{_sysroot_dir}}
  # tar \
  #   -xvzfk {{_kernel_build_dir}}/vendor_dlkm_staging_archive.tar.gz \
  #   -C {{_sysroot_dir}}

[group('rootfs')]
[working-directory: 'rootfs']
create_rootfs_image: build_rootfs_second_stage
  {{_sysroot_dir}}/_enter rm -f /root/.bash_history # in case this exists
  {{_fakeroot}} -i {{_fakeroot_config_path}} -- sh -c \
    "fallocate -l {{rootfs_size}} rootfs.img"
  {{_fakeroot}} -i {{_fakeroot_config_path}} -- sh -c \
    "mkfs.ext4 -d {{_sysroot_dir}} rootfs.img"

# DEPEND ON everything else?
[group('boot')]
[working-directory: 'boot']
build_boot_image: 
  {{_mkbootimg}} \
    --kernel {{_kernel_build_dir}}/Image.lz4 \
    --ramdisk {{_initramfs_path}} \
    --dtb {{_kernel_build_dir}}/dtb.img \
    --header_version 4 \
    -o boot.img \
    --pagesize 4096 \
    --os_version 15.0.0 \
    --os_patch_level 2025-02


# kernel version = strings Image | grep "Linux version"
# flash?
