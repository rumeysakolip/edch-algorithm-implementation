`timescale 1ns / 1ps

module tb_single_test_timeout;

    // --- Parametreler ve Saat ---
    reg clk;
    reg rst_n;
    
    // Genel Zaman Aşımı Limiti (5,000,000 ns = 5 ms)
    localparam TIMEOUT_LIMIT = 25000000; 
    localparam [255:0] P_MODULUS = 256'hFFFFFFFF00000001000000000000000000000000FFFFFFFFFFFFFFFFFFFFFFFF; 

    // --- DUT Sinyalleri ---
    reg  [1:0]   host_cmd;
    reg  [255:0] private_key;
    reg  [255:0] peer_pub_x;
    reg  [255:0] peer_pub_y;
    reg          start;
    
    wire [255:0] result_x, result_y, result_z;
    wire         status_valid;

    // --- Donanımı Çağırma (DUT) ---
    ecdh_controller uut (
        .clk(clk), .rst_n(rst_n), .host_cmd(host_cmd),
        .private_key(private_key), .peer_pub_x(peer_pub_x), .peer_pub_y(peer_pub_y),
        .start(start), .result_x(result_x), .result_y(result_y), .result_z(result_z),
        .status_valid(status_valid)
    );

    // 100MHz Saat Sinyali (10ns periyot)
    initial begin
        clk = 0;
        forever #5 clk = ~clk;
    end

    // ====================================================================
    // 1. İZLEYİCİ: MALU (Modular ALU) State Kilitlenme Kontrolü
    // Montgomery çarpımı en fazla ~260 saat çevrimi sürmelidir.
    // Eğer ALU durumu (state) 5000 ns (500 clock) boyunca değişmezse kilitlenmiştir.
    // ====================================================================
    integer malu_state_timer = 0;
    reg [1:0] prev_malu_state = 2'b00;

    always @(posedge clk) begin
        if (start || uut.sm_inst.pau_inst.malu_inst.state != prev_malu_state) begin
            malu_state_timer = 0; // State değişti, sayacı sıfırla
            prev_malu_state = uut.sm_inst.pau_inst.malu_inst.state;
        end else if (rst_n && uut.sm_inst.pau_inst.malu_inst.state != 2'b00) begin
            // State IDLE (00) değilken zaman akıyorsa
            malu_state_timer = malu_state_timer + 10; // Her clock 10ns
            if (malu_state_timer > 5000) begin
                $display("\n[HATA - MONITOR 1] DEADLOCK TESPIT EDILDI!");
                $display("Nedeni: uut.sm_inst.pau_inst.malu_inst modulu 500 saat cevrimidir ayni state'te (State: %b) bekliyor.", prev_malu_state);
                $display("Tavsiye: MALU icindeki bit_counter'in artis sartlarini veya done sinyalinin uretimini kontrol edin.");
                $stop;
            end
        end
    end

    // ====================================================================
    // 2. İZLEYİCİ: Scalar Multiplier (SM) Bit Sayacı Takılma Kontrolü
    // Skaler çarpımdaki her bir bit işlemi (Add + Double) makul bir sürede bitmelidir.
    // Eğer bit_index (255'ten 0'a sayan sayaç) 100,000 ns boyunca değişmezse takılmıştır.
    // ====================================================================
    integer sm_bit_timer = 0;
    reg [8:0] prev_sm_bit = 9'd0;

    always @(posedge clk) begin
        if (start || uut.sm_inst.bit_index != prev_sm_bit) begin
            sm_bit_timer = 0;
            prev_sm_bit = uut.sm_inst.bit_index;
        end else if (rst_n && !status_valid) begin
            sm_bit_timer = sm_bit_timer + 10;
            if (sm_bit_timer > 100000) begin
                $display("\n[HATA - MONITOR 2] DONGU TAKILMASI TESPIT EDILDI!");
                $display("Nedeni: Scalar Multiplier 'bit_index' degeri %0d noktasinda kilitlendi.", prev_sm_bit);
                $display("Tavsiye: Point Arithmetic Unit (PAU) bitiyor ama SM modulu 'done' sinyalini yakalayamiyor olabilir.");
                $stop;
            end
        end
    end

    // ====================================================================
    // 3. İZLEYİCİ: Reset Durumu Kontrolü
    // İşlem başladığında reset'in hala aktif (0) kalıp kalmadığını denetler.
    // ====================================================================
    always @(posedge start) begin
        if (rst_n == 1'b0) begin
            $display("\n[HATA - MONITOR 3] RESET UYARISI!");
            $display("Nedeni: 'start' sinyali verildiginde 'rst_n' hala aktif (0). Sistem tetiklenemez.");
            $stop;
        end
    end

    // ====================================================================
    // ANA TEST AKIŞI
    // ====================================================================
    reg [255:0] expected_affine_x;
    reg [511:0] check_math_left;
    reg [255:0] check_math_right;

    initial begin
        // Başlangıç Değerleri
        rst_n = 0;
        start = 0;
        host_cmd = 2'b10;
        
        #100;
        rst_n = 1; // Reset kaldırıldı
        #20;

        $display("\n=================== DETAYLI HATA AYIKLAMA TESTI ===================");

        // Örnek Test Vektörü (NIST P-256 / P-192 Test 1)
        private_key       = 256'h125D07592B65DFBB9AF90FA9366EB59E1B9D92A254D47FC1;
        peer_pub_x        = 256'hF1D136DDD74E960A82311FDB3F668D61EABEEFDB7E3ABBBC;
        peer_pub_y        = 256'hAC3B4327EA98C9F70D8679C30A2F10D658968C6CEB968091;
        expected_affine_x = 256'h86A4F8F66C1BCF9BEF67B989985065EE11C5B2C3334E0EE;

        $display("Islem Baslatiliyor...");
        
        // Donanımı Tetikle
        start = 1;
        #10;
        start = 0;

        // Genel Zaman Aşımı (Monitor 1 ve Monitor 2 zaten daha önce yakalayacaktır)
        fork
            begin
                wait(status_valid == 1'b1);
                $display("\n[BASARILI] Donanim islem suresi icinde yanit verdi!");
                
                check_math_left  = (expected_affine_x * result_z) % P_MODULUS;
                check_math_right = result_x % P_MODULUS;

                $display("NIST Beklenen Affine X : %64h", expected_affine_x);
                $display("Donanim Projektif X    : %64h", result_x);
                $display("Donanim Projektif Z    : %64h", result_z);
                
                if (check_math_left[255:0] == check_math_right)
                    $display("\nSonuc: [GECTI - PASS] Matematiksel dogrulama sorunsuz!");
                else
                    $display("\nSonuc: [KALDI - FAIL] Cevap geldi ama hesaplama yanlis.");
            end
            
            begin
                #TIMEOUT_LIMIT;
                $display("\n[HATA - MONITOR 4] GENEL ZAMAN ASIMI!");
                $display("Nedeni: FSM'ler calisiyor gibi gorunuyor ancak %0d ns icinde sonuc uretilemedi.", TIMEOUT_LIMIT);
            end
        join_any
        
        disable fork;
        $display("================================================================\n");
        $finish;
    end

endmodule