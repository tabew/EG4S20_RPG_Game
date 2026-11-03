`timescale 1ns/1ps

module tb_alert_bar;
    reg clk = 0;
    always #5 clk = ~clk;
    reg rst_n = 0;
    reg gal_on = 0;
    reg media_alert = 0;
    reg [11:0] x = 0;
    reg [11:0] y = 0;
    wire [15:0] gal_rgb;
    wire [23:0] gal_rgb_full;
    wire alert_opaque;
    integer errors;

    gal_layer #(.PIPELINE(1), .VIDEO_MODE(1)) dut (
        .clk(clk), .rst_n(rst_n), .gal_on(gal_on),
        .gal_img(2'd0), .gal_fade(4'd8),
        .x2(x), .y2(y), .x3(x), .y3(y),
        .tf_valid(1'b0), .tf_err(2'd0), .diag(8'd0), .diag2(8'd0),
        .dfill(1'b0), .tf_rdata(4'd0), .tf_raddr(),
        .gal_rgb(gal_rgb), .alert_opaque(alert_opaque),
        .media_mode(2'd0), .media_auto(1'b1), .media_settings(1'b0),
        .media_loading(1'b0), .media_osd(1'b1),
        .media_index(6'd0), .media_count(6'd1), .media_name(64'd0),
        .media_brightness(4'd4), .media_contrast(2'd1), .media_view(2'd0),
        .media_visual(1'b0), .media_alert(media_alert),
        .fb_front_valid(1'b0), .fb_pixel_valid(1'b0), .fb_pixel_rgb(24'd0),
        .fb_pixel_req(), .gal_rgb_full(gal_rgb_full)
    );

    initial begin
        errors = 0;
        rst_n = 0;
        repeat (4) @(posedge clk);
        rst_n = 1;
        @(posedge clk);

        x = 12'd52; y = 12'd200; media_alert = 1'b1;
        repeat (3) @(posedge clk); #1;
        if (alert_opaque !== 1'b1 || gal_rgb !== 16'hffff || gal_rgb_full !== 24'hffffff) begin
            $display("FAIL letter opaque=%b rgb=%h full=%h", alert_opaque, gal_rgb, gal_rgb_full);
            errors = errors + 1;
        end

        x = 12'd10; y = 12'd210; media_alert = 1'b1;
        repeat (3) @(posedge clk); #1;
        if (alert_opaque !== 1'b1 || gal_rgb !== 16'hf800 || gal_rgb_full !== 24'hff0000) begin
            $display("FAIL margin opaque=%b rgb=%h full=%h", alert_opaque, gal_rgb, gal_rgb_full);
            errors = errors + 1;
        end

        x = 12'd52; y = 12'd100; media_alert = 1'b1;
        repeat (3) @(posedge clk); #1;
        if (alert_opaque !== 1'b0 || gal_rgb !== 16'h0000 || gal_rgb_full !== 24'h000000) begin
            $display("FAIL outside opaque=%b rgb=%h full=%h", alert_opaque, gal_rgb, gal_rgb_full);
            errors = errors + 1;
        end

        x = 12'd52; y = 12'd200; media_alert = 1'b0;
        repeat (3) @(posedge clk); #1;
        if (alert_opaque !== 1'b0 || gal_rgb !== 16'h0000) begin
            $display("FAIL idle opaque=%b rgb=%h", alert_opaque, gal_rgb);
            errors = errors + 1;
        end

        if (errors == 0) $display("PASS");
        else $display("FAIL %0d", errors);
        $finish;
    end
endmodule
