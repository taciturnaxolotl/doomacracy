-- RV32IMA + Zicsr, machine and user modes (spec.md, "Linux platform"),
-- as a five stage in-order pipeline:
--
--   IF   the fetch address goes to the I-cache RAMs (registered inside them)
--   IF2  hit check; predecode: JAL target, backward branch, return stack
--   ID   decode, predicted-taken redirect, register file address; a second
--        queue entry behind it takes a fetch while ID waits
--   EX   forwarding, ALU, branch check, address, CSRs, traps, MUL/DIV
--   MEM  D-cache access, AMO read-modify-write
--   WB   register file write, retirement
--
-- Branch prediction is static: JAL and backward branches are taken, and a
-- four entry return stack predicts JALR returns. The prediction redirects
-- fetch from ID (one bubble). EX checks every branch and jump; a wrong
-- guess, a trap, MRET, FENCE.I and CSR writes redirect from a register in
-- the following cycle (three bubbles).
--
-- Timing: no RAM address depends on an operand value or on a stall. Fetch
-- only needs the decode queue's room (registers) and the I-cache hit; the
-- register file is read at ID's address and EX keeps its operands in
-- registers while it waits; the D-cache reads EX's address unless MEM is
-- past its first cycle. A D-cache hit only reaches pipeline registers.
--
-- Forwarding into EX comes from MEM, WB and the write retired on the last
-- edge (the register file RAM cannot return a value written on the edge
-- its read address is latched). A load result is not forwarded from MEM:
-- an instruction that needs it waits one cycle.
--
-- CSR instructions, SYSTEM instructions, FENCE.I, illegal instructions,
-- interrupts and a power off wait in EX until MEM and WB are empty, so
-- the counters, traps and halts see every older instruction retired.
--
-- Data port: hold req, addr, we, wstrb, wdata steady until ack. ack is one
-- cycle; rdata is valid with it. raddr is read by the cache RAMs every
-- cycle; while a request waits, raddr is its addr.
-- Instruction port: the address may move in any cycle (a redirect); ack
-- and rdata are for this cycle's addr. It always primes: its next address
-- is always this cycle's raddr.
--
-- Traps: everything goes to mtvec, but only once mtvec is nonzero. Until
-- then ECALL, EBREAK and illegal instructions halt the CPU (halted output)
-- and faulting accesses go ahead, exactly like the emulator. WFI is a no-op.
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
        -- instruction port
        i_prime : out std_logic;
        i_raddr : out std_logic_vector(31 downto 0);
        i_req   : out std_logic;
        i_addr  : out std_logic_vector(31 downto 0);
        i_ack   : in  std_logic;
        i_rdata : in  std_logic_vector(31 downto 0);
        -- data port, same split as the instruction port
        d_raddr : out std_logic_vector(31 downto 0);
        d_req   : out std_logic;
        d_addr  : out std_logic_vector(31 downto 0);
        d_we    : out std_logic;
        d_wstrb : out std_logic_vector(3 downto 0);
        d_wdata : out std_logic_vector(31 downto 0);
        d_ack   : in  std_logic;
        d_rdata : in  std_logic_vector(31 downto 0);
        d_wbe   : in  std_logic;   -- the D-cache's write buffer is empty
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

    ---------------------------------------------------------------- IF / IF2
    signal f_pc, f_pc4, fa : unsigned(31 downto 0) := unsigned(RESET_PC);
    signal f_bad, f_ftrap, f_hit, f_kill, f_take : std_logic;
    signal f_fault   : std_logic_vector(1 downto 0);
    signal pd_target : unsigned(31 downto 0);
    signal pd_pt, pd_call, pd_ret : std_logic;
    type ras_t is array (0 to 3) of unsigned(31 downto 0);
    signal ras     : ras_t := (others => (others => '0'));
    signal ras_top : unsigned(1 downto 0) := "00";

    ---------------------------------------------------------------- ID
    signal id_valid, id_pt, id_redirected : std_logic := '0';
    signal id_pc, id_target : unsigned(31 downto 0) := (others => '0');
    signal id_instr  : std_logic_vector(31 downto 0) := (others => '0');
    signal id_fault  : std_logic_vector(1 downto 0) := "00";  -- 01 access, 10 misaligned
    signal id_redir_now, id_adv : std_logic;
    -- the second decode queue entry, behind ID
    signal q1_valid, q1_pt : std_logic := '0';
    signal q1_pc, q1_target : unsigned(31 downto 0) := (others => '0');
    signal q1_instr : std_logic_vector(31 downto 0) := (others => '0');
    signal q1_fault : std_logic_vector(1 downto 0) := "00";
    signal id_imm    : unsigned(31 downto 0);
    signal id_u1, id_u2, id_serial : std_logic;

    ---------------------------------------------------------------- EX
    -- instr is the instruction in EX; the decode below works on it
    signal ex_valid, ex_pt : std_logic := '0';
    signal instr      : std_logic_vector(31 downto 0) := (others => '0');
    signal pc, ex_tgt, ex_imm : unsigned(31 downto 0) := (others => '0');
    signal ex_fault   : std_logic_vector(1 downto 0) := "00";
    signal ex_u1, ex_u2, ex_serial : std_logic := '0';
    type exst_t is (X_RUN, X_MUL0, X_MUL1, X_MUL2, X_DIV);
    signal ex_st : exst_t := X_RUN;
    signal ex_run, ex_done, ex_adv, ex_free, ld_hazard, ser_wait : std_logic;
    -- operands: the register file's in EX's first cycle, then held here
    signal ex_first : std_logic := '0';
    signal ex_opa, ex_opb : std_logic_vector(31 downto 0) := (others => '0');
    signal src1, src2 : std_logic_vector(31 downto 0);
    signal x_halt, x_irq, x_fault, x_trap, x_stop, x_redir, x_flush, x_muldiv : std_logic;
    signal x_start, x_last : std_logic;
    signal x_tgt    : unsigned(31 downto 0);
    signal x_result : std_logic_vector(31 downto 0);
    signal redir_r  : std_logic := '0';
    signal redir_pc : unsigned(31 downto 0) := (others => '0');
    signal halt_r   : std_logic := '0';

    -- register file: two copies so both operands read in one cycle; the read
    -- address is registered, the way an M4K wants it
    type regs_t is array (0 to 31) of std_logic_vector(31 downto 0);
    signal rf_a, rf_b : regs_t := (others => (others => '0'));
    signal ra1, ra2   : std_logic_vector(4 downto 0) := (others => '0');
    signal rf1, rf2   : std_logic_vector(31 downto 0);
    signal rs1v, rs2v : std_logic_vector(31 downto 0);   -- forwarded operands
    signal rf_we      : std_logic;

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
    signal div_res   : std_logic_vector(31 downto 0);

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

    -- decode of the instruction in EX
    signal opcode : std_logic_vector(6 downto 0);
    signal funct3 : std_logic_vector(2 downto 0);
    signal funct7 : std_logic_vector(6 downto 0);
    signal rd     : std_logic_vector(4 downto 0);
    signal imm_u  : unsigned(31 downto 0);
    signal is_csr, sys_ecall, sys_ebreak, sys_mret, is_fencei : std_logic;
    signal amo_lr, amo_sc, amo_badf5, illegal : std_logic;
    signal csr_rdata, csr_wdata : std_logic_vector(31 downto 0);
    signal csr_we   : std_logic;
    signal mis, ld_fault, st_fault, lr_hit : std_logic;
    signal exc, stop  : std_logic;
    signal exc_cause  : std_logic_vector(3 downto 0);
    signal exc_tval   : std_logic_vector(31 downto 0);
    signal irq_take   : std_logic;
    signal pc4      : unsigned(31 downto 0);
    signal alu_out  : std_logic_vector(31 downto 0);
    signal ea       : unsigned(31 downto 0);
    signal take     : std_logic;
    signal st_strb  : std_logic_vector(3 downto 0);
    signal st_data  : std_logic_vector(31 downto 0);
    signal writes   : std_logic;

    ---------------------------------------------------------------- MEM
    type kind_t is (K_NONE, K_LOAD, K_STORE, K_AMO);
    type mst_t is (M_REQ, M_AMOC, M_AMOW);
    signal mem_valid, mem_we, mem_late : std_logic := '0';
    signal mem_kind  : kind_t := K_NONE;
    signal mem_st    : mst_t := M_REQ;
    signal mem_rd    : std_logic_vector(4 downto 0) := (others => '0');
    signal mem_res   : std_logic_vector(31 downto 0) := (others => '0');
    signal mem_pc    : unsigned(31 downto 0) := (others => '0');
    signal mem_instr : std_logic_vector(31 downto 0) := (others => '0');
    signal mem_f3    : std_logic_vector(2 downto 0) := "000";
    signal m_addr  : std_logic_vector(31 downto 0) := (others => '0');
    signal m_we    : std_logic := '0';
    signal m_wstrb : std_logic_vector(3 downto 0) := (others => '0');
    signal m_wdata : std_logic_vector(31 downto 0) := (others => '0');
    signal amo_old : std_logic_vector(31 downto 0) := (others => '0');
    signal amo_new, load_val : std_logic_vector(31 downto 0);
    signal mem_done, mem_free, mem_first : std_logic := '0';
    -- an exception found in EX traps when its instruction reaches MEM, so
    -- the address adder never feeds the flush logic
    signal mem_exc   : std_logic := '0';
    signal mem_cause : std_logic_vector(3 downto 0) := (others => '0');
    signal mem_tval  : std_logic_vector(31 downto 0) := (others => '0');
    signal m_trap    : std_logic;

    ---------------------------------------------------------------- WB
    signal wb_valid, wb_we : std_logic := '0';
    signal wb_rd    : std_logic_vector(4 downto 0) := (others => '0');
    signal wb_res   : std_logic_vector(31 downto 0) := (others => '0');
    signal wb_pc    : unsigned(31 downto 0) := (others => '0');
    signal wb_instr : std_logic_vector(31 downto 0) := (others => '0');
    signal halt_pc  : unsigned(31 downto 0) := (others => '0');
    -- the write retired on the last edge
    signal w1_we : std_logic := '0';
    signal w1_rd : std_logic_vector(4 downto 0) := (others => '0');
    signal w1_res : std_logic_vector(31 downto 0) := (others => '0');

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

    -- everything the emulator rejects as an illegal instruction (AMO funct5
    -- is separate: the emulator checks it after the address)
    function is_illegal(i : std_logic_vector(31 downto 0)) return std_logic is
        variable op : std_logic_vector(6 downto 0);
        variable f3 : std_logic_vector(2 downto 0);
        variable f7 : std_logic_vector(6 downto 0);
        variable il : boolean;
    begin
        op := i(6 downto 0); f3 := i(14 downto 12); f7 := i(31 downto 25);
        il := false;
        case op is
            when OP_LUI | OP_AUIPC | OP_JAL | OP_FENCE => null;
            when OP_JALR   => il := f3 /= "000";
            when OP_BRANCH => il := f3(2 downto 1) = "01";
            when OP_LOAD   => il := f3 = "011" or f3(2 downto 1) = "11";
            when OP_STORE  => il := f3(2) = '1' or f3 = "011";
            when OP_IMM    =>
                il := (f3 = "001" and f7 /= "0000000")
                   or (f3 = "101" and f7 /= "0000000" and f7 /= "0100000");
            when OP_REG    =>
                il := not (f7 = "0000000" or f7 = "0000001"
                           or (f7 = "0100000" and (f3 = "000" or f3 = "101")));
            when OP_AMO    => il := f3 /= "010";
            when OP_SYSTEM =>
                if f3 = "000" then
                    il := i /= x"00000073" and i /= x"00100073" and i /= x"30200073" and i /= x"10500073";
                else
                    il := f3 = "100";
                end if;
            when others => il := true;
        end case;
        if il then return '1'; else return '0'; end if;
    end function;

    -- a + b = c, without a carry chain: every bit's sum must match and the
    -- carry each bit would need must be the one the bit below makes
    function sum_eq(a, b, c : unsigned(31 downto 0)) return boolean is
        variable k : unsigned(31 downto 0);
    begin
        k := shift_left((a and b) or ((a or b) and not c), 1);
        return (a xor b xor c) = k;
    end function;

    function amo_bad(f5 : std_logic_vector(4 downto 0)) return std_logic is
    begin
        case f5 is
            when "00000" | "00001" | "00010" | "00011" | "00100" | "01000" | "01100"
               | "10000" | "10100" | "11000" | "11100" => return '0';
            when others => return '1';
        end case;
    end function;
begin
    ---------------------------------------------------------------- IF / IF2
    f_pc4 <= f_pc + 4;
    f_bad <= '0' when f_pc(1 downto 0) = "00" and
                      ((f_pc(31 downto 28) = x"0" and f_pc(27 downto 12) = 0) or
                       (f_pc(31 downto 28) = x"1" and f_pc(27 downto 19) = 0) or
                       ((f_pc(31 downto 28) = x"2" or f_pc(31 downto 28) = x"8") and f_pc(27 downto 23) = 0))
             else '1';
    -- a fetch that would fault is not sent to the cache once traps are on;
    -- it travels down as a marker and traps in EX
    f_ftrap <= f_bad and traps_on;
    f_fault <= "00" when f_ftrap = '0' else "10" when f_pc(1 downto 0) /= "00" else "01";
    f_hit   <= i_ack or f_ftrap;
    f_kill  <= redir_r or id_redir_now or halt_r;
    -- the fetched instruction joins the decode queue if it has room; the
    -- room is known from registers, so the back end's stalls never reach
    -- the fetch address
    f_take  <= f_hit and not f_kill and not (id_valid and q1_valid);

    i_req   <= not f_ftrap and not halt_r;
    i_addr  <= std_logic_vector(f_pc);
    i_prime <= '1';
    i_raddr <= std_logic_vector(fa);

    -- next fetch address
    fa <= redir_pc  when redir_r = '1' else
          id_target when id_redir_now = '1' else
          f_pc4     when f_take = '1' else
          f_pc;

    -- predecode of the instruction arriving from the cache
    process (i_rdata, f_pc, ras, ras_top)
        variable op  : std_logic_vector(6 downto 0);
        variable imm : unsigned(31 downto 0);
        variable rdl, rs1l : boolean;
    begin
        op := i_rdata(6 downto 0);
        if op = OP_JAL then
            imm := sext(i_rdata(31) & i_rdata(19 downto 12) & i_rdata(20) & i_rdata(30 downto 21) & '0');
        else
            imm := sext(i_rdata(31) & i_rdata(7) & i_rdata(30 downto 25) & i_rdata(11 downto 8) & '0');
        end if;
        rdl  := i_rdata(11 downto 7) = "00001" or i_rdata(11 downto 7) = "00101";
        rs1l := i_rdata(19 downto 15) = "00001" or i_rdata(19 downto 15) = "00101";
        pd_call <= '0';
        pd_ret  <= '0';
        if (op = OP_JAL or op = OP_JALR) and rdl then
            pd_call <= '1';
        end if;
        if op = OP_JALR and i_rdata(11 downto 7) = "00000" and rs1l then
            pd_ret <= '1';
        end if;
        if op = OP_JALR then
            pd_target <= ras(to_integer(ras_top));
        else
            pd_target <= f_pc + imm;
        end if;
        pd_pt <= '0';
        if op = OP_JAL or (op = OP_BRANCH and i_rdata(31) = '1')
           or (op = OP_JALR and i_rdata(11 downto 7) = "00000" and rs1l) then
            pd_pt <= '1';
        end if;
    end process;

    ---------------------------------------------------------------- ID
    id_redir_now <= id_valid and id_pt and not id_redirected and not redir_r;
    id_adv       <= id_valid and ex_free;

    process (id_instr)
        variable op : std_logic_vector(6 downto 0);
        variable f3 : std_logic_vector(2 downto 0);
    begin
        op := id_instr(6 downto 0);
        f3 := id_instr(14 downto 12);
        case op is
            when OP_STORE => id_imm <= sext(id_instr(31 downto 25) & id_instr(11 downto 7));
            when OP_AMO   => id_imm <= (others => '0');
            when others   => id_imm <= sext(id_instr(31 downto 20));
        end case;
        case op is
            when OP_JALR | OP_LOAD | OP_IMM => id_u1 <= '1'; id_u2 <= '0';
            when OP_BRANCH | OP_STORE | OP_REG | OP_AMO => id_u1 <= '1'; id_u2 <= '1';
            when OP_SYSTEM =>
                id_u2 <= '0';
                if f3(2) = '0' and f3(1 downto 0) /= "00" then id_u1 <= '1'; else id_u1 <= '0'; end if;
            when others => id_u1 <= '0'; id_u2 <= '0';
        end case;
        if op = OP_SYSTEM or (op = OP_FENCE and f3 = "001") or is_illegal(id_instr) = '1'
           or (op = OP_AMO and amo_bad(id_instr(31 downto 27)) = '1') then
            id_serial <= '1';
        else
            id_serial <= '0';
        end if;
    end process;

    -- register file read: the address is ID's, so the data arrives in the
    -- cycle that instruction enters EX
    ra1 <= id_instr(19 downto 15);
    ra2 <= id_instr(24 downto 20);

    rf_we <= '1' when wb_valid = '1' and wb_we = '1' else '0';
    process (clk)
    begin
        if rising_edge(clk) then
            if rf_we = '1' then
                rf_a(to_integer(unsigned(wb_rd))) <= wb_res;
                rf_b(to_integer(unsigned(wb_rd))) <= wb_res;
            end if;
            rf1 <= rf_a(to_integer(unsigned(ra1)));
            rf2 <= rf_b(to_integer(unsigned(ra2)));
        end if;
    end process;

    ---------------------------------------------------------------- EX decode
    opcode <= instr(6 downto 0);
    funct3 <= instr(14 downto 12);
    funct7 <= instr(31 downto 25);
    rd     <= instr(11 downto 7);
    imm_u  <= unsigned(instr(31 downto 12)) & x"000";
    pc4    <= pc + 4;

    sys_ecall  <= '1' when instr = x"00000073" else '0';
    sys_ebreak <= '1' when instr = x"00100073" else '0';
    sys_mret   <= '1' when instr = x"30200073" else '0';
    is_csr     <= '1' when opcode = OP_SYSTEM and funct3(1 downto 0) /= "00" else '0';
    is_fencei  <= '1' when opcode = OP_FENCE and funct3 = "001" else '0';
    amo_lr     <= '1' when instr(31 downto 27) = "00010" else '0';
    amo_sc     <= '1' when instr(31 downto 27) = "00011" else '0';
    amo_badf5  <= amo_bad(instr(31 downto 27));
    illegal    <= is_illegal(instr);
    x_muldiv   <= '1' when opcode = OP_REG and funct7 = "0000001" else '0';

    -- forwarding: MEM, then WB, then the write on the last edge, then the
    -- register file (first cycle in EX) or the operand held since
    src1 <= rf1 when ex_first = '1' else ex_opa;
    src2 <= rf2 when ex_first = '1' else ex_opb;
    process (instr, src1, src2, mem_valid, mem_we, mem_rd, mem_res, wb_valid, wb_we, wb_rd, wb_res,
             w1_we, w1_rd, w1_res)
        function pick(r : std_logic_vector(4 downto 0); ram : std_logic_vector(31 downto 0);
                      mv, mw : std_logic; mr : std_logic_vector(4 downto 0); mx : std_logic_vector(31 downto 0);
                      wv, ww : std_logic; wr : std_logic_vector(4 downto 0); wx : std_logic_vector(31 downto 0);
                      ow : std_logic; orr : std_logic_vector(4 downto 0); ox : std_logic_vector(31 downto 0))
                      return std_logic_vector is
        begin
            if r = "00000" then return x"00000000";
            elsif mv = '1' and mw = '1' and mr = r then return mx;
            elsif wv = '1' and ww = '1' and wr = r then return wx;
            elsif ow = '1' and orr = r then return ox;
            else return ram;
            end if;
        end function;
    begin
        rs1v <= pick(instr(19 downto 15), src1, mem_valid, mem_we, mem_rd, mem_res,
                     wb_valid, wb_we, wb_rd, wb_res, w1_we, w1_rd, w1_res);
        rs2v <= pick(instr(24 downto 20), src2, mem_valid, mem_we, mem_rd, mem_res,
                     wb_valid, wb_we, wb_rd, wb_res, w1_we, w1_rd, w1_res);
    end process;

    ea <= unsigned(rs1v) + ex_imm;

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

    -- exception for the instruction in EX, in the emulator's order
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

    irq_take <= '1' when ((irq_timer = '1' and ie_t = '1') or (irq_soft = '1' and ie_s = '1')
                          or (irq_ext = '1' and ie_e = '1'))
                         and (st_mie = '1' or priv_m = '0') else '0';

    ---------------------------------------------------------------- EX control
    -- an instruction that needs a load result still in MEM waits a cycle
    ld_hazard <= '1' when mem_valid = '1' and mem_late = '1' and mem_we = '1' and
                          ((ex_u1 = '1' and mem_rd = instr(19 downto 15)) or
                           (ex_u2 = '1' and mem_rd = instr(24 downto 20))) else '0';
    -- serialising instructions and interrupts wait for MEM and WB to drain
    ser_wait <= '1' when (ex_serial = '1' or irq_take = '1' or halt_req = '1') and
                         (mem_valid = '1' or wb_valid = '1' or (is_fencei = '1' and d_wbe = '0')) else '0';
    ex_run  <= ex_valid and not halt_r and not ld_hazard and not ser_wait when ex_st = X_RUN else '0';
    x_halt  <= halt_req when ex_st = X_RUN else '0';
    x_irq   <= irq_take when ex_st = X_RUN else '0';
    x_fault <= traps_on when ex_st = X_RUN and ex_fault /= "00" else '0';
    x_start <= ex_run and x_muldiv and not x_halt and not x_irq and not x_fault;
    x_last  <= '1' when ex_st = X_MUL2 or (ex_st = X_DIV and div_count = 0) else '0';
    ex_done <= (ex_run and not x_start) or (ex_valid and not halt_r and x_last);
    mem_free <= not mem_valid or mem_done;
    ex_adv   <= ex_done and mem_free;
    ex_free  <= not ex_valid or ex_adv;

    x_stop <= x_halt or ((not x_irq) and (not x_fault) and stop);
    x_trap <= (not x_halt) and (x_irq or x_fault);

    -- AMO arithmetic in MEM, from the old value and rs2 (parked in m_wdata)
    process (mem_instr, amo_old, m_wdata)
        variable a, b : std_logic_vector(31 downto 0);
    begin
        a := amo_old;
        b := m_wdata;
        case mem_instr(31 downto 27) is
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
    process (opcode, funct3, funct7, rs1v, rs2v, ex_imm, imm_u, pc, pc4, csr_rdata)
        variable a, b  : unsigned(31 downto 0);
        variable shamt : integer range 0 to 31;
        variable r     : unsigned(31 downto 0);
        variable sub   : boolean;
    begin
        a := unsigned(rs1v);
        if opcode = OP_REG then
            b := unsigned(rs2v);
        else
            b := ex_imm;
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

    -- branch outcome and whether fetch went the wrong way
    process (opcode, funct3, rs1v, rs2v, ex_pt, ex_tgt, ea, pc4, mepc, sys_mret, is_fencei,
             is_csr, csr_we)
        variable t  : boolean;
        variable jt : unsigned(31 downto 0);
    begin
        case funct3 is
            when "000"  => t := rs1v = rs2v;
            when "001"  => t := rs1v /= rs2v;
            when "100"  => t := signed(rs1v) < signed(rs2v);
            when "101"  => t := signed(rs1v) >= signed(rs2v);
            when "110"  => t := unsigned(rs1v) < unsigned(rs2v);
            when "111"  => t := unsigned(rs1v) >= unsigned(rs2v);
            when others => t := false;
        end case;
        if t then take <= '1'; else take <= '0'; end if;
        jt := ea(31 downto 1) & '0';
        x_redir <= ex_pt;
        x_tgt   <= pc4;
        case opcode is
            when OP_BRANCH =>
                if t then
                    x_redir <= not ex_pt;
                    x_tgt   <= ex_tgt;
                end if;
            when OP_JAL =>
                x_redir <= not ex_pt;
                x_tgt   <= ex_tgt;
            when OP_JALR =>
                x_tgt <= jt;
                -- (rs1 + imm) & ~1 against the prediction; bit 0 of the
                -- compare is the sum's own bit 0, so only bits 31..1 count
                if ex_pt = '0' or not sum_eq(unsigned(rs1v), ex_imm,
                                             ex_tgt(31 downto 1) & (rs1v(0) xor ex_imm(0))) then
                    x_redir <= '1';
                else
                    x_redir <= '0';
                end if;
            when OP_SYSTEM =>
                if sys_mret = '1' then
                    x_redir <= '1';
                    x_tgt   <= unsigned(mepc);
                elsif is_csr = '1' and csr_we = '1' then
                    x_redir <= '1';
                end if;
            when OP_FENCE =>
                x_redir <= is_fencei;
            when others =>
                null;
        end case;
    end process;

    -- divide result
    process (div_quo, div_rem, div_negq, div_negr, div_byz, div_ovf, div_dvd0, funct3)
        variable q, r : unsigned(31 downto 0);
    begin
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
            div_res <= std_logic_vector(q);
        else
            div_res <= std_logic_vector(r);
        end if;
    end process;

    -- what EX hands to MEM as the result
    process (ex_st, funct3, mul_p, div_res, opcode, amo_sc, lr_hit, alu_out)
    begin
        x_result <= alu_out;
        if ex_st = X_MUL2 then
            if funct3 = "000" then
                x_result <= std_logic_vector(mul_p(31 downto 0));
            else
                x_result <= std_logic_vector(mul_p(63 downto 32));
            end if;
        elsif ex_st = X_DIV then
            x_result <= div_res;
        elsif opcode = OP_AMO then
            if amo_sc = '1' and lr_hit = '0' then
                x_result <= x"00000001";    -- SC failed
            else
                x_result <= x"00000000";    -- SC succeeded (AMO results come from MEM)
            end if;
        end if;
    end process;

    with opcode select writes <=
        '1' when OP_REG | OP_IMM | OP_LUI | OP_AUIPC | OP_JAL | OP_JALR | OP_LOAD | OP_AMO,
        is_csr when OP_SYSTEM,
        '0' when others;

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

    x_flush <= ex_adv and (x_trap or x_stop or x_redir);
    i_inval <= ex_adv and is_fencei and not x_trap and not x_stop;

    ---------------------------------------------------------------- MEM
    -- load alignment, from the address of the access in flight
    process (d_rdata, m_addr, mem_f3)
        variable sh : std_logic_vector(31 downto 0);
    begin
        case m_addr(1 downto 0) is
            when "00"   => sh := d_rdata;
            when "01"   => sh := x"00" & d_rdata(31 downto 8);
            when "10"   => sh := x"0000" & d_rdata(31 downto 16);
            when others => sh := x"000000" & d_rdata(31 downto 24);
        end case;
        case mem_f3 is
            when "000"  => load_val <= std_logic_vector(sext(sh(7 downto 0)));
            when "001"  => load_val <= std_logic_vector(sext(sh(15 downto 0)));
            when "100"  => load_val <= x"000000" & sh(7 downto 0);
            when "101"  => load_val <= x"0000" & sh(15 downto 0);
            when others => load_val <= sh;
        end case;
    end process;

    m_trap   <= mem_valid and mem_exc;
    mem_done <= '1' when mem_valid = '1' and
                         (mem_kind = K_NONE or
                          (d_ack = '1' and ((mem_st = M_REQ and mem_kind /= K_AMO) or mem_st = M_AMOW)))
                else '0';

    -- the D-cache RAMs read EX's address, so a hit in MEM's first cycle needs
    -- no extra one; an access still in MEM after its first cycle (a miss, an
    -- AMO) reads its own. Only registers pick, so no hit result reaches the
    -- RAM address.
    d_raddr <= m_addr when mem_valid = '1' and mem_kind /= K_NONE and mem_first = '0' else std_logic_vector(ea);
    d_req   <= '1' when mem_valid = '1' and mem_kind /= K_NONE and (mem_st = M_REQ or mem_st = M_AMOW) else '0';
    d_addr  <= m_addr;
    d_we    <= m_we;
    d_wstrb <= m_wstrb;
    d_wdata <= m_wdata;

    ---------------------------------------------------------------- WB
    retire      <= wb_valid;
    retire_pc   <= std_logic_vector(halt_pc) when halt_r = '1' else std_logic_vector(wb_pc);
    retire_rd   <= wb_rd when rf_we = '1' else "00000";
    retire_data <= wb_res;
    halted      <= halt_r and not mem_valid and not wb_valid;

    -- synthesis translate_off
    -- one line per retired instruction: pc instr rd value (hex; rd 00 when
    -- nothing is written)
    tracer : if TRACE /= "" generate
        process (clk)
            file f      : text open write_mode is TRACE;
            variable l  : line;
            variable n  : integer := 0;
        begin
            if rising_edge(clk) and wb_valid = '1' and n < TRACE_MAX then
                hwrite(l, std_logic_vector(wb_pc)); write(l, ' ');
                hwrite(l, wb_instr); write(l, ' ');
                if rf_we = '1' then
                    hwrite(l, "000" & wb_rd); write(l, ' '); hwrite(l, wb_res);
                else
                    write(l, string'("00 00000000"));
                end if;
                writeline(f, l);
                n := n + 1;
            end if;
        end process;
    end generate;
    -- synthesis translate_on

    ---------------------------------------------------------------- registers
    process (clk)
        variable a, b : signed(32 downto 0);
        variable diff : unsigned(32 downto 0);
        variable rem2 : unsigned(31 downto 0);
        variable tcause : std_logic_vector(31 downto 0);
        variable ttval  : std_logic_vector(31 downto 0);
        variable in_instr : std_logic_vector(31 downto 0);
        variable in_pt    : std_logic;
    begin
        if rising_edge(clk) then
            cycles <= cycles + 1;

            -------------------------------------------------------- IF
            f_pc    <= fa;
            redir_r <= '0';

            -- return stack, updated as instructions enter the decode queue
            if f_take = '1' then
                if pd_call = '1' then
                    ras(to_integer(ras_top + 1)) <= f_pc4;
                    ras_top <= ras_top + 1;
                elsif pd_ret = '1' then
                    ras_top <= ras_top - 1;
                end if;
            end if;

            -------------------------------------------------------- ID
            -- the decode queue: ID, then q1. A fault marker never decodes junk.
            if f_fault /= "00" then
                in_instr := x"00000013";
                in_pt    := '0';
            else
                in_instr := i_rdata;
                in_pt    := pd_pt;
            end if;
            if id_valid = '0' or id_adv = '1' then
                id_redirected <= '0';
                if q1_valid = '1' and id_redir_now = '0' then
                    id_valid  <= '1';
                    id_pc     <= q1_pc;
                    id_instr  <= q1_instr;
                    id_fault  <= q1_fault;
                    id_target <= q1_target;
                    id_pt     <= q1_pt;
                    q1_valid  <= f_take;
                else
                    id_valid  <= f_take;
                    q1_valid  <= '0';
                end if;
                if (q1_valid = '0' or id_redir_now = '1') and f_take = '1' then
                    id_pc     <= f_pc;
                    id_instr  <= in_instr;
                    id_fault  <= f_fault;
                    id_target <= pd_target;
                    id_pt     <= in_pt;
                end if;
            elsif id_redir_now = '1' then
                id_redirected <= '1';
                q1_valid      <= '0';     -- fetched past the taken branch
            elsif f_take = '1' then
                q1_valid <= '1';
            end if;
            if f_take = '1' then
                q1_pc     <= f_pc;
                q1_instr  <= in_instr;
                q1_fault  <= f_fault;
                q1_target <= pd_target;
                q1_pt     <= in_pt;
            end if;

            -------------------------------------------------------- EX
            ex_opa   <= rs1v;
            ex_opb   <= rs2v;
            ex_first <= '0';
            if ex_free = '1' then
                ex_first  <= '1';
                ex_valid  <= id_valid;
                instr     <= id_instr;
                pc        <= id_pc;
                ex_pt     <= id_pt;
                ex_tgt    <= id_target;
                ex_imm    <= id_imm;
                ex_fault  <= id_fault;
                ex_u1     <= id_u1;
                ex_u2     <= id_u2;
                ex_serial <= id_serial;
                ex_st     <= X_RUN;
            end if;

            -- multiply and divide run inside EX
            if x_start = '1' then
                if funct3(2) = '0' then
                    -- MUL, MULH, MULHSU, MULHU
                    if funct3 = "011" then a := signed('0' & rs1v); else a := signed(rs1v(31) & rs1v); end if;
                    if funct3 = "010" or funct3 = "011" then b := signed('0' & rs2v); else b := signed(rs2v(31) & rs2v); end if;
                    mul_a <= a;
                    mul_b <= b;
                    ex_st <= X_MUL0;
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
                    ex_st     <= X_DIV;
                end if;
            end if;
            case ex_st is
                when X_MUL0 =>
                    pp_hh <= mul_a(32 downto 16) * mul_b(32 downto 16);
                    pp_hl <= mul_a(32 downto 16) * signed('0' & mul_b(15 downto 0));
                    pp_lh <= signed('0' & mul_a(15 downto 0)) * mul_b(32 downto 16);
                    pp_ll <= unsigned(mul_a(15 downto 0)) * unsigned(mul_b(15 downto 0));
                    ex_st <= X_MUL1;
                when X_MUL1 =>
                    mul_p <= shift_left(resize(pp_hh, 66), 32)
                           + shift_left(resize(pp_hl, 66), 16)
                           + shift_left(resize(pp_lh, 66), 16)
                           + signed(resize(pp_ll, 66));
                    ex_st <= X_MUL2;
                when X_DIV =>
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
                when others =>
                    null;
            end case;

            -------------------------------------------------------- MEM
            if mem_valid = '1' then
                case mem_st is
                    when M_REQ =>
                        if d_ack = '1' and mem_kind = K_AMO then
                            amo_old <= load_val;
                            mem_st  <= M_AMOC;
                        end if;
                    when M_AMOC =>
                        m_wdata <= amo_new;
                        m_we    <= '1';
                        mem_st  <= M_AMOW;
                    when M_AMOW =>
                        if d_ack = '1' then
                            mem_st <= M_REQ;
                        end if;
                end case;
            end if;

            -------------------------------------------------------- WB
            wb_valid <= mem_done and not mem_exc;
            if mem_done = '1' then
                wb_we    <= mem_we;
                wb_rd    <= mem_rd;
                wb_pc    <= mem_pc;
                wb_instr <= mem_instr;
                case mem_kind is
                    when K_LOAD => wb_res <= load_val;
                    when K_AMO  => wb_res <= amo_old;
                    when others => wb_res <= mem_res;
                end case;
            end if;
            w1_we  <= rf_we;
            w1_rd  <= wb_rd;
            w1_res <= wb_res;
            if wb_valid = '1' then
                instret <= instret + 1;
            end if;

            -------------------------------------------------------- EX retires into MEM
            mem_first <= '0';
            if mem_done = '1' then
                mem_valid <= '0';
            end if;
            tcause := (others => '0');
            ttval  := (others => '0');
            if ex_adv = '1' and x_trap = '0' and x_stop = '0' and m_trap = '0' then
                mem_valid <= '1';
                mem_first <= '1';
                mem_pc    <= pc;
                mem_instr <= instr;
                mem_rd    <= rd;
                if writes = '1' and rd /= "00000" then mem_we <= '1'; else mem_we <= '0'; end if;
                mem_res   <= x_result;
                mem_f3    <= funct3;
                mem_st    <= M_REQ;
                mem_late  <= '0';
                mem_kind  <= K_NONE;
                m_addr    <= std_logic_vector(ea);
                m_we      <= '0';
                m_wstrb   <= "1111";
                m_wdata   <= rs2v;
                case opcode is
                    when OP_LOAD =>
                        mem_kind <= K_LOAD;
                        mem_late <= '1';
                    when OP_STORE =>
                        mem_kind <= K_STORE;
                        m_we     <= '1';
                        m_wstrb  <= st_strb;
                        m_wdata  <= st_data;
                    when OP_AMO =>
                        mem_f3 <= "010";
                        if amo_sc = '1' then
                            lr_valid <= '0';
                            if lr_hit = '1' then
                                mem_kind <= K_STORE;
                                m_we     <= '1';
                            end if;
                        elsif amo_lr = '1' then
                            mem_kind <= K_LOAD;
                            mem_late <= '1';
                            lr_valid <= '1';
                            lr_addr  <= ea(31 downto 2);
                        else
                            mem_kind <= K_AMO;
                            mem_late <= '1';
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
                mem_exc   <= exc;
                mem_cause <= exc_cause;
                mem_tval  <= exc_tval;
                if exc = '1' then
                    mem_kind <= K_NONE;     -- traps in MEM without touching memory
                end if;
                if x_redir = '1' then
                    redir_r  <= '1';
                    redir_pc <= x_tgt;
                end if;
            end if;

            if ex_adv = '1' and x_stop = '1' and m_trap = '0' then
                halt_r  <= '1';
                halt_pc <= pc;
            end if;

            -- trap entry: the instruction in EX does not execute
            if ex_adv = '1' and x_trap = '1' and m_trap = '0' then
                if x_irq = '1' then
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
                elsif x_fault = '1' then
                    if ex_fault = "10" then tcause := x"00000000"; else tcause := x"00000001"; end if;
                    ttval := std_logic_vector(pc);
                else
                    tcause := x"0000000" & exc_cause;
                    ttval  := exc_tval;
                end if;
                mepc     <= std_logic_vector(pc);
                mcause   <= tcause;
                mtval    <= ttval;
                st_mpie  <= st_mie;
                st_mie   <= '0';
                st_mpp   <= priv_m & priv_m;
                priv_m   <= '1';
                lr_valid <= '0';
                redir_r  <= '1';
                if mtvec(0) = '1' and tcause(31) = '1' then
                    redir_pc <= (unsigned(mtvec(31 downto 2)) + unsigned(tcause(4 downto 0))) & "00";
                else
                    redir_pc <= unsigned(mtvec(31 downto 2)) & "00";
                end if;
            end if;

            -- everything younger than a redirect, trap or halt is dropped
            if x_flush = '1' then
                id_valid <= '0';
                q1_valid <= '0';
                ex_valid <= '0';
            end if;

            -- an exception in MEM: older instructions have retired, younger
            -- ones are dropped, the one following it into MEM included
            if m_trap = '1' then
                mepc     <= std_logic_vector(mem_pc);
                mcause   <= x"0000000" & mem_cause;
                mtval    <= mem_tval;
                st_mpie  <= st_mie;
                st_mie   <= '0';
                st_mpp   <= priv_m & priv_m;
                priv_m   <= '1';
                lr_valid <= '0';
                redir_r  <= '1';
                redir_pc <= unsigned(mtvec(31 downto 2)) & "00";
                id_valid  <= '0';
                q1_valid  <= '0';
                ex_valid  <= '0';
                mem_valid <= '0';
            end if;

            if reset = '1' then
                f_pc      <= unsigned(RESET_PC);
                redir_r   <= '0';
                halt_r    <= '0';
                id_valid  <= '0';
                q1_valid  <= '0';
                ex_valid  <= '0';
                ex_st     <= X_RUN;
                mem_valid <= '0';
                mem_st    <= M_REQ;
                wb_valid  <= '0';
                w1_we     <= '0';
                instret   <= (others => '0');
                priv_m    <= '1';
                st_mie    <= '0';
                st_mpie   <= '0';
                st_mpp    <= "00";
                ie_s      <= '0';
                ie_t      <= '0';
                ie_e      <= '0';
                mtvec     <= (others => '0');
                traps_on  <= '0';
                lr_valid  <= '0';
            end if;
        end if;
    end process;
end rtl;
