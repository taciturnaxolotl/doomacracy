-- Instruction cache: direct mapped, 16-byte lines, read only.
-- The RAMs are read with raddr, the CPU's next fetch address; the hit check
-- uses addr, which comes from a register. A hit answers in the first cycle
-- of a request when the CPU primed the read the cycle before, otherwise one
-- cycle later.
--
-- A miss latches its line address and fills the whole line with a 4-word
-- burst, so the CPU is free to move its address (a redirect) meanwhile.
-- While the line fills, the tag RAM looks up the next line; if that one is
-- missing it is prefetched right after. Hits are served during the
-- prefetch, except on the line being written.
--
-- inval (FENCE.I) is remembered until the cache is idle, then every tag is
-- cleared, one line a cycle, the way reset does; nothing hits meanwhile.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity icache is
    generic (
        IB       : integer := 8;      -- index bits: 2**IB lines of 16 bytes
        PREFETCH : boolean := true
    );
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
    type state_t is (S_INIT, S_IDLE, S_FILL, S_PF);
    signal state  : state_t := S_INIT;
    signal primed : std_logic := '0';
    signal inval_p : std_logic := '0';
    signal count  : unsigned(1 downto 0) := "00";
    signal init_i : unsigned(IB - 1 downto 0) := (others => '0');
    signal line   : unsigned(31 downto 4) := (others => '0');   -- line being filled
    signal line_n : unsigned(31 downto 4);                      -- the one after it

    signal tag_we, data_we : std_logic;
    signal tag_wa, tag_ra : std_logic_vector(IB - 1 downto 0);
    signal tag_wd, tag_q : std_logic_vector(TW downto 0);   -- valid & tag
    signal data_wa : std_logic_vector(IB + 1 downto 0);
    signal match, hit, ack_i, busy_line : std_logic;
begin
    line_n <= line + 1;
    -- during a fill the tag port looks at the next line, for the prefetch
    tag_ra <= std_logic_vector(line_n(IB + 3 downto 4)) when state = S_FILL else raddr(IB + 3 downto 4);

    tags : entity work.sdpram
        generic map (IB, TW + 1)
        port map (clk, tag_we, tag_wa, tag_wd, tag_ra, tag_q);

    data : entity work.sdpram
        generic map (IB + 2, 32)
        port map (clk, data_we, data_wa, m_rdata, raddr(IB + 3 downto 2), rdata);

    match <= '1' when tag_q(TW) = '1' and tag_q(TW - 1 downto 0) = addr(31 downto 4 + IB) else '0';
    busy_line <= '1' when state = S_PF and addr(IB + 3 downto 4) = std_logic_vector(line(IB + 3 downto 4)) else '0';
    hit   <= '1' when primed = '1' and match = '1' and inval_p = '0' and busy_line = '0'
                      and (state = S_IDLE or state = S_PF) else '0';
    ack_i <= req and hit;
    ack   <= ack_i;

    m_req  <= '1' when state = S_FILL or state = S_PF else '0';
    m_addr <= std_logic_vector(line) & "0000";

    data_we <= '1' when (state = S_FILL or state = S_PF) and m_ack = '1' else '0';
    data_wa <= std_logic_vector(line(IB + 3 downto 4)) & std_logic_vector(count);

    tag_we <= '1' when state = S_INIT or ((state = S_FILL or state = S_PF) and m_ack = '1' and count = 3) else '0';
    tag_wa <= std_logic_vector(init_i) when state = S_INIT else std_logic_vector(line(IB + 3 downto 4));
    tag_wd <= (others => '0') when state = S_INIT else '1' & std_logic_vector(line(31 downto 4 + IB));

    process (clk)
    begin
        if rising_edge(clk) then
            -- the RAM output is good next cycle if it was read at next
            -- cycle's addr and no tag write raced the read
            if (state = S_IDLE or state = S_PF) and tag_we = '0' and (prime = '1' or (req = '1' and ack_i = '0')) then
                primed <= '1';
            else
                primed <= '0';
            end if;
            if inval = '1' then
                inval_p <= '1';
            end if;

            case state is
                when S_INIT =>
                    init_i <= init_i + 1;
                    if init_i = 2 ** IB - 1 then
                        state <= S_IDLE;
                    end if;
                when S_IDLE =>
                    if inval_p = '1' or inval = '1' then
                        state   <= S_INIT;
                        init_i  <= (others => '0');
                        inval_p <= '0';
                    elsif req = '1' and primed = '1' and match = '0' then
                        state <= S_FILL;
                        line  <= unsigned(addr(31 downto 4));
                        count <= "00";
                    end if;
                when S_FILL =>
                    if m_ack = '1' then
                        count <= count + 1;
                        if count = 3 then
                            state <= S_IDLE;
                            if PREFETCH and not (tag_q(TW) = '1' and
                                    tag_q(TW - 1 downto 0) = std_logic_vector(line_n(31 downto 4 + IB))) then
                                state <= S_PF;
                                line  <= line_n;
                            end if;
                        end if;
                    end if;
                when S_PF =>
                    if m_ack = '1' then
                        count <= count + 1;
                        if count = 3 then
                            state <= S_IDLE;
                        end if;
                    end if;
            end case;

            if reset = '1' then
                state   <= S_INIT;
                init_i  <= (others => '0');
                primed  <= '0';
                inval_p <= '0';
            end if;
        end if;
    end process;
end rtl;
