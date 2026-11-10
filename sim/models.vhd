-- Behavioral models of the DE1's external chips, just accurate enough to
-- catch protocol and timing-order mistakes in the controllers.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

-- IS61LV25616: 256K x 16 async SRAM, 10 ns
entity sram_model is
    port (
        a    : in    std_logic_vector(17 downto 0);
        dq   : inout std_logic_vector(15 downto 0);
        we_n : in    std_logic;
        oe_n : in    std_logic;
        ub_n : in    std_logic;
        lb_n : in    std_logic;
        ce_n : in    std_logic
    );
end sram_model;

architecture sim of sram_model is
    type mem_t is array (0 to 262143) of integer range 0 to 65535;
    shared variable mem : mem_t := (others => 0);
begin
    -- write ends on the rising edge of WE
    process (we_n)
        variable w : unsigned(15 downto 0);
        variable i : integer;
    begin
        if rising_edge(we_n) and ce_n = '0' then
            assert not is_x(a) report "SRAM write with X address" severity error;
            i := to_integer(unsigned(a));
            w := to_unsigned(mem(i), 16);
            if lb_n = '0' then w(7 downto 0)  := unsigned(dq(7 downto 0)); end if;
            if ub_n = '0' then w(15 downto 8) := unsigned(dq(15 downto 8)); end if;
            mem(i) := to_integer(w);
        end if;
    end process;

    process (a, oe_n, we_n, ce_n)
    begin
        if ce_n = '0' and oe_n = '0' and we_n = '1' then
            dq <= (others => 'X'), std_logic_vector(to_unsigned(mem(to_integer(unsigned(a))), 16)) after 8 ns;
        else
            dq <= (others => 'Z');
        end if;
    end process;

    process (we_n, a)
    begin
        -- the address must not move while WE is low
        if we_n = '0' and a'event then
            report "SRAM address changed while WE low" severity error;
        end if;
    end process;
end sim;

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

-- IS42S16400: 4 banks x 4096 x 256 x 16. Only BL1, CL2 are modelled.
entity sdram_model is
    port (
        clk   : in    std_logic;
        a     : in    std_logic_vector(11 downto 0);
        ba    : in    std_logic_vector(1 downto 0);
        dq    : inout std_logic_vector(15 downto 0);
        dqm   : in    std_logic_vector(1 downto 0);
        ras_n : in    std_logic;
        cas_n : in    std_logic;
        we_n  : in    std_logic;
        cs_n  : in    std_logic;
        cke   : in    std_logic
    );
end sdram_model;

architecture sim of sdram_model is
    type mem_t is array (0 to 4194303) of integer range 0 to 65535;
    shared variable mem : mem_t := (others => 0);
    type rows_t is array (0 to 3) of integer;
begin
    process
        variable row    : rows_t := (others => -1);
        variable cmd    : std_logic_vector(2 downto 0);
        variable i      : integer;
        variable w      : unsigned(15 downto 0);
        variable rd1    : integer := -1;
        variable mode_ok : boolean := false;
        variable act_t  : time := 0 ns;
        variable first  : boolean := true;
    begin
        if first then
            dq <= (others => 'Z');
            first := false;
        end if;
        wait until rising_edge(clk);
        -- CL2: a READ sampled at the previous edge drives its data tAC after
        -- this one, and it is sampled at the next
        if rd1 >= 0 then
            dq <= (others => 'X'), std_logic_vector(to_unsigned(mem(rd1), 16)) after 5 ns,
                  (others => 'Z') after 22 ns;
        end if;
        rd1 := -1;

        if cs_n = '0' and cke = '1' then
            cmd := ras_n & cas_n & we_n;
            case cmd is
                when "011" =>    -- ACTIVE
                    assert row(to_integer(unsigned(ba))) = -1
                        report "SDRAM activate on an open bank" severity error;
                    row(to_integer(unsigned(ba))) := to_integer(unsigned(a));
                    act_t := now;
                when "101" | "100" =>   -- READ / WRITE
                    assert mode_ok report "SDRAM access before mode set" severity error;
                    assert row(to_integer(unsigned(ba))) /= -1
                        report "SDRAM access to a closed bank" severity error;
                    assert now - act_t >= 20 ns report "SDRAM tRCD violated" severity error;
                    i := (row(to_integer(unsigned(ba))) * 4 + to_integer(unsigned(ba))) * 256
                         + to_integer(unsigned(a(7 downto 0)));
                    if cmd = "101" then
                        rd1 := i;
                    else
                        w := to_unsigned(mem(i), 16);
                        if dqm(0) = '0' then w(7 downto 0)  := unsigned(dq(7 downto 0)); end if;
                        if dqm(1) = '0' then w(15 downto 8) := unsigned(dq(15 downto 8)); end if;
                        mem(i) := to_integer(w);
                    end if;
                    if a(10) = '1' then
                        row(to_integer(unsigned(ba))) := -1;
                    end if;
                when "010" =>    -- PRECHARGE
                    if a(10) = '1' then
                        row := (others => -1);
                    else
                        row(to_integer(unsigned(ba))) := -1;
                    end if;
                when "001" =>    -- REFRESH
                    assert row = (0 to 3 => -1) report "SDRAM refresh with a bank open" severity error;
                when "000" =>    -- MODE
                    assert a(6 downto 4) = "010" and a(2 downto 0) = "000"
                        report "SDRAM mode is not CL2 BL1" severity error;
                    mode_ok := true;
                when others => null;
            end case;
        end if;
    end process;
end sim;

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.textio.all;
use ieee.std_logic_textio.all;

-- 4 MB x 8 NOR flash, read only, 70 ns, loaded from a hex file (one byte a line)
entity flash_model is
    generic (IMAGE : string := "build/flash.hex");
    port (
        a     : in  std_logic_vector(21 downto 0);
        dq    : inout std_logic_vector(7 downto 0);
        oe_n  : in  std_logic;
        we_n  : in  std_logic
    );
end flash_model;

architecture sim of flash_model is
    type mem_t is array (0 to 4194303) of integer range 0 to 255;
    shared variable mem : mem_t := (others => 255);
    signal loaded : boolean := false;
begin
    process
        file f : text;
        variable st : file_open_status;
        variable l  : line;
        variable b  : std_logic_vector(7 downto 0);
        variable i  : integer := 0;
    begin
        file_open(st, f, IMAGE, read_mode);
        if st = open_ok then
            while not endfile(f) loop
                readline(f, l);
                hread(l, b);
                mem(i) := to_integer(unsigned(b));
                i := i + 1;
            end loop;
            report "flash: loaded " & integer'image(i) & " bytes from " & IMAGE;
        else
            report "flash: no image " & IMAGE & ", reads as FF" severity warning;
        end if;
        loaded <= true;
        wait;
    end process;

    process (a, oe_n, loaded)
    begin
        if oe_n = '0' then
            dq <= (others => 'X'), std_logic_vector(to_unsigned(mem(to_integer(unsigned(a))), 8)) after 70 ns;
        else
            dq <= (others => 'Z');
        end if;
    end process;
end sim;
