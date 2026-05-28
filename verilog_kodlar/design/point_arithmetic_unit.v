`timescale 1ns / 1ps

module point_arithmetic_unit (
    input  wire         clk,
    input  wire         rst_n,
    input  wire [255:0] modulus_p, // Dinamik asal geçiş kanalı
    input  wire         cmd,       // 0: Point Double, 1: Point Add
    input  wire [255:0] p1_x, p1_y, p1_z,
    input  wire [255:0] p2_x, p2_y, p2_z,
    input  wire         start,
    
    output reg  [255:0] pout_x, pout_y, pout_z,
    output reg          done
);

    // GECICI OPERAND REGiSTERLARI
    reg [255:0] t1, t2; 
    reg [255:0] w_part, w, s, Y1_s, B, w_sq, two_B, four_B, eight_B;
    reg [255:0] h, h_s, four_B_minus_h, part1, Y1_sq, s_sq, Y1_sq_s_sq, t_8_Y1, s_cubed;
    
    reg [255:0] U1, U2, V1, V2, u, v, w_add, v_sq, v_cb, v_sq_V2;
    reg [255:0] u_sq, u_sq_w, two_v_sq_V2, A, v_sq_V2_m_A, part1_add, part2_add;

    localparam S_IDLE      = 2'd0;
    localparam S_SETUP     = 2'd1;
    localparam S_WAIT_MALU = 2'd2;
    localparam S_FINISH    = 2'd3;
    
    reg [1:0] state;
    reg [4:0] step_counter; 
    
    reg  [1:0]   malu_opcode; 
    reg  [255:0] malu_op_a, malu_op_b;
    reg          malu_start;
    wire [255:0] malu_result;
    wire         malu_done;

    modular_alu malu_inst (
        .clk(clk), .rst_n(rst_n), .opcode(malu_opcode),
        .operand_a(malu_op_a), .operand_b(malu_op_b),
        .modulus_p(modulus_p), .start(malu_start), .result(malu_result), .done(malu_done)
    );

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            // RESET GÜVENLİĞİ: Tüm ara matematik veri yolları sıfırlanır
            state <= S_IDLE; done <= 1'b0; malu_start <= 1'b0; step_counter <= 5'd0;
            pout_x <= 256'd0; pout_y <= 256'd0; pout_z <= 256'd0;
            malu_opcode <= 2'b00; malu_op_a <= 256'd0; malu_op_b <= 256'd0;
            t1 <= 256'd0; t2 <= 256'd0; w_part <= 256'd0; w <= 256'd0; s <= 256'd0;
            Y1_s <= 256'd0; B <= 256'd0; w_sq <= 256'd0; two_B <= 256'd0; four_B <= 256'd0;
            eight_B <= 256'd0; h <= 256'd0; h_s <= 256'd0; four_B_minus_h <= 256'd0;
            part1 <= 256'd0; Y1_sq <= 256'd0; s_sq <= 256'd0; Y1_sq_s_sq <= 256'd0;
            t_8_Y1 <= 256'd0; s_cubed <= 256'd0; U1 <= 256'd0; U2 <= 256'd0; V1 <= 256'd0;
            V2 <= 256'd0; u <= 256'd0; v <= 256'd0; w_add <= 256'd0; v_sq <= 256'd0;
            v_cb <= 256'd0; v_sq_V2 <= 256'd0; u_sq <= 256'd0; u_sq_w <= 256'd0;
            two_v_sq_V2 <= 256'd0; A <= 256'd0; v_sq_V2_m_A <= 256'd0; part1_add <= 256'd0;
            part2_add <= 256'd0;
        end else begin
            case (state)
                S_IDLE: begin
                    done <= 1'b0;
                    if (start) begin
                        if (cmd == 1'b1 && p1_z == 256'd0) begin
                            pout_x <= p2_x; pout_y <= p2_y; pout_z <= p2_z;
                            state <= S_FINISH;
                        end else if (cmd == 1'b1 && p2_z == 256'd0) begin
                            pout_x <= p1_x; pout_y <= p1_y; pout_z <= p1_z;
                            state <= S_FINISH;
                        end else if (cmd == 1'b0 && p1_z == 256'd0) begin
                            pout_x <= p1_x; pout_y <= p1_y; pout_z <= p1_z;
                            state <= S_FINISH;
                        end else begin
                            state <= S_SETUP;
                            step_counter <= 5'd0;
                        end
                    end
                end
                
                S_SETUP: begin
                    malu_start <= 1'b1;
                    if (cmd == 1'b0) begin 
                        case (step_counter)
                            5'd0:  begin malu_opcode<=2'b01; malu_op_a<=p1_x; malu_op_b<=p1_z; end 
                            5'd1:  begin malu_opcode<=2'b00; malu_op_a<=p1_x; malu_op_b<=p1_z; end 
                            5'd2:  begin malu_opcode<=2'b10; malu_op_a<=t1;   malu_op_b<=t2;   end 
                            5'd3:  begin malu_opcode<=2'b00; malu_op_a<=w_part; malu_op_b<=w_part; end 
                            5'd4:  begin malu_opcode<=2'b00; malu_op_a<=t1;   malu_op_b<=w_part; end 
                            5'd5:  begin malu_opcode<=2'b10; malu_op_a<=p1_y; malu_op_b<=p1_z; end 
                            5'd6:  begin malu_opcode<=2'b10; malu_op_a<=p1_y; malu_op_b<=s;    end 
                            5'd7:  begin malu_opcode<=2'b10; malu_op_a<=p1_x; malu_op_b<=Y1_s; end 
                            5'd8:  begin malu_opcode<=2'b10; malu_op_a<=w;    malu_op_b<=w;    end 
                            5'd9:  begin malu_opcode<=2'b00; malu_op_a<=B;    malu_op_b<=B;    end 
                            5'd10: begin malu_opcode<=2'b00; malu_op_a<=two_B; malu_op_b<=two_B; end 
                            5'd11: begin malu_opcode<=2'b00; malu_op_a<=four_B; malu_op_b<=four_B; end 
                            5'd12: begin malu_opcode<=2'b01; malu_op_a<=w_sq; malu_op_b<=eight_B; end 
                            5'd13: begin malu_opcode<=2'b10; malu_op_a<=h;    malu_op_b<=s;    end 
                            5'd14: begin malu_opcode<=2'b00; malu_op_a<=h_s;  malu_op_b<=h_s;  end 
                            5'd15: begin malu_opcode<=2'b01; malu_op_a<=four_B; malu_op_b<=h;  end 
                            5'd16: begin malu_opcode<=2'b10; malu_op_a<=w;    malu_op_b<=four_B_minus_h; end 
                            5'd17: begin malu_opcode<=2'b10; malu_op_a<=p1_y; malu_op_b<=p1_y; end 
                            5'd18: begin malu_opcode<=2'b10; malu_op_a<=s;    malu_op_b<=s;    end 
                            5'd19: begin malu_opcode<=2'b10; malu_op_a<=Y1_sq; malu_op_b<=s_sq; end 
                            5'd20: begin malu_opcode<=2'b00; malu_op_a<=Y1_sq_s_sq; malu_op_b<=Y1_sq_s_sq; end 
                            5'd21: begin malu_opcode<=2'b00; malu_op_a<=t1;   malu_op_b<=t1;   end 
                            5'd22: begin malu_opcode<=2'b00; malu_op_a<=t2;   malu_op_b<=t2;   end 
                            5'd23: begin malu_opcode<=2'b01; malu_op_a<=part1; malu_op_b<=t_8_Y1; end 
                            5'd24: begin malu_opcode<=2'b10; malu_op_a<=s_sq; malu_op_b<=s;    end 
                            5'd25: begin malu_opcode<=2'b00; malu_op_a<=s_cubed; malu_op_b<=s_cubed; end 
                            5'd26: begin malu_opcode<=2'b00; malu_op_a<=t1;   malu_op_b<=t1;   end 
                            5'd27: begin malu_opcode<=2'b00; malu_op_a<=t2;   malu_op_b<=t2;   end 
                        endcase
                    end else begin 
                        case (step_counter)
                            5'd0:  begin malu_opcode<=2'b10; malu_op_a<=p2_y; malu_op_b<=p1_z; end 
                            5'd1:  begin malu_opcode<=2'b10; malu_op_a<=p1_y; malu_op_b<=p2_z; end 
                            5'd2:  begin malu_opcode<=2'b10; malu_op_a<=p2_x; malu_op_b<=p1_z; end 
                            5'd3:  begin malu_opcode<=2'b10; malu_op_a<=p1_x; malu_op_b<=p2_z; end 
                            5'd4:  begin malu_opcode<=2'b01; malu_op_a<=U1;   malu_op_b<=U2;   end 
                            5'd5:  begin malu_opcode<=2'b01; malu_op_a<=V1;   malu_op_b<=V2;   end 
                            5'd6:  begin malu_opcode<=2'b10; malu_op_a<=p1_z; malu_op_b<=p2_z; end 
                            5'd7:  begin malu_opcode<=2'b10; malu_op_a<=v;    malu_op_b<=v;    end 
                            5'd8:  begin malu_opcode<=2'b10; malu_op_a<=v_sq; malu_op_b<=v;    end 
                            5'd9:  begin malu_opcode<=2'b10; malu_op_a<=v_sq; malu_op_b<=V2;   end 
                            5'd10: begin malu_opcode<=2'b10; malu_op_a<=u;    malu_op_b<=u;    end 
                            5'd11: begin malu_opcode<=2'b10; malu_op_a<=u_sq; malu_op_b<=w_add;end 
                            5'd12: begin malu_opcode<=2'b00; malu_op_a<=v_sq_V2; malu_op_b<=v_sq_V2; end 
                            5'd13: begin malu_opcode<=2'b01; malu_op_a<=u_sq_w; malu_op_b<=v_cb; end 
                            5'd14: begin malu_opcode<=2'b01; malu_op_a<=A;    malu_op_b<=two_v_sq_V2; end 
                            5'd15: begin malu_opcode<=2'b10; malu_op_a<=v;    malu_op_b<=A;    end 
                            5'd16: begin malu_opcode<=2'b01; malu_op_a<=v_sq_V2; malu_op_b<=A; end 
                            5'd17: begin malu_opcode<=2'b10; malu_op_a<=u;    malu_op_b<=v_sq_V2_m_A; end 
                            5'd18: begin malu_opcode<=2'b10; malu_op_a<=v_cb; malu_op_b<=U2;   end 
                            5'd19: begin malu_opcode<=2'b01; malu_op_a<=part1_add; malu_op_b<=part2_add; end 
                            5'd20: begin malu_opcode<=2'b10; malu_op_a<=v_cb; malu_op_b<=w_add;end 
                        endcase
                    end
                    state <= S_WAIT_MALU;
                end
                
                S_WAIT_MALU: begin
                    malu_start <= 1'b0; 
                    if (malu_done) begin
                        if (cmd == 1'b0) begin
                            case (step_counter)
                                5'd0:  t1 <= malu_result; 5'd1:  t2 <= malu_result; 5'd2:  w_part <= malu_result;
                                5'd3:  t1 <= malu_result; 5'd4:  w <= malu_result; 5'd5:  s <= malu_result;
                                5'd6:  Y1_s <= malu_result; 5'd7:  B <= malu_result; 5'd8:  w_sq <= malu_result;
                                5'd9:  two_B <= malu_result; 5'd10: four_B <= malu_result; 5'd11: eight_B <= malu_result;
                                5'd12: h <= malu_result; 5'd13: h_s <= malu_result; 5'd14: pout_x <= malu_result; 
                                5'd15: four_B_minus_h <= malu_result; 5'd16: part1 <= malu_result; 5'd17: Y1_sq <= malu_result;
                                5'd18: s_sq <= malu_result; 5'd19: Y1_sq_s_sq <= malu_result; 5'd20: t1 <= malu_result;
                                5'd21: t2 <= malu_result; 5'd22: t_8_Y1 <= malu_result; 5'd23: pout_y <= malu_result; 
                                5'd24: s_cubed <= malu_result; 5'd25: t1 <= malu_result; 5'd26: t2 <= malu_result;
                                5'd27: pout_z <= malu_result; 
                            endcase
                        end else begin
                            case (step_counter)
                                5'd0:  U1 <= malu_result; 5'd1:  U2 <= malu_result; 5'd2:  V1 <= malu_result;
                                5'd3:  V2 <= malu_result; 5'd4:  u <= malu_result;  5'd5:  v <= malu_result;
                                5'd6:  w_add <= malu_result; 5'd7:  v_sq <= malu_result; 5'd8:  v_cb <= malu_result;
                                5'd9:  v_sq_V2 <= malu_result; 5'd10: u_sq <= malu_result; 5'd11: u_sq_w <= malu_result;
                                5'd12: two_v_sq_V2 <= malu_result; 5'd13: A <= malu_result; 5'd14: A <= malu_result;
                                5'd15: pout_x <= malu_result; 5'd16: v_sq_V2_m_A <= malu_result; 5'd17: part1_add <= malu_result;
                                5'd18: part2_add <= malu_result; 5'd19: pout_y <= malu_result; 5'd20: pout_z <= malu_result;
                            endcase
                        end
                        
                        if ((cmd == 1'b0 && step_counter == 5'd27) || (cmd == 1'b1 && step_counter == 5'd20)) 
                            state <= S_FINISH; 
                        else begin
                            step_counter <= step_counter + 1; 
                            state <= S_SETUP;
                        end
                    end
                end
                
                S_FINISH: begin
                    done <= 1'b1;
                    state <= S_IDLE;
                end
            endcase
        end
    end

endmodule