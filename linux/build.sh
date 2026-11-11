#!/usr/bin/env bash
# Build the doomacracy Linux kernel (no-MMU RV32IMA, busybox in initramfs)
# with cnlohr's buildroot fork. Needs a Linux host; on NixOS run it inside the
# FHS environment:  nix-build fhs.nix -o br-fhs && ./br-fhs/bin/br-fhs -c ./build.sh
# Output: work/buildroot/output/images/Image
set -e
here=$(cd "$(dirname "$0")" && pwd)
mkdir -p "$here/work" && cd "$here/work"
[ -d buildroot ] || git clone https://github.com/cnlohr/buildroot --recurse-submodules --depth 1
cp "$here/kernel_config"  buildroot/kernel_config
cp "$here/busybox_config" buildroot/busybox_config
cp "$here/uclibc_config"  buildroot/uclibc_config
cp "$here/uclibc_config"  buildroot/uclibc_config_extra
sed "s|\$(BR2_EXTERNAL_OVERLAY)|$here/overlay|" "$here/buildroot_config" > buildroot/.config
# host tools are old enough to break under C23 (GCC 15's default)
make -C buildroot -j"$(nproc)" HOSTCFLAGS="-O2 -std=gnu17"
ls -l buildroot/output/images/Image
