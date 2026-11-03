`timescale 1ns/1ps
// Capture the battle hit effect driven by rtl/video/hit_fx.v.
//
// The bench wires rpg_video directly, clears the character RAM so the text
// layer does not mask the sprite, and fires hit_trig once per frame boundary.
// One capture() call spans exactly one video frame, so back-to-back captures
// give a frame-by-frame film of the sparks.
module tb_hitfx_shots;
    reg clk = 0;
    always #10 clk = ~clk;
    reg rst_n = 0;
    reg hit_trig = 0;
    reg [1:0] hit_kind = 0;

    wire hs, vs, de, frame_tick, fb_req;
    wire [15:0] rgb, tf_raddr;
    wire [23:0] rgb_full;

    rpg_video #(.VIDEO_MODE(1)) dut (
        .clk(clk), .rst_n(rst_n), .we(1'b0), .waddr(11'd0), .wdata(17'd0),
        .anim_on(1'b0), .anim_frame(3'd0),
        .mon_on(1'b1), .mon_id(5'd1), .mon_fade(4'd8),
        .mon_rotation(2'd0), .mon_mirror(1'b0),
        .hit_trig(hit_trig), .hit_kind(hit_kind),
        .bars(64'd0), .gal_on(1'b0), .gal_img(2'd1), .gal_fade(4'd8),
        .tf_valid(1'b1), .tf_err(2'd0), .diag(8'hE4), .diag2(8'h00), .dfill(1'b0),
        .tf_rdata(4'd0), .tf_raddr(tf_raddr),
        .media_mode(2'd0), .media_auto(1'b1), .media_settings(1'b0),
        .media_loading(1'b0), .media_osd(1'b0),
        .media_index(6'd3), .media_count(6'd10), .media_name("PIC00004"),
        .media_brightness(4'd4), .media_contrast(2'd1), .media_view(2'd0),
        .media_visual(1'b0), .media_alert(1'b0),
        .frame_tick(frame_tick), .hs(hs), .vs(vs), .de(de), .rgb(rgb),
        .fb_front_valid(1'b0), .fb_pixel_valid(1'b0), .fb_pixel_rgb(24'd0),
        .fb_pixel_req(fb_req), .rgb_full(rgb_full),
        .spectrum_border_en(1'b0), .spectrum_levels(64'd0)
    );

    localparam W = 640;
    localparam H = 480;

    integer fd, ncap = 0;

    // The text layer would cover the sprite, and cell_mem powers up as X in
    // simulation, so preload every cell with an empty glyph.
    task clear_cells;
        integer c;
        begin
            for (c = 0; c < 1200; c = c + 1) dut.cell_mem[c] = 17'd0;
        end
    endtask

    task capture;
        integer got, guard, r, g, b;
        begin
            got = 0;
            guard = 0;
            while (got < W * H && guard < 2000000) begin
                @(posedge clk);
                guard = guard + 1;
                if (de) begin
                    // %c only survives values below 128 here, so dump hex text
                    // and let the renderer parse it back into RGB triples.
                    $fwrite(fd, "%02x%02x%02x\n", rgb_full[23:16], rgb_full[15:8], rgb_full[7:0]);
                    got = got + 1;
                end
            end
            if (got != W * H) $fatal(1, "frame %0d pixels %0d", ncap, got);
            $fflush(fd);
            $display("HITFX %0d", ncap);
            ncap = ncap + 1;
        end
    endtask

    task fire(input [1:0] k);
        begin
            @(posedge frame_tick);
            @(negedge clk);
            hit_trig = 1;
            hit_kind = k;
            @(negedge clk);
            hit_trig = 0;
        end
    endtask

    initial begin
        fd = $fopen("preview/sim_features/hitfx_raw.bin", "w");
        if (fd == 0) $fatal(1, "cannot open hitfx_raw.bin");
        rst_n = 0;
        repeat (8) @(posedge clk);
        rst_n = 1;
        repeat (2000) @(posedge clk);
        clear_cells();
        repeat (8) @(posedge frame_tick);

        // 0: idle, sprite only
        capture();

        // 1-4: normal attack, sparks spread then die out
        fire(2'd1);
        capture();
        capture();
        capture();
        capture();

        // 5-8: skill, cyan/magenta sparks fan out diagonally
        fire(2'd2);
        capture();
        capture();
        capture();
        capture();

        // 9-12: monster counterattack, red sparks fly low-left
        fire(2'd3);
        capture();
        capture();
        capture();
        capture();

        $display("PASS hitfx_shots %0d", ncap);
        $fclose(fd);
        $finish;
    end

    initial begin
        #200_000_000;
        $fatal(1, "hitfx shot watchdog");
    end
endmodule
