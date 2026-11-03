`timescale 1ns/1ps
// Minimal diagnostic: is cell_r3 really X when the first frame is captured?
module tb_diag;
    reg clk = 0; always #5 clk = ~clk;
    reg rst_n = 0;
    reg mon_on = 0;
    reg [1:0] rot = 0;
    wire hs, vs, de, ft, fbr;
    wire [15:0] rgb, tfa; wire [23:0] rgbf;
    rpg_video #(.VIDEO_MODE(1)) dut (
        .clk(clk), .rst_n(rst_n), .we(1'b0), .waddr(11'd0), .wdata(17'd0),
        .anim_on(1'b0), .anim_frame(3'd0),
        .mon_on(mon_on), .mon_id(5'd1), .mon_fade(4'd8),
        .hit_trig(1'b0), .hit_kind(2'd0),
        .mon_rotation(rot), .mon_mirror(1'b0), .bars(64'd0),
        .gal_on(1'b0), .gal_img(2'd1), .gal_fade(4'd8),
        .tf_valid(1'b1), .tf_err(2'd0), .diag(8'hE4), .diag2(8'h00), .dfill(1'b0),
        .tf_rdata(4'd0), .tf_raddr(tfa),
        .media_mode(2'd0), .media_auto(1'b1), .media_settings(1'b0),
        .media_loading(1'b0), .media_osd(1'b0),
        .media_index(6'd3), .media_count(6'd10), .media_name("PIC00004"),
        .media_brightness(4'd4), .media_contrast(2'd1), .media_view(2'd0),
        .media_visual(1'b0), .media_alert(1'b0),
        .frame_tick(ft), .hs(hs), .vs(vs), .de(de), .rgb(rgb),
        .fb_front_valid(1'b0), .fb_pixel_valid(1'b0), .fb_pixel_rgb(24'd0),
        .fb_pixel_req(fbr), .rgb_full(rgbf),
        .spectrum_border_en(1'b0), .spectrum_levels(64'd0)
    );
    integer c, nz, phase;
    initial begin
        repeat (10) @(posedge clk); rst_n = 1;
        repeat (2000) @(posedge clk);
        for (c = 0; c < 1200; c = c + 1) dut.cell_mem[c] = 17'd0;
        $display("after clear: cell_mem[0]=%h cell_r3=%h", dut.cell_mem[0], dut.cell_r3);

        mon_on = 1; rot = 0;
        repeat (4) @(posedge ft);
        $display("t1 rot=0: cell_r3=%h mon_valid=%0b mon_rgb=%04h", dut.cell_r3, dut.mon_valid, dut.mon_rgb);
        repeat (4) @(posedge ft);
        $display("t2 rot=0: cell_r3=%h mon_valid=%0b mon_rgb=%04h", dut.cell_r3, dut.mon_valid, dut.mon_rgb);

        // 统计一整帧窗口内最终输出
        nz = 0;
        while (!de) @(posedge clk);
        for (c = 0; c < 640*480; c = c + 1) begin
            @(posedge clk);
            if (de) begin
                if (dut.xd5>=240 && dut.xd5<384 && dut.yd5>=48 && dut.yd5<192)
                    if (rgb != 16'd0) nz = nz + 1;
            end
        end
        $display("rot=0 frame: window non-black = %0d", nz);

        rot = 1;
        repeat (4) @(posedge ft);
        nz = 0;
        while (!de) @(posedge clk);
        for (c = 0; c < 640*480; c = c + 1) begin
            @(posedge clk);
            if (de) begin
                if (dut.xd5>=240 && dut.xd5<384 && dut.yd5>=48 && dut.yd5<192)
                    if (rgb != 16'd0) nz = nz + 1;
            end
        end
        $display("rot=1 frame: window non-black = %0d", nz);
        $finish;
    end
endmodule
