`timescale 1ns / 1ps

module modular_alu (
    input  wire         clk,
    input  wire         rst_n,
    input  wire [1:0]   opcode,     // 0: Add, 1: Sub, 2: Mult
    input  wire [255:0] operand_a,
    input  wire [255:0] operand_b,
    input  wire [255:0] modulus_p,  
    input  wire         start,
    
    output reg  [255:0] result,
    output reg          done
);

    localparam IDLE    = 2'b00;
    localparam CALC    = 2'b01;
    localparam DONE_ST = 2'b10;

    reg [1:0] state;
    reg [8:0] bit_counter; 
    reg [257:0] r_reg; 

    // Combinational Aritmetik Veri Hatları
    wire [256:0] add_res = operand_a + operand_b;
    wire [256:0] add_res_mod = (add_res >= modulus_p) ? (add_res - modulus_p) : add_res;
    
    wire [256:0] sub_res_mod = (operand_a >= operand_b) ? (operand_a - operand_b) : (operand_a + modulus_p - operand_b);
    
    // Montgomery Çarpma Mantığı
    wire a_i = operand_a[bit_counter];
    wire [257:0] add_b = a_i ? {2'b00, operand_b} : 258'd0;
    wire [257:0] temp_r = r_reg + add_b;
    wire q_i = temp_r[0];
    wire [257:0] add_p = q_i ? {2'b00, modulus_p} : 258'd0;
    wire [257:0] next_r = (temp_r + add_p) >> 1;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            // RESET GÜVENLİĞİ: Çarpım akümülatörleri ve bit sayaçları sıfırlanır
            state <= IDLE; done <= 1'b0; result <= 256'd0;
            bit_counter <= 9'd0; r_reg <= 258'd0;
        end else begin
            case (state)
                IDLE: begin
                    done <= 1'b0;
                    r_reg <= 258'd0; 
                    if (start) begin
                        state <= CALC;
                        bit_counter <= 9'd0;
                    end
                end
                
                CALC: begin
                    if (opcode == 2'b10) begin 
                        if (bit_counter == 9'd256) begin 
                            if (r_reg >= modulus_p)
                                result <= r_reg - modulus_p;
                            else
                                result <= r_reg[255:0];
                                
                            state <= DONE_ST;
                        end else begin
                            r_reg <= next_r;
                            bit_counter <= bit_counter + 1;
                        end
                    end 
                    else if (opcode == 2'b00) begin 
                        result <= add_res_mod[255:0];
                        state <= DONE_ST;
                    end 
                    else if (opcode == 2'b01) begin 
                        result <= sub_res_mod[255:0];
                        state <= DONE_ST;
                    end
                end
                
                DONE_ST: begin
                    done <= 1'b1;
                    state <= IDLE;
                end
            endcase
        end
    end

endmodule