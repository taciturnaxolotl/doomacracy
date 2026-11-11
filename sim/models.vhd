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
-- Up to two raw binary files can be preloaded at byte offsets (a Linux
-- kernel and its device tree); the controller's halfword address is
-- row & bank & column, which is also the index into mem.
entity sdram_model is
    generic (
        IMG0    : string  := "";
        IMG0_AT : natural := 0;
        IMG1    : string  := "";
        IMG1_AT : natural := 0
    );
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
    type bin_file is file of character;

    procedure preload(name : string; at : natural) is
        file f      : bin_file;
        variable st : file_open_status;
        variable c  : character;
        variable i  : natural := at;
    begin
        if name = "" then
            return;
        end if;
        file_open(st, f, name, read_mode);
        assert st = open_ok report "sdram: cannot open " & name severity failure;
        while not endfile(f) and i < 2 * mem'length loop
            read(f, c);
            if i mod 2 = 0 then
                mem(i / 2) := (mem(i / 2) / 256) * 256 + character'pos(c);
            else
                mem(i / 2) := (mem(i / 2) mod 256) + 256 * character'pos(c);
            end if;
            i := i + 1;
        end loop;
        file_close(f);
        report "sdram: loaded " & integer'image(i - at) & " bytes from " & name
               & " at " & integer'image(at);
    end procedure;
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
            preload(IMG0, IMG0_AT);
            preload(IMG1, IMG1_AT);
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

-- 4 MB x 8 NOR flash, loaded from a hex file (one byte a line). Knows the
-- AMD byte-mode commands the boot ROM uses: reset, byte program and chip
-- erase. While an operation runs, DQ7 reads inverted (0 for an erase) and
-- DQ6 toggles on every read.
entity flash_model is
    generic (
        IMAGE      : string := "build/flash.hex";
        PROG_TIME  : time   := 2 us;     -- real chip: about 9 us
        ERASE_TIME : time   := 50 us     -- real chip: tens of seconds
    );
    port (
        a     : in  std_logic_vector(21 downto 0);
        dq    : inout std_logic_vector(7 downto 0);
        oe_n  : in  std_logic;
        we_n  : in  std_logic;
        ce_n  : in  std_logic
    );
end flash_model;

architecture sim of flash_model is
    type mem_t is array (0 to 4194303) of integer range 0 to 255;
    shared variable mem : mem_t := (others => 255);
    signal loaded   : boolean := false;
    signal busy     : boolean := false;
    signal toggle   : std_logic := '0';
    signal dq7_busy : std_logic := '0';   -- what DQ7 reads during the operation
    signal rd_event : boolean := false;
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
            report "flash: no image " & IMAGE & ", starts erased";
        end if;
        loaded <= true;
        wait;
    end process;

    -- command interpreter, on the rising edge of WE
    process
        variable cyc   : integer := 0;
        variable mode  : integer := 0;  -- 0 read, 1 program next, 2 erase setup
        variable ad, v : integer;
        variable nprog : integer := 0;
    begin
        wait until rising_edge(we_n) and ce_n = '0';
        assert oe_n = '1' report "flash: write with OE low" severity error;
        assert not busy report "flash: write while busy" severity error;
        ad := to_integer(unsigned(a));
        v  := to_integer(unsigned(dq));
        if mode = 1 then
            mem(ad) := to_integer(to_unsigned(mem(ad), 8) and to_unsigned(v, 8));
            nprog := nprog + 1;
            mode := 0; cyc := 0;
            dq7_busy <= not dq(7);
            busy <= true; wait for PROG_TIME; busy <= false;
        elsif v = 16#F0# then
            mode := 0; cyc := 0;
        elsif cyc = 0 and ad = 16#AAA# and v = 16#AA# then cyc := 1;
        elsif cyc = 1 and ad = 16#555# and v = 16#55# then cyc := 2;
        elsif cyc = 2 and ad = 16#AAA# and v = 16#A0# then mode := 1; cyc := 0;
        elsif cyc = 2 and ad = 16#AAA# and v = 16#80# then mode := 2; cyc := 0;
        elsif cyc = 2 and ad = 16#AAA# and v = 16#10# and mode = 2 then
            report "flash: chip erase";
            for i in mem'range loop mem(i) := 255; end loop;
            mode := 0; cyc := 0;
            dq7_busy <= '0';
            busy <= true; wait for ERASE_TIME; busy <= false;
        else
            report "flash: unexpected write " & integer'image(v) & " to " & integer'image(ad) severity error;
            cyc := 0;
        end if;
    end process;

    -- each read (OE falling, or address change with OE low) while busy
    -- flips DQ6
    process (a, oe_n)
    begin
        if busy and oe_n = '0' and (oe_n'event or a'event) then
            toggle <= not toggle;
        end if;
    end process;

    process (a, oe_n, we_n, ce_n, loaded, busy, toggle, dq7_busy)
        variable v : std_logic_vector(7 downto 0);
    begin
        if oe_n = '0' and we_n = '1' and ce_n = '0' then
            -- a new read cycle is undefined until tACC; status changing in
            -- the middle of one just changes the output
            if busy then
                v := dq7_busy & toggle & "000000";
            else
                v := std_logic_vector(to_unsigned(mem(to_integer(unsigned(a))), 8));
            end if;
            if a'event or oe_n'event then
                dq <= (others => 'X'), v after 70 ns;
            else
                dq <= v;
            end if;
        else
            dq <= (others => 'Z');
        end if;
    end process;
end sim;
