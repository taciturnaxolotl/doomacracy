-- 16-bit async SRAM (IS61LV25616, 10 ns) at 50 MHz. Every pin is driven
-- from a register. Reads pipeline one halfword per cycle; a halfword write
-- takes three cycles (setup, WE low, hold) so the address never moves while
-- WE is low. The video port gets the next free cycle ahead of the CPU.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity sram_ctrl is
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
        -- video: halfword address, held until v_ack
        v_req   : in  std_logic;
        v_addr  : in  std_logic_vector(17 downto 0);
        v_ack   : out std_logic;
        v_data  : out std_logic_vector(15 downto 0);
        -- pins
        SRAM_ADDR : out   std_logic_vector(17 downto 0);
        SRAM_DQ   : inout std_logic_vector(15 downto 0);
        SRAM_WE_N : out   std_logic;
        SRAM_OE_N : out   std_logic;
        SRAM_UB_N : out   std_logic;
        SRAM_LB_N : out   std_logic;
        SRAM_CE_N : out   std_logic
    );
end sram_ctrl;

architecture rtl of sram_ctrl is
    signal a_r    : std_logic_vector(17 downto 0) := (others => '0');
    signal dq_o   : std_logic_vector(15 downto 0) := (others => '0');
    signal dq_oe  : std_logic := '0';
    signal we_n   : std_logic := '1';
    signal oe_n   : std_logic := '1';
    signal ub_n   : std_logic := '1';
    signal lb_n   : std_logic := '1';

    signal active   : std_logic := '0';
    signal is_write : std_logic := '0';
    signal rd_left  : integer range 0 to 8 := 0;   -- halfwords still to issue
    signal rd_next  : unsigned(2 downto 0) := "000";
    signal wr_todo  : std_logic_vector(1 downto 0) := "00";  -- hi, lo
    signal wr_phase : integer range 0 to 2 := 0;
    signal wr_half  : std_logic := '0';

    -- what was issued last cycle and is on the pins to capture now
    signal cap_cpu  : std_logic := '0';
    signal cap_vid  : std_logic := '0';
    signal cap_k    : unsigned(2 downto 0) := "000";
    signal lo_hold  : std_logic_vector(15 downto 0) := (others => '0');

    signal ack_r    : std_logic := '0';
    signal rdata_r  : std_logic_vector(31 downto 0) := (others => '0');
    signal v_ack_r  : std_logic := '0';
    signal v_data_r : std_logic_vector(15 downto 0) := (others => '0');
    signal v_issued : std_logic := '0';
begin
    SRAM_ADDR <= a_r;
    SRAM_DQ   <= dq_o when dq_oe = '1' else (others => 'Z');
    SRAM_WE_N <= we_n;
    SRAM_OE_N <= oe_n;
    SRAM_UB_N <= ub_n;
    SRAM_LB_N <= lb_n;
    SRAM_CE_N <= '0';

    ack    <= ack_r;
    rdata  <= rdata_r;
    v_ack  <= v_ack_r;
    v_data <= v_data_r;

    process (clk)
        variable k : unsigned(2 downto 0);
    begin
        if rising_edge(clk) then
            ack_r   <= '0';
            v_ack_r <= '0';

            -- capture whatever was read last cycle
            if cap_vid = '1' then
                v_data_r <= SRAM_DQ;
                v_ack_r  <= '1';
            end if;
            if cap_cpu = '1' then
                if cap_k(0) = '0' then
                    lo_hold <= SRAM_DQ;
                else
                    rdata_r <= SRAM_DQ & lo_hold;
                    ack_r   <= '1';
                end if;
            end if;
            cap_cpu <= '0';
            cap_vid <= '0';

            -- start a CPU transaction (never in the cycle of its own last ack)
            if active = '0' and req = '1' and ack_r = '0' and cap_cpu = '0' then
                active   <= '1';
                is_write <= we;
                if we = '1' then
                    wr_todo <= (wstrb(3) or wstrb(2)) & (wstrb(1) or wstrb(0));
                    rd_left <= 0;
                else
                    wr_todo <= "00";
                    if burst = '1' then rd_left <= 8; else rd_left <= 2; end if;
                    rd_next <= "000";
                end if;
            end if;

            -- drive the pins for this cycle
            we_n <= '1';
            if wr_phase = 1 then
                we_n     <= '0';
                wr_phase <= 2;
            elsif wr_phase = 2 then
                wr_phase <= 0;
                if wr_half = '0' then
                    wr_todo(0) <= '0';
                    if wr_todo(1) = '0' then
                        ack_r  <= '1';
                        active <= '0';
                    end if;
                else
                    wr_todo(1) <= '0';
                    ack_r  <= '1';
                    active <= '0';
                end if;
            elsif v_req = '1' and v_issued = '0' and v_ack_r = '0' then
                a_r      <= v_addr;
                oe_n     <= '0';
                dq_oe    <= '0';
                ub_n     <= '0';
                lb_n     <= '0';
                cap_vid  <= '1';
                v_issued <= '1';
            elsif active = '1' and is_write = '0' and rd_left /= 0 then
                k := rd_next;
                if burst = '1' then
                    a_r <= addr(18 downto 4) & std_logic_vector(k);
                else
                    a_r <= addr(18 downto 2) & k(0);
                end if;
                oe_n    <= '0';
                dq_oe   <= '0';
                ub_n    <= '0';
                lb_n    <= '0';
                cap_cpu <= '1';
                cap_k   <= k;
                rd_next <= k + 1;
                rd_left <= rd_left - 1;
                if rd_left = 1 then
                    active <= '0';   -- last capture and ack still to come
                end if;
            elsif active = '1' and is_write = '1' and wr_todo /= "00" then
                oe_n  <= '1';
                dq_oe <= '1';
                if wr_todo(0) = '1' then
                    a_r     <= addr(18 downto 2) & '0';
                    dq_o    <= wdata(15 downto 0);
                    lb_n    <= not wstrb(0);
                    ub_n    <= not wstrb(1);
                    wr_half <= '0';
                else
                    a_r     <= addr(18 downto 2) & '1';
                    dq_o    <= wdata(31 downto 16);
                    lb_n    <= not wstrb(2);
                    ub_n    <= not wstrb(3);
                    wr_half <= '1';
                end if;
                wr_phase <= 1;
            else
                oe_n  <= '1';
                dq_oe <= '0';
            end if;

            if v_ack_r = '1' then
                v_issued <= '0';
            end if;

            if reset = '1' then
                active   <= '0';
                wr_phase <= 0;
                v_issued <= '0';
                cap_cpu  <= '0';
                cap_vid  <= '0';
                dq_oe    <= '0';
            end if;
        end if;
    end process;
end rtl;
