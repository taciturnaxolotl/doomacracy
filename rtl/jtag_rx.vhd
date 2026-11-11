-- JTAG loader receiver. The host shifts long DR scans with IR = 1; every
-- 32 bits (LSB first) become one word, which crosses into the system clock
-- through a toggle handshake and lands in a 16-word FIFO the CPU drains
-- through the I/O registers. IR = 2 reads back {overflow, words received}.
-- IR = 3 is the console (rtl/jtag_console.vhd), on the same instance.
--
-- The handshake is safe because the next word takes 32 TCK cycles to
-- arrive, far longer than the 3-cycle synchroniser at 50 MHz.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity jtag_rx is
    port (
        clk      : in  std_logic;
        reset    : in  std_logic;
        pop      : in  std_logic;
        avail    : out std_logic;
        data     : out std_logic_vector(31 downto 0);
        overflow : out std_logic;
        -- console (IR = 3)
        con_tx_we    : in  std_logic;
        con_tx_data  : in  std_logic_vector(7 downto 0);
        con_tx_full  : out std_logic;
        con_rx_avail : out std_logic;
        con_rx_data  : out std_logic_vector(7 downto 0);
        con_rx_pop   : in  std_logic;
        con_attached : out std_logic
    );
end jtag_rx;

architecture rtl of jtag_rx is
    signal tck, tdi, tdo, cdr, sdr, con_tdo : std_logic;
    signal ir : std_logic_vector(1 downto 0);

    -- TCK domain
    signal sr     : std_logic_vector(31 downto 0) := (others => '0');
    signal nbits  : unsigned(4 downto 0) := (others => '0');
    signal hold   : std_logic_vector(31 downto 0) := (others => '0');
    signal tog    : std_logic := '0';
    signal st_s1, st_s2 : std_logic_vector(31 downto 0) := (others => '0');

    -- clk domain
    signal tog_s  : std_logic_vector(2 downto 0) := "000";
    type fifo_t is array (0 to 15) of std_logic_vector(31 downto 0);
    signal fifo   : fifo_t := (others => (others => '0'));
    signal wr, rd : unsigned(3 downto 0) := (others => '0');
    signal count  : integer range 0 to 16 := 0;
    signal ovf    : std_logic := '0';
    signal got    : unsigned(30 downto 0) := (others => '0');
    signal status : std_logic_vector(31 downto 0);
begin
    port0 : entity work.vjtag_port port map (tck, tdi, tdo, ir, cdr, sdr);

    tdo <= con_tdo when ir = "11" else sr(0);

    con : entity work.jtag_console
        port map (clk, tck, tdi, ir, cdr, sdr, con_tdo,
                  con_tx_we, con_tx_data, con_tx_full, con_rx_avail, con_rx_data, con_rx_pop,
                  con_attached);

    process (tck)
        variable nxt : std_logic_vector(31 downto 0);
    begin
        if rising_edge(tck) then
            st_s1 <= status;
            st_s2 <= st_s1;
            if cdr = '1' then
                nbits <= (others => '0');
                if ir = "10" then
                    sr <= st_s2;
                end if;
            elsif sdr = '1' then
                nxt := tdi & sr(31 downto 1);
                sr  <= nxt;
                if ir = "01" then
                    nbits <= nbits + 1;
                    if nbits = 31 then
                        hold <= nxt;
                        tog  <= not tog;
                    end if;
                end if;
            end if;
        end if;
    end process;

    status   <= ovf & std_logic_vector(got);
    avail    <= '1' when count /= 0 else '0';
    data     <= fifo(to_integer(rd));
    overflow <= ovf;

    process (clk)
        variable push, take : boolean;
    begin
        if rising_edge(clk) then
            tog_s <= tog_s(1 downto 0) & tog;
            push := tog_s(2) /= tog_s(1);
            take := pop = '1' and count /= 0;
            if push then
                got <= got + 1;
                if count = 16 and not take then
                    ovf  <= '1';
                    push := false;
                else
                    fifo(to_integer(wr)) <= hold;
                    wr <= wr + 1;
                end if;
            end if;
            if take then
                rd <= rd + 1;
            end if;
            if push and not take then
                count <= count + 1;
            elsif take and not push then
                count <= count - 1;
            end if;
            if reset = '1' then
                wr <= (others => '0'); rd <= (others => '0'); count <= 0;
                ovf <= '0'; got <= (others => '0');
            end if;
        end if;
    end process;
end rtl;
