-- Boot ROM slave, 4 KB in M4K. One word per cycle after the first.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.boot_rom_data.all;

entity boot_rom is
    port (
        clk   : in  std_logic;
        req   : in  std_logic;
        addr  : in  std_logic_vector(31 downto 0);
        burst : in  std_logic;
        ack   : out std_logic;
        rdata : out std_logic_vector(31 downto 0)
    );
end boot_rom;

architecture rtl of boot_rom is
    signal busy  : std_logic := '0';
    signal count : unsigned(1 downto 0) := "00";
    signal ra    : unsigned(9 downto 0) := (others => '0');
    signal ack_r : std_logic := '0';
begin
    rdata <= ROM_INIT(to_integer(ra));
    ack   <= ack_r;

    process (clk)
        variable cnt : unsigned(1 downto 0);
    begin
        if rising_edge(clk) then
            ack_r <= '0';
            if busy = '0' then
                if req = '1' then
                    busy  <= '1';
                    count <= "00";
                    ra    <= unsigned(addr(11 downto 2));
                    ack_r <= '1';
                end if;
            else
                -- ack_r is high for the word currently on rdata
                if ack_r = '1' then
                    if burst = '0' or count = 3 then
                        busy <= '0';
                    else
                        cnt   := count + 1;
                        count <= cnt;
                        ra    <= unsigned(addr(11 downto 4)) & cnt;
                        ack_r <= '1';
                    end if;
                end if;
            end if;
        end if;
    end process;
end rtl;
