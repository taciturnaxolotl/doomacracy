-- CPU against an ideal 64 KB memory with uneven latencies on both ports.
-- Loads a hex image (one 32-bit word per line), prints stores to 0xF0000000
-- as characters, stops on ebreak. The instruction side reads the word at
-- i_raddr, as the I-cache RAM does: the CPU may move its fetch address
-- before an ack, and an ack is for the address it holds in that cycle.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.textio.all;
use ieee.std_logic_textio.all;

entity tb_cpu is
    generic (IMAGE : string := "sim/cputest/torture.hex");
end tb_cpu;

architecture sim of tb_cpu is
    signal clk   : std_logic := '0';
    signal reset : std_logic := '1';
    signal done  : boolean := false;

    signal i_prime, i_req, i_ack, d_req, d_we, d_ack, halted, retire : std_logic;
    signal i_raddr, i_addr, i_rdata, d_raddr, d_addr, d_wdata, d_rdata : std_logic_vector(31 downto 0);
    signal d_wstrb : std_logic_vector(3 downto 0);
    signal retire_pc, retire_data : std_logic_vector(31 downto 0);
    signal retire_rd : std_logic_vector(4 downto 0);

    type mem_t is array (0 to 16383) of std_logic_vector(31 downto 0);

    impure function load return mem_t is
        file f : text open read_mode is IMAGE;
        variable l : line;
        variable m : mem_t := (others => (others => '0'));
        variable w : std_logic_vector(31 downto 0);
        variable i : integer := 0;
    begin
        while not endfile(f) loop
            readline(f, l);
            hread(l, w);
            m(i) := w;
            i := i + 1;
        end loop;
        return m;
    end function;
begin
    clk <= not clk after 10 ns when not done;

    dut : entity work.cpu
        port map (clk, reset, i_prime, i_raddr, i_req, i_addr, i_ack, i_rdata,
                  d_raddr, d_req, d_addr, d_we, d_wstrb, d_wdata, d_ack, d_rdata, '1',
                  open, '0', '0', '0', (63 downto 0 => '0'), '0',
                  halted, retire, retire_pc, retire_rd, retire_data);

    process
        variable mem    : mem_t := load;
        variable iwait  : integer := 0;
        variable dwait  : integer := 0;
        variable lfsr   : unsigned(15 downto 0) := x"ACE1";
        variable l      : line;
        variable w      : std_logic_vector(31 downto 0);
        variable n      : integer := 0;
        variable cycles : integer := 0;
        variable ibusy, dbusy : boolean := false;
        variable a      : integer;
    begin
        i_ack <= '0'; d_ack <= '0';
        wait until rising_edge(clk);
        wait until rising_edge(clk);
        reset <= '0';
        loop
            wait until rising_edge(clk);
            cycles := cycles + 1;
            i_ack <= '0'; d_ack <= '0';
            lfsr := lfsr(14 downto 0) & (lfsr(15) xor lfsr(13) xor lfsr(12) xor lfsr(10));

            -- requests are sampled at this edge; answer after a few cycles
            if i_ack = '0' and i_req = '1' and not ibusy then
                ibusy := true; iwait := to_integer(lfsr(1 downto 0));
            end if;
            if ibusy then
                if iwait = 0 then
                    a := to_integer(unsigned(i_raddr(15 downto 2)));  -- next cycle's i_addr
                    i_rdata <= mem(a);
                    i_ack <= '1';
                    ibusy := false;
                else
                    iwait := iwait - 1;
                end if;
            end if;

            if d_req = '1' and not dbusy and d_ack = '0' then
                dbusy := true; dwait := to_integer(lfsr(3 downto 2));
            end if;
            if dbusy then
                if dwait = 0 then
                    if d_addr = x"F0000000" then
                        if d_we = '1' then
                            if character'val(to_integer(unsigned(d_wdata(7 downto 0)))) = LF then
                                writeline(output, l);
                            else
                                write(l, character'val(to_integer(unsigned(d_wdata(7 downto 0)))));
                            end if;
                        end if;
                        d_rdata <= (others => '0');
                    else
                        a := to_integer(unsigned(d_addr(15 downto 2)));
                        if d_we = '1' then
                            w := mem(a);
                            for b in 0 to 3 loop
                                if d_wstrb(b) = '1' then
                                    w(8 * b + 7 downto 8 * b) := d_wdata(8 * b + 7 downto 8 * b);
                                end if;
                            end loop;
                            mem(a) := w;
                        end if;
                        d_rdata <= mem(a);
                    end if;
                    d_ack <= '1';
                    dbusy := false;
                else
                    dwait := dwait - 1;
                end if;
            end if;

            if retire = '1' then n := n + 1; end if;
            exit when halted = '1' or cycles > 60000000;
        end loop;
        write(l, string'("retired ")); write(l, n);
        write(l, string'(" cycles ")); write(l, cycles);
        write(l, string'(" halted pc ")); hwrite(l, retire_pc);
        writeline(output, l);
        done <= true;
        wait;
    end process;
end sim;
