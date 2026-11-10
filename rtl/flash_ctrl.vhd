-- 8-bit NOR flash (S29AL032D in byte mode, 70/90 ns). Reads take four byte
-- cycles per word, each WAIT_CYCLES long, with OE pulsed high between them
-- so each is a separate read cycle to the chip (status bits depend on it). Byte stores become one bus write
-- cycle on the chip (address and data set up, WE low, WE high, hold), which
-- is all the boot ROM needs to send the erase and program commands.
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
        we      : in  std_logic;
        wdata   : in  std_logic_vector(31 downto 0);
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
    type state_t is (S_IDLE, S_READ, S_WSETUP, S_WPULSE, S_WHOLD);
    signal state : state_t := S_IDLE;
    signal byte  : unsigned(4 downto 0) := (others => '0');  -- word(3) & byte(2)
    signal timer : integer range 0 to WAIT_CYCLES := 0;
    signal a_r   : std_logic_vector(21 downto 0) := (others => '0');
    signal word  : std_logic_vector(31 downto 0) := (others => '0');
    signal ack_r : std_logic := '0';
    signal oe_n  : std_logic := '0';
    signal we_n  : std_logic := '1';
    signal dq_o  : std_logic_vector(7 downto 0) := (others => '0');
    signal dq_oe : std_logic := '0';
    signal dq_in : std_logic_vector(7 downto 0);
begin
    FL_ADDR  <= a_r;
    FL_DQ    <= dq_o when dq_oe = '1' else (others => 'Z');
    FL_OE_N  <= oe_n;
    FL_WE_N  <= we_n;
    FL_RST_N <= not reset;
    ack      <= ack_r;
    rdata    <= word;
    dq_in    <= FL_DQ;

    process (clk)
        variable w : std_logic_vector(31 downto 0);
    begin
        if rising_edge(clk) then
            ack_r <= '0';
            case state is
                when S_IDLE =>
                    oe_n <= '1';
                    if req = '1' and ack_r = '0' then
                        timer <= WAIT_CYCLES;
                        byte  <= (others => '0');
                        if we = '1' then
                            -- one byte write; the CPU replicates a byte store
                            -- across all lanes, so lane 0 is the byte
                            oe_n  <= '1';
                            a_r   <= addr(21 downto 0);
                            dq_o  <= wdata(7 downto 0);
                            state <= S_WSETUP;
                        else
                            if burst = '1' then
                                a_r <= addr(21 downto 4) & "0000";
                            else
                                a_r <= addr(21 downto 2) & "00";
                            end if;
                            oe_n  <= '0';
                            state <= S_READ;
                        end if;
                    end if;

                when S_READ =>
                    if timer /= 0 then
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
                                state <= S_IDLE;
                            end if;
                        end if;
                        byte  <= byte + 1;
                        a_r   <= std_logic_vector(unsigned(a_r) + 1);
                        timer <= WAIT_CYCLES;
                        oe_n  <= '1';   -- end this read cycle; the next starts below
                    end if;
                    if timer = WAIT_CYCLES then
                        oe_n <= '0';
                    end if;

                -- write cycle: 40 ns setup with OE high, 120 ns WE low,
                -- 40 ns hold with the data still driven
                when S_WSETUP =>
                    dq_oe <= '1';
                    if timer > WAIT_CYCLES - 2 then
                        timer <= timer - 1;
                    else
                        we_n  <= '0';
                        timer <= WAIT_CYCLES;
                        state <= S_WPULSE;
                    end if;
                when S_WPULSE =>
                    if timer /= 0 then
                        timer <= timer - 1;
                    else
                        we_n  <= '1';
                        timer <= 2;
                        state <= S_WHOLD;
                    end if;
                when S_WHOLD =>
                    if timer /= 0 then
                        timer <= timer - 1;
                    else
                        dq_oe <= '0';
                        ack_r <= '1';
                        state <= S_IDLE;
                    end if;
            end case;
            if reset = '1' then
                state <= S_IDLE;
                we_n  <= '1';
                dq_oe <= '0';
            end if;
        end if;
    end process;
end rtl;
