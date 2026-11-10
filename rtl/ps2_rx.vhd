-- PS/2 byte receiver. Same filtering as tetricide's ps2_keys, but it hands
-- every good byte (including E0 and F0 prefixes) to software instead of
-- decoding keys itself.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity ps2_rx is
    port (
        clk      : in  std_logic;  -- 50 MHz
        reset    : in  std_logic;
        ps2_clk  : in  std_logic;
        ps2_data : in  std_logic;
        valid    : out std_logic;  -- one cycle per received byte
        data     : out std_logic_vector(7 downto 0)
    );
end ps2_rx;

architecture rtl of ps2_rx is
    constant TIMEOUT : integer := 65535;  -- ~1.3 ms without a clock edge
    signal clk_sync : std_logic_vector(1 downto 0) := "11";
    signal dat_sync : std_logic_vector(1 downto 0) := "11";
    signal clk_hist : std_logic_vector(15 downto 0) := (others => '1');
    signal clk_filt : std_logic := '1';
    signal shift    : std_logic_vector(10 downto 0) := (others => '0');
    signal nbits    : integer range 0 to 11 := 0;
    signal idle     : integer range 0 to TIMEOUT := 0;
begin
    process (clk)
        variable frame  : std_logic_vector(10 downto 0);
        variable parity : std_logic;
    begin
        if rising_edge(clk) then
            valid    <= '0';
            clk_sync <= clk_sync(0) & ps2_clk;
            dat_sync <= dat_sync(0) & ps2_data;
            clk_hist <= clk_hist(14 downto 0) & clk_sync(1);

            if idle < TIMEOUT then
                idle <= idle + 1;
            else
                nbits <= 0;
            end if;

            if clk_hist = x"FFFF" then
                clk_filt <= '1';
            elsif clk_hist = x"0000" and clk_filt = '1' then
                clk_filt <= '0';
                idle     <= 0;
                frame    := dat_sync(1) & shift(10 downto 1);
                shift    <= frame;
                if nbits = 10 then
                    nbits  <= 0;
                    parity := '0';
                    for i in 1 to 9 loop
                        parity := parity xor frame(i);
                    end loop;
                    if frame(0) = '0' and frame(10) = '1' and parity = '1' then
                        data  <= frame(8 downto 1);
                        valid <= '1';
                    end if;
                else
                    nbits <= nbits + 1;
                end if;
            end if;

            if reset = '1' then
                nbits <= 0;
            end if;
        end if;
    end process;
end rtl;
