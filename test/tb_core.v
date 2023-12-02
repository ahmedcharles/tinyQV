/* A RISC-V core designed to use minimal area.
  
   Aim is to support RV32E 
 */

module tb_core (
    input clk,
    input rstn,

    input [31:0] instr,
    input [31:0] pc,
    input [31:0] data_in,
    input load_data_ready,

    output [31:0] data_out,
    output [31:0] addr_out,
    output address_ready,
    output instr_complete,
    output branch
);

`ifdef COCOTB_SIM
initial begin
  $dumpfile ("core.vcd");
  $dumpvars (0, tb_core);
  #1;
end
`endif

    wire [31:0] imm;

    wire is_load;
    wire is_alu_imm;
    wire is_auipc;
    wire is_store;
    wire is_alu_reg;
    wire is_lui;
    wire is_branch;
    wire is_jalr;
    wire is_jal;
    wire is_system;

    wire [2:1] instr_len;
    wire [3:0] alu_op;  // See tiny45_alu for format
    wire [2:0] mem_op;

    wire [3:0] rs1;
    wire [3:0] rs2;
    wire [3:0] rd;

    tiny45_decoder decoder(instr, 
        imm,

        is_load,
        is_alu_imm,
        is_auipc,
        is_store,
        is_alu_reg,
        is_lui,
        is_branch,
        is_jalr,
        is_jal,
        is_system,

        instr_len,
        alu_op,  // See tiny45_alu for format
        mem_op,

        rs1,
        rs2,
        rd
             );

    reg [4:0] counter;
    wire [4:0] next_counter = counter + 4;

    wire [3:0] data_out_slice;
    reg [31:0] data_out_reg;
    always @(posedge clk) begin
        if (!rstn) begin
            counter <= 0;
        end else begin
            counter <= next_counter;
        end
        data_out_reg[counter+:4] <= data_out_slice;
    end

    assign data_out[31:28] = data_out_slice;
    assign data_out[27:0] = data_out_reg[27:0];
    assign addr_out[31:28] = 0;

    tiny45_core core(clk,
        rstn,
        
        imm[counter+:4],

        is_load,
        is_alu_imm,
        is_auipc,
        is_store,
        is_alu_reg,
        is_lui,
        is_branch,
        is_jalr,
        is_jal,
        is_system,
        1'b0,

        alu_op,
        mem_op,

        rs1,
        rs2,
        rd,

        counter[4:2],
        pc[counter+:4],
        data_in[counter+:4],
        load_data_ready,

        data_out_slice,
        addr_out[27:0],
        address_ready,
        instr_complete,
        branch
        );

endmodule