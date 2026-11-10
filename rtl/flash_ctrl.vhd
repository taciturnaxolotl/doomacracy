-- Read-only 8-bit NOR flash (S29AL032D, 70/90 ns). Four byte reads per
-- word, each given WAIT cycles from address to sample. Bursts are allowed
-- but the caches never ask for them here.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity flash_ctrl is
    generic (WAIT_CYCLES : integer := 6);  -- 120 ns
    port (
        clk     : in  std_logic;
        reset   : in  std_logic;
        req     : in  std_logic;
        addr    : in  std_logic_vector(31 downto 0);
        burst   : in  std_logic;
        ack     : out std_logic;
        rdata   : out std_logic_vector(31 downto 0);
        FL_ADDR : out std_logic_vector(21 downto 0);
        FL_DQ   : inout std_logic_vector(7 downto 0);
        FL_OE_N : out std_logic;
        FL_WE_N : out std_logic;
        FL_RST_N: out std_logic
    );
end flash_ctrl;

architecture rtl of flash_ctrl is
    signal busy  : std_logic := '0';
    signal byte  : unsigned(4 downto 0) := (others => '0');  -- word(3) & byte(2)
    signal timer : integer range 0 to WAIT_CYCLES := 0;
    signal a_r   : std_logic_vector(21 downto 0) := (others => '0');
    signal word  : std_logic_vector(31 downto 0) := (others => '0');
    signal ack_r : std_logic := '0';
    signal dq_in : std_logic_vector(7 downto 0);
begin
    FL_ADDR  <= a_r;
    FL_DQ    <= (others => 'Z');
    FL_OE_N  <= '0';
    FL_WE_N  <= '1';
    FL_RST_N <= not reset;
    ack      <= ack_r;
    rdata    <= word;
    dq_in    <= FL_DQ;

    process (clk)
        variable w : std_logic_vector(31 downto 0);
    begin
        if rising_edge(clk) then
            ack_r <= '0';
            if busy = '0' then
                if req = '1' and ack_r = '0' then
                    busy  <= '1';
                    byte  <= (others => '0');
                    timer <= WAIT_CYCLES;
                    if burst = '1' then
                        a_r <= addr(21 downto 4) & "0000";
                    else
                        a_r <= addr(21 downto 2) & "00";
                    end if;
                end if;
            elsif timer /= 0 then
                timer <= timer - 1;
            else
                w := word;
                case byte(1 downto 0) is
                    when "00"   => w(7 downto 0)   := dq_in;
                    when "01"   => w(15 downto 8)  := dq_in;
                    when "10"   => w(23 downto 16) := dq_in;
                    when others => w(31 downto 24) := dq_in;
                end case;
                word <= w;
                if byte(1 downto 0) = "11" then
                    ack_r <= '1';
                    if burst = '0' or byte(4 downto 2) = "011" then
                        busy <= '0';
                    end if;
                end if;
                byte  <= byte + 1;
                a_r   <= std_logic_vector(unsigned(a_r) + 1);
                timer <= WAIT_CYCLES;
            end if;
            if reset = '1' then
                busy <= '0';
            end if;
        end if;
    end process;
end rtl;
