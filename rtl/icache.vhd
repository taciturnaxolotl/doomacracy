-- Instruction cache: direct mapped, 16-byte lines, read only.
-- The RAMs are read with raddr, which the CPU computes combinationally; tag
-- compares and fills use addr, which comes from a register. A hit answers
-- in the first cycle of a request when the CPU primed the read the cycle
-- before, otherwise one cycle later.
-- Misses fill the whole line with a 4-word burst on the memory side.
-- inval (FENCE.I) clears every tag the same way reset does, one line a
-- cycle; requests wait until that is done. The CPU only raises it while
-- the cache is idle (in EXEC, with no request outstanding).
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity icache is
    generic (IB : integer := 8);  -- index bits: 2**IB lines of 16 bytes
    port (
        clk     : in  std_logic;
        reset   : in  std_logic;
        prime   : in  std_logic;   -- next cycle's addr is this cycle's raddr
        raddr   : in  std_logic_vector(31 downto 0);
        req     : in  std_logic;
        addr    : in  std_logic_vector(31 downto 0);
        inval   : in  std_logic;
        ack     : out std_logic;
        rdata   : out std_logic_vector(31 downto 0);
        m_req   : out std_logic;
        m_addr  : out std_logic_vector(31 downto 0);
        m_ack   : in  std_logic;
        m_rdata : in  std_logic_vector(31 downto 0)
    );
end icache;

architecture rtl of icache is
    constant TW : integer := 32 - 4 - IB;
    type state_t is (S_INIT, S_IDLE, S_FILL);
    signal state  : state_t := S_INIT;
    signal primed : std_logic := '0';
    signal count  : unsigned(1 downto 0) := "00";
    signal init_i : unsigned(IB - 1 downto 0) := (others => '0');

    signal tag_we, data_we : std_logic;
    signal tag_wa  : std_logic_vector(IB - 1 downto 0);
    signal tag_wd, tag_q : std_logic_vector(TW downto 0);   -- valid & tag
    signal data_wa : std_logic_vector(IB + 1 downto 0);
    signal hit, ack_i : std_logic;
begin
    tags : entity work.sdpram
        generic map (IB, TW + 1)
        port map (clk, tag_we, tag_wa, tag_wd, raddr(IB + 3 downto 4), tag_q);

    data : entity work.sdpram
        generic map (IB + 2, 32)
        port map (clk, data_we, data_wa, m_rdata, raddr(IB + 3 downto 2), rdata);

    hit   <= '1' when primed = '1' and tag_q(TW) = '1' and tag_q(TW - 1 downto 0) = addr(31 downto 4 + IB) else '0';
    ack_i <= '1' when state = S_IDLE and req = '1' and hit = '1' else '0';
    ack   <= ack_i;

    m_req  <= '1' when state = S_FILL else '0';
    m_addr <= addr(31 downto 4) & "0000";

    data_we <= '1' when state = S_FILL and m_ack = '1' else '0';
    data_wa <= addr(IB + 3 downto 4) & std_logic_vector(count);

    tag_we <= '1' when state = S_INIT or (state = S_FILL and m_ack = '1' and count = 3) else '0';
    tag_wa <= std_logic_vector(init_i) when state = S_INIT else addr(IB + 3 downto 4);
    tag_wd <= (others => '0') when state = S_INIT else '1' & addr(31 downto 4 + IB);

    process (clk)
    begin
        if rising_edge(clk) then
            if state /= S_FILL and state /= S_INIT and (prime = '1' or (req = '1' and ack_i = '0')) then
                primed <= '1';
            else
                primed <= '0';
            end if;

            case state is
                when S_INIT =>
                    init_i <= init_i + 1;
                    if init_i = 2 ** IB - 1 then
                        state <= S_IDLE;
                    end if;
                when S_IDLE =>
                    if inval = '1' then
                        state  <= S_INIT;
                        init_i <= (others => '0');
                        primed <= '0';
                    elsif req = '1' and primed = '1' and hit = '0' then
                        state <= S_FILL;
                        count <= "00";
                    end if;
                when S_FILL =>
                    if m_ack = '1' then
                        count <= count + 1;
                        if count = 3 then
                            state <= S_IDLE;
                        end if;
                    end if;
            end case;

            if reset = '1' then
                state  <= S_INIT;
                init_i <= (others => '0');
                primed <= '0';
            end if;
        end if;
    end process;
end rtl;
