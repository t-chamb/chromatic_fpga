// QSPI_Slave.v

module QSPI_Slave(
    input               QSPI_CLK,
    input               QSPI_CS,
    input               QSPI_MOSI,
    input               QSPI_MISO,
    input               QSPI_WP,
    input               QSPI_HD,
    input               AUD_MCLK,
    input               AUD_WCLK,    // Word select clock from aud_system_top (for codec)

    input      [15:0]   LEFT,        // Left channel audio from Game Boy emulator
    input      [15:0]   RIGHT,       // Right channel audio from Game Boy emulator

    output              qMenuInit,
    output              qDataValid,
    output      [15:0]  qData,
    output  reg [31:0]  qAddress = 'd0,
    output  reg [9:0]   qLength = 'd0,
    output  reg         qCommand = 'd0,

    output              audio_sample_clk,  // 44.1kHz sample clock (derived from ESP32 WS)
    input               i2s_bclk,          // I2S bit clock FROM ESP32 (ESP32 is I2S master)
    input               i2s_ws,            // I2S word select FROM ESP32 (also used for sample timing)
    output              i2s_data           // I2S serial data TO ESP32
);

    // FIFO
    localparam CMD_AUDIO = 10'h015;
    localparam AF_BITS   = 11;                 // 2^11 = 2048 samples = 8KB = ~46ms @ 44.1kHz
                                               // Balanced buffer size - fits in FPGA resources

    reg [31:0] aud_ram [0:(1<<AF_BITS)-1];
    reg  [AF_BITS-1:0] aud_wr = 0;
    reg  [AF_BITS-1:0] aud_rd = 0;

    wire fifo_empty = (aud_wr == aud_rd);
    wire fifo_full  = (aud_wr + 2'd2 == aud_rd);
    
    // Calculate FIFO fill level
    wire [AF_BITS:0] fifo_level = (aud_wr >= aud_rd) ? 
                                   (aud_wr - aud_rd) : 
                                   ((1<<AF_BITS) - aud_rd + aud_wr);
    
    // Only allow audio reads when FIFO has at least 256 samples (1024 bytes)
    // This is ~5.8ms of buffering - enough for 4x 256-byte reads
    // Lower threshold allows reads to start sooner, reducing startup delay
    wire fifo_ready = (fifo_level >= 256);

    // Synchronize audio data from hClk domain to AUD_MCLK domain
    // Double-register to prevent metastability
    reg [15:0] left_sync1, left_sync2;
    reg [15:0] right_sync1, right_sync2;
    
    always @(posedge AUD_MCLK) begin
        left_sync1  <= LEFT;
        left_sync2  <= left_sync1;
        right_sync1 <= RIGHT;
        right_sync2 <= right_sync1;
    end

    // Derive sample clock from ESP32's WS (word select) signal
    // ESP32 is I2S master and generates WS at exactly 44.1 kHz
    // We detect WS transitions to trigger audio capture at exactly the right time
    // This eliminates sample rate drift between FPGA and ESP32

    // Synchronize WS to AUD_MCLK domain for sample capture
    reg i2s_ws_mclk_sync1 = 1'b0;
    reg i2s_ws_mclk_sync2 = 1'b0;
    reg i2s_ws_mclk_prev = 1'b0;

    always @(posedge AUD_MCLK) begin
        i2s_ws_mclk_sync1 <= i2s_ws;
        i2s_ws_mclk_sync2 <= i2s_ws_mclk_sync1;
        i2s_ws_mclk_prev <= i2s_ws_mclk_sync2;
    end

    // Generate sample tick on WS LOW-to-HIGH transition only
    // This happens once per stereo frame at 44.1 kHz (start of left channel)
    // We capture both L and R channels together at this point
    wire sample_tick = i2s_ws_mclk_sync2 & ~i2s_ws_mclk_prev;

    // Output sample clock (derived from ESP32's WS)
    assign audio_sample_clk = i2s_ws_mclk_sync2;
    
    // ============================================================================
    // I2S Output (Philips Standard, 44.1kHz, 16-bit stereo in 32-bit frames)
    // ESP32 is I2S master - generates BCLK and WS, FPGA serializes audio data
    // ============================================================================

    // Capture audio samples at 44.1kHz and hold them for I2S serialization
    reg [15:0] left_captured = 16'd0;
    reg [15:0] right_captured = 16'd0;

    always @(posedge AUD_MCLK) begin
        if (sample_tick) begin
            // Capture audio at sample rate
            left_captured <= left_sync2;
            right_captured <= right_sync2;
        end
    end

    // Clock domain crossing: AUD_MCLK → i2s_bclk
    // Use double-register synchronization to safely cross clock domains
    reg [15:0] left_i2s_sync1 = 16'd0;
    reg [15:0] left_i2s_sync2 = 16'd0;
    reg [15:0] right_i2s_sync1 = 16'd0;
    reg [15:0] right_i2s_sync2 = 16'd0;

    always @(posedge i2s_bclk) begin
        // First register stage (metastability protection)
        left_i2s_sync1 <= left_captured;
        right_i2s_sync1 <= right_captured;
        // Second register stage (stable data)
        left_i2s_sync2 <= left_i2s_sync1;
        right_i2s_sync2 <= right_i2s_sync1;
    end

    // I2S serializer - runs on ESP32's BCLK
    // MSB-first, left-aligned (standard Philips I2S)
    reg [31:0] i2s_shift_reg = 32'd0;
    reg [4:0] i2s_bit_count = 5'd0;
    reg i2s_ws_prev = 1'b0;

    always @(posedge i2s_bclk) begin
        // Detect WS transition (L/R channel change) - this marks the START of a new frame
        if (i2s_ws != i2s_ws_prev) begin
            // WS just changed - load new audio data for this frame
            // Use synchronized audio data from clock domain crossing registers
            if (i2s_ws) begin
                // WS=1: Right channel - MSB-aligned (16-bit data in upper 16 bits)
                i2s_shift_reg <= {right_i2s_sync2[15:0], 16'd0};
            end else begin
                // WS=0: Left channel - MSB-aligned (16-bit data in upper 16 bits)
                i2s_shift_reg <= {left_i2s_sync2[15:0], 16'd0};
            end
            i2s_bit_count <= 5'd0;
            i2s_ws_prev <= i2s_ws;
        end else begin
            // Normal operation - shift out MSB first
            i2s_shift_reg <= {i2s_shift_reg[30:0], 1'b0};
            i2s_bit_count <= i2s_bit_count + 1'b1;
        end
    end

    // Output MSB
    assign i2s_data = i2s_shift_reg[31];

    always @(posedge AUD_MCLK) begin
        if (sample_tick && !fifo_full) begin
            // Use synchronized audio data
            aud_ram[aud_wr] <= { left_sync2[7:0], left_sync2[15:8], right_sync2[7:0], right_sync2[15:8] };
            aud_wr          <= aud_wr + 1'b1;
        end
    end

    // Audio QIO - Note: QSPI pins are inputs only
    // The original design had tristate outputs here, but they were removed
    // because QSPI pins should be driven by ESP32 only
    // Audio data is now transmitted via I2S instead of QSPI QIO mode
    // These registers are kept for compatibility but no longer drive pins
    reg qio_oe = 1'b0;     // Unused - was for tristate control
    reg [3:0] qio_out = 4'b0;  // Unused - was for QIO output

    reg [15:0] aud_shift = 16'd0;
    reg  [3:0] nibble_cnt = 4'd0;

    reg audio_xfer;

    reg        lr_sel;
    reg [31:0] rd_word;
    
    // Registered FIFO read for BRAM inference
    reg [31:0] aud_ram_q;
    reg [AF_BITS-1:0] aud_rd_addr;
    
    always @(posedge QSPI_CLK) begin
        aud_ram_q <= aud_ram[aud_rd_addr];
    end

    // Original
    reg qAddReady = 'd0;
    reg qLenReady = 'd0;

    reg [3:0] qPins_r1 = 'd0;
    reg [7:0] qDataByte = 'd0;
    reg qCyclePhase = 'd0;

    reg qValid = 'd0;
    wire [3:0] qPins = {
                    QSPI_HD,
                    QSPI_WP,
                    QSPI_MISO,
                    QSPI_MOSI};

    reg [7:0] qCycleCount = 'd0;

    reg qMenuInit1 = 1'd0;
    reg qMenuInit2 = 1'd0;
    assign qMenuInit = qMenuInit2;

    always@(posedge QSPI_CLK or posedge QSPI_CS)
    begin
        if(QSPI_CS)
        begin
            qCyclePhase <= 1'd0;
            qValid      <= 1'd0;
            qCycleCount <= 1'd0;
            qCommand    <= 1'd0;
            qAddReady   <= 1'd0;
            qLenReady   <= 1'd0;
            qio_oe      <= 1'b0;
            audio_xfer  <= 1'b0;
        end
        else
        begin
            if(qCycleCount <= 50)
                qCycleCount   <= qCycleCount + 1'd1;
            
            // Command
            if(qCycleCount == 0)
                qCommand <= QSPI_MOSI;

            if((qCycleCount >= 1) && (qCycleCount <= 10))
                qLength <= {qLength[8:0], QSPI_MOSI};
                
            if((qCycleCount >= 11) && (qCycleCount <= 42))
                qAddress <= {qAddress[30:0], QSPI_MOSI};
                
            if(qCycleCount == 11)
                qLenReady <= 1'd1;
            else
                qLenReady <= 1'd0;

            if(qCycleCount == 43)
            begin
                qAddReady <= 1'd1;
                if(qAddress == 0) // first row
                begin
                    qMenuInit1  <=  1'd1;
                    if(qMenuInit1)
                        qMenuInit2 <= 1'd1;
                end
            end
            else
                qAddReady <= 1'd0;
                
            // QSPI data (only when not in audio transfer mode)
            if(qCycleCount >= 46 && !audio_xfer)
            begin
                qCyclePhase      <= ~qCyclePhase;
                if(qCyclePhase)
                begin
                    qDataByte   <= {qPins_r1,qPins};
                    qValid      <= 1'd1;
                end
                else
                begin
                    qPins_r1    <= qPins;
                    qValid      <= 1'd0;
                end
            end

            // Audio transfer only if: READ command, correct length, magic address, AND enough data in FIFO
            // Check at cycle 43 when address is fully loaded
            // Magic address: 0xA0D10000 (unlikely to collide with real memory)
            if (qCycleCount == 43 && qCommand==1'b1 && qLength==CMD_AUDIO && qAddress==32'hA0D10000 && fifo_ready)
                audio_xfer <= 1'b1;

            // Audio read transfer - QIO mode (4 bits per clock)
            if (audio_xfer) begin
                if (qCycleCount == 43) begin
                    // Pre-fetch first sample (BRAM has 1 cycle latency)
                    aud_rd_addr <= aud_rd;
                end else if (qCycleCount == 44) begin
                    // aud_ram_q now has the data from cycle 43
                    if (!fifo_empty) begin
                        rd_word   <= aud_ram_q;
                        aud_shift <= aud_ram_q[31:16];
                        lr_sel    <= 1'b1;
                    end else begin
                        // If FIFO empty, hold last value (already in rd_word)
                        aud_shift <= rd_word[31:16];
                    end
                    nibble_cnt <= 4'd3;  // 4 nibbles per 16-bit word
                    qio_oe     <= 1'b1;  // Enable QIO outputs

                end else if (qCycleCount >= 45) begin
                    // Send 4 bits (one nibble) per clock cycle - LOW nibble first
                    qio_out    <= aud_shift[3:0];
                    aud_shift  <= {4'b0, aud_shift[15:4]};

                    if (nibble_cnt == 0) begin
                        // Finished current 16-bit word, load next
                        if (!fifo_empty) begin
                            if (lr_sel) begin
                                // Just finished left channel, switch to right channel
                                aud_shift  <= rd_word[15:0];  // RIGHT already in correct byte order
                                lr_sel     <= 1'b0;
                            end else begin
                                // Just finished right channel, load next sample and advance FIFO
                                aud_rd     <= aud_rd + 1'b1;
                                aud_rd_addr <= aud_rd + 1'b1;  // Pre-fetch next sample
                                rd_word    <= aud_ram_q;  // Use registered read
                                aud_shift  <= aud_ram_q[31:16];
                                lr_sel     <= 1'b1;
                            end
                        end else begin
                            // If FIFO empty, repeat last sample to avoid glitches
                            aud_shift <= lr_sel ? rd_word[15:0] : rd_word[31:16];
                            lr_sel    <= ~lr_sel;
                        end
                        nibble_cnt <= 4'd3;
                    end else begin
                        nibble_cnt <= nibble_cnt - 1'b1;
                    end
                end
            end
        end
    end

    reg [7:0] qDataByte_r1 = 'd0;
    reg QSPI_VALID_phase = 'd0;
    always@(posedge QSPI_CLK or posedge QSPI_CS)
        if(QSPI_CS)
            QSPI_VALID_phase <= 'd0;
        else
            if(qValid)
            begin
                qDataByte_r1 <= qDataByte;
                QSPI_VALID_phase <= ~QSPI_VALID_phase;
            end

    assign qDataValid = qValid&QSPI_VALID_phase;
    assign qData = {qDataByte,qDataByte_r1};

endmodule
