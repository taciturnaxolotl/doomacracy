-- Simulation stand-in for rtl/vjtag_port.vhd: plays a stream file (one hex
-- word per line) as DR scans with IR = 1, the way tools/jtag_flash.tcl does,
-- in chunks of CHUNK words, at about 6 MHz TCK.
--
-- If instead a testbench sets vjtag_sim_cfg.con_poll to a nonzero time, it
-- plays the host side of the console the way tools/jtag_console.tcl does
-- (IR = 3, 80-bit frames, see rtl/jtag_console.vhd): one scan every
-- con_poll, attach set, board output printed as "[jtag] ..." lines, and the
-- characters of con_input typed with the same credit rule as the script
-- ('~' stands for a carriage return). The testbench sets sim_done to stop
-- it, so the simulation can end.
library ieee;
use ieee.std_logic_1164.all;

package vjtag_sim_cfg is
    signal con_poll      : time := 0 ns;   -- 0: no console traffic
    signal con_input     : string(1 to 256) := (others => ' ');
    signal con_input_len : natural := 0;
    signal con_rx_bytes  : natural := 0;   -- board to host bytes seen so far
    signal sim_done      : boolean := false;  -- set by the testbench: stop scanning
end vjtag_sim_cfg;

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.textio.all;
use ieee.std_logic_textio.all;
use work.vjtag_sim_cfg.all;

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
        variable fo, fi : std_logic_vector(79 downto 0);
        variable sent, brp, m, nb, credit, pos, total : natural := 0;
        variable ol : line;
        variable c  : character;
        variable b  : std_logic_vector(7 downto 0);
        procedure edge is
        begin
            wait for 83 ns; clk <= '1'; wait for 83 ns; clk <= '0';
        end procedure;
    begin
        ir <= "00"; cdr <= '0'; sdr <= '0'; tdi <= '0';
        wait for 1 ns;                       -- let the testbench set con_poll
        if con_poll = 0 ns then              -- the stream only without a console
            file_open(st, f, STREAM, read_mode);
        else
            st := name_error;
        end if;
        if st = open_ok then
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
            file_close(f);
            report "jtag: shifted " & integer'image(n) & " words";
        end if;

        -- console host
        if con_poll = 0 ns then
            wait until con_poll /= 0 ns;
        end if;
        ir <= "11";
        loop
            wait for con_poll;
            exit when sim_done;
            -- what to send: at most 8 bytes, never more than 16 outstanding
            credit := 16 - ((sent + 32 - brp) mod 32);
            m := con_input_len - pos;
            if m > 8 then m := 8; end if;
            if m > credit then m := credit; end if;
            fo := (others => '0');
            fo(3 downto 0) := std_logic_vector(to_unsigned(m, 4));
            fo(4) := '1';                                    -- attach
            for i in 0 to m - 1 loop
                c := con_input(pos + 1 + i);
                if c = '~' then
                    fo(23 + 8 * i downto 16 + 8 * i) := x"0D";
                else
                    fo(23 + 8 * i downto 16 + 8 * i) := std_logic_vector(to_unsigned(character'pos(c), 8));
                end if;
            end loop;
            -- TAP walk to Capture-DR, the capture edge, 80 shifts, back to idle
            sdr <= '0'; cdr <= '0';
            edge; edge;
            cdr <= '1'; edge; cdr <= '0';
            sdr <= '1';
            for i in 0 to 79 loop
                tdi <= fo(i);
                fi(i) := tdo;          -- the bit presented before this edge
                edge;
            end loop;
            sdr <= '0';
            edge; edge;
            assert fi(7 downto 4) = "1010" report "jtag console: bad frame magic" severity error;
            sent := (sent + m) mod 32;
            pos  := pos + m;
            brp  := to_integer(unsigned(fi(12 downto 8)));
            nb   := to_integer(unsigned(fi(3 downto 0)));
            for i in 0 to nb - 1 loop
                b := fi(23 + 8 * i downto 16 + 8 * i);
                total := total + 1;
                if ol = null then
                    write(ol, string'("[jtag] "));
                elsif ol'length = 0 then
                    write(ol, string'("[jtag] "));
                end if;
                if b = x"0A" then
                    writeline(output, ol);
                elsif b /= x"0D" then
                    write(ol, character'val(to_integer(unsigned(b))));
                end if;
            end loop;
            con_rx_bytes <= total;
        end loop;
        wait;
    end process;
end sim;
