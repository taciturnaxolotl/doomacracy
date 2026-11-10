-- Simulation stand-in for rtl/vjtag_port.vhd: plays a stream file (one hex
-- word per line) as DR scans with IR = 1, the way tools/jtag_flash.tcl does,
-- in chunks of CHUNK words, at about 6 MHz TCK.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.textio.all;
use ieee.std_logic_textio.all;

entity vjtag_port is
    generic (
        STREAM : string  := "sim/jtagtest/stream.hex";   -- skipped if missing
        CHUNK  : integer := 64;
        START  : time    := 200 us
    );
    port (
        tck  : out std_logic;
        tdi  : out std_logic;
        tdo  : in  std_logic;
        ir   : out std_logic_vector(1 downto 0);
        cdr  : out std_logic;
        sdr  : out std_logic
    );
end vjtag_port;

architecture sim of vjtag_port is
    signal clk : std_logic := '0';
begin
    tck <= clk;
    process
        file f      : text;
        variable st : file_open_status;
        variable l  : line;
        variable w  : std_logic_vector(31 downto 0);
        variable n  : integer := 0;
        procedure edge is
        begin
            wait for 83 ns; clk <= '1'; wait for 83 ns; clk <= '0';
        end procedure;
    begin
        ir <= "00"; cdr <= '0'; sdr <= '0'; tdi <= '0';
        file_open(st, f, STREAM, read_mode);
        if st /= open_ok then
            wait;
        end if;
        wait for START;
        ir <= "01";
        while not endfile(f) loop
            if n mod CHUNK = 0 then
                sdr <= '0'; cdr <= '1'; edge; cdr <= '0';   -- capture, then shift
                for i in 1 to 4 loop edge; end loop;         -- gap between scans
            end if;
            readline(f, l);
            hread(l, w);
            sdr <= '1';
            for b in 0 to 31 loop
                tdi <= w(b);
                edge;
            end loop;
            n := n + 1;
        end loop;
        sdr <= '0';
        report "jtag: shifted " & integer'image(n) & " words";
        wait;
    end process;
end sim;
