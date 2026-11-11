-- 640x480 @ 60 Hz out of the 50 MHz clock (pixel every other cycle).
-- Shows a 320x200 framebuffer from SRAM (8 bpp through the palette, or
-- RGB565 when mode16 is set), each pixel 2x2, on VGA rows
-- 40..439. Each source line is fetched into one half of a two-line buffer
-- while the other half is on screen.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity video is
    port (
        clk      : in  std_logic;
        reset    : in  std_logic;
        fb_base  : in  std_logic_vector(18 downto 0);  -- byte offset in SRAM
        mode16   : in  std_logic;   -- 1: RGB565 pixels instead of palette indices
        pal_we   : in  std_logic;
        pal_idx  : in  std_logic_vector(7 downto 0);
        pal_rgb  : in  std_logic_vector(11 downto 0);
        vblank   : out std_logic;   -- one cycle at the start of vertical blank
        -- SRAM read port
        v_req    : out std_logic;
        v_addr   : out std_logic_vector(17 downto 0);
        v_ack    : in  std_logic;
        v_data   : in  std_logic_vector(15 downto 0);
        VGA_R    : out std_logic_vector(3 downto 0);
        VGA_G    : out std_logic_vector(3 downto 0);
        VGA_B    : out std_logic_vector(3 downto 0);
        VGA_HS   : out std_logic;
        VGA_VS   : out std_logic
    );
end video;

architecture rtl of video is
    signal pix_en : std_logic := '0';
    signal h, v   : unsigned(9 downto 0) := (others => '0');
    signal base   : unsigned(17 downto 0) := (others => '0');  -- halfword address
    signal m16    : std_logic := '0';   -- mode16, latched with base

    -- line fetch
    signal fetching : std_logic := '0';
    signal f_line   : unsigned(7 downto 0) := (others => '0');
    signal f_count  : unsigned(8 downto 0) := (others => '0');
    signal f_addr   : unsigned(17 downto 0) := (others => '0');
    signal lb_we    : std_logic;
    signal lb_wa    : std_logic_vector(9 downto 0);
    signal lb_ra    : std_logic_vector(9 downto 0);
    signal rgb1     : std_logic_vector(11 downto 0) := (others => '0');
    signal lb_q     : std_logic_vector(15 downto 0);

    signal pal_ra   : std_logic_vector(7 downto 0);
    signal pal_q    : std_logic_vector(11 downto 0);

    -- display pipeline: line buffer read, palette read, output register
    signal act0, act1, act2 : std_logic := '0';
    signal hs0, hs1, hs2    : std_logic := '1';
    signal vs0, vs1, vs2    : std_logic := '1';
    signal hi1              : std_logic := '0';
    signal src_row          : unsigned(9 downto 0);
    signal shown            : std_logic;
begin
    lbuf : entity work.sdpram
        generic map (10, 16)
        port map (clk, lb_we, lb_wa, v_data, lb_ra, lb_q);

    pal : entity work.sdpram
        generic map (8, 12)
        port map (clk, pal_we, pal_idx, pal_rgb, pal_ra, pal_q);

    -- source line on screen now: (v - 40) / 2
    src_row <= v - 40;
    shown   <= '1' when h < 640 and v >= 40 and v < 440 else '0';

    lb_we <= v_ack;
    lb_wa <= std_logic_vector(f_line(0) & f_count);
    -- 8 bpp: 160 halfwords per line, two pixels each; 16 bpp: 320, one each
    lb_ra <= std_logic_vector(src_row(1) & '0' & h(9 downto 2)) when m16 = '0' else
             std_logic_vector(src_row(1) & h(9 downto 1));

    pal_ra <= lb_q(15 downto 8) when hi1 = '1' else lb_q(7 downto 0);

    v_req  <= fetching;
    v_addr <= std_logic_vector(f_addr);

    process (clk)
    begin
        if rising_edge(clk) then
            pix_en <= not pix_en;
            vblank <= '0';

            if pix_en = '1' then
                if h = 799 then
                    h <= (others => '0');
                    if v = 524 then
                        v <= (others => '0');
                    else
                        v <= v + 1;
                    end if;
                    -- start of a VGA line: on odd lines 39..437 fetch the
                    -- source line that goes on screen at the next line
                    if v >= 38 and v <= 436 and v(0) = '0' then
                        fetching <= '1';
                        f_line   <= resize(shift_right(v + 1 - 39, 1), 8);
                        f_count  <= (others => '0');
                        if m16 = '1' then
                            f_addr <= base + resize(shift_right(v + 1 - 39, 1) * 320, 18);
                        else
                            f_addr <= base + resize(shift_right(v + 1 - 39, 1) * 160, 18);
                        end if;
                    end if;
                    -- new framebuffer takes effect at the start of vertical
                    -- blank, the same moment FRAME_COUNT ticks
                    if v = 479 then
                        vblank <= '1';
                        base   <= unsigned(fb_base(18 downto 1));
                        m16    <= mode16;
                    end if;
                else
                    h <= h + 1;
                end if;
            end if;

            if v_ack = '1' then
                f_addr  <= f_addr + 1;
                f_count <= f_count + 1;
                if (m16 = '0' and f_count = 159) or f_count = 319 then
                    fetching <= '0';
                end if;
            end if;

            -- pipeline: cycle 0 addresses the line buffer, cycle 1 the
            -- palette, cycle 2 registers the pins
            act0 <= shown;
            if h >= 656 and h < 752 then hs0 <= '0'; else hs0 <= '1'; end if;
            if v >= 490 and v < 492 then vs0 <= '0'; else vs0 <= '1'; end if;
            hi1  <= h(1);
            -- RGB565 to the DAC's 4 bits per channel, one cycle behind lb_q
            -- so it lines up with the palette output
            rgb1 <= lb_q(15 downto 12) & lb_q(10 downto 7) & lb_q(4 downto 1);
            act1 <= act0; hs1 <= hs0; vs1 <= vs0;
            act2 <= act1; hs2 <= hs1; vs2 <= vs1;

            if act2 = '1' and m16 = '1' then
                VGA_R <= rgb1(11 downto 8);
                VGA_G <= rgb1(7 downto 4);
                VGA_B <= rgb1(3 downto 0);
            elsif act2 = '1' then
                VGA_R <= pal_q(11 downto 8);
                VGA_G <= pal_q(7 downto 4);
                VGA_B <= pal_q(3 downto 0);
            else
                VGA_R <= (others => '0');
                VGA_G <= (others => '0');
                VGA_B <= (others => '0');
            end if;
            VGA_HS <= hs2;
            VGA_VS <= vs2;

            if reset = '1' then
                fetching <= '0';
            end if;
        end if;
    end process;
end rtl;
