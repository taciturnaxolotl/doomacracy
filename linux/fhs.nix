# FHS environment so buildroot finds /usr/bin/file and friends on NixOS
with import <nixpkgs> {};
(buildFHSEnv {
  name = "br-fhs";
  targetPkgs = p: with p; [ gcc13 gnumake which file perl python3 unzip zip rsync bc cpio wget git ncurses ncurses.dev pkg-config flex bison gzip bzip2 xz patch diffutils findutils gawk gnused gnutar util-linux glibc.dev zlib zlib.dev libxcrypt ];
  runScript = "bash";
  profile = "export hardeningDisable=all; unset CC CXX LD";
})
