/* TinyQV: A RISC-V core designed to use minimal area.
  
   This core module takes decoded instructions and produces output data
 */

module tinyqv_core #(parameter NUM_REGS=16, parameter REG_ADDR_BITS=4) (
    input clk,
    input rstn,

    input [3:0] imm,
    input [11:0] imm_lo,

    input is_load,
    input is_alu_imm,
    input is_auipc,
    input is_store,
    input is_alu_reg,
    input is_lui,
    input is_branch,
    input is_jalr,
    input is_jal,
    input is_system,
    input is_interrupt,
    input is_stall,

    input [3:0] alu_op,  // See tinyqv_alu for format
    input [2:0] mem_op,

    input [REG_ADDR_BITS-1:0] rs1,
    input [REG_ADDR_BITS-1:0] rs2,
    input [REG_ADDR_BITS-1:0] rd,

    input [2:0] counter,    // Sub cycle counter, must increment on every clock
    input [3:0] pc,
    input [3:0] next_pc,
    input [3:0] data_in,
    input load_data_ready,

    output reg [3:0] data_out,  // Data for the active store instruction
    output [27:0] addr_out,
    output address_ready,   // The addr_out holds the address for the active load/store instruction
    output reg instr_complete,  // The current instruction will complete this clock, so the instruction may be updated.
                            // If no new instruction is available all a NOOP should be issued, which will complete in 1 cycle.
    output branch           // addr_out holds the address to branch to
);

    ///////// Register file /////////

    wire [3:0] data_rs1;
    wire [3:0] data_rs2;
    reg [3:0] data_rd;
    reg wr_en;

    reg [31:0] tmp_data;

    tinyqv_registers #(.REG_ADDR_BITS(REG_ADDR_BITS), .NUM_REGS(NUM_REGS)) 
        i_registers(clk, rstn, wr_en, counter, rs1, rs2, rd, data_rs1, data_rs2, data_rd);


    ///////// ALU /////////

    wire is_slt = alu_op[3:1] == 3'b001;

    reg [2:0] alu_cycles;
    always @(*) begin
        if (is_slt || is_shift || is_mul) alu_cycles = 1;
        else alu_cycles = 0;
    end

    reg cy;
    reg cmp;
    wire [3:0] alu_op_in = (is_branch && cycle == 1) ? 4'b0000 : alu_op;
    wire [3:0] alu_a_in = (is_auipc || is_jal || (is_branch && cycle == 1)) ? pc : data_rs1;
    wire [3:0] alu_b_in = (is_alu_reg || (is_branch && cycle == 0)) ? data_rs2 : imm;
    wire [3:0] alu_out;
    wire cy_in = (counter == 0) ? (alu_op_in[1] || alu_op_in[3]) : cy;
    wire cmp_in = (counter == 0) ? 1'b1 : cmp;
    wire cy_out, cmp_out;

    tinyqv_alu i_alu(alu_op_in, alu_a_in, alu_b_in, cy_in, cmp_in, alu_out, cy_out, cmp_out);

    always @(posedge clk) begin
        cy <= cy_out;
        cmp <= cmp_out;
    end

    ///////// Shifter /////////

    wire is_shift = alu_op[1:0] == 2'b01;

    reg [4:0] shift_amt;
    always @(posedge clk) begin
        if (cycle == 0) begin
            if (counter == 0) shift_amt[3:0] <= is_alu_imm ? imm : data_rs2;
            else if (counter == 1) shift_amt[4] <= is_alu_imm ? imm[0] : data_rs2[0];
        end
    end

    wire [3:0] shift_out;
    tinyqv_shifter i_shift(alu_op[3:2], counter, tmp_data, shift_amt, shift_out);


    ///////// Multiplier /////////

    wire is_mul = alu_op[3] && alu_op[1];
    wire [3:0] mul_out;
    tinyqv_mul #(.B_BITS(16)) multiplier(clk, data_rs1 & {4{cycle[0]}}, tmp_data[15:0], mul_out);


    ///////// Writeback /////////

    reg load_top_bit_next;
    reg load_top_bit;
    always @(*) begin
        load_top_bit_next = (counter == 0) ? 0 : load_top_bit;
        if (is_load && load_data_ready &&
            ((mem_op == 3'b001 && counter == 3) || 
             (mem_op == 3'b000 && counter == 1)))
        begin
            load_top_bit_next = data_in[3];
        end
    end

    always @(posedge clk)
        load_top_bit <= load_top_bit_next;

    always @(*) begin
        wr_en = 0;
        data_rd = 0;
        if (is_alu_imm || is_alu_reg || is_auipc) begin
            wr_en = 1;
            if (is_slt && cycle == 1 && counter == 0)
                data_rd = {3'b000, cmp};
            else if (is_shift && cycle == 1)
                data_rd = shift_out;
            else if (is_mul) begin
                wr_en = cycle[0];
                data_rd = mul_out;
            end else
                data_rd = alu_out;

        end else if (is_load && load_data_ready) begin
            wr_en = 1;
            if ((mem_op[1:0] == 2'b00 && counter > 1) ||
                (mem_op[1:0] == 2'b01 && counter > 3))
                data_rd = {4{load_top_bit}};
            else
                data_rd = data_in;

        end else if (is_lui) begin
            wr_en = 1;
            data_rd = imm;
        end else if (is_jal || is_jalr) begin
            wr_en = 1;
            data_rd = next_pc;
        end else if (is_system) begin
            if (alu_op[1:0] != 2'b00) begin
                // CSR read
                wr_en = 1;
                data_rd = csr_read;
            end
        end
    end


    ///////// Branching /////////

    assign branch = last_count && ((is_jal || is_jalr || is_trap || is_interrupt) || (cycle == 1 && is_branch));
    wire take_branch = last_count && (cmp_out ^ mem_op[0]);


    ///////// Cycle management /////////

    wire last_count = (counter == 7);

    reg [2:0] cycle;
    always @(posedge clk) begin
        if (!rstn) cycle <= 0;
        else if (last_count) begin
            if (instr_complete) cycle <= 0;
            else if (cycle != 3'b111) cycle <= cycle + 1;
        end
    end

    always @(*) begin
        instr_complete = 0;
        if (last_count) begin
            if (is_alu_imm || is_alu_reg)
                instr_complete = cycle == alu_cycles;
            else if (is_auipc || is_lui || is_store || is_jal || is_jalr || is_system || is_stall)
                instr_complete = 1;
            else if (load_done && is_load)
                instr_complete = 1;
            else if (is_branch) begin
                if (cycle == 0 && !take_branch) instr_complete = 1;
                else if (cycle == 1) instr_complete = 1;
            end
        end
    end

    reg load_done;
    always @(posedge clk) begin
        if (counter == 0)
            load_done <= load_data_ready && cycle[2:1] != 2'b00;
    end

    assign address_ready = last_count && (cycle == 0) && (is_load || is_store);


    ///////// Working temporary data /////////

    reg [3:0] tmp_data_in;
    reg tmp_data_shift;
    
    always @(*) begin
        tmp_data_shift = 1;
        if (is_shift)
            tmp_data_in = data_rs1;
        else if (is_mul)
            tmp_data_in = data_rs2;
        else if (is_trap)
            tmp_data_in = (counter == 0) ? 4'b0100 : 4'b0000;
        else if (cycle == 0 || is_branch)
            tmp_data_in = alu_out;
        else
            tmp_data_in = data_rs2;
        
        if (cycle == 1 && (is_shift || is_mul))
            tmp_data_shift = 0;
    end

    always @(posedge clk) begin
        if (tmp_data_shift)
            tmp_data <= {tmp_data_in, tmp_data[31:4]};
    end

    assign addr_out = tmp_data[31:4];

    always @(*) begin
        data_out = data_rs2;
        if ((mem_op[1:0] == 2'b00 && counter > 1) ||
            (mem_op[1:0] == 2'b01 && counter > 3))
            data_out = 0;
    end


    ///////// Counters /////////

    wire [6:0] cycle_count_wide;
    tinyqv_counter #(.OUTPUT_WIDTH(7)) i_cycles (
        .clk(clk),
        .rstn(rstn),
        .add(1'b1),
        .counter(counter),
        .data(cycle_count_wide)
    );

    wire [3:0] cycle_count = cycle_count_wide[3:0];
    wire [3:0] time_count = (counter == 7) ? {3'b000, cycle_count_wide[3]} : cycle_count_wide[6:3];

    wire [3:0] instrret_count;
    reg instr_retired;
    always @(posedge clk) begin
        instr_retired <= instr_complete && !is_stall;
    end
    tinyqv_counter i_instrret (
        .clk(clk),
        .rstn(rstn),
        .add(instr_retired),
        .counter(counter),
        .data(instrret_count)
    );


    ///////// Traps /////////    

    wire is_trap = is_system && (alu_op[2:0] == 3'b000);
    reg [5:0] mcause;
    always @(posedge clk) begin
        if (!rstn) mcause <= 0;
        else if (counter == 0) begin
            if (is_interrupt) begin
                mcause <= {1'b1, imm_lo[4:0]};
            end else if (is_trap) begin
                if (imm == 4'b0000)      mcause <= 6'd11;  // ECALL
                else if (imm == 4'b0001) mcause <= 6'd3;   // EBREAK
                else                     mcause <= 6'd2;   // Illegal instruction
            end
        end
    end

    reg [23:0] mepc;
    always @(posedge clk) begin
        if (counter <= 5) begin
            mepc <= {(!rstn) ?                   4'b0000 :
                     (is_interrupt || is_trap) ? pc : 
                                                 mepc[3:0], mepc[23:4]};
        end
    end

    ///////// CSRs /////////    

    reg [3:0] csr_read;
    always @(*) begin
        case (imm_lo) 
            // misa
            12'h301: csr_read = (counter == 0 || counter == 7) ? 4'b0100 :  // C, 32
                                (counter == 1) ?                 4'b0001 :  // E
                                                                 4'b0000;
            
            // mepc
            12'h341: csr_read = (counter <= 5) ? mepc[3:0] : 4'b0000;

            // mcause
            12'h342: csr_read = (counter == 0) ? mcause[3:0] :
                                (counter == 1) ? {3'b000, mcause[4]} :
                                (counter == 7) ? {mcause[5], 3'b000} :
                                                 4'b0000;
            
            12'hC00: csr_read = cycle_count;
            12'hC01: csr_read = time_count;
            12'hC02: csr_read = instrret_count;
            default: csr_read = 4'b0000;
        endcase
    end

endmodule
