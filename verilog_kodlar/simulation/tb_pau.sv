`timescale 1ns / 1ps

module tb_pau;
    reg clk;
    reg rst_n;
    
    reg          cmd;
    reg  [255:0] p1_x, p1_y, p1_z;
    reg  [255:0] p2_x, p2_y, p2_z;
    reg          start;
    
    wire [255:0] pout_x, pout_y, pout_z;
    wire         done;

    point_arithmetic_unit uut (
        .clk(clk), .rst_n(rst_n), .cmd(cmd),
        .p1_x(p1_x), .p1_y(p1_y), .p1_z(p1_z),
        .p2_x(p2_x), .p2_y(p2_y), .p2_z(p2_z), 
        .start(start), .pout_x(pout_x), .pout_y(pout_y), .pout_z(pout_z), .done(done)
    );

    initial begin
        clk = 0;
        forever #5 clk = ~clk;
    end

    integer fd, scan_res, test_no;
    reg [255:0] exp_x, exp_y, exp_z;

    initial begin
        rst_n = 0; start = 0; test_no = 1;
        #100; rst_n = 1; #20;

        fd = $fopen("pau_test_vectors.txt", "r");
        if (fd == 0) begin $display("HATA: pau_test_vectors.txt bulunamadi!"); $finish; end

        $display("\n=================== PAU (ADD & DOUBLE & BYPASS) TESTI BASLIYOR ===================");

        while (!$feof(fd)) begin
            // FORMAT GUNCELLEMESI: 10 Sutun okur
            scan_res = $fscanf(fd, "%d %h %h %h %h %h %h %h %h %h\n", 
                               cmd, p1_x, p1_y, p1_z, p2_x, p2_y, p2_z, exp_x, exp_y, exp_z);
            
            if (scan_res == 10) begin
                start = 1; #10; start = 0;
                
                wait(done == 1'b1);
                
                $display("---------------------------------------------------------");
                $display("Test #%0d | Islem: %s %s", test_no, 
                         (cmd==0) ? "POINT DOUBLE" : "POINT ADD",
                         (p1_z==0 || p2_z==0) ? "(INFINITY BYPASS DEVREDE)" : "");
                
                if (pout_x == exp_x && pout_y == exp_y && pout_z == exp_z)
                    $display("Durum: [GECTI - PASS] Modul Kusursuz!");
                else begin
                    $display("Durum: [KALDI - FAIL]");
                    $display("X Hata: Bkl= %64h, Bul= %64h", exp_x, pout_x);
                    $stop;
                end
                
                test_no = test_no + 1;
                #50;
            end
        end
        $fclose(fd);
        $display("==================================================================");
        $finish;
    end
endmodule