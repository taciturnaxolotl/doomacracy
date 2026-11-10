-- Altera Virtual JTAG instance (2-bit IR). Quartus only; simulation uses
-- sim/vjtag_port_sim.vhd, which has the same entity.
library ieee;
use ieee.std_logic_1164.all;

entity vjtag_port is
    port (
        tck  : out std_logic;
        tdi  : out std_logic;
        tdo  : in  std_logic;
        ir   : out std_logic_vector(1 downto 0);
        cdr  : out std_logic;   -- capture DR
        sdr  : out std_logic    -- shift DR: tdi valid on this tck edge
    );
end vjtag_port;

architecture rtl of vjtag_port is
    component sld_virtual_jtag
        generic (
            sld_auto_instance_index : string  := "YES";
            sld_instance_index      : natural := 0;
            sld_ir_width            : natural := 1;
            sld_sim_action          : string  := "";
            sld_sim_n_scan          : natural := 0;
            sld_sim_total_length    : natural := 0;
            lpm_type                : string  := "sld_virtual_jtag"
        );
        port (
            ir_out             : in  std_logic_vector(sld_ir_width - 1 downto 0);
            tdo                : in  std_logic;
            ir_in              : out std_logic_vector(sld_ir_width - 1 downto 0);
            tck                : out std_logic;
            tdi                : out std_logic;
            virtual_state_cdr  : out std_logic;
            virtual_state_cir  : out std_logic;
            virtual_state_e1dr : out std_logic;
            virtual_state_e2dr : out std_logic;
            virtual_state_pdr  : out std_logic;
            virtual_state_sdr  : out std_logic;
            virtual_state_udr  : out std_logic;
            virtual_state_uir  : out std_logic
        );
    end component;
begin
    vj : sld_virtual_jtag
        generic map (sld_auto_instance_index => "YES", sld_instance_index => 0, sld_ir_width => 2)
        port map (ir_out => "00", tdo => tdo, ir_in => ir, tck => tck, tdi => tdi,
                  virtual_state_cdr => cdr, virtual_state_sdr => sdr,
                  virtual_state_cir => open, virtual_state_e1dr => open, virtual_state_e2dr => open,
                  virtual_state_pdr => open, virtual_state_udr => open, virtual_state_uir => open);
end rtl;
