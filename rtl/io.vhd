-- Memory-mapped I/O at 0xF000_0000 (see spec.md for the register list).
--
--   0xF000_0000 .. 0xF000_00FF  the original registers
--   0xF000_1000 .. 0xF000_101F  16550 console, registers 4 bytes apart
--   0xF000_2000                 syscon: 0x5555 power off, 0x7777 reboot
--   0xF100_0000 .. 0xF100_FFFF  CLINT: msip +0, mtimecmp +0x4000, mtime +0xBFF8
--
-- Anything else in the region reads 0 and ignores writes (the CPU raises
-- an access fault for it first once software has a trap handler).
--
-- The 16550 sends to the console FIFO (Virtual JTAG) and the RS-232 UART at
-- once and receives from either. The transmitter reports empty (LSR bits 5
-- and 6) when the UART is idle and, if a JTAG host is attached, the console
-- FIFO has room; with no host attached bytes that do not fit are dropped,
-- so a board without a host never stalls. Polled only: IER is stored and
-- shapes IIR, but there is no interrupt line.
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
        jtag_pop      : out std_logic;
        -- console FIFOs (rtl/jtag_console.vhd)
        con_tx_we     : out std_logic;
        con_tx_data   : out std_logic_vector(7 downto 0);
        con_tx_full   : in  std_logic;
        con_rx_avail  : in  std_logic;
        con_rx_data   : in  std_logic_vector(7 downto 0);
        con_rx_pop    : out std_logic;
        con_attached  : in  std_logic;
        -- CLINT and syscon
        mtime         : out std_logic_vector(63 downto 0);
        mtip          : out std_logic;
        msip          : out std_logic;
        poweroff      : out std_logic;
        reboot        : out std_logic
    );
end io;

architecture rtl of io is
    signal ack_r    : std_logic := '0';
    signal rdata_r  : std_logic_vector(31 downto 0) := (others => '0');
    signal cycles   : unsigned(31 downto 0) := (others => '0');
    signal us       : unsigned(63 downto 0) := (others => '0');   -- also CLINT mtime
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

    -- 16550
    signal u_ier    : std_logic_vector(3 downto 0) := (others => '0');
    signal u_lcr, u_mcr, u_scr, u_dll, u_dlm : std_logic_vector(7 downto 0) := (others => '0');
    signal u_thre, u_dr : std_logic;

    -- CLINT
    signal mtimecmp : unsigned(63 downto 0) := (others => '1');
    signal msip_r   : std_logic := '0';
    signal mtip_r   : std_logic := '0';
    signal off_r    : std_logic := '0';
begin
    mtime    <= std_logic_vector(us);
    mtip     <= mtip_r;
    msip     <= msip_r;
    poweroff <= off_r;
    u_thre   <= uart_tx_ready and (not con_attached or not con_tx_full);
    u_dr     <= con_rx_avail or rx_full;
    ack     <= ack_r;
    rdata   <= rdata_r;
    fb_base <= fb_r;
    ledr    <= ledr_r;
    ledg    <= ledg_r;
    hex     <= hex_r;
    uart_tx_data <= wdata(7 downto 0);
    con_tx_data  <= wdata(7 downto 0);
    pal_idx <= wdata(31 downto 24);
    pal_rgb <= wdata(23 downto 20) & wdata(15 downto 12) & wdata(7 downto 4);

    process (clk)
        variable pop_k, push_k : boolean;
        variable off : std_logic_vector(7 downto 0);
        variable sel_regs, sel_uart, sel_sysc, sel_clint : boolean;
        variable ur  : std_logic_vector(2 downto 0);
        variable co  : std_logic_vector(15 downto 0);
    begin
        if rising_edge(clk) then
            ack_r         <= '0';
            uart_tx_start <= '0';
            pal_we        <= '0';
            jtag_pop      <= '0';
            con_tx_we     <= '0';
            con_rx_pop    <= '0';
            reboot        <= '0';
            cycles        <= cycles + 1;
            if us >= mtimecmp then mtip_r <= '1'; else mtip_r <= '0'; end if;
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
            sel_regs  := unsigned(addr(27 downto 8)) = 0;
            sel_uart  := unsigned(addr(27 downto 5)) = 16#80#;
            sel_sysc  := unsigned(addr(27 downto 0)) = 16#2000#;
            sel_clint := unsigned(addr(27 downto 16)) = 16#100#;
            ur := addr(4 downto 2);
            co := addr(15 downto 0);
            if req = '1' and ack_r = '0' then
                ack_r   <= '1';
                rdata_r <= (others => '0');
                if not sel_regs then
                    if we = '1' then
                        if sel_uart then
                            if u_lcr(7) = '1' and ur = "000" then
                                u_dll <= wdata(7 downto 0);
                            elsif u_lcr(7) = '1' and ur = "001" then
                                u_dlm <= wdata(7 downto 0);
                            else
                                case ur is
                                    when "000" =>              -- THR
                                        uart_tx_start <= '1';
                                        con_tx_we     <= '1';
                                    when "001" => u_ier <= wdata(3 downto 0);
                                    when "011" => u_lcr <= wdata(7 downto 0);
                                    when "100" => u_mcr <= wdata(7 downto 0);
                                    when "111" => u_scr <= wdata(7 downto 0);
                                    when others => null;       -- FCR, LSR, MSR
                                end case;
                            end if;
                        elsif sel_sysc then
                            if wdata = x"00005555" then
                                off_r <= '1';
                                hex_r <= x"00FF";
                            elsif wdata = x"00007777" then
                                reboot <= '1';
                            end if;
                        elsif sel_clint then
                            case co is
                                when x"0000" => msip_r <= wdata(0);
                                when x"4000" => mtimecmp(31 downto 0)  <= unsigned(wdata);
                                when x"4004" => mtimecmp(63 downto 32) <= unsigned(wdata);
                                when others  => null;
                            end case;
                        end if;
                    else
                        if sel_uart then
                            if u_lcr(7) = '1' and ur = "000" then
                                rdata_r(7 downto 0) <= u_dll;
                            elsif u_lcr(7) = '1' and ur = "001" then
                                rdata_r(7 downto 0) <= u_dlm;
                            else
                                case ur is
                                    when "000" =>              -- RBR: JTAG first, then RS-232
                                        if con_rx_avail = '1' then
                                            rdata_r(7 downto 0) <= con_rx_data;
                                            con_rx_pop <= '1';
                                        elsif rx_full = '1' then
                                            rdata_r(7 downto 0) <= rx_byte;
                                            rx_full <= '0';
                                        end if;
                                    when "001" => rdata_r(3 downto 0) <= u_ier;
                                    when "010" =>              -- IIR, FIFOs enabled
                                        if u_ier(0) = '1' and u_dr = '1' then
                                            rdata_r(7 downto 0) <= x"C4";
                                        elsif u_ier(1) = '1' and u_thre = '1' then
                                            rdata_r(7 downto 0) <= x"C2";
                                        else
                                            rdata_r(7 downto 0) <= x"C1";
                                        end if;
                                    when "011" => rdata_r(7 downto 0) <= u_lcr;
                                    when "100" => rdata_r(7 downto 0) <= u_mcr;
                                    when "101" =>              -- LSR
                                        rdata_r(6) <= u_thre;
                                        rdata_r(5) <= u_thre;
                                        rdata_r(0) <= u_dr;
                                    when "110" => rdata_r(7 downto 0) <= x"B0";   -- MSR: DCD DSR CTS
                                    when others => rdata_r(7 downto 0) <= u_scr;
                                end case;
                            end if;
                        elsif sel_clint then
                            case co is
                                when x"0000" => rdata_r(0) <= msip_r;
                                when x"4000" => rdata_r <= std_logic_vector(mtimecmp(31 downto 0));
                                when x"4004" => rdata_r <= std_logic_vector(mtimecmp(63 downto 32));
                                when x"BFF8" => rdata_r <= std_logic_vector(us(31 downto 0));
                                when x"BFFC" => rdata_r <= std_logic_vector(us(63 downto 32));
                                when others  => null;
                            end case;
                        end if;
                    end if;
                elsif we = '1' then
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
                        when x"08" => rdata_r <= std_logic_vector(us(31 downto 0));
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
                rx_full  <= '0';
                u_ier    <= (others => '0');
                u_lcr    <= (others => '0');
                u_mcr    <= (others => '0');
                u_scr    <= (others => '0');
                u_dll    <= (others => '0');
                u_dlm    <= (others => '0');
                mtimecmp <= (others => '1');
                msip_r   <= '0';
                off_r    <= '0';
            end if;
        end if;
    end process;
end rtl;
