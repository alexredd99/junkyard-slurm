# Config
android_kernel_branch := "android-gs-felix-6.1-android16"

# Tools
repo := require("repo")

# Maybe change later to auto-build everything
default:
  just --list

# Will take around 1hr
[group('kernel')]
[working-directory: 'kernel/source']
clone_kernel_source:
  @echo "Cloning Android kernel from branch: {{android_kernel_branch}}"
  {{repo}} init -u https://android.googlesource.com/kernel/manifest -b {{android_kernel_branch}}
  {{repo}} sync -j {{ num_cpus() }}


# TODO: depend on clone_kernel_source
[group('kernel')]
[working-directory: 'kernel/source']
build_kernel: 
  tools/bazel clean --expunge
  cp -r ../custom_defconfig_mod .
  tools/bazel run \
    --config=use_source_tree_aosp \
    --config=stamp \
    --config=felix \
    --defconfig_fragment=//custom_defconfig_mod:custom_defconfig \
    //private/devices/google/felix:gs201_felix_dist

# Download android boot image?
# init boot, download existing android boot image
# debian/ubuntu rootfs
# flash?