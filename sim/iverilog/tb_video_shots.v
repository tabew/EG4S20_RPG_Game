`timescale 1ns/1ps
// One production rpg_video frame per display function.
// Thumbnail pixels come back from tf_raddr so zoom/brightness/fade are visible.
module tb_video_shots;
    localparam integer W = 640;
    localparam integer H = 480;
    reg clk = 0;
    always #5 clk = ~clk;
    reg rst_n = 0;
    reg gal_on = 0;
    reg [3:0] gal_fade = 4'd8;
    reg [1:0] media_mode = 0;
    reg media_auto = 1;
    reg media_settings = 0;
    reg media_osd = 1;
    reg media_visual = 0;
    reg media_alert = 0;
    reg [3:0] media_brightness = 4;
    reg [1:0] media_contrast = 1;
    reg [1:0] media_view = 0;
    reg fb_front_valid = 0;
    reg spectrum_en = 0;
    reg [63:0] spectrum_levels = 0;
    reg [63:0] bars = 0;
    reg mon_on = 0;
    reg [1:0] mon_rotation = 0;
    reg mon_mirror = 0;
    reg [4:0] mon_id = 5'd1;
    wire hs, vs, de, frame_tick, fb_req;
    wire [15:0] rgb, tf_raddr;
    wire [23:0] rgb_full;
    reg [3:0] tf_rdata = 0;
    reg fb_pixel_valid = 0;
    reg [23:0] fb_pixel_rgb = 0;
    integer ncap = 0;

    // Clear the character RAM before any capture. tb_video_shots drives no
    // writes, so cell_mem would stay X and cell_blank would be X as well,
    // which makes the monster-layer mux pick nothing. Real hardware gets a
    // full redraw from rpg_core; here the bench supplies the empty cells.
    // The cell data passes three pipeline stages before it reaches
    // cell_blank, so a few extra clocks are needed after the last store.
    task clear_cells;
        integer c;
        begin
            // Hierarchical writes are applied through the memory array
            // directly; force/release makes the intent explicit and survives
            // the procedural assignment ordering in the DUT.
            for (c = 0; c < 1200; c = c + 1)
                dut.cell_mem[c] = 17'd0;
            // The cell data passes three pipeline stages before it reaches
            // cell_blank, so a few extra clocks are needed before capture.
            repeat (16) @(posedge clk);
        end
    endtask

    rpg_video #(.VIDEO_MODE(1)) dut (
        .clk(clk), .rst_n(rst_n), .we(1'b0), .waddr(11'd0), .wdata(17'd0),
        .anim_on(1'b0), .anim_frame(3'd0),
        .mon_on(mon_on), .mon_id(mon_id), .mon_fade(4'd8),
        .hit_trig(1'b0), .hit_kind(2'd0),
        .mon_rotation(mon_rotation), .mon_mirror(mon_mirror),
        .bars(bars),
        .gal_on(gal_on), .gal_img(2'd1), .gal_fade(gal_fade),
        .tf_valid(1'b1), .tf_err(2'd0), .diag(8'hE4), .diag2(8'h00), .dfill(1'b0),
        .tf_rdata(tf_rdata), .tf_raddr(tf_raddr),
        .media_mode(media_mode), .media_auto(media_auto), .media_settings(media_settings),
        .media_loading(1'b0), .media_osd(media_osd),
        .media_index(6'd3), .media_count(6'd10), .media_name("PIC00004"),
        .media_brightness(media_brightness), .media_contrast(media_contrast),
        .media_view(media_view), .media_visual(media_visual), .media_alert(media_alert),
        .frame_tick(frame_tick),
        .hs(hs), .vs(vs), .de(de), .rgb(rgb),
        .fb_front_valid(fb_front_valid), .fb_pixel_valid(fb_pixel_valid),
        .fb_pixel_rgb(fb_pixel_rgb), .fb_pixel_req(fb_req), .rgb_full(rgb_full),
        .spectrum_border_en(spectrum_en), .spectrum_levels(spectrum_levels)
    );

    always @(posedge clk) begin
        tf_rdata <= {tf_raddr[9:8], tf_raddr[4:3]} + tf_raddr[12:11];
        fb_pixel_valid <= fb_req;
        fb_pixel_rgb <= {tf_raddr[7:0], tf_raddr[11:4], tf_raddr[3:0], 4'h8};
    end

    task automatic capture;
        integer fd, got, guard;
        reg [7:0] r, g, b;
        begin
            guard = 0;
            while (de && guard < 2000000) begin @(posedge clk); guard = guard + 1; end
            got = 0; guard = 0;
            fd = $fopen("preview/sim_features/video_raw.bin", "ab");
            if (fd == 0) $fatal(1, "raw open");
            while (got < W*H && guard < 2000000) begin
                @(posedge clk);
                guard = guard + 1;
                if (de) begin
                    r = {rgb[15:11], rgb[15:13]};
                    g = {rgb[10:5], rgb[10:9]};
                    b = {rgb[4:0], rgb[4:2]};
                    $fwrite(fd, "%c%c%c", r, g, b);
                    got = got + 1;
                end
            end
            $fclose(fd);
            if (got != W*H) $fatal(1, "frame %0d pixels %0d", ncap, got);
            $display("VIDEO %0d", ncap);
            ncap = ncap + 1;
        end
    endtask

    initial begin
        rst_n = 0;
        repeat (8) @(posedge clk);
        rst_n = 1;
        // Let the pipeline fill before the first capture.
        repeat (2000) @(posedge clk);
        clear_cells();

        // 0 rainbow spectrum + monster
        gal_on = 0; mon_on = 1; mon_rotation = 0; mon_mirror = 0; mon_id = 5'd1;
        spectrum_en = 1; spectrum_levels = 64'h785a483c3024180c;
        media_visual = 0; bars = 0; media_alert = 0;
        repeat (4) @(posedge frame_tick);
        // The monster palette reloads whenever mon_id or fade changes, and
        // the very first reload happens after reset. Give it a couple of
        // whole frames before the first capture, otherwise the first two
        // frames come out black.
        repeat (4) @(posedge frame_tick);
        capture();

        // 1 silence keeps a dim frame
        spectrum_levels = 64'd0;
        repeat (2) @(posedge frame_tick);
        capture();

        // 2 monster rotated, 3 mirrored
        mon_rotation = 2'd1; spectrum_levels = 64'h4040404040404040;
        repeat (2) @(posedge frame_tick);
        capture();
        mon_mirror = 1; mon_rotation = 0;
        repeat (2) @(posedge frame_tick);
        capture();

        // 4 pitch bars over the playfield
        spectrum_en = 0; mon_on = 0; media_visual = 1;
        bars = 64'h7860402818080402;
        repeat (2) @(posedge frame_tick);
        capture();

        // 5 gallery, normal view, subtitles, fade full
        media_visual = 0; bars = 0; gal_on = 1; gal_fade = 4'd8;
        media_osd = 1; media_settings = 0; media_view = 0;
        media_brightness = 4; media_contrast = 1; media_mode = 1; media_auto = 1;
        fb_front_valid = 0; media_alert = 0;
        repeat (2) @(posedge frame_tick);
        capture();

        // 6 dark, 7 high contrast, 8 zoom, 9 half fade
        media_brightness = 0;
        repeat (2) @(posedge frame_tick);
        capture();
        media_brightness = 4; media_contrast = 2;
        repeat (2) @(posedge frame_tick);
        capture();
        media_contrast = 1; media_view = 2;
        repeat (2) @(posedge frame_tick);
        capture();
        media_view = 0; gal_fade = 3;
        repeat (2) @(posedge frame_tick);
        capture();

        // 10 settings page, 11 red emergency bar
        gal_fade = 8; media_settings = 1; media_brightness = 8; media_view = 1;
        repeat (2) @(posedge frame_tick);
        capture();
        media_settings = 0; media_alert = 1; media_view = 0; media_brightness = 4;
        repeat (2) @(posedge frame_tick);
        capture();

        $display("PASS video_shots %0d", ncap);
        $finish;
    end
    initial begin #2_000_000_000; $fatal(1, "video watchdog"); end
endmodule
