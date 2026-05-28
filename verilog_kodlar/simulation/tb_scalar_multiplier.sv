`timescale 1ns / 1ps

module tb_scalar_multiplier;

    reg clk;
    reg rst_n;
    
    reg  [255:0] scalar_d;
    reg  [255:0] base_x, base_y, base_z;
    reg          start;
    
    wire [255:0] out_x, out_y, out_z;
    wire         done;

    scalar_multiplier uut (
        .clk(clk), .rst_n(rst_n),
        .scalar_d(scalar_d), 
        .base_x(base_x), .base_y(base_y), .base_z(base_z), 
        .start(start),
        .out_x(out_x), .out_y(out_y), .out_z(out_z), .done(done)
    );

    // 100MHz Clock
    initial begin
        clk = 0;
        forever #5 clk = ~clk;
    end

    integer fd, scan_res, test_no;
    reg [255:0] exp_x, exp_y, exp_z;

    initial begin
        rst_n = 0; start = 0; test_no = 1;
        #100; rst_n = 1; #20;

        fd = $fopen("sm_test_vectors.txt", "r");
        if (fd == 0) begin $display("HATA: sm_test_vectors.txt bulunamadi!"); $finish; end

        $display("\n=================== SCALAR MULTIPLIER (MONTGOMERY LADDER) TESTI ===================");
        $display("DIKKAT: 256-Bit Skaler Carpim donanimda cok buyuk bir islemdir.");
        $display("Her bir test senaryosu gercek hayatta yaklasik 1.3 Milyon saat cevrimi (~13 ms) surer.");
        $display("Lutfen sonuclar ekrana dusene kadar simulasyonu kapatmayin...\n");

        while (!$feof(fd)) begin
            scan_res = $fscanf(fd, "%h %h %h %h %h %h %h\n", 
                               scalar_d, base_x, base_y, base_z, exp_x, exp_y, exp_z);
            
            if (scan_res == 7) begin
                start = 1; #10; start = 0;
                
                fork
                    begin
                        wait(done == 1'b1); // Islem bitmesini bekle
                        $display("---------------------------------------------------------");
                        $display("Test #%0d | Islem: 256-BIT SKALER CARPIM", test_no);
                        
                        // Montgomery formunda birebir eslesme kontrolu
                        if (out_x == exp_x && out_y == exp_y && out_z == exp_z)
                            $display("Durum: [GECTI - PASS] R0 Sonucu Python Altin Model ile Eslesiyor!");
                        else begin
                            $display("Durum: [KALDI - FAIL]");
                            $display("X Hata: Bkl= %64h, Bul= %64h", exp_x, out_x);
                            $stop;
                        end
                    end
                    begin
                        #30000000; // 30 Milisaniye Timeout (3 Milyon cycle)
                        $display("\n[HATA] 30 ms Timeout Asildi. FSM Kilitlendi!");
                        $stop;
                    end
                join_any
                disable fork;
                
                test_no = test_no + 1;
                #100;
            end
        end
        $fclose(fd);
        $display("==================================================================");
        $display("TUM SCALAR MULTIPLIER TESTLERI BASARIYLA TAMAMLANDI!");
        $finish;
    end
endmodule