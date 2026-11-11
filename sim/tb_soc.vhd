-- Whole DE1 board: the doomacracy top level plus SRAM, SDRAM and flash
-- models. Decodes the UART to stdout, grabs VGA frames to PPM files, and
-- can type on a PS/2 keyboard from a script.
--
-- Key script lines: "<frame> <hex byte> <hex byte> ..." sends those raw PS/2
-- bytes when that VGA frame starts.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.textio.all;
use ieee.std_logic_textio.all;
use work.vjtag_sim_cfg.all;

entity tb_soc is
    generic (
        FLASH      : string  := "build/flash.hex";
        KEYS       : string  := "";
        OUTDIR     : string  := "sim/out";
        MAX_MS     : integer := 100;        -- simulated milliseconds
        MAX_FRAMES : integer := 1000000;
        DUMP_EVERY : integer := 1;          -- write every Nth VGA frame
        DUMP_FIRST : integer := 0;          -- skip frames before this one
        UART_DIV   : integer := 16;
        SWITCHES   : integer := 0;          -- SW9 (512) selects the JTAG loader
        TRACE      : string  := "";
        TRACE_MAX  : integer := 0;
        -- SDRAM preload (raw binaries at byte offsets), e.g. a kernel and DTB
        SDRAM_IMG0    : string  := "";
        SDRAM_IMG0_AT : natural := 0;
        SDRAM_IMG1    : string  := "";
        SDRAM_IMG1_AT : natural := 0;
        -- JTAG console host (sim/vjtag_port_sim.vhd): poll period, 0 = off,
        -- and text to type ('~' = carriage return)
        CON_POLL_US : integer := 0;
        CON_IN      : string  := ""
    );
end tb_soc;

architecture sim of tb_soc is
    signal clk  : std_logic := '0';
    signal done : boolean := false;

    signal KEY  : std_logic_vector(3 downto 0) := "1111";
    signal SW   : std_logic_vector(9 downto 0) := std_logic_vector(to_unsigned(SWITCHES, 10));
    signal LEDR : std_logic_vector(9 downto 0);
    signal LEDG : std_logic_vector(7 downto 0);
    signal HEX0, HEX1, HEX2, HEX3 : std_logic_vector(6 downto 0);
    signal PS2_CLK, PS2_DAT : std_logic := '1';
    signal UART_TXD : std_logic;
    signal VGA_R, VGA_G, VGA_B : std_logic_vector(3 downto 0);
    signal VGA_HS, VGA_VS : std_logic;
    signal SRAM_ADDR : std_logic_vector(17 downto 0);
    signal SRAM_DQ : std_logic_vector(15 downto 0);
    signal SRAM_WE_N, SRAM_OE_N, SRAM_UB_N, SRAM_LB_N, SRAM_CE_N : std_logic;
    signal DRAM_ADDR : std_logic_vector(11 downto 0);
    signal DRAM_BA_0, DRAM_BA_1 : std_logic;
    signal DRAM_DQ : std_logic_vector(15 downto 0);
    signal DRAM_LDQM, DRAM_UDQM, DRAM_RAS_N, DRAM_CAS_N, DRAM_WE_N, DRAM_CS_N, DRAM_CKE, DRAM_CLK : std_logic;
    signal FL_ADDR : std_logic_vector(21 downto 0);
    signal FL_DQ : std_logic_vector(7 downto 0);
    signal FL_OE_N, FL_WE_N, FL_RST_N, FL_CE_N : std_logic;

    signal frame_no : integer := 0;
    signal dram_ba, dram_dqm : std_logic_vector(1 downto 0);
begin
    clk <= not clk after 10 ns when not done;

    dut : entity work.doomacracy
        generic map (UART_DIV => UART_DIV, SDRAM_INIT_WAIT => 100, TRACE => TRACE, TRACE_MAX => TRACE_MAX)
        port map (
            CLOCK_50 => clk, KEY => KEY, SW => SW, LEDR => LEDR, LEDG => LEDG,
            HEX0 => HEX0, HEX1 => HEX1, HEX2 => HEX2, HEX3 => HEX3,
            PS2_CLK => PS2_CLK, PS2_DAT => PS2_DAT, UART_RXD => '1', UART_TXD => UART_TXD,
            VGA_R => VGA_R, VGA_G => VGA_G, VGA_B => VGA_B, VGA_HS => VGA_HS, VGA_VS => VGA_VS,
            SRAM_ADDR => SRAM_ADDR, SRAM_DQ => SRAM_DQ, SRAM_WE_N => SRAM_WE_N, SRAM_OE_N => SRAM_OE_N,
            SRAM_UB_N => SRAM_UB_N, SRAM_LB_N => SRAM_LB_N, SRAM_CE_N => SRAM_CE_N,
            DRAM_ADDR => DRAM_ADDR, DRAM_BA_0 => DRAM_BA_0, DRAM_BA_1 => DRAM_BA_1, DRAM_DQ => DRAM_DQ,
            DRAM_LDQM => DRAM_LDQM, DRAM_UDQM => DRAM_UDQM, DRAM_RAS_N => DRAM_RAS_N,
            DRAM_CAS_N => DRAM_CAS_N, DRAM_WE_N => DRAM_WE_N, DRAM_CS_N => DRAM_CS_N,
            DRAM_CKE => DRAM_CKE, DRAM_CLK => DRAM_CLK,
            FL_ADDR => FL_ADDR, FL_DQ => FL_DQ, FL_OE_N => FL_OE_N, FL_WE_N => FL_WE_N, FL_RST_N => FL_RST_N, FL_CE_N => FL_CE_N);

    sram_chip : entity work.sram_model
        port map (SRAM_ADDR, SRAM_DQ, SRAM_WE_N, SRAM_OE_N, SRAM_UB_N, SRAM_LB_N, SRAM_CE_N);

    sdram_chip : entity work.sdram_model
        generic map (SDRAM_IMG0, SDRAM_IMG0_AT, SDRAM_IMG1, SDRAM_IMG1_AT)
        port map (DRAM_CLK, DRAM_ADDR, dram_ba, DRAM_DQ, dram_dqm,
                  DRAM_RAS_N, DRAM_CAS_N, DRAM_WE_N, DRAM_CS_N, DRAM_CKE);

    dram_ba  <= DRAM_BA_1 & DRAM_BA_0;
    dram_dqm <= DRAM_UDQM & DRAM_LDQM;

    flash_chip : entity work.flash_model
        generic map (FLASH)
        port map (FL_ADDR, FL_DQ, FL_OE_N, FL_WE_N, FL_CE_N);

    -- JTAG console host settings
    process
    begin
        con_poll <= CON_POLL_US * 1 us;
        if CON_IN'length > 0 then
            con_input(1 to CON_IN'length) <= CON_IN;
        end if;
        con_input_len <= CON_IN'length;
        wait;
    end process;

    -- UART receiver
    process
        variable l : line;
        variable c : std_logic_vector(7 downto 0);
    begin
        wait until falling_edge(UART_TXD);
        for i in 1 to UART_DIV + UART_DIV / 2 loop
            wait until rising_edge(clk);
        end loop;
        for b in 0 to 7 loop
            c(b) := UART_TXD;
            for i in 1 to UART_DIV loop
                wait until rising_edge(clk);
            end loop;
        end loop;
        if c = x"0A" then
            writeline(output, l);
        elsif c /= x"0D" then
            write(l, character'val(to_integer(unsigned(c))));
        end if;
    end process;

    -- VGA frame grabber
    process
        type row_t is array (0 to 639) of integer range 0 to 4095;
        type frame_t is array (0 to 479) of row_t;
        variable fb    : frame_t;
        variable hpos  : integer := 0;
        variable vline : integer := 0;
        variable sub   : integer := 0;
        variable hs_d, vs_d : std_logic := '1';
        variable l     : line;
        file f         : text;
        variable px    : integer;
    begin
        wait until rising_edge(clk);
        if VGA_HS = '0' and hs_d = '1' then
            hpos := 656;
            sub  := 0;
        else
            sub := sub + 1;
            if sub = 2 then
                sub  := 0;
                hpos := hpos + 1;
                if hpos = 800 then
                    hpos  := 0;
                    vline := (vline + 1) mod 525;
                end if;
            end if;
        end if;
        if VGA_VS = '0' and vs_d = '1' then
            vline := 490;
            if frame_no >= DUMP_FIRST and (frame_no - DUMP_FIRST) mod DUMP_EVERY = 0 then
                file_open(f, OUTDIR & "/frame_" & integer'image(frame_no) & ".ppm", write_mode);
                write(l, string'("P3 640 480 15"));
                writeline(f, l);
                for y in 0 to 479 loop
                    for x in 0 to 639 loop
                        px := fb(y)(x);
                        write(l, px / 256); write(l, ' ');
                        write(l, (px / 16) mod 16); write(l, ' ');
                        write(l, px mod 16); write(l, ' ');
                    end loop;
                    writeline(f, l);
                end loop;
                file_close(f);
                write(l, string'("[tb] frame ") & integer'image(frame_no) & " written at " & time'image(now));
                writeline(output, l);
            end if;
            frame_no <= frame_no + 1;
        end if;
        hs_d := VGA_HS;
        vs_d := VGA_VS;
        if hpos < 640 and vline < 480 and sub = 0 then
            fb(vline)(hpos) := to_integer(unsigned(VGA_R & VGA_G & VGA_B));
        end if;
    end process;

    -- PS/2 keyboard: device-driven clock, about 12.5 kHz (sped up 4x in sim)
    process
        file f      : text;
        variable st : file_open_status;
        variable l  : line;
        variable at : integer;
        variable b  : std_logic_vector(7 downto 0);
        variable ok : boolean;
        variable frame : std_logic_vector(10 downto 0);
        variable par   : std_logic;
        variable ch    : character;
        variable nib   : integer;
    begin
        if KEYS = "" then
            wait;
        end if;
        file_open(st, f, KEYS, read_mode);
        if st /= open_ok then
            report "no key script " & KEYS severity warning;
            wait;
        end if;
        while not endfile(f) loop
            readline(f, l);
            read(l, at, ok);
            next when not ok;
            while frame_no < at loop
                wait until frame_no'event;
            end loop;
            loop
                -- next two hex digits, skipping spaces
                b := (others => '0');
                ok := false;
                while l'length > 0 and l(l'left) = ' ' loop
                    read(l, ch);
                end loop;
                exit when l'length < 2;
                for d in 1 to 2 loop
                    read(l, ch);
                    case ch is
                        when '0' to '9' => nib := character'pos(ch) - character'pos('0');
                        when 'A' to 'F' => nib := character'pos(ch) - character'pos('A') + 10;
                        when 'a' to 'f' => nib := character'pos(ch) - character'pos('a') + 10;
                        when others     => nib := 0;
                    end case;
                    b := b(3 downto 0) & std_logic_vector(to_unsigned(nib, 4));
                end loop;
                par := '1';
                for i in 0 to 7 loop par := par xor b(i); end loop;
                frame := '1' & par & b & '0';
                for i in 0 to 10 loop
                    PS2_DAT <= frame(i);
                    wait for 10 us;
                    PS2_CLK <= '0';
                    wait for 20 us;
                    PS2_CLK <= '1';
                    wait for 10 us;
                end loop;
                wait for 100 us;
            end loop;
        end loop;
        wait;
    end process;

    -- stop conditions
    process
        variable l : line;
    begin
        loop
            wait for 1 ms;
            write(l, string'("[tb] ") & time'image(now) & " frames " & integer'image(frame_no));
            writeline(output, l);
            exit when LEDR(9) = '1' or now >= MAX_MS * 1 ms or frame_no >= MAX_FRAMES;
        end loop;
        if LEDR(9) = '1' then
            write(l, string'("[tb] CPU halted (ebreak or illegal)"));
            writeline(output, l);
        end if;
        done <= true;
        sim_done <= true;
        wait;
    end process;
end sim;
