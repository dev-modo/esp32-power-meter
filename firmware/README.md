# ESP32 Power Meter — Firmware

Firmware for an ESP32 devkit that reads a **PZEM-004T (100 A, Modbus-RTU)**
energy monitor every **second** and POSTs the readings as JSON to the
project's ingest server (`POST <server_url>/api/ingest`). WiFi and server
settings are configured through a captive pairing portal — no code edits or
reflashing needed to change networks or servers.

> **⚠️ Mains voltage warning:** the PZEM-004T's measurement side connects to
> live mains wiring. If you are not comfortable and qualified to work with
> mains voltage, get help from someone who is. Always kill the breaker before
> touching the high-voltage side.

## Wiring

| PZEM-004T pin | ESP32 pin        | Notes                                   |
|---------------|------------------|-----------------------------------------|
| TX            | GPIO16 (RX2)     | PZEM transmits → ESP32 receives         |
| RX            | GPIO17 (TX2)     | ESP32 transmits → PZEM receives         |
| VCC           | 5V (VIN)         | The PZEM logic side needs 5 V           |
| GND           | GND              | Common ground                           |

| Peripheral | ESP32 pin | Notes                                                            |
|------------|-----------|------------------------------------------------------------------|
| LED        | GPIO2     | Onboard LED on most devkits; an external LED + 220 Ω to GND works too |
| Button     | GPIO13    | Other leg to GND; firmware uses `INPUT_PULLUP`, no external resistor  |

**3.3 V note:** the PZEM-004T is powered from 5 V, but its UART logic side
works fine at 3.3 V TTL, so its TX/RX lines can connect directly to the ESP32
— no level shifter needed. (This applies to the common opto-isolated v3.0/100 A
boards; on very old non-isolated revisions people sometimes add a 1 kΩ series
resistor on the PZEM-TX line as cheap insurance.)

## LED status codes

| LED pattern              | Meaning                                                  |
|--------------------------|----------------------------------------------------------|
| Fast blink (150 ms)      | Config/pairing portal is active                          |
| Medium blink (500 ms)    | Connecting to WiFi                                       |
| Solid ON                 | WiFi OK + server reachable                               |
| Slow blink (1200 ms)     | WiFi OK, server unreachable (4+ consecutive failed POSTs)|
| 5 rapid flashes          | Factory reset triggered, then reboot into the portal     |

## Button

Hold the button for **5 seconds or more** to factory-reset: the LED flashes
5 times rapidly, the **WiFi credentials are erased**, and the device reboots
into the pairing portal. The **server URL, API key and device ID are kept**
in flash (NVS) and show up prefilled in the portal — you only need to pick a
WiFi network again.

## First boot / pairing

1. Power the ESP32. With no WiFi configured, the LED fast-blinks and the
   device opens an **open access point named `PowerMeter-Setup`**.
2. Join `PowerMeter-Setup` from your phone or laptop. A captive portal should
   pop up automatically; if not, browse to **http://192.168.4.1**.
3. Tap **Configure WiFi**, pick your network and enter its password.
4. Fill in the three extra fields:
   - **Server URL** — where the ingest server runs, e.g. `http://192.168.1.8:8000`
     (plain `http://`; the firmware does not do TLS)
   - **API key** — leave empty unless the server was started with an `API_KEY`
   - **Device ID** — default `powermeter-01`; change it if you run several meters
5. Save. The device connects (medium blink), then goes **solid ON** once the
   server accepts data. Watch the serial monitor at **115200 baud** for logs.

Settings live in NVS namespace `powermeter`, so they survive reboots and
re-flashes.

## Reporting

Every **second** the firmware reads voltage, current, power, cumulative
energy (kWh), frequency and power factor from the PZEM and POSTs them to
`<server_url>/api/ingest` with the `X-API-Key` header (only when a key is
set). Failed sensor reads are sent as JSON `null`. Example payload:

```json
{
  "device_id": "powermeter-01",
  "voltage": 231.2,
  "current": 1.234,
  "power": 285.1,
  "energy": 12.345,
  "frequency": 50.0,
  "pf": 0.95,
  "rssi": -61,
  "uptime_s": 12345
}
```

## Flashing

### Option A — PlatformIO (recommended)

```sh
cd firmware
pio run                  # build
pio run -t upload        # flash (auto-detects the serial port)
pio device monitor       # serial logs at 115200 baud
```

The `esp32dev` environment in `platformio.ini` pulls in all three libraries
automatically.

### Option B — Arduino IDE

1. Install the **ESP32 board package** (Boards Manager → search "esp32" by
   Espressif) and select the board **ESP32 Dev Module**.
2. Install these libraries via **Sketch → Include Library → Manage Libraries**:
   - **WiFiManager** by *tzapu* (2.x)
   - **PZEM004Tv30** by *Jakub Mandula* (1.2.1 or later) — search for
     `PZEM004Tv30`, spelled exactly like that. The GitHub repo and the
     PlatformIO registry call it `PZEM-004T-v30`, but the Arduino Library
     Manager has no entry under that name.
   - **ArduinoJson** by *Benoit Blanchon* (7.x)
3. Set **Tools → Partition Scheme → "Minimal SPIFFS (1.9MB APP with OTA)"**.
   WiFiManager's captive portal is large: on the default 1.2 MB app partition
   the build lands at **89% full**, which works but leaves no headroom. Minimal
   SPIFFS drops it to ~59%. This firmware keeps everything in NVS and never
   uses SPIFFS, so nothing is lost. (PlatformIO does this automatically via
   `board_build.partitions` in `platformio.ini`.)
4. Create a sketch folder named e.g. `PowerMeter`, copy `src/main.cpp` into it
   and rename it `PowerMeter.ino`. (The `#include <Arduino.h>` at the top is
   harmless in the IDE.)
5. Set the serial monitor to **115200 baud**, pick your port, and Upload.

### Verified builds

This firmware is confirmed to compile — not merely reviewed — on **both**
toolchains and, usefully, on **both ESP32 Arduino core generations**. Plenty of
ESP32 sketches break between core 2.x and 3.x; this one builds on each:

| Toolchain | ESP32 core | Flash (min_spiffs) | RAM |
|---|---|---|---|
| PlatformIO 6.1.19, Espressif32 7.0.1 | 2.0.17 | 1 043 665 B — **53.1%** | 14.7% |
| arduino-cli 1.5.1 | 3.3.10 | 1 166 616 B — **59%** | 15% |

Libraries resolved: WiFiManager 2.0.17, ArduinoJson 7.4.3, and the PZEM library
at 1.1.2 (PlatformIO) / 1.2.1 (Arduino) — plus `WiFi`, `HTTPClient`,
`Preferences` and `Ticker` from the core.

Zero compiler warnings from this code at `--warnings all`. WiFiManager emits a
few `-Wformat` warnings from its own source; those are upstream, not ours.

On the **stock 1.2 MB partition** the same binary sits at **89%** full — it
flashes and runs, but leaves nothing spare, which is why `min_spiffs` is the
configured default.

## Troubleshooting

- **All readings `null` / "no response" in the log** — TX/RX swapped (PZEM TX
  must go to GPIO16), or the PZEM isn't getting 5 V. Note the PZEM only
  measures when its mains side is live.
- **Slow LED blink** — the ESP32 has WiFi but can't reach the server: check
  the server URL (including the `:8000` port), that the server is running,
  and the API key. Exact HTTP errors are printed on the serial monitor.
- **Stuck at medium blink** — wrong WiFi password or network out of range.
  Hold the button 5 s to reopen the pairing portal.
