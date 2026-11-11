#!/usr/bin/env python3
"""Device tree for Linux on doomacracy (spec.md, "Linux platform").

    gen_dts.py [SDRAM_MB] > doomacracy.dts

SDRAM is seen at 0x80000000; its top 16 KB holds the DTB itself and is left
out of the memory node. Everything else is a fixed I/O address."""
import sys

mb = int(sys.argv[1]) if len(sys.argv) > 1 else 8
size = (mb << 20) - 0x4000
print(f"""/dts-v1/;

/ {{
	#address-cells = <1>;
	#size-cells = <1>;
	compatible = "doomacracy,de1";
	model = "doomacracy (Terasic DE1, RV32IMA)";

	chosen {{
		bootargs = "earlycon=uart8250,mmio32,0xf0001000 console=tty0 console=ttyS0";
		stdout-path = &uart0;
	}};

	memory@80000000 {{
		device_type = "memory";
		reg = <0x80000000 0x{size:x}>;
	}};

	cpus {{
		#address-cells = <1>;
		#size-cells = <0>;
		timebase-frequency = <1000000>;

		cpu0: cpu@0 {{
			device_type = "cpu";
			reg = <0>;
			status = "okay";
			compatible = "riscv";
			riscv,isa = "rv32ima";
			mmu-type = "riscv,none";

			cpu0_intc: interrupt-controller {{
				#interrupt-cells = <1>;
				interrupt-controller;
				compatible = "riscv,cpu-intc";
			}};
		}};
	}};

	soc {{
		#address-cells = <1>;
		#size-cells = <1>;
		compatible = "simple-bus";
		ranges;

		/* 320x200 RGB565 in SRAM; the boot ROM points the video at it
		   (FB_BASE 0x40000, VIDEO_MODE 1) before starting the kernel */
		framebuffer@10040000 {{
			compatible = "simple-framebuffer";
			reg = <0x10040000 0x1f400>;
			width = <320>;
			height = <200>;
			stride = <640>;
			format = "r5g6b5";
		}};

		uart0: serial@f0001000 {{
			compatible = "ns16550a";
			reg = <0xf0001000 0x20>;
			reg-shift = <2>;
			reg-io-width = <4>;
			clock-frequency = <1843200>;
			current-speed = <115200>;
		}};

		syscon: syscon@f0002000 {{
			compatible = "syscon";
			reg = <0xf0002000 0x1000>;
		}};

		poweroff {{
			compatible = "syscon-poweroff";
			regmap = <&syscon>;
			offset = <0>;
			value = <0x5555>;
		}};

		reboot {{
			compatible = "syscon-reboot";
			regmap = <&syscon>;
			offset = <0>;
			value = <0x7777>;
		}};

		clint@f1000000 {{
			compatible = "sifive,clint0", "riscv,clint0";
			reg = <0xf1000000 0x10000>;
			interrupts-extended = <&cpu0_intc 3>, <&cpu0_intc 7>;
		}};
	}};
}};""")
