`timescale 1ns / 1ps

module scalar_multiplier (
    input  wire         clk,
    input  wire         rst_n,
    input  wire [255:0] modulus_p, // Dinamik olarak üstten beslenen asal
    input  wire [255:0] scalar_d,  // 256-bit Özel Anahtar
    input  wire [255:0] base_x,    // Montgomery formunda X
    input  wire [255:0] base_y,    // Montgomery formunda Y
    input  wire [255:0] base_z,    // Montgomery formunda Z
    input  wire         start,
    
    output reg  [255:0] out_x,     
    output reg  [255:0] out_y,     
    output reg  [255:0] out_z,     
    output reg          done
);

    reg [8:0] bit_index;
    
    localparam IDLE       = 3'd0;
    localparam PAU_ADD    = 3'd1;
    localparam WAIT_ADD   = 3'd2;
    localparam PAU_DBL    = 3'd3;
    localparam WAIT_DBL   = 3'd4;
    localparam FINISH     = 3'd5;
    
    reg [2:0] state;

    reg  pau_cmd;
    reg  pau_start;
    wire pau_done;
    
    reg [255:0] r0_x, r0_y, r0_z;
    reg [255:0] r1_x, r1_y, r1_z;

    reg [255:0] pau_p1_x, pau_p1_y, pau_p1_z;
    reg [255:0] pau_p2_x, pau_p2_y, pau_p2_z;
    wire [255:0] pout_x, pout_y, pout_z;

    point_arithmetic_unit pau_inst (
        .clk(clk), .rst_n(rst_n), .modulus_p(modulus_p), .cmd(pau_cmd),
        .p1_x(pau_p1_x), .p1_y(pau_p1_y), .p1_z(pau_p1_z),
        .p2_x(pau_p2_x), .p2_y(pau_p2_y), .p2_z(pau_p2_z),
        .start(pau_start), 
        .pout_x(pout_x), .pout_y(pout_y), .pout_z(pout_z), 
        .done(pau_done)
    );

    wire d_i = scalar_d[bit_index];

    // Combinational MUX: Yan Kanal Koruma Dağıtıcı Yolu
    always @(*) begin
        if (state == PAU_ADD || state == WAIT_ADD) begin
            pau_p1_x = r0_x; pau_p1_y = r0_y; pau_p1_z = r0_z;
            pau_p2_x = r1_x; pau_p2_y = r1_y; pau_p2_z = r1_z;
        end else begin 
            if (d_i == 1'b0) begin
                pau_p1_x = r0_x; pau_p1_y = r0_y; pau_p1_z = r0_z;
            end else begin
                pau_p1_x = r1_x; pau_p1_y = r1_y; pau_p1_z = r1_z;
            end
            pau_p2_x = 256'd0; pau_p2_y = 256'd0; pau_p2_z = 256'd0;
        end
    end

    // Kontrol Döngüsü
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            // RESET GÜVENLİĞİ: Tüm ara merdiven noktaları tamamen sıfırlanır
            state <= IDLE; done <= 1'b0; pau_start <= 1'b0; bit_index <= 9'd255;
            out_x <= 256'd0; out_y <= 256'd0; out_z <= 256'd0;
            r0_x <= 256'd0; r0_y <= 256'd0; r0_z <= 256'd0;
            r1_x <= 256'd0; r1_y <= 256'd0; r1_z <= 256'd0;
            pau_cmd <= 1'b0;
        end else begin
            case (state)
                IDLE: begin
                    done <= 1'b0;
                    if (start) begin
                        bit_index <= 9'd255;
                        r0_x <= 256'd0; r0_y <= 256'd0; r0_z <= 256'd0; // Sonsuzluk noktası başlangıcı
                        r1_x <= base_x; r1_y <= base_y; r1_z <= base_z; 
                        state <= PAU_ADD;
                    end
                end
                
                PAU_ADD: begin pau_cmd <= 1'b1; pau_start <= 1'b1; state <= WAIT_ADD; end
                
                WAIT_ADD: begin
                    pau_start <= 1'b0;
                    if (pau_done) begin
                        if (d_i == 1'b0) begin r1_x <= pout_x; r1_y <= pout_y; r1_z <= pout_z; end 
                        else begin r0_x <= pout_x; r0_y <= pout_y; r0_z <= pout_z; end
                        state <= PAU_DBL;
                    end
                end
                
                PAU_DBL: begin pau_cmd <= 1'b0; pau_start <= 1'b1; state <= WAIT_DBL; end
                
                WAIT_DBL: begin
                    pau_start <= 1'b0;
                    if (pau_done) begin
                        if (d_i == 1'b0) begin r0_x <= pout_x; r0_y <= pout_y; r0_z <= pout_z; end 
                        else begin r1_x <= pout_x; r1_y <= pout_y; r1_z <= pout_z; end
                        
                        if (bit_index == 9'd0) state <= FINISH;
                        else begin bit_index <= bit_index - 1; state <= PAU_ADD; end
                    end
                end
                
                FINISH: begin out_x <= r0_x; out_y <= r0_y; out_z <= r0_z; done <= 1'b1; state <= IDLE; end
            endcase
        end
    end

endmodule