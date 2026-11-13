-- Data cache: direct mapped, 16-byte lines, write-through with a WBD-entry
-- write buffer, no write allocate. Caches SRAM (0x1...) and SDRAM (0x2... and 0x8...).
-- Everything else goes straight through as a single uncached access.
--
-- A cacheable store updates the line if present, parks in the write buffer
-- and is acknowledged at once while the buffer has room; the buffer drains
-- on its own, oldest first. Loads that hit go ahead of it (a store hit
-- already updated the line). Anything else that needs the memory bus (a
-- fill, an uncached access) waits for the buffer to empty first, so memory
-- sees accesses in program order.
--
-- A store hit writes a line word on the same edge the CPU may latch a read
-- of it; the RAM does not promise new data then, so that read is redone.
--
-- The RAMs read raddr, the CPU's combinational address, every cycle; every
-- decision uses addr, which is registered, so the CPU's address adder stays
-- off the memory-side paths. The RAM output is good for this cycle's addr
-- when the word index read last cycle is addr's and nothing was written
-- over that read; otherwise the cache asks again (raddr must then be addr).
--
-- 0x8xxxxxxx is an alias of the SDRAM at 0x2xxxxxxx (for Linux). Tags are
-- kept with region 8 folded onto region 2, so both views hit the same line
-- and a store through one can never leave a stale copy under the other.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity dcache is
    generic (
        IB  : integer := 8;
        WBD : integer := 4     -- write buffer entries, a power of two
    );
    port (
        clk     : in  std_logic;
        reset   : in  std_logic;
        raddr   : in  std_logic_vector(31 downto 0);
        req     : in  std_logic;
        addr    : in  std_logic_vector(31 downto 0);
        we      : in  std_logic;
        wstrb   : in  std_logic_vector(3 downto 0);
        wdata   : in  std_logic_vector(31 downto 0);
        ack     : out std_logic;
        rdata   : out std_logic_vector(31 downto 0);
        wbe     : out std_logic;   -- the write buffer is empty
        m_req   : out std_logic;
        m_addr  : out std_logic_vector(31 downto 0);
        m_we    : out std_logic;
        m_wstrb : out std_logic_vector(3 downto 0);
        m_wdata : out std_logic_vector(31 downto 0);
        m_burst : out std_logic;
        m_ack   : in  std_logic;
        m_rdata : in  std_logic_vector(31 downto 0)
    );
end dcache;

architecture rtl of dcache is
    constant TW : integer := 32 - 4 - IB;
    type state_t is (S_INIT, S_IDLE, S_FILL, S_UNC);
    signal state  : state_t := S_INIT;
    signal primed : std_logic;
    signal fresh  : std_logic := '0';                                    -- no write raced the read
    signal ra_r   : std_logic_vector(IB + 1 downto 0) := (others => '0'); -- word index read
    signal count  : unsigned(1 downto 0) := "00";
    signal init_i : unsigned(IB - 1 downto 0) := (others => '0');

    -- write buffer: a ring of WBD entries
    type wa_t is array (0 to WBD - 1) of std_logic_vector(31 downto 0);
    type ws_t is array (0 to WBD - 1) of std_logic_vector(3 downto 0);
    signal wb_addr  : wa_t := (others => (others => '0'));
    signal wb_data  : wa_t := (others => (others => '0'));
    signal wb_strb  : ws_t := (others => (others => '0'));
    signal wb_head, wb_tail : integer range 0 to WBD - 1 := 0;
    signal wb_count : integer range 0 to WBD := 0;
    signal wb_empty, wb_full : std_logic;

    signal tag_we : std_logic;
    signal tag_wa : std_logic_vector(IB - 1 downto 0);
    signal tag_wd, tag_q : std_logic_vector(TW downto 0);
    signal lane_we : std_logic_vector(3 downto 0);
    signal data_wa : std_logic_vector(IB + 1 downto 0);
    signal data_wd, data_q : std_logic_vector(31 downto 0);
    signal hit, cacheable, ack_i : std_logic;
    signal take_store, start_unc, start_fill, drain : std_logic;
    signal taddr : std_logic_vector(31 downto 0);   -- addr with the alias folded
begin
    tags : entity work.sdpram
        generic map (IB, TW + 1)
        port map (clk, tag_we, tag_wa, tag_wd, raddr(IB + 3 downto 4), tag_q);

    lanes : for b in 0 to 3 generate
        lane : entity work.sdpram
            generic map (IB + 2, 8)
            port map (clk, lane_we(b), data_wa, data_wd(8 * b + 7 downto 8 * b),
                      raddr(IB + 3 downto 2), data_q(8 * b + 7 downto 8 * b));
    end generate;

    cacheable <= '1' when addr(31 downto 28) = x"1" or addr(31 downto 28) = x"2" or addr(31 downto 28) = x"8" else '0';
    taddr <= x"2" & addr(27 downto 0) when addr(31 downto 28) = x"8" else addr;
    primed <= '1' when fresh = '1' and ra_r = addr(IB + 3 downto 2) else '0';
    hit <= '1' when primed = '1' and tag_q(TW) = '1' and tag_q(TW - 1 downto 0) = taddr(31 downto 4 + IB) else '0';

    wb_empty <= '1' when wb_count = 0 else '0';
    wb_full  <= '1' when wb_count = WBD else '0';
    wbe      <= wb_empty;

    take_store <= '1' when state = S_IDLE and req = '1' and we = '1' and cacheable = '1'
                           and primed = '1' and wb_full = '0' else '0';
    start_unc  <= '1' when state = S_IDLE and req = '1' and cacheable = '0' and wb_empty = '1' else '0';
    start_fill <= '1' when state = S_IDLE and req = '1' and we = '0' and cacheable = '1'
                           and primed = '1' and hit = '0' and wb_empty = '1' else '0';
    drain      <= '1' when wb_empty = '0' and state = S_IDLE else '0';

    process (state, req, we, cacheable, hit, m_ack, m_rdata, data_q, take_store)
    begin
        ack_i <= '0';
        rdata <= data_q;
        case state is
            when S_IDLE =>
                if (req = '1' and we = '0' and cacheable = '1' and hit = '1') or take_store = '1' then
                    ack_i <= '1';
                end if;
            when S_UNC =>
                ack_i <= m_ack;
                rdata <= m_rdata;
            when others =>
                null;
        end case;
    end process;
    ack <= ack_i;

    -- memory side: a line fill, the CPU's uncached access, or the write buffer
    process (state, drain, start_unc, wb_addr, wb_strb, wb_data, wb_head, addr, we, wstrb, wdata)
    begin
        m_req   <= '0';
        m_burst <= '0';
        m_addr  <= addr;
        m_we    <= we;
        m_wstrb <= wstrb;
        m_wdata <= wdata;
        if state = S_FILL then
            m_req   <= '1';
            m_burst <= '1';
            m_addr  <= addr(31 downto 4) & "0000";
            m_we    <= '0';
        elsif state = S_UNC or start_unc = '1' then
            m_req <= '1';
        elsif drain = '1' then
            m_req   <= '1';
            m_addr  <= wb_addr(wb_head);
            m_we    <= '1';
            m_wstrb <= wb_strb(wb_head);
            m_wdata <= wb_data(wb_head);
        end if;
    end process;

    -- data RAM writes: whole words on a fill, strobed bytes on a store hit
    data_wa <= addr(IB + 3 downto 4) & std_logic_vector(count) when state = S_FILL else addr(IB + 3 downto 2);
    data_wd <= m_rdata when state = S_FILL else wdata;
    lane_we <= "1111" when state = S_FILL and m_ack = '1' else
               wstrb  when take_store = '1' and hit = '1' else
               "0000";

    tag_we <= '1' when state = S_INIT or (state = S_FILL and m_ack = '1' and count = 3) else '0';
    tag_wa <= std_logic_vector(init_i) when state = S_INIT else addr(IB + 3 downto 4);
    tag_wd <= (others => '0') when state = S_INIT else '1' & taddr(31 downto 4 + IB);

    process (clk)
    begin
        if rising_edge(clk) then
            ra_r <= raddr(IB + 3 downto 2);
            if state /= S_FILL and state /= S_INIT
               and not (lane_we /= "0000" and data_wa = raddr(IB + 3 downto 2)) then
                fresh <= '1';
            else
                fresh <= '0';
            end if;

            if drain = '1' and m_ack = '1' then
                wb_head <= (wb_head + 1) mod WBD;
            end if;
            if take_store = '1' then
                wb_addr(wb_tail) <= addr;
                wb_strb(wb_tail) <= wstrb;
                wb_data(wb_tail) <= wdata;
                wb_tail <= (wb_tail + 1) mod WBD;
            end if;
            if take_store = '1' and not (drain = '1' and m_ack = '1') then
                wb_count <= wb_count + 1;
            elsif take_store = '0' and drain = '1' and m_ack = '1' then
                wb_count <= wb_count - 1;
            end if;

            case state is
                when S_INIT =>
                    init_i <= init_i + 1;
                    if init_i = 2 ** IB - 1 then
                        state <= S_IDLE;
                    end if;
                when S_IDLE =>
                    if start_unc = '1' then
                        state <= S_UNC;
                    elsif start_fill = '1' then
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
                when S_UNC =>
                    if m_ack = '1' then
                        state <= S_IDLE;
                    end if;
            end case;

            if reset = '1' then
                state    <= S_INIT;
                init_i   <= (others => '0');
                fresh    <= '0';
                wb_head  <= 0;
                wb_tail  <= 0;
                wb_count <= 0;
            end if;
        end if;
    end process;
end rtl;
