# Config
android_kernel_branch := "android-gs-felix-6.1-android15-qpr2-beta"

# Tools
repo := require("repo")

# Maybe change later to auto-build everything
default:
  just --list

[group('kernel')]
[working-directory: 'kernel/source']
clone_android_kernel_source:
  @echo "Cloning Android kernel from branch: {{android_kernel_branch}}"
  {{repo}} init -u https://android.googlesource.com/kernel/manifest -b {{android_kernel_branch}}
  {{repo}} sync -j {{ num_cpus() }} # Will take like 30m minimum, probably at least 1hr


[group('kernel')]
[working-directory: 'kernel']
build_kernel:
  # TODO: Make build directory in kernel
  # TODO: depend on clone_android_kernel_source


# Download android boot image

# customize_kernel w/ some fragment?
# clone_and_build_kernel: clone_android_kernel_source customize_kernel
# init boot, download existing android boot image
# debian/ubuntu rootfs
# flash?