-- RV32IM, multicycle, no interrupts. An ALU instruction takes two cycles:
-- EXEC computes and asks for the next instruction, FETCH waits for it. The
-- next fetch is issued in the cycle an instruction finishes, so a cache hit
-- lands one cycle later with nothing wasted in between.
--
-- Bus protocol (both ports): hold req, addr, we, wstrb, wdata steady until ack.
-- ack is one cycle; rdata is valid with it. A new request may start in the
-- cycle after ack. addr and req always come straight from registers; the
-- combinational next address only goes to raddr, to start the cache RAM read
-- a cycle early.
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
        -- debug
        halted  : out std_logic;
        retire  : out std_logic;                      -- one cycle per retired instruction
        retire_pc   : out std_logic_vector(31 downto 0);
        retire_rd   : out std_logic_vector(4 downto 0); -- 0 when nothing written
        retire_data : out std_logic_vector(31 downto 0)
    );
end cpu;

architecture rtl of cpu is
    type state_t is (S_FETCH, S_EXEC, S_MEM, S_MUL0, S_MUL1, S_MUL2, S_DIV, S_HALT);
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
    ea  <= unsigned(rs1v) + imm_s when opcode = OP_STORE else unsigned(rs1v) + imm_i;

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

    -- ALU for OP, OP-IMM, LUI, AUIPC, JAL, JALR, SYSTEM reads
    process (opcode, funct3, funct7, rs1v, rs2v, imm_i, imm_u, pc, pc4, instr, cycles, instret)
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
            when OP_SYSTEM =>
                case instr(31 downto 20) is
                    when x"C00" | x"C01" | x"B00" => r := cycles(31 downto 0);
                    when x"C80" | x"C81" | x"B80" => r := cycles(63 downto 32);
                    when x"C02" | x"B02"          => r := instret(31 downto 0);
                    when x"C82" | x"B82"          => r := instret(63 downto 32);
                    when others                   => r := (others => '0');
                end case;
            when others => null;
        end case;
        alu_out <= std_logic_vector(r);
    end process;

    -- next PC for anything finishing in EXEC
    process (opcode, funct3, rs1v, rs2v, pc, pc4, imm_b, imm_j, imm_i)
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
             div_count, div_quo, div_rem, div_negq, div_negr, div_byz, div_ovf, div_dvd0, instr)
        variable fin  : std_logic;
        variable we   : std_logic;
        variable wd   : std_logic_vector(31 downto 0);
        variable q, r : unsigned(31 downto 0);
    begin
        d_req   <= '0';
        d_prime <= '0';
        d_raddr <= m_addr;
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
                    when OP_SYSTEM =>
                        if instr(14 downto 12) /= "000" then
                            we := '1'; fin := '1';
                        end if;
                    when OP_BRANCH | OP_FENCE =>
                        fin := '1';
                    when others =>
                        null;
                end case;

            when S_MEM =>
                d_req <= '1';
                if d_ack = '1' then
                    fin := '1';
                    if m_we = '0' then
                        we := '1';
                        wd := load_val;
                    end if;
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

    i_req   <= '1' when state = S_FETCH else '0';
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
    begin
        if rising_edge(clk) then
            cycles <= cycles + 1;
            if finish = '1' then
                instret <= instret + 1;
            end if;

            case state is
                when S_FETCH =>
                    if i_ack = '1' then
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
                        when OP_LUI | OP_AUIPC | OP_JAL | OP_JALR | OP_IMM | OP_BRANCH | OP_FENCE =>
                            null;
                        when OP_SYSTEM =>
                            if instr(14 downto 12) = "000" then
                                state <= S_HALT;  -- ECALL, EBREAK, xRET
                            end if;
                        when others =>
                            state <= S_HALT;
                    end case;

                when S_MEM =>
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
            end if;

            if reset = '1' then
                state   <= S_FETCH;
                pc      <= unsigned(RESET_PC);
                instret <= (others => '0');
            end if;
        end if;
    end process;
end rtl;
