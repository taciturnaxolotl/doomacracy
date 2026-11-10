-- 8N1 UART, both directions, with a one-byte receive holding register.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity uart is
    generic (DIVISOR : integer := 434);  -- 50 MHz / 115200
    port (
        clk      : in  std_logic;
        reset    : in  std_logic;
        tx_start : in  std_logic;
        tx_data  : in  std_logic_vector(7 downto 0);
        tx_ready : out std_logic;
        rx_valid : out std_logic;   -- one cycle per received byte
        rx_data  : out std_logic_vector(7 downto 0);
        txd      : out std_logic;
        rxd      : in  std_logic
    );
end uart;

architecture rtl of uart is
    signal tx_shift : std_logic_vector(9 downto 0) := (others => '1');
    signal tx_bits  : integer range 0 to 10 := 0;
    signal tx_timer : integer range 0 to DIVISOR := 0;

    signal rx_sync  : std_logic_vector(1 downto 0) := "11";
    signal rx_busy  : std_logic := '0';
    signal rx_timer : integer range 0 to DIVISOR * 3 / 2 := 0;
    signal rx_bits  : integer range 0 to 9 := 0;
    signal rx_shift : std_logic_vector(7 downto 0) := (others => '0');
begin
    txd      <= tx_shift(0);
    tx_ready <= '1' when tx_bits = 0 else '0';

    process (clk)
    begin
        if rising_edge(clk) then
            if tx_bits = 0 then
                if tx_start = '1' then
                    tx_shift <= '1' & tx_data & '0';
                    tx_bits  <= 10;
                    tx_timer <= DIVISOR - 1;
                end if;
            elsif tx_timer = 0 then
                tx_shift <= '1' & tx_shift(9 downto 1);
                tx_bits  <= tx_bits - 1;
                tx_timer <= DIVISOR - 1;
            else
                tx_timer <= tx_timer - 1;
            end if;

            rx_valid <= '0';
            rx_sync  <= rx_sync(0) & rxd;
            if rx_busy = '0' then
                if rx_sync(1) = '0' then
                    rx_busy  <= '1';
                    rx_timer <= DIVISOR * 3 / 2;  -- middle of bit 0
                    rx_bits  <= 0;
                end if;
            elsif rx_timer = 0 then
                if rx_bits = 8 then
                    rx_busy <= '0';
                    if rx_sync(1) = '1' then
                        rx_data  <= rx_shift;
                        rx_valid <= '1';
                    end if;
                else
                    rx_shift <= rx_sync(1) & rx_shift(7 downto 1);
                    rx_bits  <= rx_bits + 1;
                    rx_timer <= DIVISOR - 1;
                end if;
            else
                rx_timer <= rx_timer - 1;
            end if;

            if reset = '1' then
                tx_bits <= 0;
                tx_shift <= (others => '1');
                rx_busy <= '0';
            end if;
        end if;
    end process;
end rtl;
