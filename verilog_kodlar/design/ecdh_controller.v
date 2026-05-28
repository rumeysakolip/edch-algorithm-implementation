`timescale 1ns / 1ps

module ecdh_controller (
    input  wire         clk,
    input  wire         rst_n,
    
    input  wire [1:0]   host_cmd,          // 01: GenPubKey, 10: ComputeSecret
    input  wire [255:0] private_key,       // Kullanıcının özel anahtarı (d)
    
    input  wire [255:0] peer_pub_x,        // Karşı tarafın standart Affine X'i
    input  wire [255:0] peer_pub_y,        // Karşı tarafın standart Affine Y'si
    
    // --- Esneklik İçin Dışarıdan Alınan Eğri Parametreleri ---
    input  wire [255:0] i_p_modulus,       // Eğrinin asalı P
    input  wire [255:0] i_r2_mod_p,        // Montgomery dönüşüm sabiti R^2 mod P
    input  wire [255:0] i_curve_b,         // Eğrinin b katsayısı (y^2 = x^3 - 3x + b)
    input  wire [255:0] i_curve_g_x,       // Taban noktası G_x
    input  wire [255:0] i_curve_g_y,       // Taban noktası G_y
    
    input  wire         start,             // Host tetikleyici sinyal
    
    output reg  [255:0] final_affine_x,    // Gerçek ve nihai ortak sır çıkışı
    output reg          status_valid,      // İşlem tamamlandı (Kesme/Interrupt)
    output reg          err_invalid_curve  // Saldırı Tespit Bayrağı (Geçersiz Nokta)
);

    // FSM Durum Tanımlamaları
    localparam IDLE           = 5'd0;
    localparam STAGE_MONT_X   = 5'd1;
    localparam STAGE_MONT_Y   = 5'd2;
    localparam VAL_B          = 5'd3;
    localparam VAL_THREE      = 5'd4;
    localparam VAL_LHS        = 5'd5;
    localparam VAL_X2         = 5'd6;
    localparam VAL_X2_M3      = 5'd7;
    localparam VAL_RHS_MULT   = 5'd8;
    localparam VAL_RHS_ADD    = 5'd9;
    localparam VAL_COMPARE    = 5'd10;
    localparam STAGE_MONT_Z   = 5'd11;
    localparam CALC_SM        = 5'd12;
    localparam GET_R_MOD_P    = 5'd13;
    localparam INV_FIND_TOP   = 5'd14;
    localparam INV_SQUARE     = 5'd15;
    localparam WAIT_INV_SQ    = 5'd16;
    localparam WAIT_INV_MULT  = 5'd17;
    localparam AFFINE_MULT    = 5'd18;
    localparam WAIT_AFF_MULT  = 5'd19;
    localparam EXIT_MONT      = 5'd20;
    localparam DONE_ST        = 5'd21;
    
    reg [4:0] state;

    // Parametre Kayıtçıları (Reset Güvenliği Kapsamında Sıfırlanır)
    reg [255:0] p_modulus_reg;
    reg [255:0] r2_mod_p_reg;
    reg [255:0] curve_b_reg;
    reg [255:0] curve_g_x_reg;
    reg [255:0] curve_g_y_reg;
    reg [255:0] p_minus_2_reg;

    // Doğrulama Motoru Ara Kayıtçıları
    reg [255:0] b_mont;
    reg [255:0] three_mont;
    reg [255:0] lhs_val;
    reg [255:0] x2_mont;
    reg [255:0] x2_m3_mont;
    reg [255:0] rhs_mult_mont;
    reg [255:0] rhs_val;

    // Giriş Seçim MUX Kayıtçıları
    reg [255:0] pt_x;
    reg [255:0] pt_y;

    // Modular ALU Sinyalleri
    reg  [1:0]   malu_opcode;
    reg  [255:0] malu_op_a, malu_op_b;
    reg          malu_start;
    wire [255:0] malu_result;
    wire         malu_done;

    modular_alu conv_alu (
        .clk(clk), .rst_n(rst_n), .opcode(malu_opcode),
        .operand_a(malu_op_a), .operand_b(malu_op_b),
        .modulus_p(p_modulus_reg), .start(malu_start), .result(malu_result), .done(malu_done)
    );

    // Scalar Multiplier Sinyalleri
    reg  [255:0] sm_base_x, sm_base_y, sm_base_z;
    reg          sm_start;
    wire         sm_done;
    wire [255:0] sm_out_x, sm_out_y, sm_out_z;

    scalar_multiplier sm_inst (
        .clk(clk), .rst_n(rst_n), .modulus_p(p_modulus_reg),
        .scalar_d(private_key),
        .base_x(sm_base_x), .base_y(sm_base_y), .base_z(sm_base_z),
        .start(sm_start),
        .out_x(sm_out_x), .out_y(sm_out_y), .out_z(sm_out_z), .done(sm_done)
    );

    // Inversion (Bölme) Kayıtçıları
    reg [255:0] inv_acc, inv_base, inv_exp;
    reg [7:0]   bit_idx;

    // Master Durum Makinesi
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            // RESET GÜVENLİĞİ: Tüm kayıtçılar istisnasız tamamen sıfırlanır
            state <= IDLE; status_valid <= 1'b0; err_invalid_curve <= 1'b0;
            sm_start <= 1'b0; malu_start <= 1'b0; malu_opcode <= 2'b00;
            malu_op_a <= 256'd0; malu_op_b <= 256'd0; final_affine_x <= 256'd0;
            sm_base_x <= 256'd0; sm_base_y <= 256'd0; sm_base_z <= 256'd0;
            p_modulus_reg <= 256'd0; r2_mod_p_reg <= 256'd0; curve_b_reg <= 256'd0;
            curve_g_x_reg <= 256'd0; curve_g_y_reg <= 256'd0; p_minus_2_reg <= 256'd0;
            inv_acc <= 256'd0; inv_base <= 256'd0; inv_exp <= 256'd0; bit_idx <= 8'd0;
            b_mont <= 256'd0; three_mont <= 256'd0; lhs_val <= 256'd0;
            x2_mont <= 256'd0; x2_m3_mont <= 256'd0; rhs_mult_mont <= 256'd0; rhs_val <= 256'd0;
            pt_x <= 256'd0; pt_y <= 256'd0;
        end else begin
            case (state)
                IDLE: begin
                    status_valid <= 1'b0;
                    if (start) begin
                        // Parametreleri giriş portlarından güvenli bir şekilde kaydet
                        p_modulus_reg <= i_p_modulus;
                        r2_mod_p_reg  <= i_r2_mod_p;
                        curve_b_reg   <= i_curve_b;
                        curve_g_x_reg <= i_curve_g_x;
                        curve_g_y_reg <= i_curve_g_y;
                        p_minus_2_reg <= i_p_modulus - 2;
                        err_invalid_curve <= 1'b0;

                        // DÜZELTİLDİ: i_peer_pub_x yerine peer_pub_x kullanıldı
                        pt_x <= (host_cmd == 2'b01) ? i_curve_g_x : peer_pub_x;
                        pt_y <= (host_cmd == 2'b01) ? i_curve_g_y : peer_pub_y;
                        
                        // X koordinatını Montgomery alanına taşımaya başla
                        malu_op_a <= (host_cmd == 2'b01) ? i_curve_g_x : peer_pub_x;
                        malu_op_b <= i_r2_mod_p;
                        malu_opcode <= 2'b10; // Çarpma emri
                        malu_start <= 1'b1;
                        state <= STAGE_MONT_X;
                    end
                end
                
                STAGE_MONT_X: begin
                    malu_start <= 1'b0;
                    if (malu_done) begin
                        sm_base_x <= malu_result;
                        // Y koordinatını Montgomery alanına taşı
                        malu_op_a <= pt_y;
                        malu_start <= 1'b1;
                        state <= STAGE_MONT_Y;
                    end
                end
                
                STAGE_MONT_Y: begin
                    malu_start <= 1'b0;
                    if (malu_done) begin
                        sm_base_y <= malu_result;
                        if (host_cmd == 2'b01) begin
                            // Kendi ürettiğimiz güvenli Base noktasında doğrulama atlanır
                            malu_op_a <= 256'd1;
                            malu_start <= 1'b1;
                            state <= STAGE_MONT_Z;
                        end else begin
                            // GEÇERSİZ NOKTA SALDIRISI DOĞRULAMA MOTORU BAŞLIYOR
                            malu_op_a <= curve_b_reg;
                            malu_start <= 1'b1;
                            state <= VAL_B;
                        end
                    end
                end
                
                VAL_B: begin
                    malu_start <= 1'b0;
                    if (malu_done) begin
                        b_mont <= malu_result;
                        // Sabit 3 değerini Montgomery uzayına taşı
                        malu_op_a <= 256'd3;
                        malu_start <= 1'b1;
                        state <= VAL_THREE;
                    end
                end
                
                VAL_THREE: begin
                    malu_start <= 1'b0;
                    if (malu_done) begin
                        three_mont <= malu_result;
                        // LHS Hesapla: Y^2 * R^-1 mod P
                        malu_op_a <= sm_base_y;
                        malu_op_b <= sm_base_y;
                        malu_start <= 1'b1;
                        state <= VAL_LHS;
                    end
                end
                
                VAL_LHS: begin
                    malu_start <= 1'b0;
                    if (malu_done) begin
                        lhs_val <= malu_result;
                        // RHS Adım 1: X^2 * R^-1 mod P
                        malu_op_a <= sm_base_x;
                        malu_op_b <= sm_base_x;
                        malu_start <= 1'b1;
                        state <= VAL_X2;
                    end
                end
                
                VAL_X2: begin
                    malu_start <= 1'b0;
                    if (malu_done) begin
                        x2_mont <= malu_result;
                        // RHS Adım 2: (X^2 - 3) mod P
                        malu_op_a <= malu_result;
                        malu_op_b <= three_mont;
                        malu_opcode <= 2'b01; // Çıkarma emri
                        malu_start <= 1'b1;
                        state <= VAL_X2_M3;
                    end
                end
                
                VAL_X2_M3: begin
                    malu_start <= 1'b0;
                    if (malu_done) begin
                        x2_m3_mont <= malu_result;
                        // RHS Adım 3: X * (X^2 - 3) * R^-1 mod P
                        malu_op_a <= sm_base_x;
                        malu_op_b <= malu_result;
                        malu_opcode <= 2'b10; // Çarpma
                        malu_start <= 1'b1;
                        state <= VAL_RHS_MULT;
                    end
                end
                
                VAL_RHS_MULT: begin
                    malu_start <= 1'b0;
                    if (malu_done) begin
                        rhs_mult_mont <= malu_result;
                        // RHS Adım 4: (X^3 - 3X + B) mod P
                        malu_op_a <= malu_result;
                        malu_op_b <= b_mont;
                        malu_opcode <= 2'b00; // Toplama
                        malu_start <= 1'b1;
                        state <= VAL_RHS_ADD;
                    end
                end
                
                VAL_RHS_ADD: begin
                    malu_start <= 1'b0;
                    if (malu_done) begin
                        rhs_val <= malu_result;
                        state <= VAL_COMPARE;
                    end
                end
                
                VAL_COMPARE: begin
                    if (lhs_val == rhs_val) begin
                        // Nokta doğrulamadan geçti, Z koordinatını kurarak devam et
                        malu_op_a <= 256'd1;
                        malu_op_b <= r2_mod_p_reg;
                        malu_opcode <= 2'b10;
                        malu_start <= 1'b1;
                        state <= STAGE_MONT_Z;
                    end else begin
                        // SALDIRI/GÜVENLİK İHLALİ ALARMI: Nokta eğri üzerinde değil!
                        err_invalid_curve <= 1'b1;
                        final_affine_x <= 256'd0; // Sızıntıyı önlemek için çıkış temizlenir
                        status_valid <= 1'b1;
                        state <= DONE_ST;
                    end
                end
                
                STAGE_MONT_Z: begin
                    malu_start <= 1'b0;
                    if (malu_done) begin
                        sm_base_z <= malu_result;
                        sm_start <= 1'b1; // Skaler Çarpımı başlat
                        state <= CALC_SM;
                    end
                end
                
                CALC_SM: begin
                    sm_start <= 1'b0;
                    if (sm_done) begin
                        // Inversion için R sabiti üretilir (1 * R^2 * R^-1 = R)
                        malu_op_a <= 256'd1;
                        malu_op_b <= r2_mod_p_reg;
                        malu_opcode <= 2'b10;
                        malu_start <= 1'b1;
                        state <= GET_R_MOD_P;
                    end
                end
                
                GET_R_MOD_P: begin
                    malu_start <= 1'b0;
                    if (malu_done) begin
                        inv_acc  <= malu_result;
                        inv_base <= sm_out_z;
                        inv_exp  <= p_minus_2_reg;
                        bit_idx  <= 8'd191; // P-192 için en yüksek bit konumu
                        state    <= INV_FIND_TOP;
                    end
                end
                
                INV_FIND_TOP: begin
                    if (inv_exp[bit_idx] == 1'b0 && bit_idx > 0)
                        bit_idx <= bit_idx - 1;
                    else
                        state <= INV_SQUARE;
                end
                
                INV_SQUARE: begin
                    malu_op_a <= inv_acc;
                    malu_op_b <= inv_acc;
                    malu_opcode <= 2'b10;
                    malu_start <= 1'b1;
                    state <= WAIT_INV_SQ;
                end
                
                WAIT_INV_SQ: begin
                    malu_start <= 1'b0;
                    if (malu_done) begin
                        inv_acc <= malu_result;
                        if (inv_exp[bit_idx] == 1'b1) begin
                            malu_op_a <= malu_result;
                            malu_op_b <= inv_base;
                            malu_start <= 1'b1;
                            state <= WAIT_INV_MULT;
                        end else begin
                            if (bit_idx == 0) state <= AFFINE_MULT;
                            else begin bit_idx <= bit_idx - 1; state <= INV_SQUARE; end
                        end
                    end
                end
                
                WAIT_INV_MULT: begin
                    malu_start <= 1'b0;
                    if (malu_done) begin
                        inv_acc <= malu_result;
                        if (bit_idx == 0) state <= AFFINE_MULT;
                        else begin bit_idx <= bit_idx - 1; state <= INV_SQUARE; end
                    end
                end
                
                AFFINE_MULT: begin
                    malu_op_a <= sm_out_x;
                    malu_op_b <= inv_acc;
                    malu_opcode <= 2'b10;
                    malu_start <= 1'b1;
                    state <= WAIT_AFF_MULT;
                end
                
                WAIT_AFF_MULT: begin
                    malu_start <= 1'b0;
                    if (malu_done) begin
                        malu_op_a <= malu_result;
                        malu_op_b <= 256'd1; // Montgomery alanından normal alana geçiş
                        malu_start <= 1'b1;
                        state <= EXIT_MONT;
                    end
                end
                
                EXIT_MONT: begin
                    malu_start <= 1'b0;
                    if (malu_done) begin
                        final_affine_x <= malu_result; // Ortak sır hazır
                        status_valid <= 1'b1;
                        state <= DONE_ST;
                    end
                end
                
                DONE_ST: begin
                    status_valid <= 1'b0;
                    state <= IDLE;
                end
            endcase
        end
    end

endmodule