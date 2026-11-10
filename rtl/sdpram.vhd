-- Simple dual-port RAM: one write port, one read port with a registered read
-- address, which is the shape Quartus maps onto M4K blocks.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity sdpram is
    generic (
        AW : integer := 8;
        DW : integer := 32
    );
    port (
        clk   : in  std_logic;
        we    : in  std_logic;
        waddr : in  std_logic_vector(AW - 1 downto 0);
        wdata : in  std_logic_vector(DW - 1 downto 0);
        raddr : in  std_logic_vector(AW - 1 downto 0);
        rdata : out std_logic_vector(DW - 1 downto 0)
    );
end sdpram;

architecture rtl of sdpram is
    type mem_t is array (0 to 2 ** AW - 1) of std_logic_vector(DW - 1 downto 0);
    signal mem : mem_t := (others => (others => '0'));
    signal ra  : std_logic_vector(AW - 1 downto 0) := (others => '0');
begin
    process (clk)
    begin
        if rising_edge(clk) then
            if we = '1' then
                mem(to_integer(unsigned(waddr))) <= wdata;
            end if;
            ra <= raddr;
        end if;
    end process;
    rdata <= mem(to_integer(unsigned(ra)));
end rtl;
