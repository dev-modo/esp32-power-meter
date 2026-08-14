# ESP32 Power Meter — Firmware

Firmware for an ESP32 devkit that reads a **PZEM-004T (100 A, Modbus-RTU)**
energy monitor every **2 seconds** and POSTs the readings as JSON to the
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
| Slow blink (1200 ms)     | WiFi OK, server unreachable (2+ consecutive failed POSTs)|
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

Every **2 seconds** the firmware reads voltage, current, power, cumulative
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
   - **PZEM-004T-v30** by *Jakub Mandula* (1.1.2 or later)
   - **ArduinoJson** by *Benoit Blanchon* (7.x)
3. Create a sketch folder named e.g. `PowerMeter`, copy `src/main.cpp` into it
   and rename it `PowerMeter.ino`. (The `#include <Arduino.h>` at the top is
   harmless in the IDE.)
4. Set the serial monitor to **115200 baud**, pick your port, and Upload.

## Troubleshooting

- **All readings `null` / "no response" in the log** — TX/RX swapped (PZEM TX
  must go to GPIO16), or the PZEM isn't getting 5 V. Note the PZEM only
  measures when its mains side is live.
- **Slow LED blink** — the ESP32 has WiFi but can't reach the server: check
  the server URL (including the `:8000` port), that the server is running,
  and the API key. Exact HTTP errors are printed on the serial monitor.
- **Stuck at medium blink** — wrong WiFi password or network out of range.
  Hold the button 5 s to reopen the pairing portal.
