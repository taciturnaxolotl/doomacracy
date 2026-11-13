-- SDRAM controller for the DE1's IS42S16400 (4 banks x 4096 rows x 256
-- columns x 16 bits) at 50 MHz. CAS latency 2, burst length 1: every
-- halfword gets its own READ or WRITE command, issued back to back, which
-- keeps the logic simple and still streams one halfword a cycle.
--
-- Rows stay open after an access (one per bank). A request to the open row
-- of its bank goes straight to its column commands; a different row costs a
-- precharge of that bank first. All banks close before each auto refresh.
-- Timing at 20 ns a cycle: tRCD and tRP 20 ns (one idle cycle each), tWR
-- 15 ns and tRAS 42 ns (guarded by wr_recov and the ACT, NOP, column
-- sequence), tRC 70 ns after a refresh (7 cycles).
--
-- Halfword address = row(12) & bank(2) & column(8).
-- DRAM_CLK is driven inverted at the top level so commands and data launched
-- on our rising edge sit in the middle of the SDRAM's clock period.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity sdram_ctrl is
    generic (
        INIT_WAIT    : integer := 10000;  -- 200 us at 50 MHz
        REFRESH_TIME : integer := 700     -- under 15.6 us between refreshes
    );
    port (
        clk     : in  std_logic;
        reset   : in  std_logic;
        req     : in  std_logic;
        addr    : in  std_logic_vector(31 downto 0);
        we      : in  std_logic;
        wstrb   : in  std_logic_vector(3 downto 0);
        wdata   : in  std_logic_vector(31 downto 0);
        burst   : in  std_logic;
        ack     : out std_logic;
        rdata   : out std_logic_vector(31 downto 0);
        ready   : out std_logic;
        DRAM_ADDR  : out   std_logic_vector(11 downto 0);
        DRAM_BA    : out   std_logic_vector(1 downto 0);
        DRAM_DQ    : inout std_logic_vector(15 downto 0);
        DRAM_LDQM  : out   std_logic;
        DRAM_UDQM  : out   std_logic;
        DRAM_RAS_N : out   std_logic;
        DRAM_CAS_N : out   std_logic;
        DRAM_WE_N  : out   std_logic;
        DRAM_CS_N  : out   std_logic;
        DRAM_CKE   : out   std_logic
    );
end sdram_ctrl;

architecture rtl of sdram_ctrl is
    --                                       RAS CAS WE
    constant C_NOP  : std_logic_vector(2 downto 0) := "111";
    constant C_ACT  : std_logic_vector(2 downto 0) := "011";
    constant C_RD   : std_logic_vector(2 downto 0) := "101";
    constant C_WR   : std_logic_vector(2 downto 0) := "100";
    constant C_PRE  : std_logic_vector(2 downto 0) := "010";
    constant C_REF  : std_logic_vector(2 downto 0) := "001";
    constant C_MRS  : std_logic_vector(2 downto 0) := "000";

    type state_t is (S_POWERUP, S_INIT_PRE, S_INIT_REF, S_INIT_MRS, S_IDLE,
                     S_REFRESH, S_ACTIVATE, S_COLS, S_DRAIN, S_PRE_ONE, S_PRE_ALL, S_DONE, S_RESET);
    signal state : state_t := S_POWERUP;
    signal wait_n : integer range 0 to INIT_WAIT := 0;
    signal refs   : integer range 0 to 8 := 0;
    signal ref_timer : integer range 0 to REFRESH_TIME := 0;
    signal ref_due   : std_logic := '0';

    signal cmd   : std_logic_vector(2 downto 0) := C_NOP;
    signal a_r   : std_logic_vector(11 downto 0) := (others => '0');
    signal ba_r  : std_logic_vector(1 downto 0) := "00";
    signal dqm_r : std_logic_vector(1 downto 0) := "11";
    signal dq_o  : std_logic_vector(15 downto 0) := (others => '0');
    signal dq_oe : std_logic := '0';

    signal hw     : unsigned(21 downto 0);   -- halfword address of the first column
    signal ncols  : integer range 0 to 8 := 0;
    signal issued : integer range 0 to 8 := 0;
    signal is_wr  : std_logic := '0';

    -- read data pipeline: CL2 plus our input register
    constant RD_DELAY : integer := 3;
    signal rd_pipe : std_logic_vector(RD_DELAY downto 1) := (others => '0');
    signal got     : integer range 0 to 8 := 0;
    signal lo_hold : std_logic_vector(15 downto 0) := (others => '0');
    signal dq_in   : std_logic_vector(15 downto 0) := (others => '0');

    signal ack_r   : std_logic := '0';

    type rows_t is array (0 to 3) of unsigned(11 downto 0);
    signal open_row : rows_t := (others => (others => '0'));
    signal open_v   : std_logic_vector(3 downto 0) := (others => '0');
    signal wr_recov : integer range 0 to 3 := 0;   -- tWR before a precharge
    signal rdata_r : std_logic_vector(31 downto 0) := (others => '0');
begin
    DRAM_CS_N  <= '0';
    DRAM_CKE   <= '1';
    DRAM_RAS_N <= cmd(2);
    DRAM_CAS_N <= cmd(1);
    DRAM_WE_N  <= cmd(0);
    DRAM_ADDR  <= a_r;
    DRAM_BA    <= ba_r;
    DRAM_LDQM  <= dqm_r(0);
    DRAM_UDQM  <= dqm_r(1);
    DRAM_DQ    <= dq_o when dq_oe = '1' else (others => 'Z');

    ack   <= ack_r;
    rdata <= rdata_r;
    ready <= '1' when state /= S_POWERUP and state /= S_INIT_PRE and state /= S_INIT_REF
                      and state /= S_INIT_MRS and state /= S_RESET else '0';

    hw <= unsigned(addr(22 downto 1));

    process (clk)
        variable col : unsigned(21 downto 0);
        variable b   : integer range 0 to 3;
    begin
        if rising_edge(clk) then
            cmd     <= C_NOP;
            if wr_recov /= 0 then
                wr_recov <= wr_recov - 1;
            end if;
            dq_oe   <= '0';
            dqm_r   <= "11";
            ack_r   <= '0';
            dq_in   <= DRAM_DQ;
            rd_pipe <= rd_pipe(RD_DELAY - 1 downto 1) & '0';

            if ref_timer = REFRESH_TIME then
                ref_due <= '1';
            else
                ref_timer <= ref_timer + 1;
            end if;

            -- read data arrives RD_DELAY cycles after its READ command
            if rd_pipe(RD_DELAY) = '1' then
                if got mod 2 = 0 then
                    lo_hold <= dq_in;
                else
                    rdata_r <= dq_in & lo_hold;
                    ack_r   <= '1';
                end if;
                got <= got + 1;
            end if;

            case state is
                when S_POWERUP =>
                    if wait_n = INIT_WAIT then
                        state <= S_INIT_PRE;
                    else
                        wait_n <= wait_n + 1;
                    end if;

                when S_INIT_PRE =>
                    cmd    <= C_PRE;
                    a_r(10) <= '1';      -- all banks
                    refs   <= 0;
                    wait_n <= 0;
                    state  <= S_INIT_REF;

                when S_INIT_REF =>
                    -- 8 refreshes, 8 cycles apart (tRC 70 ns)
                    if wait_n = 0 then
                        if refs = 8 then
                            state <= S_INIT_MRS;
                        else
                            cmd    <= C_REF;
                            refs   <= refs + 1;
                            wait_n <= 7;
                        end if;
                    else
                        wait_n <= wait_n - 1;
                    end if;

                when S_INIT_MRS =>
                    -- burst length 1, sequential, CL2, single-location writes
                    cmd   <= C_MRS;
                    ba_r  <= "00";
                    a_r   <= "00" & '1' & "00" & "010" & '0' & "000";
                    wait_n <= 3;
                    state <= S_DONE;

                when S_IDLE =>
                    if ref_due = '1' and wr_recov = 0 then
                        if open_v /= "0000" then
                            cmd     <= C_PRE;         -- close every bank first
                            a_r(10) <= '1';
                            open_v  <= "0000";
                            wait_n  <= 1;
                            state   <= S_PRE_ALL;
                        else
                            cmd       <= C_REF;
                            ref_due   <= '0';
                            ref_timer <= 0;
                            wait_n    <= 7;
                            state     <= S_REFRESH;
                        end if;
                    elsif req = '1' and ref_due = '0' and ack_r = '0' then
                        is_wr  <= we;
                        got    <= 0;
                        issued <= 0;
                        if we = '1' or burst = '0' then
                            ncols <= 2;
                        else
                            ncols <= 8;
                        end if;
                        b := to_integer(hw(9 downto 8));
                        if open_v(b) = '1' and open_row(b) = hw(21 downto 10) then
                            state <= S_COLS;          -- row hit
                        elsif open_v(b) = '1' then
                            if wr_recov = 0 then      -- row miss: close it
                                cmd       <= C_PRE;
                                ba_r      <= std_logic_vector(hw(9 downto 8));
                                a_r(10)   <= '0';
                                open_v(b) <= '0';
                                state     <= S_PRE_ONE;
                            end if;
                        else
                            cmd         <= C_ACT;
                            ba_r        <= std_logic_vector(hw(9 downto 8));
                            a_r         <= std_logic_vector(hw(21 downto 10));
                            open_v(b)   <= '1';
                            open_row(b) <= hw(21 downto 10);
                            state       <= S_ACTIVATE;
                        end if;
                    end if;

                when S_PRE_ONE =>
                    -- one idle cycle for tRP, then open the new row
                    b := to_integer(hw(9 downto 8));
                    cmd         <= C_ACT;
                    ba_r        <= std_logic_vector(hw(9 downto 8));
                    a_r         <= std_logic_vector(hw(21 downto 10));
                    open_v(b)   <= '1';
                    open_row(b) <= hw(21 downto 10);
                    state       <= S_ACTIVATE;

                when S_RESET =>
                    -- after a board reset (KEY0) the chip may still have
                    -- rows open: close every bank once tRAS and tWR are
                    -- safe, before anything else
                    if wait_n = 0 then
                        cmd     <= C_PRE;
                        a_r(10) <= '1';
                        wait_n  <= 1;
                        state   <= S_PRE_ALL;
                    else
                        wait_n <= wait_n - 1;
                    end if;

                when S_PRE_ALL | S_REFRESH | S_DONE =>
                    if wait_n = 0 then
                        state <= S_IDLE;
                    else
                        wait_n <= wait_n - 1;
                    end if;

                when S_ACTIVATE =>
                    -- one NOP for tRCD (20 ns)
                    state <= S_COLS;

                when S_COLS =>
                    if burst = '1' and is_wr = '0' then
                        col := (hw(21 downto 3) & "000") + issued;
                    else
                        col := (hw(21 downto 1) & '0') + issued;
                    end if;
                    a_r  <= "0000" & std_logic_vector(col(7 downto 0));
                    ba_r <= std_logic_vector(col(9 downto 8));
                    if is_wr = '1' then
                        cmd   <= C_WR;
                        dq_oe <= '1';
                        if issued = 0 then
                            dq_o  <= wdata(15 downto 0);
                            dqm_r <= not wstrb(1 downto 0);
                        else
                            dq_o  <= wdata(31 downto 16);
                            dqm_r <= not wstrb(3 downto 2);
                        end if;
                    else
                        cmd     <= C_RD;
                        dqm_r   <= "00";
                        rd_pipe(1) <= '1';
                    end if;
                    issued <= issued + 1;
                    if issued + 1 = ncols then
                        if is_wr = '1' then
                            -- the row stays open; the write is done as far as
                            -- the bus is concerned, tWR guards a later precharge
                            ack_r    <= '1';
                            wr_recov <= 2;
                            state    <= S_IDLE;
                        else
                            state <= S_DRAIN;
                        end if;
                    end if;

                when S_DRAIN =>
                    -- wait for the last word's ack, so a request the master
                    -- is still holding can't start again
                    if rd_pipe = (rd_pipe'range => '0') then
                        state <= S_IDLE;
                    end if;
            end case;

            if reset = '1' then
                rd_pipe <= (others => '0');
                open_v  <= (others => '0');
                dq_oe   <= '0';
                -- only once initialised: before that the init sequence
                -- runs on its own and the chip has nothing open
                if state /= S_POWERUP and state /= S_INIT_PRE and state /= S_INIT_REF
                   and state /= S_INIT_MRS then
                    cmd    <= C_NOP;
                    wait_n <= 3;
                    state  <= S_RESET;
                end if;
            end if;
        end if;
    end process;
end rtl;
