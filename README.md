# Junkyard Slurm Setup
Automated flow for
* Cloning, modifying, and building Android kernel
* Creating and modifying Ubuntu rootfs
* TODO: etc...

## Requirements
* [just](https://github.com/casey/just)
* [repo](https://source.android.com/docs/setup/download/source-control-tools)

## Customizing Kernel
Add/remove kernel modules in [defconfig fragment](kernel/custom_defconfig_mod/custom_defconfig).

## Building
```shell
just ...
```