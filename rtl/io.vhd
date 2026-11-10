-- Memory-mapped I/O at 0xF000_0000 (see spec.md for the register list).
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity io is
    port (
        clk     : in  std_logic;
        reset   : in  std_logic;
        req     : in  std_logic;
        addr    : in  std_logic_vector(31 downto 0);
        we      : in  std_logic;
        wdata   : in  std_logic_vector(31 downto 0);
        ack     : out std_logic;
        rdata   : out std_logic_vector(31 downto 0);
        -- peripherals
        uart_tx_start : out std_logic;
        uart_tx_data  : out std_logic_vector(7 downto 0);
        uart_tx_ready : in  std_logic;
        uart_rx_valid : in  std_logic;
        uart_rx_data  : in  std_logic_vector(7 downto 0);
        kbd_valid     : in  std_logic;
        kbd_data      : in  std_logic_vector(7 downto 0);
        sw            : in  std_logic_vector(9 downto 0);
        key           : in  std_logic_vector(3 downto 0);
        ledr          : out std_logic_vector(9 downto 0);
        ledg          : out std_logic_vector(7 downto 0);
        hex           : out std_logic_vector(15 downto 0);
        fb_base       : out std_logic_vector(18 downto 0);
        vblank        : in  std_logic;
        pal_we        : out std_logic;
        pal_idx       : out std_logic_vector(7 downto 0);
        pal_rgb       : out std_logic_vector(11 downto 0);
        jtag_avail    : in  std_logic;
        jtag_data     : in  std_logic_vector(31 downto 0);
        jtag_ovf      : in  std_logic;
        jtag_pop      : out std_logic
    );
end io;

architecture rtl of io is
    signal ack_r    : std_logic := '0';
    signal rdata_r  : std_logic_vector(31 downto 0) := (others => '0');
    signal cycles   : unsigned(31 downto 0) := (others => '0');
    signal us       : unsigned(31 downto 0) := (others => '0');
    signal us_div   : integer range 0 to 49 := 0;
    signal frames   : unsigned(31 downto 0) := (others => '0');
    signal fb_r     : std_logic_vector(18 downto 0) := "110" & x"0000";  -- 0x60000
    signal ledr_r   : std_logic_vector(9 downto 0) := (others => '0');
    signal ledg_r   : std_logic_vector(7 downto 0) := (others => '0');
    signal hex_r    : std_logic_vector(15 downto 0) := (others => '0');

    type fifo_t is array (0 to 15) of std_logic_vector(7 downto 0);
    signal kfifo    : fifo_t := (others => (others => '0'));
    signal k_wr, k_rd : unsigned(3 downto 0) := (others => '0');
    signal k_count  : integer range 0 to 16 := 0;

    signal rx_byte  : std_logic_vector(7 downto 0) := (others => '0');
    signal rx_full  : std_logic := '0';
begin
    ack     <= ack_r;
    rdata   <= rdata_r;
    fb_base <= fb_r;
    ledr    <= ledr_r;
    ledg    <= ledg_r;
    hex     <= hex_r;
    uart_tx_data <= wdata(7 downto 0);
    pal_idx <= wdata(31 downto 24);
    pal_rgb <= wdata(23 downto 20) & wdata(15 downto 12) & wdata(7 downto 4);

    process (clk)
        variable pop_k, push_k : boolean;
        variable off : std_logic_vector(7 downto 0);
    begin
        if rising_edge(clk) then
            ack_r         <= '0';
            uart_tx_start <= '0';
            pal_we        <= '0';
            jtag_pop      <= '0';
            cycles        <= cycles + 1;
            if us_div = 49 then
                us_div <= 0;
                us     <= us + 1;
            else
                us_div <= us_div + 1;
            end if;
            if vblank = '1' then
                frames <= frames + 1;
            end if;
            if uart_rx_valid = '1' then
                rx_byte <= uart_rx_data;
                rx_full <= '1';
            end if;

            pop_k  := false;
            push_k := kbd_valid = '1' and k_count < 16;

            off := addr(7 downto 0);
            if req = '1' and ack_r = '0' then
                ack_r   <= '1';
                rdata_r <= (others => '0');
                if we = '1' then
                    case off is
                        when x"00" => uart_tx_start <= '1';
                        when x"18" => ledr_r <= wdata(9 downto 0);
                        when x"1C" => ledg_r <= wdata(7 downto 0);
                        when x"20" => hex_r  <= wdata(15 downto 0);
                        when x"30" => fb_r   <= wdata(18 downto 0);
                        when x"38" => pal_we <= '1';
                        when others => null;
                    end case;
                else
                    case off is
                        when x"00" =>
                            rdata_r <= rx_full & "00000000000000000000000" & rx_byte;
                            rx_full <= '0';
                        when x"04" => rdata_r(0) <= uart_tx_ready;
                        when x"08" => rdata_r <= std_logic_vector(us);
                        when x"0C" => rdata_r <= std_logic_vector(cycles);
                        when x"10" =>
                            if k_count /= 0 then
                                rdata_r <= x"00000" & "0001" & kfifo(to_integer(k_rd));
                                pop_k := true;
                            end if;
                        when x"14" => rdata_r <= x"000" & key & "000000" & sw;
                        when x"30" => rdata_r <= "0000000000000" & fb_r;
                        when x"34" => rdata_r <= std_logic_vector(frames);
                        when x"40" =>
                            rdata_r  <= jtag_data;
                            jtag_pop <= jtag_avail;
                        when x"44" => rdata_r(1 downto 0) <= jtag_ovf & jtag_avail;
                        when others => null;
                    end case;
                end if;
            end if;

            if push_k then
                kfifo(to_integer(k_wr)) <= kbd_data;
                k_wr <= k_wr + 1;
            end if;
            if pop_k then
                k_rd <= k_rd + 1;
            end if;
            if push_k and not pop_k then
                k_count <= k_count + 1;
            elsif pop_k and not push_k then
                k_count <= k_count - 1;
            end if;

            if reset = '1' then
                k_wr <= (others => '0'); k_rd <= (others => '0'); k_count <= 0;
                rx_full <= '0';
            end if;
        end if;
    end process;
end rtl;
