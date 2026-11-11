-- Memory bus: two masters (instruction fill, data cache) onto five slaves
-- picked by address bits 31..28 (0x8 is the SDRAM again, for Linux). The
-- data side wins a tie. A transaction is one ack, or four for a burst; the
-- owner keeps the bus until the last one.
--
-- Slave protocol: req is held steady for the whole transaction; the slave
-- pulses ack once per word, never in the same cycle req first appears.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity membus is
    port (
        clk       : in  std_logic;
        reset     : in  std_logic;
        -- master 0: instruction cache (burst reads only)
        i_req     : in  std_logic;
        i_addr    : in  std_logic_vector(31 downto 0);
        i_ack     : out std_logic;
        -- master 1: data cache
        d_req     : in  std_logic;
        d_addr    : in  std_logic_vector(31 downto 0);
        d_we      : in  std_logic;
        d_wstrb   : in  std_logic_vector(3 downto 0);
        d_wdata   : in  std_logic_vector(31 downto 0);
        d_burst   : in  std_logic;
        d_ack     : out std_logic;
        -- shared read data back to both masters
        rdata     : out std_logic_vector(31 downto 0);
        -- to the slaves (shared request lines, one req per slave)
        s_addr    : out std_logic_vector(31 downto 0);
        s_we      : out std_logic;
        s_wstrb   : out std_logic_vector(3 downto 0);
        s_wdata   : out std_logic_vector(31 downto 0);
        s_burst   : out std_logic;
        rom_req   : out std_logic;
        rom_ack   : in  std_logic;
        rom_rdata : in  std_logic_vector(31 downto 0);
        sram_req  : out std_logic;
        sram_ack  : in  std_logic;
        sram_rdata: in  std_logic_vector(31 downto 0);
        sdram_req : out std_logic;
        sdram_ack : in  std_logic;
        sdram_rdata : in std_logic_vector(31 downto 0);
        flash_req : out std_logic;
        flash_ack : in  std_logic;
        flash_rdata : in std_logic_vector(31 downto 0);
        io_req    : out std_logic;
        io_ack    : in  std_logic;
        io_rdata  : in  std_logic_vector(31 downto 0)
    );
end membus;

architecture rtl of membus is
    signal busy    : std_logic := '0';
    signal owner_r : std_logic := '0';      -- '1' = data side
    signal owner   : std_logic;
    signal req     : std_logic;
    signal burst   : std_logic;
    signal addr    : std_logic_vector(31 downto 0);
    signal ack     : std_logic;
    signal count   : unsigned(1 downto 0) := "00";
    signal bad_ack : std_logic := '0';
    signal region  : std_logic_vector(3 downto 0);
begin
    owner <= owner_r when busy = '1' else d_req;
    req   <= d_req when owner = '1' else i_req;
    addr  <= d_addr when owner = '1' else i_addr;
    burst <= d_burst when owner = '1' else '1';

    s_addr  <= addr;
    s_we    <= d_we when owner = '1' else '0';
    s_wstrb <= d_wstrb;
    s_wdata <= d_wdata;
    s_burst <= burst;

    region <= addr(31 downto 28);
    rom_req   <= req when region = x"0" else '0';
    sram_req  <= req when region = x"1" else '0';
    sdram_req <= req when region = x"2" or region = x"8" else '0';   -- 0x8: alias
    flash_req <= req when region = x"3" else '0';
    io_req    <= req when region = x"F" else '0';

    process (region, rom_ack, rom_rdata, sram_ack, sram_rdata, sdram_ack, sdram_rdata,
             flash_ack, flash_rdata, io_ack, io_rdata, bad_ack)
    begin
        case region is
            when x"0"   => ack <= rom_ack;   rdata <= rom_rdata;
            when x"1"   => ack <= sram_ack;  rdata <= sram_rdata;
            when x"2" | x"8" => ack <= sdram_ack; rdata <= sdram_rdata;
            when x"3"   => ack <= flash_ack; rdata <= flash_rdata;
            when x"F"   => ack <= io_ack;    rdata <= io_rdata;
            when others => ack <= bad_ack;   rdata <= (others => '0');
        end case;
    end process;

    i_ack <= ack when owner = '0' else '0';
    d_ack <= ack when owner = '1' else '0';

    process (clk)
        variable last : boolean;
    begin
        if rising_edge(clk) then
            -- unmapped addresses answer with zeros so nothing hangs
            bad_ack <= '0';
            if req = '1' and region /= x"0" and region /= x"1" and region /= x"2" and region /= x"8"
               and region /= x"3" and region /= x"F" and bad_ack = '0' then
                bad_ack <= '1';
            end if;

            if busy = '0' then
                if req = '1' then
                    busy    <= '1';
                    owner_r <= owner;
                    count   <= "00";
                end if;
            end if;
            if ack = '1' then
                last := burst = '0' or count = 3;
                count <= count + 1;
                if last then
                    busy <= '0';
                end if;
            end if;

            if reset = '1' then
                busy <= '0';
            end if;
        end if;
    end process;
end rtl;
