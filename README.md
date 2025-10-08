# Junkyard Slurm Setup
Automated flow for
* Cloning, modifying, and building Android kernel
* Creating Debian/Ubuntu root filesystem
* Building initramfs
* TODO: etc...

## Requirements
* [just](https://github.com/casey/just)
* [repo](https://source.android.com/docs/setup/download/source-control-tools)

## Customizing Kernel
Add/remove kernel modules in the defconfig fragment [custom_defconfig](kernel/custom_defconfig_mod/custom_defconfig). You may have to first add/remove modules manually with something like `nconfig` to see which other dependent modules also need to be added.

## Installing Additional Debian/Ubuntu Apt Packages
Add/remove packages in [packages.txt](rootfs/packages.txt). **Specify one package per-line**.

## Variables

## Building
```shell
just ...
```