{
  description = "doomacracy: Doom on a homemade RV32IM CPU on the DE1";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/7dcdd87373d72e7a2173e4db02e20d3d7f495cfd";

  outputs = { nixpkgs, ... }:
    let
      systems = [ "aarch64-darwin" "x86_64-darwin" "x86_64-linux" "aarch64-linux" ];
      forAll = f: nixpkgs.lib.genAttrs systems (system: f system nixpkgs.legacyPackages.${system});
      # pkgsCross.riscv32-embedded builds newlib and libgcc for rv32gc/ilp32d,
      # which cannot be linked into rv32im/ilp32 code. Same target triple, but
      # with the default arch/abi set so newlib and libgcc are rv32im/ilp32.
      rv32im = system: import nixpkgs {
        inherit system;
        crossSystem = {
          config = "riscv32-none-elf";
          libc = "newlib";
          gcc = { arch = "rv32im"; abi = "ilp32"; };
        };
      };
    in {
      packages = forAll (system: pkgs: {
        riscv-gcc = (rv32im system).buildPackages.gcc;
      });
      devShells = forAll (system: pkgs: {
        default = pkgs.mkShell {
          # the cc wrapper's hardening flags (stack protector, fortify,
          # relro...) are wrong for bare-metal firmware
          hardeningDisable = [ "all" ];
          packages = [
            (rv32im system).buildPackages.gcc
            pkgs.nvc
            pkgs.python3
            pkgs.gnumake
            pkgs.imagemagick
          ];
        };
      });
    };
}
