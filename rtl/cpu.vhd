-- RV32IMA + Zicsr, multicycle, machine and user modes (spec.md, "Linux
-- platform"). An ALU instruction takes two cycles:
-- EXEC computes and asks for the next instruction, FETCH waits for it. The
-- next fetch is issued in the cycle an instruction finishes, so a cache hit
-- lands one cycle later with nothing wasted in between.
--
-- Bus protocol (both ports): hold req, addr, we, wstrb, wdata steady until ack.
-- ack is one cycle; rdata is valid with it. A new request may start in the
-- cycle after ack. addr and req always come straight from registers; the
-- combinational next address only goes to raddr, to start the cache RAM read
-- a cycle early.
--
-- Traps: everything goes to mtvec, but only once mtvec is nonzero. Until
-- then ECALL, EBREAK and illegal instructions halt the CPU (halted output)
-- and faulting accesses go ahead as they always did, exactly like the
-- emulator, so firmware without a handler behaves as before. Interrupts
-- (CLINT timer and software) are taken between instructions, in the first
-- cycle of FETCH, before the fetch is requested. WFI is a no-op.
--
-- A extension: LR/SC keep a one-word reservation; AMOs are a read, one
-- cycle to compute, then a write, all through the data port. FENCE.I tells
-- the I-cache to invalidate itself; the next fetch simply waits for it.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
-- synthesis translate_off
use std.textio.all;
use ieee.std_logic_textio.all;
-- synthesis translate_on

entity cpu is
    generic (
        RESET_PC  : std_logic_vector(31 downto 0) := x"00000000";
        TRACE     : string  := "";   -- simulation only: retirement trace file
        TRACE_MAX : integer := 0
    );
    port (
        clk     : in  std_logic;
        reset   : in  std_logic;
        -- instruction port. raddr is the early address for the cache RAMs;
        -- addr, req and everything the cache decides on are registered.
        -- prime says: next cycle's addr is this cycle's raddr.
        i_prime : out std_logic;
        i_raddr : out std_logic_vector(31 downto 0);
        i_req   : out std_logic;
        i_addr  : out std_logic_vector(31 downto 0);
        i_ack   : in  std_logic;
        i_rdata : in  std_logic_vector(31 downto 0);
        -- data port, same split as the instruction port
        d_prime : out std_logic;
        d_raddr : out std_logic_vector(31 downto 0);
        d_req   : out std_logic;
        d_addr  : out std_logic_vector(31 downto 0);
        d_we    : out std_logic;
        d_wstrb : out std_logic_vector(3 downto 0);
        d_wdata : out std_logic_vector(31 downto 0);
        d_ack   : in  std_logic;
        d_rdata : in  std_logic_vector(31 downto 0);
        -- FENCE.I: one-cycle pulse, the I-cache invalidates every line
        i_inval : out std_logic;
        -- CLINT
        irq_timer : in std_logic;                     -- mip.MTIP
        irq_soft  : in std_logic;                     -- mip.MSIP
        irq_ext   : in std_logic;                     -- mip.MEIP (PS/2 receive)
        mtime     : in std_logic_vector(63 downto 0); -- time CSR
        halt_req  : in std_logic;                     -- syscon power off
        -- debug
        halted  : out std_logic;
        retire  : out std_logic;                      -- one cycle per retired instruction
        retire_pc   : out std_logic_vector(31 downto 0);
        retire_rd   : out std_logic_vector(4 downto 0); -- 0 when nothing written
        retire_data : out std_logic_vector(31 downto 0)
    );
end cpu;

architecture rtl of cpu is
    type state_t is (S_FETCH, S_EXEC, S_MEM, S_AMOC, S_AMOW, S_MUL0, S_MUL1, S_MUL2, S_DIV, S_HALT);
    signal state : state_t := S_FETCH;

    signal pc    : unsigned(31 downto 0) := unsigned(RESET_PC);
    signal instr : std_logic_vector(31 downto 0) := (others => '0');

    -- register file: two copies so both operands read in one cycle; the read
    -- address is registered, the way an M4K wants it
    type regs_t is array (0 to 31) of std_logic_vector(31 downto 0);
    signal rf_a, rf_b : regs_t := (others => (others => '0'));
    signal ra1, ra2   : std_logic_vector(4 downto 0) := (others => '0');
    signal rs1v, rs2v : std_logic_vector(31 downto 0);
    signal rf_we      : std_logic;
    signal rf_wa      : std_logic_vector(4 downto 0);
    signal rf_wd      : std_logic_vector(31 downto 0);

    -- memory access in flight
    signal m_addr  : std_logic_vector(31 downto 0) := (others => '0');
    signal m_we    : std_logic := '0';
    signal m_wstrb : std_logic_vector(3 downto 0) := (others => '0');
    signal m_wdata : std_logic_vector(31 downto 0) := (others => '0');

    -- multiply
    -- multiply: 33x33 signed as four registered partial products, then a sum
    signal mul_a, mul_b : signed(32 downto 0) := (others => '0');
    signal pp_hh        : signed(33 downto 0) := (others => '0');  -- 17s x 17s
    signal pp_hl, pp_lh : signed(33 downto 0) := (others => '0');  -- 17s x 16u
    signal pp_ll        : unsigned(31 downto 0) := (others => '0');
    signal mul_p        : signed(65 downto 0) := (others => '0');

    -- divide (restoring, one bit a cycle)
    signal div_count : integer range 0 to 32 := 0;
    signal div_quo   : unsigned(31 downto 0) := (others => '0');
    signal div_rem   : unsigned(31 downto 0) := (others => '0');
    signal div_den   : unsigned(31 downto 0) := (others => '0');
    signal div_negq  : std_logic := '0';
    signal div_negr  : std_logic := '0';
    signal div_byz   : std_logic := '0';
    signal div_ovf   : std_logic := '0';
    signal div_dvd0  : std_logic_vector(31 downto 0) := (others => '0');

    signal cycles  : unsigned(63 downto 0) := (others => '0');
    signal instret : unsigned(63 downto 0) := (others => '0');

    -- machine mode state
    signal priv_m   : std_logic := '1';   -- 1 = machine, 0 = user
    signal st_mie, st_mpie : std_logic := '0';
    signal st_mpp   : std_logic_vector(1 downto 0) := "00";
    signal ie_s, ie_t, ie_e : std_logic := '0';   -- mie bits 3, 7, 11
    signal mtvec, mscratch, mepc, mcause, mtval : std_logic_vector(31 downto 0) := (others => '0');
    signal traps_on : std_logic := '0';  -- mtvec /= 0
    signal lr_valid : std_logic := '0';
    signal lr_addr  : unsigned(31 downto 2) := (others => '0');
    signal amo_old  : std_logic_vector(31 downto 0) := (others => '0');
    signal fetch_first : std_logic := '1';  -- first cycle of FETCH: interrupts go here

    -- decode of the new instructions
    signal is_csr, sys_ecall, sys_ebreak, sys_mret, sys_wfi : std_logic;
    signal amo_lr, amo_sc, amo_badf5, illegal : std_logic;
    signal csr_rdata, csr_wdata : std_logic_vector(31 downto 0);
    signal csr_we   : std_logic;
    signal imm_mem  : unsigned(31 downto 0);
    signal mis, ld_fault, st_fault, lr_hit : std_logic;
    signal exc, stop  : std_logic;   -- EXEC: take a trap / halt
    signal exc_cause  : std_logic_vector(3 downto 0);
    signal exc_tval   : std_logic_vector(31 downto 0);
    signal irq_take, fetch_bad, ftrap, fstop : std_logic;
    signal amo_new  : std_logic_vector(31 downto 0);

    -- decode
    signal opcode : std_logic_vector(6 downto 0);
    signal funct3 : std_logic_vector(2 downto 0);
    signal funct7 : std_logic_vector(6 downto 0);
    signal rd     : std_logic_vector(4 downto 0);
    signal imm_i, imm_s, imm_b, imm_u, imm_j : unsigned(31 downto 0);

    -- combinational results
    signal next_pc  : unsigned(31 downto 0);
    signal pc4      : unsigned(31 downto 0);
    signal alu_out  : std_logic_vector(31 downto 0);
    signal ea       : unsigned(31 downto 0);
    signal load_val : std_logic_vector(31 downto 0);
    signal finish   : std_logic;   -- current instruction completes this cycle
    signal st_strb  : std_logic_vector(3 downto 0);
    signal st_data  : std_logic_vector(31 downto 0);

    constant OP_LUI    : std_logic_vector(6 downto 0) := "0110111";
    constant OP_AUIPC  : std_logic_vector(6 downto 0) := "0010111";
    constant OP_JAL    : std_logic_vector(6 downto 0) := "1101111";
    constant OP_JALR   : std_logic_vector(6 downto 0) := "1100111";
    constant OP_BRANCH : std_logic_vector(6 downto 0) := "1100011";
    constant OP_LOAD   : std_logic_vector(6 downto 0) := "0000011";
    constant OP_STORE  : std_logic_vector(6 downto 0) := "0100011";
    constant OP_IMM    : std_logic_vector(6 downto 0) := "0010011";
    constant OP_REG    : std_logic_vector(6 downto 0) := "0110011";
    constant OP_FENCE  : std_logic_vector(6 downto 0) := "0001111";
    constant OP_SYSTEM : std_logic_vector(6 downto 0) := "1110011";
    constant OP_AMO    : std_logic_vector(6 downto 0) := "0101111";

    -- Would this data access fault (spec.md memory map, as the emulator
    -- sees it)? sz is funct3(1:0): 00 byte, 01 half, 10 word.
    function acc_fault(a : unsigned(31 downto 0); sz : std_logic_vector(1 downto 0);
                       st : boolean) return std_logic is
        variable off : unsigned(27 downto 0);
        variable f   : boolean;
    begin
        off := a(27 downto 0);
        case a(31 downto 28) is
            when x"0" => f := st or off(27 downto 12) /= 0;           -- 4 KB ROM
            when x"1" => f := off(27 downto 19) /= 0;                 -- 512 KB SRAM
            when x"2" | x"8" => f := off(27 downto 23) /= 0;          -- 8 MB SDRAM
            when x"3" => f := off(27 downto 22) /= 0 or (st and sz /= "00");  -- flash
            when x"F" =>                                              -- I/O: words only
                f := sz /= "10" or not (off(27 downto 8) = 0                    -- registers
                                        or off(27 downto 5) = 16#80#            -- 16550
                                        or off = 16#2000#                       -- syscon
                                        or off(27 downto 3) = 16#600#           -- PS/2 (altera_ps2)
                                        or off(27 downto 22) = 16               -- PLIC
                                        or off(27 downto 16) = 16#100#);        -- CLINT
            when others => f := true;
        end case;
        if f then return '1'; else return '0'; end if;
    end function;

    function sext(v : std_logic_vector) return unsigned is
        variable r : unsigned(31 downto 0);
    begin
        r := (others => v(v'left));
        r(v'length - 1 downto 0) := unsigned(v);
        return r;
    end function;
begin
    opcode <= instr(6 downto 0);
    funct3 <= instr(14 downto 12);
    funct7 <= instr(31 downto 25);
    rd     <= instr(11 downto 7);

    imm_i <= sext(instr(31 downto 20));
    imm_s <= sext(instr(31 downto 25) & instr(11 downto 7));
    imm_b <= sext(instr(31) & instr(7) & instr(30 downto 25) & instr(11 downto 8) & '0');
    imm_u <= unsigned(instr(31 downto 12)) & x"000";
    imm_j <= sext(instr(31) & instr(19 downto 12) & instr(20) & instr(30 downto 21) & '0');

    pc4 <= pc + 4;
    -- the immediate comes from the instruction register, so the mux stays off
    -- the register-file-to-adder path
    imm_mem <= imm_s when opcode = OP_STORE else (others => '0') when opcode = OP_AMO else imm_i;
    ea  <= unsigned(rs1v) + imm_mem;

    -- register file read: the address follows the instruction as it arrives
    ra1 <= i_rdata(19 downto 15) when state = S_FETCH else instr(19 downto 15);
    ra2 <= i_rdata(24 downto 20) when state = S_FETCH else instr(24 downto 20);

    process (clk)
    begin
        if rising_edge(clk) then
            if rf_we = '1' then
                rf_a(to_integer(unsigned(rf_wa))) <= rf_wd;
                rf_b(to_integer(unsigned(rf_wa))) <= rf_wd;
            end if;
            rs1v <= rf_a(to_integer(unsigned(ra1)));
            rs2v <= rf_b(to_integer(unsigned(ra2)));
        end if;
    end process;

    ---------------------------------------------------------------- decode
    sys_ecall  <= '1' when instr = x"00000073" else '0';
    sys_ebreak <= '1' when instr = x"00100073" else '0';
    sys_mret   <= '1' when instr = x"30200073" else '0';
    sys_wfi    <= '1' when instr = x"10500073" else '0';
    is_csr     <= '1' when opcode = OP_SYSTEM and funct3(1 downto 0) /= "00" else '0';
    amo_lr     <= '1' when instr(31 downto 27) = "00010" else '0';
    amo_sc     <= '1' when instr(31 downto 27) = "00011" else '0';
    with instr(31 downto 27) select amo_badf5 <=
        '0' when "00000" | "00001" | "00010" | "00011" | "00100" | "01000" | "01100"
               | "10000" | "10100" | "11000" | "11100",
        '1' when others;

    -- everything the emulator rejects as an illegal instruction (AMO funct5
    -- is separate: the emulator checks it after the address)
    process (opcode, funct3, funct7, sys_ecall, sys_ebreak, sys_mret, sys_wfi)
        variable il : boolean;
    begin
        il := false;
        case opcode is
            when OP_LUI | OP_AUIPC | OP_JAL | OP_FENCE => null;
            when OP_JALR   => il := funct3 /= "000";
            when OP_BRANCH => il := funct3(2 downto 1) = "01";
            when OP_LOAD   => il := funct3 = "011" or funct3(2 downto 1) = "11";
            when OP_STORE  => il := funct3(2) = '1' or funct3 = "011";
            when OP_IMM    =>
                il := (funct3 = "001" and funct7 /= "0000000")
                   or (funct3 = "101" and funct7 /= "0000000" and funct7 /= "0100000");
            when OP_REG    =>
                il := not (funct7 = "0000000" or funct7 = "0000001"
                           or (funct7 = "0100000" and (funct3 = "000" or funct3 = "101")));
            when OP_AMO    => il := funct3 /= "010";
            when OP_SYSTEM =>
                if funct3 = "000" then
                    il := sys_ecall = '0' and sys_ebreak = '0' and sys_mret = '0' and sys_wfi = '0';
                else
                    il := funct3 = "100";
                end if;
            when others => il := true;
        end case;
        if il then illegal <= '1'; else illegal <= '0'; end if;
    end process;

    ---------------------------------------------------------------- CSRs
    process (instr, st_mie, st_mpie, st_mpp, ie_s, ie_t, ie_e, mtvec, mscratch, mepc, mcause,
             mtval, irq_timer, irq_soft, irq_ext, cycles, instret, mtime)
        variable r : std_logic_vector(31 downto 0);
    begin
        r := (others => '0');
        case instr(31 downto 20) is
            when x"300" => r(12 downto 11) := st_mpp; r(7) := st_mpie; r(3) := st_mie;
            when x"301" => r := x"40101101";              -- RV32 I M A U
            when x"304" => r(11) := ie_e; r(7) := ie_t; r(3) := ie_s;
            when x"305" => r := mtvec;
            when x"340" => r := mscratch;
            when x"341" => r := mepc;
            when x"342" => r := mcause;
            when x"343" => r := mtval;
            when x"344" => r(11) := irq_ext; r(7) := irq_timer; r(3) := irq_soft;
            when x"C00" | x"B00" => r := std_logic_vector(cycles(31 downto 0));
            when x"C80" | x"B80" => r := std_logic_vector(cycles(63 downto 32));
            when x"C01"          => r := mtime(31 downto 0);
            when x"C81"          => r := mtime(63 downto 32);
            when x"C02" | x"B02" => r := std_logic_vector(instret(31 downto 0));
            when x"C82" | x"B82" => r := std_logic_vector(instret(63 downto 32));
            when others => null;
        end case;
        csr_rdata <= r;
    end process;

    process (funct3, instr, rs1v, csr_rdata)
        variable src : std_logic_vector(31 downto 0);
    begin
        if funct3(2) = '1' then
            src := x"000000" & "000" & instr(19 downto 15);
        else
            src := rs1v;
        end if;
        case funct3(1 downto 0) is
            when "01"   => csr_wdata <= src;
            when "10"   => csr_wdata <= csr_rdata or src;
            when others => csr_wdata <= csr_rdata and not src;
        end case;
    end process;
    csr_we <= '1' when funct3(1 downto 0) = "01" or instr(19 downto 15) /= "00000" else '0';

    ---------------------------------------------------------------- traps
    process (opcode, funct3, ea)
        variable sz : std_logic_vector(1 downto 0);
    begin
        if opcode = OP_AMO then sz := "10"; else sz := funct3(1 downto 0); end if;
        mis <= '0';
        if (sz = "01" and ea(0) = '1') or (sz(1) = '1' and ea(1 downto 0) /= "00") then
            mis <= '1';
        end if;
        ld_fault <= acc_fault(ea, sz, false);
        st_fault <= acc_fault(ea, sz, true);
    end process;
    lr_hit <= '1' when lr_valid = '1' and lr_addr = ea(31 downto 2) else '0';

    -- exception for the instruction in EXEC, in the emulator's order
    process (opcode, illegal, sys_ecall, sys_ebreak, priv_m, mis, ld_fault, st_fault, amo_lr,
             amo_sc, amo_badf5, lr_hit, traps_on, instr, pc, ea)
        variable e : boolean;
        variable c : integer range 0 to 15;
    begin
        e := true;
        c := 2;
        if illegal = '1' then
            c := 2;
        elsif opcode = OP_SYSTEM and sys_ecall = '1' then
            if priv_m = '1' then c := 11; else c := 8; end if;
        elsif opcode = OP_SYSTEM and sys_ebreak = '1' then
            c := 3;
        elsif opcode = OP_LOAD then
            e := mis = '1' or ld_fault = '1';
            if mis = '1' then c := 4; else c := 5; end if;
        elsif opcode = OP_STORE then
            e := mis = '1' or st_fault = '1';
            if mis = '1' then c := 6; else c := 7; end if;
        elsif opcode = OP_AMO then
            if mis = '1' then c := 6;
            elsif amo_lr = '1' then e := ld_fault = '1'; c := 5;
            elsif amo_sc = '1' then e := lr_hit = '1' and st_fault = '1'; c := 7;
            elsif ld_fault = '1' then c := 5;
            elsif amo_badf5 = '1' then c := 2;
            else e := st_fault = '1'; c := 7;
            end if;
        else
            e := false;
        end if;
        exc_cause <= std_logic_vector(to_unsigned(c, 4));
        case c is
            when 2      => exc_tval <= instr;
            when 3      => exc_tval <= std_logic_vector(pc);
            when 8 | 11 => exc_tval <= (others => '0');
            when others => exc_tval <= std_logic_vector(ea);
        end case;
        exc <= '0';
        stop <= '0';
        if e and traps_on = '1' then
            exc <= '1';
        end if;
        -- without a handler only these stop the machine; bad accesses go ahead
        if traps_on = '0' and (illegal = '1' or (opcode = OP_AMO and amo_badf5 = '1')
                               or (opcode = OP_SYSTEM and (sys_ecall = '1' or sys_ebreak = '1'))) then
            stop <= '1';
        end if;
    end process;

    -- between instructions: interrupts, then a fetch that would fault
    irq_take <= '1' when ((irq_timer = '1' and ie_t = '1') or (irq_soft = '1' and ie_s = '1')
                          or (irq_ext = '1' and ie_e = '1'))
                         and (st_mie = '1' or priv_m = '0') else '0';
    fetch_bad <= '0' when pc(1 downto 0) = "00" and
                          ((pc(31 downto 28) = x"0" and pc(27 downto 12) = 0) or
                           (pc(31 downto 28) = x"1" and pc(27 downto 19) = 0) or
                           ((pc(31 downto 28) = x"2" or pc(31 downto 28) = x"8") and pc(27 downto 23) = 0))
                 else '1';
    ftrap <= fetch_first and (irq_take or (traps_on and fetch_bad));
    fstop <= fetch_first and halt_req;

    -- AMO arithmetic, from registers (old value and rs2)
    process (instr, amo_old, rs2v)
        variable a, b : std_logic_vector(31 downto 0);
    begin
        a := amo_old;
        b := rs2v;
        case instr(31 downto 27) is
            when "00001" => amo_new <= b;
            when "00000" => amo_new <= std_logic_vector(unsigned(a) + unsigned(b));
            when "00100" => amo_new <= a xor b;
            when "01100" => amo_new <= a and b;
            when "01000" => amo_new <= a or b;
            when "10000" => if signed(a) < signed(b) then amo_new <= a; else amo_new <= b; end if;
            when "10100" => if signed(a) > signed(b) then amo_new <= a; else amo_new <= b; end if;
            when "11000" => if unsigned(a) < unsigned(b) then amo_new <= a; else amo_new <= b; end if;
            when others  => if unsigned(a) > unsigned(b) then amo_new <= a; else amo_new <= b; end if;
        end case;
    end process;

    -- ALU for OP, OP-IMM, LUI, AUIPC, JAL, JALR, SYSTEM reads
    process (opcode, funct3, funct7, rs1v, rs2v, imm_i, imm_u, pc, pc4, instr, csr_rdata)
        variable a, b  : unsigned(31 downto 0);
        variable shamt : integer range 0 to 31;
        variable r     : unsigned(31 downto 0);
        variable sub   : boolean;
    begin
        a := unsigned(rs1v);
        if opcode = OP_REG then
            b := unsigned(rs2v);
        else
            b := imm_i;
        end if;
        shamt := to_integer(b(4 downto 0));
        sub := opcode = OP_REG and funct7(5) = '1';
        r := (others => '0');
        case funct3 is
            when "000" =>
                if sub then r := a - b; else r := a + b; end if;
            when "001" => r := shift_left(a, shamt);
            when "010" =>
                if signed(a) < signed(b) then r := to_unsigned(1, 32); end if;
            when "011" =>
                if a < b then r := to_unsigned(1, 32); end if;
            when "100" => r := a xor b;
            when "101" =>
                if funct7(5) = '1' then
                    r := unsigned(shift_right(signed(a), shamt));
                else
                    r := shift_right(a, shamt);
                end if;
            when "110" => r := a or b;
            when others => r := a and b;
        end case;

        case opcode is
            when OP_LUI   => r := imm_u;
            when OP_AUIPC => r := pc + imm_u;
            when OP_JAL | OP_JALR => r := pc4;
            when OP_SYSTEM => r := unsigned(csr_rdata);
            when others => null;
        end case;
        alu_out <= std_logic_vector(r);
    end process;

    -- next PC for anything finishing in EXEC
    process (opcode, funct3, rs1v, rs2v, pc, pc4, imm_b, imm_j, imm_i, sys_mret, mepc)
        variable take : boolean;
    begin
        take := false;
        case funct3 is
            when "000"  => take := rs1v = rs2v;
            when "001"  => take := rs1v /= rs2v;
            when "100"  => take := signed(rs1v) < signed(rs2v);
            when "101"  => take := signed(rs1v) >= signed(rs2v);
            when "110"  => take := unsigned(rs1v) < unsigned(rs2v);
            when "111"  => take := unsigned(rs1v) >= unsigned(rs2v);
            when others => take := false;
        end case;
        case opcode is
            when OP_JAL  => next_pc <= pc + imm_j;
            when OP_JALR => next_pc <= (unsigned(rs1v) + imm_i) and x"FFFFFFFE";
            when OP_BRANCH =>
                if take then next_pc <= pc + imm_b; else next_pc <= pc4; end if;
            when OP_SYSTEM =>
                if sys_mret = '1' then next_pc <= unsigned(mepc); else next_pc <= pc4; end if;
            when others => next_pc <= pc4;
        end case;
    end process;

    -- load alignment, from the address of the access in flight
    process (d_rdata, m_addr, funct3)
        variable sh : std_logic_vector(31 downto 0);
    begin
        case m_addr(1 downto 0) is
            when "00"   => sh := d_rdata;
            when "01"   => sh := x"00" & d_rdata(31 downto 8);
            when "10"   => sh := x"0000" & d_rdata(31 downto 16);
            when others => sh := x"000000" & d_rdata(31 downto 24);
        end case;
        case funct3 is
            when "000"  => load_val <= std_logic_vector(sext(sh(7 downto 0)));
            when "001"  => load_val <= std_logic_vector(sext(sh(15 downto 0)));
            when "100"  => load_val <= x"000000" & sh(7 downto 0);
            when "101"  => load_val <= x"0000" & sh(15 downto 0);
            when others => load_val <= sh;
        end case;
    end process;

    -- store lane placement for this instruction
    process (funct3, ea, rs2v)
    begin
        case funct3(1 downto 0) is
            when "00" =>
                st_data <= rs2v(7 downto 0) & rs2v(7 downto 0) & rs2v(7 downto 0) & rs2v(7 downto 0);
                case ea(1 downto 0) is
                    when "00"   => st_strb <= "0001";
                    when "01"   => st_strb <= "0010";
                    when "10"   => st_strb <= "0100";
                    when others => st_strb <= "1000";
                end case;
            when "01" =>
                st_data <= rs2v(15 downto 0) & rs2v(15 downto 0);
                if ea(1) = '0' then st_strb <= "0011"; else st_strb <= "1100"; end if;
            when others =>
                st_data <= rs2v;
                st_strb <= "1111";
        end case;
    end process;

    -- outputs and writeback, all combinational from state. The next fetch
    -- goes out in the same cycle an instruction finishes.
    process (state, opcode, funct7, funct3, rd, alu_out, next_pc, pc, pc4, ea,
             st_strb, st_data, m_addr, m_we, d_ack, load_val, mul_p,
             div_count, div_quo, div_rem, div_negq, div_negr, div_byz, div_ovf, div_dvd0, instr,
             exc, stop, is_csr, amo_lr, amo_sc, lr_hit, amo_old)
        variable fin  : std_logic;
        variable we   : std_logic;
        variable wd   : std_logic_vector(31 downto 0);
        variable q, r : unsigned(31 downto 0);
    begin
        d_req   <= '0';
        d_prime <= '0';
        d_raddr <= m_addr;
        i_inval <= '0';
        fin := '0';
        we  := '0';
        wd  := alu_out;

        case state is
            when S_EXEC =>
                case opcode is
                    when OP_LOAD | OP_STORE =>
                        d_prime <= '1';
                        d_raddr <= std_logic_vector(ea);
                    when OP_REG =>
                        if funct7 /= "0000001" then
                            we := '1'; fin := '1';
                        end if;
                    when OP_LUI | OP_AUIPC | OP_JAL | OP_JALR | OP_IMM =>
                        we := '1'; fin := '1';
                    when OP_SYSTEM =>         -- CSR access, MRET, WFI
                        we := is_csr; fin := '1';
                    when OP_BRANCH =>
                        fin := '1';
                    when OP_FENCE =>
                        fin := '1';
                        if funct3 = "001" then
                            i_inval <= '1';     -- FENCE.I
                        end if;
                    when OP_AMO =>
                        if amo_sc = '1' and lr_hit = '0' then
                            we := '1'; fin := '1'; wd := x"00000001";   -- SC failed
                        else
                            d_prime <= '1';
                            d_raddr <= std_logic_vector(ea);
                        end if;
                    when others =>
                        null;
                end case;
                if exc = '1' or stop = '1' then
                    we := '0'; fin := '0';
                    i_inval <= '0';
                end if;

            when S_MEM =>
                d_req <= '1';
                if d_ack = '1' then
                    if opcode = OP_AMO and amo_lr = '0' and amo_sc = '0' then
                        null;                   -- read half of an AMO
                    elsif m_we = '0' then
                        fin := '1';
                        we := '1';
                        wd := load_val;
                    else
                        fin := '1';
                        if opcode = OP_AMO then  -- SC succeeded
                            we := '1';
                            wd := (others => '0');
                        end if;
                    end if;
                end if;

            when S_AMOC =>
                d_prime <= '1';             -- d_raddr is m_addr

            when S_AMOW =>
                d_req <= '1';
                if d_ack = '1' then
                    fin := '1';
                    we  := '1';
                    wd  := amo_old;
                end if;

            when S_MUL2 =>
                we := '1'; fin := '1';
                if funct3 = "000" then
                    wd := std_logic_vector(mul_p(31 downto 0));
                else
                    wd := std_logic_vector(mul_p(63 downto 32));
                end if;

            when S_DIV =>
                if div_count = 0 then
                    we := '1'; fin := '1';
                    q := div_quo;
                    r := div_rem;
                    if div_negq = '1' then q := 0 - q; end if;
                    if div_negr = '1' then r := 0 - r; end if;
                    if div_byz = '1' then
                        q := (others => '1');
                        r := unsigned(div_dvd0);
                    elsif div_ovf = '1' then
                        q := x"80000000";
                        r := (others => '0');
                    end if;
                    if funct3(1) = '0' then
                        wd := std_logic_vector(q);
                    else
                        wd := std_logic_vector(r);
                    end if;
                end if;

            when others =>
                null;
        end case;

        if rd = "00000" then
            we := '0';
        end if;

        rf_we  <= we;
        rf_wa  <= rd;
        rf_wd  <= wd;
        finish <= fin;

        i_prime <= fin;
        if fin = '1' and state = S_EXEC then
            i_raddr <= std_logic_vector(next_pc);
        elsif fin = '1' then
            i_raddr <= std_logic_vector(pc4);
        else
            i_raddr <= std_logic_vector(pc);
        end if;
    end process;

    i_req   <= '1' when state = S_FETCH and ftrap = '0' and fstop = '0' else '0';
    i_addr  <= std_logic_vector(pc);
    d_addr  <= m_addr;
    d_we    <= m_we;
    d_wstrb <= m_wstrb;
    d_wdata <= m_wdata;

    retire      <= finish;
    retire_pc   <= std_logic_vector(pc);
    retire_rd   <= rf_wa when rf_we = '1' else "00000";
    retire_data <= rf_wd;
    halted      <= '1' when state = S_HALT else '0';

    -- synthesis translate_off
    -- one line per retired instruction: pc instr rd value (hex; rd 00 when
    -- nothing is written)
    tracer : if TRACE /= "" generate
        process (clk)
            file f      : text open write_mode is TRACE;
            variable l  : line;
            variable n  : integer := 0;
        begin
            if rising_edge(clk) and finish = '1' and n < TRACE_MAX then
                hwrite(l, std_logic_vector(pc)); write(l, ' ');
                hwrite(l, instr); write(l, ' ');
                if rf_we = '1' then
                    hwrite(l, "000" & rf_wa); write(l, ' '); hwrite(l, rf_wd);
                else
                    write(l, string'("00 00000000"));
                end if;
                writeline(f, l);
                n := n + 1;
            end if;
        end process;
    end generate;
    -- synthesis translate_on

    process (clk)
        variable a, b : signed(32 downto 0);
        variable diff : unsigned(32 downto 0);
        variable rem2 : unsigned(31 downto 0);
        variable trap : boolean;
        variable tcause : std_logic_vector(31 downto 0);
        variable ttval  : std_logic_vector(31 downto 0);
    begin
        if rising_edge(clk) then
            cycles <= cycles + 1;
            if finish = '1' then
                instret <= instret + 1;
            end if;
            if state = S_FETCH then
                fetch_first <= '0';
            end if;
            trap   := false;
            tcause := (others => '0');
            ttval  := (others => '0');

            case state is
                when S_FETCH =>
                    if fstop = '1' then
                        state <= S_HALT;
                    elsif ftrap = '1' then
                        trap := true;
                        if irq_take = '1' then
                            -- priority as in the privileged spec: external, software, timer
                            if irq_ext = '1' and ie_e = '1' then
                                tcause := x"8000000B";
                            elsif irq_soft = '1' and ie_s = '1' then
                                tcause := x"80000003";
                            elsif irq_timer = '1' and ie_t = '1' then
                                tcause := x"80000007";
                            else
                                tcause := x"80000003";
                            end if;
                        else
                            if pc(1 downto 0) /= "00" then
                                tcause := x"00000000";
                            else
                                tcause := x"00000001";
                            end if;
                            ttval := std_logic_vector(pc);
                        end if;
                    elsif i_ack = '1' then
                        instr <= i_rdata;
                        state <= S_EXEC;
                    end if;

                when S_EXEC =>
                    case opcode is
                        when OP_LOAD | OP_STORE =>
                            m_addr  <= std_logic_vector(ea);
                            if opcode = OP_STORE then m_we <= '1'; else m_we <= '0'; end if;
                            m_wstrb <= st_strb;
                            m_wdata <= st_data;
                            state   <= S_MEM;
                        when OP_REG =>
                            if funct7 = "0000001" then
                                if funct3(2) = '0' then
                                    -- MUL, MULH, MULHSU, MULHU
                                    if funct3 = "011" then
                                        a := signed('0' & rs1v);
                                    else
                                        a := signed(rs1v(31) & rs1v);
                                    end if;
                                    if funct3 = "010" or funct3 = "011" then
                                        b := signed('0' & rs2v);
                                    else
                                        b := signed(rs2v(31) & rs2v);
                                    end if;
                                    mul_a <= a;
                                    mul_b <= b;
                                    state <= S_MUL0;
                                else
                                    -- DIV, DIVU, REM, REMU
                                    div_dvd0 <= rs1v;
                                    div_byz  <= '0';
                                    div_ovf  <= '0';
                                    if unsigned(rs2v) = 0 then div_byz <= '1'; end if;
                                    if funct3(0) = '0' and rs1v = x"80000000" and rs2v = x"FFFFFFFF" then
                                        div_ovf <= '1';
                                    end if;
                                    if funct3(0) = '0' then
                                        div_negq <= rs1v(31) xor rs2v(31);
                                        div_negr <= rs1v(31);
                                        if rs1v(31) = '1' then div_quo <= 0 - unsigned(rs1v); else div_quo <= unsigned(rs1v); end if;
                                        if rs2v(31) = '1' then div_den <= 0 - unsigned(rs2v); else div_den <= unsigned(rs2v); end if;
                                    else
                                        div_negq <= '0';
                                        div_negr <= '0';
                                        div_quo  <= unsigned(rs1v);
                                        div_den  <= unsigned(rs2v);
                                    end if;
                                    div_rem   <= (others => '0');
                                    div_count <= 32;
                                    state     <= S_DIV;
                                end if;
                            end if;
                        when OP_AMO =>
                            m_addr  <= std_logic_vector(ea);
                            m_wstrb <= "1111";
                            m_wdata <= rs2v;
                            if amo_sc = '1' then
                                lr_valid <= '0';
                                m_we     <= '1';
                                if lr_hit = '1' then
                                    state <= S_MEM;
                                end if;
                            else
                                m_we  <= '0';
                                state <= S_MEM;
                                if amo_lr = '1' then
                                    lr_valid <= '1';
                                    lr_addr  <= ea(31 downto 2);
                                end if;
                            end if;
                        when OP_SYSTEM =>
                            if is_csr = '1' and csr_we = '1' then
                                case instr(31 downto 20) is
                                    when x"300" =>
                                        st_mie  <= csr_wdata(3);
                                        st_mpie <= csr_wdata(7);
                                        st_mpp  <= csr_wdata(12 downto 11);
                                    when x"304" =>
                                        ie_s <= csr_wdata(3);
                                        ie_t <= csr_wdata(7);
                                        ie_e <= csr_wdata(11);
                                    when x"305" =>
                                        mtvec <= csr_wdata;
                                        if csr_wdata = x"00000000" then traps_on <= '0'; else traps_on <= '1'; end if;
                                    when x"340" => mscratch <= csr_wdata;
                                    when x"341" => mepc     <= csr_wdata(31 downto 2) & "00";
                                    when x"342" => mcause   <= csr_wdata;
                                    when x"343" => mtval    <= csr_wdata;
                                    when others => null;
                                end case;
                            end if;
                            if sys_mret = '1' then
                                if st_mpp = "11" then priv_m <= '1'; else priv_m <= '0'; end if;
                                st_mie  <= st_mpie;
                                st_mpie <= '1';
                                st_mpp  <= "00";
                            end if;
                        when others =>
                            null;
                    end case;
                    if exc = '1' then
                        trap   := true;
                        tcause := x"0000000" & exc_cause;
                        ttval  := exc_tval;
                    elsif stop = '1' then
                        state <= S_HALT;   -- no trap handler yet
                    end if;

                when S_MEM =>
                    if d_ack = '1' and opcode = OP_AMO and amo_lr = '0' and amo_sc = '0' then
                        amo_old <= load_val;
                        state   <= S_AMOC;
                    end if;

                when S_AMOC =>
                    m_wdata <= amo_new;
                    m_we    <= '1';
                    state   <= S_AMOW;

                when S_AMOW =>
                    null;

                when S_MUL0 =>
                    pp_hh <= mul_a(32 downto 16) * mul_b(32 downto 16);
                    pp_hl <= mul_a(32 downto 16) * signed('0' & mul_b(15 downto 0));
                    pp_lh <= signed('0' & mul_a(15 downto 0)) * mul_b(32 downto 16);
                    pp_ll <= unsigned(mul_a(15 downto 0)) * unsigned(mul_b(15 downto 0));
                    state <= S_MUL1;

                when S_MUL1 =>
                    mul_p <= shift_left(resize(pp_hh, 66), 32)
                           + shift_left(resize(pp_hl, 66), 16)
                           + shift_left(resize(pp_lh, 66), 16)
                           + signed(resize(pp_ll, 66));
                    state <= S_MUL2;

                when S_MUL2 =>
                    null;

                when S_DIV =>
                    if div_count /= 0 then
                        -- shift the next dividend bit into the remainder
                        rem2 := div_rem(30 downto 0) & div_quo(31);
                        diff := ('0' & rem2) - ('0' & div_den);
                        if div_rem(31) = '1' or diff(32) = '0' then
                            div_rem <= diff(31 downto 0);
                            div_quo <= div_quo(30 downto 0) & '1';
                        else
                            div_rem <= rem2;
                            div_quo <= div_quo(30 downto 0) & '0';
                        end if;
                        div_count <= div_count - 1;
                    end if;

                when S_HALT =>
                    null;
            end case;

            if finish = '1' then
                if state = S_EXEC then
                    pc <= next_pc;
                else
                    pc <= pc4;
                end if;
                state <= S_FETCH;
                fetch_first <= '1';
            end if;

            -- trap entry (never in the same cycle as a finish)
            if trap then
                mepc     <= std_logic_vector(pc);
                mcause   <= tcause;
                mtval    <= ttval;
                st_mpie  <= st_mie;
                st_mie   <= '0';
                st_mpp   <= priv_m & priv_m;
                priv_m   <= '1';
                lr_valid <= '0';
                if mtvec(0) = '1' and tcause(31) = '1' then
                    pc <= (unsigned(mtvec(31 downto 2)) + unsigned(tcause(4 downto 0))) & "00";
                else
                    pc <= unsigned(mtvec(31 downto 2)) & "00";
                end if;
                state       <= S_FETCH;
                fetch_first <= '1';
            end if;

            if reset = '1' then
                state    <= S_FETCH;
                pc       <= unsigned(RESET_PC);
                instret  <= (others => '0');
                fetch_first <= '1';
                priv_m   <= '1';
                st_mie   <= '0';
                st_mpie  <= '0';
                st_mpp   <= "00";
                ie_s     <= '0';
                ie_t     <= '0';
                ie_e     <= '0';
                mtvec    <= (others => '0');
                traps_on <= '0';
                lr_valid <= '0';
            end if;
        end if;
    end process;
end rtl;
