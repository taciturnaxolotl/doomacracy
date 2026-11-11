-- DE1 top level: CPU, caches, memory bus and every slave, with DE1 pin names.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity doomacracy is
    generic (
        UART_DIV        : integer := 434;    -- 115200 baud
        SDRAM_INIT_WAIT : integer := 10000;  -- 200 us
        TRACE           : string  := "";     -- simulation only
        TRACE_MAX       : integer := 0
    );
    port (
        CLOCK_50   : in    std_logic;
        KEY        : in    std_logic_vector(3 downto 0);
        SW         : in    std_logic_vector(9 downto 0);
        LEDR       : out   std_logic_vector(9 downto 0);
        LEDG       : out   std_logic_vector(7 downto 0);
        HEX0       : out   std_logic_vector(6 downto 0);
        HEX1       : out   std_logic_vector(6 downto 0);
        HEX2       : out   std_logic_vector(6 downto 0);
        HEX3       : out   std_logic_vector(6 downto 0);
        PS2_CLK    : in    std_logic;
        PS2_DAT    : in    std_logic;
        UART_RXD   : in    std_logic;
        UART_TXD   : out   std_logic;
        VGA_R      : out   std_logic_vector(3 downto 0);
        VGA_G      : out   std_logic_vector(3 downto 0);
        VGA_B      : out   std_logic_vector(3 downto 0);
        VGA_HS     : out   std_logic;
        VGA_VS     : out   std_logic;
        SRAM_ADDR  : out   std_logic_vector(17 downto 0);
        SRAM_DQ    : inout std_logic_vector(15 downto 0);
        SRAM_WE_N  : out   std_logic;
        SRAM_OE_N  : out   std_logic;
        SRAM_UB_N  : out   std_logic;
        SRAM_LB_N  : out   std_logic;
        SRAM_CE_N  : out   std_logic;
        DRAM_ADDR  : out   std_logic_vector(11 downto 0);
        DRAM_BA_0  : out   std_logic;
        DRAM_BA_1  : out   std_logic;
        DRAM_DQ    : inout std_logic_vector(15 downto 0);
        DRAM_LDQM  : out   std_logic;
        DRAM_UDQM  : out   std_logic;
        DRAM_RAS_N : out   std_logic;
        DRAM_CAS_N : out   std_logic;
        DRAM_WE_N  : out   std_logic;
        DRAM_CS_N  : out   std_logic;
        DRAM_CKE   : out   std_logic;
        DRAM_CLK   : out   std_logic;
        FL_ADDR    : out   std_logic_vector(21 downto 0);
        FL_DQ      : inout std_logic_vector(7 downto 0);
        FL_OE_N    : out   std_logic;
        FL_WE_N    : out   std_logic;
        FL_RST_N   : out   std_logic;
        FL_CE_N    : out   std_logic
    );
end doomacracy;

architecture rtl of doomacracy is
    signal clk   : std_logic;
    signal reset : std_logic := '1';
    signal por   : unsigned(7 downto 0) := (others => '0');
    signal key_s : std_logic_vector(1 downto 0) := "11";
    signal cpu_reset : std_logic;
    signal dram_ready : std_logic;

    -- CPU ports
    signal ci_prime, ci_req, ci_ack, cd_prime, cd_req, cd_we, cd_ack : std_logic;
    signal ci_raddr, ci_addr, ci_rdata, cd_raddr, cd_addr, cd_wdata, cd_rdata : std_logic_vector(31 downto 0);
    signal cd_wstrb : std_logic_vector(3 downto 0);
    signal halted, retire : std_logic;
    signal retire_pc, retire_data : std_logic_vector(31 downto 0);
    signal retire_rd : std_logic_vector(4 downto 0);

    -- cache memory sides
    signal im_req, im_ack : std_logic;
    signal im_addr : std_logic_vector(31 downto 0);
    signal dm_req, dm_we, dm_burst, dm_ack : std_logic;
    signal dm_addr, dm_wdata : std_logic_vector(31 downto 0);
    signal dm_wstrb : std_logic_vector(3 downto 0);
    signal m_rdata : std_logic_vector(31 downto 0);

    -- slave side
    signal s_addr, s_wdata : std_logic_vector(31 downto 0);
    signal s_we, s_burst : std_logic;
    signal s_wstrb : std_logic_vector(3 downto 0);
    signal rom_req, rom_ack, sram_req, sram_ack, sdram_req, sdram_ack : std_logic;
    signal flash_req, flash_ack, io_req, io_ack : std_logic;
    signal rom_rdata, sram_rdata, sdram_rdata, flash_rdata, io_rdata : std_logic_vector(31 downto 0);

    -- video
    signal v_req, v_ack, vblank, pal_we : std_logic;
    signal v_addr : std_logic_vector(17 downto 0);
    signal v_data : std_logic_vector(15 downto 0);
    signal fb_base : std_logic_vector(18 downto 0);
    signal mode16  : std_logic;
    signal pal_idx : std_logic_vector(7 downto 0);
    signal pal_rgb : std_logic_vector(11 downto 0);

    -- small peripherals
    signal tx_start, tx_ready, rx_valid, kbd_valid : std_logic;
    signal tx_data, rx_data, kbd_data : std_logic_vector(7 downto 0);
    signal hex : std_logic_vector(15 downto 0);
    signal dram_ba : std_logic_vector(1 downto 0);
    signal ledr_io : std_logic_vector(9 downto 0);
    signal jt_avail, jt_ovf, jt_pop : std_logic;
    signal jt_data : std_logic_vector(31 downto 0);
    signal con_tx_we, con_tx_full, con_rx_avail, con_rx_pop, con_attached : std_logic;
    signal con_tx_data, con_rx_data : std_logic_vector(7 downto 0);
    signal ci_inval, mtip, msip, poweroff, reboot : std_logic;
    signal mtime : std_logic_vector(63 downto 0);

    function seg7(d : std_logic_vector(3 downto 0)) return std_logic_vector is
    begin
        case d is   -- active low, segment 6 (g) first
            when x"0" => return "1000000";
            when x"1" => return "1111001";
            when x"2" => return "0100100";
            when x"3" => return "0110000";
            when x"4" => return "0011001";
            when x"5" => return "0010010";
            when x"6" => return "0000010";
            when x"7" => return "1111000";
            when x"8" => return "0000000";
            when x"9" => return "0010000";
            when x"A" => return "0001000";
            when x"B" => return "0000011";
            when x"C" => return "1000110";
            when x"D" => return "0100001";
            when x"E" => return "0000110";
            when others => return "0001110";
        end case;
    end function;
begin
    clk      <= CLOCK_50;
    DRAM_CLK <= not clk;

    -- reset: a short power-on pulse, KEY0 or a syscon reboot, then the CPU
    -- waits for SDRAM
    process (clk)
    begin
        if rising_edge(clk) then
            key_s <= key_s(0) & KEY(0);
            if reboot = '1' then
                por   <= (others => '0');
                reset <= '1';
            elsif por /= 255 then
                por   <= por + 1;
                reset <= '1';
            else
                reset <= not key_s(1);
            end if;
        end if;
    end process;
    cpu_reset <= reset or not dram_ready;

    core : entity work.cpu
        generic map (TRACE => TRACE, TRACE_MAX => TRACE_MAX)
        port map (clk, cpu_reset, ci_prime, ci_raddr, ci_req, ci_addr, ci_ack, ci_rdata,
                  cd_prime, cd_raddr, cd_req, cd_addr, cd_we, cd_wstrb, cd_wdata, cd_ack, cd_rdata,
                  ci_inval, mtip, msip, mtime, poweroff,
                  halted, retire, retire_pc, retire_rd, retire_data);

    ic : entity work.icache
        generic map (IB => 9)
        port map (clk, cpu_reset, ci_prime, ci_raddr, ci_req, ci_addr, ci_inval, ci_ack, ci_rdata,
                  im_req, im_addr, im_ack, m_rdata);

    dc : entity work.dcache
        generic map (IB => 9)
        port map (clk, cpu_reset, cd_prime, cd_raddr, cd_req, cd_addr, cd_we, cd_wstrb, cd_wdata, cd_ack, cd_rdata,
                  dm_req, dm_addr, dm_we, dm_wstrb, dm_wdata, dm_burst, dm_ack, m_rdata);

    bus0 : entity work.membus
        port map (clk, cpu_reset,
                  im_req, im_addr, im_ack,
                  dm_req, dm_addr, dm_we, dm_wstrb, dm_wdata, dm_burst, dm_ack,
                  m_rdata,
                  s_addr, s_we, s_wstrb, s_wdata, s_burst,
                  rom_req, rom_ack, rom_rdata,
                  sram_req, sram_ack, sram_rdata,
                  sdram_req, sdram_ack, sdram_rdata,
                  flash_req, flash_ack, flash_rdata,
                  io_req, io_ack, io_rdata);

    rom : entity work.boot_rom
        port map (clk, rom_req, s_addr, s_burst, rom_ack, rom_rdata);

    sram : entity work.sram_ctrl
        port map (clk, reset, sram_req, s_addr, s_we, s_wstrb, s_wdata, s_burst,
                  sram_ack, sram_rdata, v_req, v_addr, v_ack, v_data,
                  SRAM_ADDR, SRAM_DQ, SRAM_WE_N, SRAM_OE_N, SRAM_UB_N, SRAM_LB_N, SRAM_CE_N);

    sdram : entity work.sdram_ctrl
        generic map (INIT_WAIT => SDRAM_INIT_WAIT)
        port map (clk, reset, sdram_req, s_addr, s_we, s_wstrb, s_wdata, s_burst,
                  sdram_ack, sdram_rdata, dram_ready,
                  DRAM_ADDR, dram_ba, DRAM_DQ, DRAM_LDQM, DRAM_UDQM,
                  DRAM_RAS_N, DRAM_CAS_N, DRAM_WE_N, DRAM_CS_N, DRAM_CKE);
    DRAM_BA_0 <= dram_ba(0);
    DRAM_BA_1 <= dram_ba(1);

    flash : entity work.flash_ctrl
        port map (clk, reset, flash_req, s_addr, s_we, s_wdata, s_burst, flash_ack, flash_rdata,
                  FL_ADDR, FL_DQ, FL_OE_N, FL_WE_N, FL_RST_N);

    regs : entity work.io
        port map (clk, reset, io_req, s_addr, s_we, s_wdata, io_ack, io_rdata,
                  tx_start, tx_data, tx_ready, rx_valid, rx_data, kbd_valid, kbd_data,
                  SW, KEY, ledr_io, LEDG, hex, fb_base, mode16, vblank, pal_we, pal_idx, pal_rgb,
                  jt_avail, jt_data, jt_ovf, jt_pop,
                  con_tx_we, con_tx_data, con_tx_full, con_rx_avail, con_rx_data, con_rx_pop, con_attached,
                  mtime, mtip, msip, poweroff, reboot);

    jtag : entity work.jtag_rx
        port map (clk, reset, jt_pop, jt_avail, jt_data, jt_ovf,
                  con_tx_we, con_tx_data, con_tx_full, con_rx_avail, con_rx_data, con_rx_pop, con_attached);

    vid : entity work.video
        port map (clk, reset, fb_base, mode16, pal_we, pal_idx, pal_rgb, vblank,
                  v_req, v_addr, v_ack, v_data,
                  VGA_R, VGA_G, VGA_B, VGA_HS, VGA_VS);

    ser : entity work.uart
        generic map (DIVISOR => UART_DIV)
        port map (clk, reset, tx_start, tx_data, tx_ready, rx_valid, rx_data, UART_TXD, UART_RXD);

    kbd : entity work.ps2_rx
        port map (clk, reset, PS2_CLK, PS2_DAT, kbd_valid, kbd_data);

    FL_CE_N <= '0';   -- the flash is the only thing on its bus

    LEDR <= halted & ledr_io(8 downto 0);
    HEX0 <= seg7(hex(3 downto 0));
    HEX1 <= seg7(hex(7 downto 4));
    HEX2 <= seg7(hex(11 downto 8));
    HEX3 <= seg7(hex(15 downto 12));
end rtl;
