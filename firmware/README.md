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

The PZEM has **two electrically separate sides** at opposite ends of the board.
Only the 4-pin header touches the ESP32. The screw terminals are mains.

### Low-voltage side: the 4-pin header → ESP32

The header is labelled, in order, **GND · TX · RX · 5V**. Trust the silkscreen
text rather than counting pins — clone boards have been seen rotated.

| PZEM header | ESP32 | Notes |
|---|---|---|
| GND | GND | Mandatory. Without it the opto interface cannot work at all. |
| **TX** | **GPIO4** | ⚠️ Note the cross-over — PZEM *TX* goes to the ESP32 pin that *receives* |
| **RX** | **GPIO25** | ⚠️ PZEM *RX* goes to the ESP32 pin that *transmits* |
| 5V | **3V3** ← *not* 5V | See the box below. This pin only feeds the optocoupler LEDs. |

9600 baud, 8N1, Modbus-RTU.

> [!IMPORTANT]
> **The data pair crosses over. TX does not go to TX.**
>
> ```
>   PZEM  TX ──────────────╮   ╭────────── GPIO4   (ESP32 receives)
>                          ╰─╳─╯
>   PZEM  RX ──────────────╯   ╰────────── GPIO25  (ESP32 transmits)
> ```
>
> "TX" printed on a board always means *that board's* transmit pin, so the label
> is relative to whichever board you are reading. TX is a mouth, RX is an ear —
> each device's mouth has to point at the other's ear. Wiring TX→TX puts two
> mouths together and leaves both ears listening to each other.
>
> **Getting it wrong causes no damage**, it just means silence: every register
> reads `NAN` and the serial log prints `[pzem] no response`. Swap the two data
> wires and it works. Leave GND and the 3V3 supply alone.

Both data pins are named from the ESP32's side in the firmware — `PIN_UART_RX`
is the pin the *ESP32* receives on, so it connects to the PZEM's **TX**.

> [!WARNING]
> **Feed that header's "5V" pin from 3.3 V, not 5 V.** An earlier version of
> this file said to use 5 V and claimed no level shifter was needed. That
> combination is wrong and stresses the ESP32.
>
> The TTL section is nothing but a connector, four 1 kΩ resistors and two
> optocouplers — there is no regulator or level translation on it. The opto
> output is open-collector with **`R4`, a 1 kΩ pull-up to that header pin**, so
> whatever you feed it *becomes the logic level*. At 5 V the PZEM's TX idles at
> 5 V into a GPIO specified for 3.6 V max (ESP32 datasheet Table 5-3,
> V_IH max = VDD + 0.3). The RX line is worse than it looks: its opto LED is fed
> from the same pin through `R8` = 1 kΩ, so whenever GPIO25 is not actively
> pulling low — during reset, before `Serial2` is configured — RX floats to
> ~4.9 V, and the ESP32's internal 45 kΩ pull-down cannot fight a 1 kΩ pull-up.
> So at 5 V *both* pins are over-stressed.
>
> Many people run it at 5 V and report it working: the 1 kΩ limits injected
> current to ~1.4 mA, which parts often survive. That is survival, not
> compliance, and not what you want in a wall for years.
>
> **Powering it from 3.3 V makes both directions natively 3.3 V with no extra
> parts.** The only consequence is less optocoupler current — about 2.1 mA
> instead of 3.8 mA — still ample at 9600 baud, where one bit lasts 104 µs and
> the optocoupler switches in microseconds. If reads are unreliable, solder a
> second 1 kΩ across `R8` to restore ~4.2 mA.
>
> Two honest caveats. This is validated by the module schematic and widely used
> (ESPHome and Tasmota both document it), but it is **not a vendor-sanctioned
> mode** — Peacefair's manual only ever says "requires external 5V power supply"
> and never states a logic level. It fails *safe*: too little opto current gives
> `NAN` reads, never damage. And the board's TX/RX indicator LEDs go dim or dark
> at 3.3 V, so don't diagnose from them.
>
> **If you must use 5 V**, the fix is one resistor, not a level shifter: a
> **1.5 kΩ from the PZEM-TX / GPIO4 node to GND**, which forms a divider with the
> internal 1 kΩ `R4` and lands at 3.00 V. The other direction needs nothing —
> the ESP32's 3.3 V comfortably drives the PZEM's input.

### LED and button

| Peripheral | ESP32 | Notes |
|---|---|---|
| LED | GPIO2 → 220 Ω → LED **anode**; cathode → GND | Active-high. 220 Ω suits red/yellow/green; use 100 Ω for blue/white. The onboard LED on many devkits is already on GPIO2 with its own resistor. |
| Button | GPIO13, other leg → GND | `INPUT_PULLUP`, no external resistor |

GPIO2 is a **download-mode strapping pin**. Wire the LED active-high as above
and it is fine; wiring it active-low or adding a pull-up can break flashing. If
uploads ever turn flaky, disconnecting the GPIO2 LED is the first thing to try.

GPIO13 is also JTAG TCK, which matters only if you ever want hardware debugging
— you would need to unplug the button for that.

### Why GPIO4 / GPIO25 and not the usual GPIO16 / GPIO17

**GPIO16 and GPIO17 are wired to the PSRAM** on every ESP32-WROVER, on
`-N4R2`/`-N8R2`/`-N16R2` WROOM variants, and on PICO-D4. Espressif's DevKitC
guide is blunt: *"The pins GPIO16 and GPIO17 are available for use only on the
boards with the modules ESP32-WROOM and ESP32-SOLO-1. The boards with
ESP32-WROVER modules have the pins reserved for internal use."*

GPIO4 and GPIO25 are free on every variant, and are Espressif's own UART2
defaults from arduino-esp32 3.x onward — changed from 16/17 to *"avoid conflicts
with other peripherals."* The ESP32 routes UART through its GPIO matrix, so any
free pins work. If you have a plain WROOM-32 and prefer 16/17, they will work;
just change `PIN_PZEM_RX` / `PIN_PZEM_TX`.

### Powering it

**Use exactly one 5 V source for the ESP32** — either USB or an external supply
into 5V/VIN, never both at once. Some clone devkits omit the protection diode,
and back-feeding the USB rail can damage the board or the host.

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

## Reconnecting — it never gives up

Once a network has been saved, the firmware **retries it forever and will not
put itself back into pairing mode on its own.** This is deliberate: after a
power cut the router routinely takes a minute or two longer to boot than the
ESP32, and a meter that parks itself in a pairing portal until someone walks
over to it is useless.

| Situation | What happens |
|---|---|
| Saved network not up yet at boot | Retries every ~23 s **indefinitely**, LED medium-blinking. Never opens the portal. |
| WiFi drops while running | `setAutoReconnect` plus a `WiFi.reconnect()` nudge every 15 s, forever. |
| Router gone for a week | Keeps retrying; reconnects on its own when it returns. |
| Saved password no longer correct | Also retries forever — the serial log says `connect failed (wrong password?)` rather than "network not found", so the one user-fixable case is distinguishable. Hold the button to re-pair. |
| Server down but WiFi fine | Keeps posting; LED slow-blinks after 4 failures. Recovers on the first success. |
| No credentials saved (first boot / after reset) | Opens the portal and leaves it open with **no timeout** — there is nothing to retry. |

The only way into pairing mode is to ask for it: **hold the button 5 seconds.**
That works at any time, including while the device is stuck retrying at boot, so
you never need to power-cycle to get the portal back.

Making that guarantee real took some care, and it is the reason the retry loop
calls `WiFi.begin()` directly instead of `wm.autoConnect()`. `autoConnect()`
blocks for the whole connect timeout (~20 s against an absent router) without
reading the button, which left the escape hatch unusable precisely when it was
needed — and worse, a brief tap during that blind window could be mistaken for a
finished hold and wipe the credentials. The connect is now driven by a polled
loop that samples the button every 10 ms, and `handleButton()` additionally
refuses to act on a hold it did not observe continuously. Both directions are
covered by [`test/test_button_logic.py`](test/test_button_logic.py), which runs
on a laptop with no hardware:

```bash
python3 firmware/test/test_button_logic.py    # 12 passed, 0 failed
```

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

- **All readings `null` / "no response" in the log** — in rough order of
  likelihood: TX/RX swapped (PZEM TX must go to **GPIO4**); the 4-pin header's
  GND not connected (all four pins are required); the header unpowered; or you
  are on a WROVER/PSRAM board still wired to GPIO16/17. Note the PZEM only
  measures when its **mains side is live** — a bench-powered module with no
  mains reports nothing, which looks identical to a wiring fault.
- **Voltage reads fine but current sits at 0.00 A** — the CT is almost certainly
  clamped around **both** live and neutral, so the two currents cancel. It must
  go around one conductor only. Also check the split core is fully latched
  closed; anything below the 0.02 A starting current reads as zero.
- **Slow LED blink** — the ESP32 has WiFi but can't reach the server: check
  the server URL (including the `:8000` port), that the server is running,
  and the API key. Exact HTTP errors are printed on the serial monitor.
- **Stuck at medium blink** — wrong WiFi password or network out of range.
  Hold the button 5 s to reopen the pairing portal.
