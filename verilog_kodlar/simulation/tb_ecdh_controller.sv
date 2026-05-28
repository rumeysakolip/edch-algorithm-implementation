`timescale 1ns / 1ps

module tb_ecdh_controller;

    reg clk;
    reg rst_n;
    
    reg  [1:0]   host_cmd;
    reg  [255:0] private_key;
    reg  [255:0] peer_pub_x;
    reg  [255:0] peer_pub_y;
    reg          start;
    
    // NIST P-192 Sabit Test Değerleri (Giriş Portlarını Sürmek İçin)
    localparam [255:0] TB_P_MODULUS = 256'h0000000000000000FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEFFFFFFFFFFFFFFFF;
    localparam [255:0] TB_R2_MOD_P  = 256'h0000000000000000000000000000000200000000000000030000000000000002;
    localparam [255:0] TB_CURVE_B   = 256'h000000000000000064210519E59C80E70FA7E9AB72243049FEB8DEECC146B9B1;
    localparam [255:0] TB_CURVE_G_X = 256'h0000000000000000188DA80EB03090F67CBF20EB43A18800F4FF0AFD82FF1012;
    localparam [255:0] TB_CURVE_G_Y = 256'h000000000000000007192B95FFC8DA78631011ED6B24CDD573F977A11E794811;

    wire [255:0] final_affine_x;
    wire         status_valid;
    wire         err_invalid_curve;

    ecdh_controller uut (
        .clk(clk), .rst_n(rst_n),
        .host_cmd(host_cmd), .private_key(private_key),
        .peer_pub_x(peer_pub_x), .peer_pub_y(peer_pub_y),
        .i_p_modulus(TB_P_MODULUS), .i_r2_mod_p(TB_R2_MOD_P),
        .i_curve_b(TB_CURVE_B), .i_curve_g_x(TB_CURVE_G_X), .i_curve_g_y(TB_CURVE_G_Y),
        .start(start), .final_affine_x(final_affine_x),
        .status_valid(status_valid), .err_invalid_curve(err_invalid_curve)
    );

    initial begin
        clk = 0;
        forever #5 clk = ~clk;
    end

    integer fd, scan_result, tc_id;
    reg [255:0] exp_d, exp_qx, exp_qy, expected_z;
    integer pass_count, fail_count;

    initial begin
        rst_n = 0; start = 0; host_cmd = 2'b10;
        private_key = 0; peer_pub_x = 0; peer_pub_y = 0;
        pass_count = 0; fail_count = 0;

        #100; rst_n = 1; #20;

        fd = $fopen("nist_test_vectors.txt", "r");
        if (fd == 0) begin
            $display("HATA: nist_test_vectors.txt bulunamadi!");
            $finish;
        end

        $display("\n==================================================================");
        $display("===== ECDH GÜVENLİK VE NIST P-192 ENTEGRASYON TESTİ BAŞLIYOR =====");
        $display("==================================================================");

        while (!$feof(fd)) begin
            scan_result = $fscanf(fd, "%d %h %h %h %h\n", tc_id, exp_d, exp_qx, exp_qy, expected_z);
            
            if (scan_result == 5) begin
                private_key = exp_d; peer_pub_x = exp_qx; peer_pub_y = exp_qy;
                start = 1; #10; start = 0;

                fork
                    begin
                        wait(status_valid == 1'b1);
                        $display("----------------------------------------------------------------");
                        $display("[TEST CASE %0d] - Analiz Edildi.", tc_id);
                        
                        if (err_invalid_curve) begin
                            $display("Sonuç        : [HATA] Güvenli Nokta Algılama Radarı Tetiklendi!");
                            fail_count = fail_count + 1;
                            $stop;
                        end else if (final_affine_x == expected_z) begin
                            $display("Sonuç        : [GEÇTİ - PASS] NIST Vektörüyle Kusursuz Eşleşme.");
                            pass_count = pass_count + 1;
                        end else begin
                            $display("Sonuç        : [KALDI - FAIL] Matematik Hatası!");
                            fail_count = fail_count + 1;
                            $stop;
                        end
                    end
                    begin
                        #50000000;
                        $display("\n[HATA] Simülasyon Zaman Aşımına Uğradı!");
                        $stop;
                    end
                join_any
                disable fork;
                #100;
            end
        end
        $fclose(fd);

        // ==================================================================
        // AKTİF NEGATİF SALDIRI TEST SENARYOSU
        // ==================================================================
        $display("\n==================================================================");
        $display("===== AKTİF SALDIRI TESTİ: Rastgele Geçersiz Nokta Enjekte Ediliyor =====");
        $display("==================================================================");
        
        private_key = 256'hA1B2C3D4E5F6;
        peer_pub_x  = 256'hFFFFFFFFFFFFFFFF; // Rastgele uydurulmuş geçersiz X
        peer_pub_y  = 256'hEEEEEEEEEEEEEEEE; // Rastgele uydurulmuş geçersiz Y
        start = 1; #10; start = 0;

        fork
            begin
                wait(status_valid == 1'b1);
                $display("Saldırı Noktası Çıkış Durumu:");
                $display("Donanım Çıktısı (final_affine_x): %64h", final_affine_x);
                $display("Hata Radarı (err_invalid_curve) : %b", err_invalid_curve);
                
                if (err_invalid_curve == 1'b1 && final_affine_x == 256'd0) begin
                    $display("\n>>>>> [BAŞARILI] GEÇERSİZ NOKTA SALDIRISI DONANIM TARAFINDAN ENGELLEDİ! <<<<<");
                end else begin
                    $display("\n>>>>> [GÜVENLİK AÇIĞI] Donanım geçersiz noktayı algılayamadı! <<<<<");
                    $stop;
                end
            end
            begin
                #50000000;
                $display("[HATA] Saldırı testinde Zaman Aşımı!");
                $stop;
            end
        join_any
        disable fork;

        $display("\nTüm test süreçleri ve negatif siber atak senaryoları başarıyla tamamlandı.");
        $finish;
    end
endmodule