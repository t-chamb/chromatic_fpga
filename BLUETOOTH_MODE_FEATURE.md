# Bluetooth Mode Feature

## Overview

The `bluetooth_mode` feature allows the ESP32 to control the FPGA system speaker independently of the headphone jack. When enabled, it mutes the system speaker while keeping the volume pot active for Bluetooth audio volume control.

## Purpose

This feature enables the Game Boy emulator to:
- Send audio to ESP32 via I2S for Bluetooth transmission
- Mute the system speaker to prevent dual audio output
- Continue reading the volume pot for Bluetooth volume control
- Keep the 3.5mm headphone jack fully functional

## How It Works

### Audio Routing Priority

The audio system routes audio based on the following priority:

1. **Headphone jack detected** → Send stereo audio to headphone jack (always works)
2. **No headphones + bluetooth_mode ON** → Mute system speaker
3. **No headphones + bluetooth_mode OFF** → Send mono mix to system speaker

### Volume Pot Behavior

The volume pot (potentiometer) continues to:
- Be read by the FPGA audio system
- Apply volume control to headphone output
- Be transmitted to ESP32 in the `audio_brightness` UART packet
- Remain active regardless of bluetooth_mode state

This allows the ESP32 to read the pot value and apply it to Bluetooth audio volume.

## ESP32 Integration

### Enabling Bluetooth Mode

To enable bluetooth_mode from ESP32, send a UART packet:

**Address:** `0x0A` (10 decimal)
**Data:**
- Bit 0: `1` = Enable bluetooth mode (mute speaker)
- Bit 0: `0` = Disable bluetooth mode (speaker works normally)

### Reading Volume Pot

The volume pot value is transmitted to ESP32 in the existing `audio_brightness` packet:

**Channel:** 3
**Format:** 14-bit value
**Fields:**
- Bits 3-0: `brightness` (4 bits)
- Bit 4: `hHeadphones` (1 bit) - headphone jack detection
- Bits 11-5: `hVolume` (7 bits) - **volume pot value**

The ESP32 can use this value to control Bluetooth audio volume.

## Implementation Details

### Files Modified

1. **system_monitor.sv** - Added bluetooth_mode control
   - Added `bluetooth_mode` output port
   - Initialize to 0 on reset
   - UART receive handler at address 0x0A

2. **top.v** - Routed bluetooth_mode signal
   - Added `bluetooth_mode` wire
   - Connected in system_monitor instantiation
   - Connected in aud_system_top instantiation

3. **aud_system_top.v** - Modified audio routing
   - Added `bluetooth_mode` input port
   - Updated audio routing logic to check headphones first
   - Mutes speaker only when no headphones and bluetooth_mode active

### Audio Routing Logic

```verilog
// Priority order:
// 1. Headphones detected: send stereo to headphone jack (always works)
// 2. No headphones + bluetooth_mode: mute system speaker
// 3. No headphones + normal mode: send mono mix to system speaker

stereo_sr <= hHeadphones ? { right_m[15:0],left_m[15:0] } :
             bluetooth_mode ? 32'd0 :
             {16'd0,gMonoSpeaker[16:1]};
```

### Signal Flow

```
ESP32 UART (addr 0x0A) → system_monitor.bluetooth_mode
                              ↓
                         top.bluetooth_mode (wire)
                              ↓
                      aud_system_top.bluetooth_mode
                              ↓
                    Audio routing logic (selects speaker vs mute)
```

## Use Cases

### Use Case 1: Bluetooth Audio Playback

**Scenario:** User wants to stream Game Boy audio via Bluetooth

**Steps:**
1. ESP32 connects Bluetooth headphones
2. ESP32 sends UART command to enable bluetooth_mode
3. FPGA mutes system speaker
4. FPGA continues sending I2S audio to ESP32
5. FPGA continues reading pot and sending value to ESP32
6. ESP32 applies pot value to Bluetooth volume
7. User hears audio only through Bluetooth headphones

### Use Case 2: Headphone Jack Override

**Scenario:** User plugs in 3.5mm headphones while bluetooth_mode is active

**Steps:**
1. bluetooth_mode is ON (speaker muted)
2. User plugs in 3.5mm headphones
3. FPGA detects headphone jack insertion (hHeadphones = HIGH)
4. Audio routing prioritizes headphones over bluetooth_mode
5. User hears audio through 3.5mm headphones
6. System speaker remains muted
7. I2S audio still flows to ESP32 for Bluetooth

### Use Case 3: Normal Speaker Mode

**Scenario:** User wants to use system speaker

**Steps:**
1. No headphones plugged in
2. bluetooth_mode is OFF (default state)
3. FPGA sends mono mix to system speaker
4. User hears audio through speaker
5. Pot controls speaker volume
6. I2S audio still flows to ESP32

## Important Notes

1. **Headphones always work** - The 3.5mm jack takes priority over bluetooth_mode
2. **Pot always active** - Volume pot continues to be read and transmitted regardless of mode
3. **I2S always flows** - Audio data continues to flow to ESP32 via I2S in all modes
4. **Default state is OFF** - bluetooth_mode initializes to 0 (disabled) on reset

## Testing

### Test 1: Bluetooth Mode Enable/Disable

```c
// Enable bluetooth mode
uart_send_packet(0x0A, 0x01);  // Speaker should mute

// Disable bluetooth mode
uart_send_packet(0x0A, 0x00);  // Speaker should work
```

### Test 2: Headphone Override

```c
// Enable bluetooth mode
uart_send_packet(0x0A, 0x01);

// Plug in headphones
// Expected: Headphones work, speaker muted

// Unplug headphones
// Expected: Speaker muted (bluetooth_mode still active)
```

### Test 3: Pot Value Reading

```c
// Enable bluetooth mode
uart_send_packet(0x0A, 0x01);

// Read audio_brightness packet (channel 3)
// Expected: hVolume bits 11-5 contain current pot value
// Expected: Value changes as user adjusts pot
```

## Revision History

- **2025-11-03** - Initial implementation
  - Added bluetooth_mode UART command (address 0x0A)
  - Modified audio routing to prioritize headphones
  - Ensured pot value continues to be transmitted
