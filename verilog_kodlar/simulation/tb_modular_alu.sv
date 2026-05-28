`timescale 1ns / 1ps

module tb_modular_alu;

    reg clk;
    reg rst_n;
    
    // DUT Sinyalleri
    reg  [1:0]   opcode;
    reg  [255:0] operand_a;
    reg  [255:0] operand_b;
    reg  [255:0] modulus_p;
    reg          start;
    wire [255:0] result;
    wire         done;

    // Modülü Çağır
    modular_alu uut (
        .clk(clk),
        .rst_n(rst_n),
        .opcode(opcode),
        .operand_a(operand_a),
        .operand_b(operand_b),
        .modulus_p(modulus_p),
        .start(start),
        .result(result),
        .done(done)
    );

    // 100MHz Clock
    initial begin
        clk = 0;
        forever #5 clk = ~clk;
    end

    integer fd, scan_res, test_no;
    reg [255:0] exp_res;
    
    // NIST P-256 Asalı
    localparam [255:0] P = 256'hFFFFFFFF00000001000000000000000000000000FFFFFFFFFFFFFFFFFFFFFFFF;

    initial begin
        rst_n = 0;
        start = 0;
        modulus_p = P;
        test_no = 1;
        
        #100;
        rst_n = 1;
        #20;

        // Dosyayı oku
        fd = $fopen("malu_test_vectors.txt", "r");
        if (fd == 0) begin
            $display("HATA: malu_test_vectors.txt bulunamadi!");
            $finish;
        end

        $display("\n=================== MODULAR ALU TESTI BASLIYOR ===================");

        while (!$feof(fd)) begin
            // Format: opcode(int) A(hex) B(hex) Exp(hex)
            scan_res = $fscanf(fd, "%d %h %h %h\n", opcode, operand_a, operand_b, exp_res);
            
            if (scan_res == 4) begin
                // Modülü Tetikle
                start = 1;
                #10;
                start = 0;
                
                // Done sinyalini bekle
                wait(done == 1'b1);
                
                $display("---------------------------------------------------------");
                $display("Test #%0d | Opcode: %0d (%s)", test_no, opcode, 
                         (opcode==0) ? "ADD" : (opcode==1) ? "SUB" : "MULT");
                $display("A   : %64h", operand_a);
                $display("B   : %64h", operand_b);
                $display("Exp : %64h", exp_res);
                $display("Out : %64h", result);
                
                if (result == exp_res)
                    $display("Durum: [GECTI - PASS]");
                else begin
                    $display("Durum: [KALDI - FAIL]");
                    $stop; // Hata bulursa simülasyonu durdur
                end
                
                test_no = test_no + 1;
                #30; // Sonraki teste geçmek için biraz bekle
            end
        end

        $fclose(fd);
        $display("==================================================================");
        $display("TUM MALU TESTLERI BASARIYLA TAMAMLANDI! ALGORITMA 100%% DOGRU.");
        $finish;
    end
endmodule