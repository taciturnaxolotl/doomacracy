-- Console over the Virtual JTAG (IR = 3), the transport behind the 16550 at
-- 0xF000_1000. Two 16-byte FIFOs built from logic registers, each crossing
-- between TCK and the system clock as a classic asynchronous FIFO: the
-- writer's pointer goes to the reader in Gray code through two flip-flops,
-- and the reader's pointer comes back the same way. Each pointer moves by
-- at most one per clock of its own domain, so the Gray value is always safe
-- to sample. TCK only runs while the host is scanning, which only makes the
-- other side's view of a pointer older, never wrong.
--
-- One DR scan of 80 bits (least significant bit first) moves bytes both
-- ways. What the board shifts out, captured at Capture-DR:
--
--   [3:0]   n, TX bytes in this frame (0..8)
--   [7:4]   0xA, so the host can tell the console is there
--   [12:8]  RX read pointer (mod 32): bytes the board has taken so far
--   [13]    attached
--   [15:14] 0
--   [79:16] TX bytes, byte i in bits 16+8i .. 23+8i, valid for i < n
--
-- What the host shifts in:
--
--   [3:0]   m, RX bytes in this frame (0..8)
--   [4]     attach: from now on the board waits for the host when the TX
--           FIFO is full instead of dropping bytes. A host that stops
--           scanning for about 0.67 s (2**25 clocks) counts as detached, so
--           a killed host script cannot stall the board for long.
--   [5]     detach
--   [15:6]  0
--   [79:16] RX bytes, byte i valid for i < m
--
-- A TX byte leaves the FIFO as its last bit is shifted, an RX byte enters
-- it the same way, so a scan must always be shifted to the end (the host
-- script always does). Flow control for RX is a credit: the host counts the
-- bytes it has sent (mod 32) and never has more than 16 outstanding beyond
-- the board's RX read pointer from the latest frame. The pointers are not
-- reset with the system: the FIFOs are a transport and outlive a reboot.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity jtag_console is
    port (
        clk      : in  std_logic;
        -- virtual JTAG, TCK domain
        tck      : in  std_logic;
        tdi      : in  std_logic;
        ir       : in  std_logic_vector(1 downto 0);
        cdr      : in  std_logic;
        sdr      : in  std_logic;
        tdo      : out std_logic;
        -- system side
        tx_we    : in  std_logic;                     -- push, ignored when full
        tx_data  : in  std_logic_vector(7 downto 0);
        tx_full  : out std_logic;
        rx_avail : out std_logic;
        rx_data  : out std_logic_vector(7 downto 0);
        rx_pop   : in  std_logic;
        attached : out std_logic
    );
end jtag_console;

architecture rtl of jtag_console is
    type mem_t is array (0 to 15) of std_logic_vector(7 downto 0);
    subtype ptr_t is unsigned(4 downto 0);

    function to_gray(b : ptr_t) return std_logic_vector is
    begin
        return std_logic_vector(b xor ('0' & b(4 downto 1)));
    end function;

    function from_gray(g : std_logic_vector(4 downto 0)) return ptr_t is
        variable b : ptr_t;
    begin
        b(4) := g(4);
        for i in 3 downto 0 loop
            b(i) := b(i + 1) xor g(i);
        end loop;
        return b;
    end function;

    -- TX: written on clk, read on TCK
    signal tx_mem  : mem_t := (others => (others => '0'));
    signal tx_wp   : ptr_t := (others => '0');                          -- clk
    signal tx_wp_g : std_logic_vector(4 downto 0) := (others => '0');   -- clk
    signal tx_rp   : ptr_t := (others => '0');                          -- tck
    signal tx_rp_g : std_logic_vector(4 downto 0) := (others => '0');   -- tck
    signal tx_wp_s1, tx_wp_s2 : std_logic_vector(4 downto 0) := (others => '0');  -- tck
    signal tx_rp_s1, tx_rp_s2 : std_logic_vector(4 downto 0) := (others => '0');  -- clk

    -- RX: written on TCK, read on clk
    signal rx_mem  : mem_t := (others => (others => '0'));
    signal rx_wp   : ptr_t := (others => '0');                          -- tck
    signal rx_wp_g : std_logic_vector(4 downto 0) := (others => '0');   -- tck
    signal rx_rp   : ptr_t := (others => '0');                          -- clk
    signal rx_rp_g : std_logic_vector(4 downto 0) := (others => '0');   -- clk
    signal rx_wp_s1, rx_wp_s2 : std_logic_vector(4 downto 0) := (others => '0');  -- clk
    signal rx_rp_s1, rx_rp_s2 : std_logic_vector(4 downto 0) := (others => '0');  -- tck

    -- the FIFOs are read asynchronously from the other clock domain: logic
    -- registers, never block RAM
    attribute ramstyle : string;
    attribute ramstyle of tx_mem : signal is "logic";
    attribute ramstyle of rx_mem : signal is "logic";

    -- TCK side of a scan
    signal cnt   : unsigned(6 downto 0) := (others => '0');   -- bits shifted, saturating
    signal hdr   : std_logic_vector(15 downto 0) := (others => '0');
    signal hin   : std_logic_vector(5 downto 0) := (others => '0');
    signal ntx   : unsigned(3 downto 0) := (others => '0');
    signal nrx   : unsigned(3 downto 0) := (others => '0');
    signal bin   : std_logic_vector(7 downto 0) := (others => '0');
    signal att   : std_logic := '0';
    signal att_s : std_logic_vector(1 downto 0) := "00";
    signal k     : unsigned(3 downto 0);   -- byte index in the data part
    signal txb   : std_logic_vector(7 downto 0);
    signal scan_tog : std_logic := '0';                      -- tck: flips every console scan
    signal scan_s   : std_logic_vector(2 downto 0) := "000"; -- clk
    signal idle     : unsigned(25 downto 0) := (others => '0');
begin
    k   <= cnt(6 downto 3) - 2;
    txb <= tx_mem(to_integer(tx_rp(3 downto 0)));
    tdo <= hdr(0) when cnt < 16 else
           txb(to_integer(cnt(2 downto 0))) when k < ntx else
           '0';

    process (tck)
        variable avail : ptr_t;
        variable byte  : std_logic_vector(7 downto 0);
    begin
        if rising_edge(tck) then
            tx_wp_s1 <= tx_wp_g;
            tx_wp_s2 <= tx_wp_s1;
            rx_rp_s1 <= rx_rp_g;
            rx_rp_s2 <= rx_rp_s1;
            if ir = "11" then
                if cdr = '1' then
                    scan_tog <= not scan_tog;
                    cnt   <= (others => '0');
                    avail := from_gray(tx_wp_s2) - tx_rp;
                    if avail > 8 then
                        avail := to_unsigned(8, 5);
                    end if;
                    ntx <= avail(3 downto 0);
                    hdr <= "00" & att & std_logic_vector(from_gray(rx_rp_s2)) & "1010"
                           & std_logic_vector(avail(3 downto 0));
                    nrx <= (others => '0');
                elsif sdr = '1' then
                    if cnt /= 127 then
                        cnt <= cnt + 1;
                    end if;
                    hdr <= '0' & hdr(15 downto 1);
                    if cnt < 6 then
                        hin <= tdi & hin(5 downto 1);
                    end if;
                    if cnt = 6 then
                        nrx <= unsigned(hin(3 downto 0));
                        if hin(4) = '1' then att <= '1'; end if;
                        if hin(5) = '1' then att <= '0'; end if;
                    end if;
                    bin  <= tdi & bin(7 downto 1);
                    byte := tdi & bin(7 downto 1);
                    if cnt >= 16 and cnt(2 downto 0) = "111" then
                        if k < nrx and nrx <= 8 then
                            rx_mem(to_integer(rx_wp(3 downto 0))) <= byte;
                            rx_wp   <= rx_wp + 1;
                            rx_wp_g <= to_gray(rx_wp + 1);
                        end if;
                        if k < ntx then
                            tx_rp   <= tx_rp + 1;
                            tx_rp_g <= to_gray(tx_rp + 1);
                        end if;
                    end if;
                end if;
            end if;
        end if;
    end process;

    -- system clock side
    tx_full  <= '1' when tx_wp - from_gray(tx_rp_s2) = 16 else '0';
    rx_avail <= '1' when from_gray(rx_wp_s2) /= rx_rp else '0';
    rx_data  <= rx_mem(to_integer(rx_rp(3 downto 0)));
    attached <= att_s(1) and not idle(25);

    process (clk)
    begin
        if rising_edge(clk) then
            tx_rp_s1 <= tx_rp_g;
            tx_rp_s2 <= tx_rp_s1;
            rx_wp_s1 <= rx_wp_g;
            rx_wp_s2 <= rx_wp_s1;
            att_s    <= att_s(0) & att;
            scan_s   <= scan_s(1 downto 0) & scan_tog;
            if scan_s(2) /= scan_s(1) then
                idle <= (others => '0');
            elsif idle(25) = '0' then
                idle <= idle + 1;
            end if;
            if tx_we = '1' and tx_wp - from_gray(tx_rp_s2) /= 16 then
                tx_mem(to_integer(tx_wp(3 downto 0))) <= tx_data;
                tx_wp   <= tx_wp + 1;
                tx_wp_g <= to_gray(tx_wp + 1);
            end if;
            if rx_pop = '1' and from_gray(rx_wp_s2) /= rx_rp then
                rx_rp   <= rx_rp + 1;
                rx_rp_g <= to_gray(rx_rp + 1);
            end if;
        end if;
    end process;
end rtl;
