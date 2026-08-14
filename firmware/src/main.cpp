/**
 * ============================================================================
 *  ESP32 Power Meter — firmware
 * ============================================================================
 *
 *  Reads a PZEM-004T (100 A, Modbus-RTU) energy monitor once a second and
 *  POSTs the readings as JSON to a small ingest server:
 *
 *      POST <server_url>/api/ingest
 *      {"device_id":"powermeter-01","voltage":231.2,"current":1.234,
 *       "power":285.1,"energy":12.345,"frequency":50.0,"pf":0.95,
 *       "rssi":-61,"uptime_s":12345}
 *
 *  Any PZEM value that could not be read is sent as JSON null.
 *
 *  Wiring (see README.md for the full table):
 *      PZEM TX  -> GPIO16 (RX2)      LED    -> GPIO2  (onboard on most kits)
 *      PZEM RX  -> GPIO17 (TX2)      BUTTON -> GPIO13 to GND (INPUT_PULLUP)
 *      PZEM VCC -> 5V (VIN), GND -> GND
 *
 *  LED status codes:
 *      fast blink  (150 ms)  config/pairing portal is open
 *      medium blink(500 ms)  connecting to WiFi
 *      solid ON              WiFi OK + server reachable
 *      slow blink  (1200 ms) WiFi OK but 2+ consecutive POSTs failed
 *      5 rapid flashes       factory reset triggered, rebooting into portal
 *
 *  Button (GPIO13): hold >= 5 s to erase the WiFi credentials and reboot
 *  into the pairing portal. Server URL / API key / device-id are kept in
 *  NVS and prefilled in the portal.
 *
 *  First boot: the device opens an open access point "PowerMeter-Setup".
 *  Join it and browse to http://192.168.4.1 to pick your WiFi network and
 *  enter the server URL, API key and device id.
 *
 *  Libraries (Arduino IDE Library Manager names):
 *      WiFiManager    by tzapu           (^2.x)
 *      PZEM-004T-v30  by Jakub Mandula   (^1.1.2)
 *      ArduinoJson    by Benoit Blanchon (^7)
 * ============================================================================
 */

#include <Arduino.h>
#include <WiFi.h>
#include <WiFiManager.h>   // tzapu/WiFiManager
#include <HTTPClient.h>
#include <Preferences.h>   // NVS key/value storage (built into the ESP32 core)
#include <PZEM004Tv30.h>   // mandulaj/PZEM-004T-v30
#include <ArduinoJson.h>   // bblanchon/ArduinoJson v7
#include <Ticker.h>        // built-in: lets the LED blink even while
                           // WiFiManager blocks in the config portal

// ----------------------------------------------------------------------------
// Pin assignments — MUST match the wiring table in README.md
// ----------------------------------------------------------------------------
static const int PIN_LED     = 2;   // status LED (onboard LED on most devkits)
static const int PIN_BUTTON  = 13;  // factory-reset button to GND, INPUT_PULLUP
static const int PIN_PZEM_RX = 16;  // ESP32 RX2  <- PZEM TX
static const int PIN_PZEM_TX = 17;  // ESP32 TX2  -> PZEM RX

// ----------------------------------------------------------------------------
// Behaviour constants
// ----------------------------------------------------------------------------
static const uint32_t REPORT_INTERVAL_MS   = 1000;   // contract: post every 1 s
// Connect and read timeouts apply back-to-back, so the worst case for a dead
// server is 2 x this. Keep it under the report interval so an unreachable
// server slows the cadence a little instead of derailing it.
static const uint32_t HTTP_TIMEOUT_MS      = 700;    // per-request budget
// Counted in failed POSTs, but what matters is the time it represents: 4 at the
// 1 s cadence is ~4 s of trouble, the same as 2 was at the old 2 s cadence. Any
// lower and the LED flickers on every transient blip.
static const int      FAILS_BEFORE_WARNING = 4;      // 4+ fails -> slow blink
static const uint32_t BUTTON_HOLD_MS       = 5000;   // hold time for reset
static const uint32_t BUTTON_DEBOUNCE_MS   = 30;     // contact-bounce filter
static const uint32_t WIFI_NUDGE_MS        = 15000;  // reconnect() retry pace
static const uint32_t WIFI_CONNECT_TIMEOUT_S = 20;   // per connect attempt
static const uint32_t WIFI_BOOT_RETRY_MS   = 3000;   // pause between boot
                                                     // connect attempts; we
                                                     // retry saved credentials
                                                     // forever, never giving up
static const uint32_t BUTTON_POLL_MS       = 10;     // button sampling period
// If handleButton() has not run for longer than this, something blocked and we
// cannot trust the press state we last saw — see the resync there. Must stay
// comfortably below BUTTON_HOLD_MS.
static const uint32_t BUTTON_STARVE_MS     = 250;

// LED blink half-periods (ms) from the status-code table
static const uint32_t BLINK_PORTAL_MS     = 150;
static const uint32_t BLINK_CONNECTING_MS = 500;
static const uint32_t BLINK_NO_SERVER_MS  = 1200;

static const char *AP_NAME           = "PowerMeter-Setup";
static const char *NVS_NAMESPACE     = "powermeter";
static const char *DEFAULT_DEVICE_ID = "powermeter-01";

// ----------------------------------------------------------------------------
// Globals
// ----------------------------------------------------------------------------

// The PZEM-004T "100 A" unit speaks the same Modbus-RTU protocol as the v3.0,
// so this library drives it fine. The constructor starts Serial2 at 9600 baud
// on the given pins.
PZEM004Tv30 pzem(Serial2, PIN_PZEM_RX, PIN_PZEM_TX);

WiFiManager wm;
Preferences prefs;
Ticker      ledTicker;

// Runtime copies of the persisted settings
String gServerUrl;  // e.g. "http://192.168.1.8:8000" (no trailing slash)
String gApiKey;     // may be empty -> X-API-Key header is omitted
String gDeviceId;   // e.g. "powermeter-01"

// Portal text fields — created in setup() after loading NVS so they can be
// prefilled with the previously saved values.
WiFiManagerParameter *paramServerUrl = nullptr;
WiFiManagerParameter *paramApiKey    = nullptr;
WiFiManagerParameter *paramDeviceId  = nullptr;

int gConsecutiveFailures = 0;  // failed POSTs in a row (any success resets)

// ----------------------------------------------------------------------------
// LED state machine
//
// A Ticker (hardware timer) toggles the LED in the background, so the blink
// codes stay accurate even while WiFiManager blocks inside the config portal
// or during the initial connection attempt.
// ----------------------------------------------------------------------------
enum LedMode : uint8_t {
  LED_OFF,
  LED_SOLID,             // WiFi OK + server reachable
  LED_BLINK_PORTAL,      // config/pairing portal open   (150 ms)
  LED_BLINK_CONNECTING,  // connecting to WiFi           (500 ms)
  LED_BLINK_NO_SERVER,   // WiFi OK, server unreachable  (1200 ms)
};

static LedMode gLedMode = LED_OFF;

static const char *ledModeName(LedMode m) {
  switch (m) {
    case LED_OFF:              return "OFF";
    case LED_SOLID:            return "SOLID (server reachable)";
    case LED_BLINK_PORTAL:     return "FAST BLINK (portal open)";
    case LED_BLINK_CONNECTING: return "MEDIUM BLINK (connecting to WiFi)";
    case LED_BLINK_NO_SERVER:  return "SLOW BLINK (server unreachable)";
  }
  return "?";
}

// Ticker callback: just flip the LED.
static void ledToggle() { digitalWrite(PIN_LED, !digitalRead(PIN_LED)); }

// Switch the LED to a new mode. Safe to call every loop() pass — it only
// does work (and logs) when the mode actually changes.
static void setLedMode(LedMode mode) {
  if (mode == gLedMode) return;
  gLedMode = mode;

  ledTicker.detach();
  switch (mode) {
    case LED_OFF:              digitalWrite(PIN_LED, LOW);  break;
    case LED_SOLID:            digitalWrite(PIN_LED, HIGH); break;
    case LED_BLINK_PORTAL:     ledTicker.attach_ms(BLINK_PORTAL_MS,     ledToggle); break;
    case LED_BLINK_CONNECTING: ledTicker.attach_ms(BLINK_CONNECTING_MS, ledToggle); break;
    case LED_BLINK_NO_SERVER:  ledTicker.attach_ms(BLINK_NO_SERVER_MS,  ledToggle); break;
  }
  Serial.printf("[led] %s\n", ledModeName(mode));
}

// ----------------------------------------------------------------------------
// Settings (NVS via Preferences, namespace "powermeter")
// ----------------------------------------------------------------------------
static void loadSettings() {
  prefs.begin(NVS_NAMESPACE, /*readOnly=*/false);  // rw so first boot creates it
  gServerUrl = prefs.getString("server_url", "");
  gApiKey    = prefs.getString("api_key", "");
  gDeviceId  = prefs.getString("device_id", DEFAULT_DEVICE_ID);
  prefs.end();

  // Normalise: no trailing slash, we append "/api/ingest" ourselves.
  while (gServerUrl.endsWith("/")) gServerUrl.remove(gServerUrl.length() - 1);

  Serial.printf("[cfg] server_url = \"%s\"\n", gServerUrl.c_str());
  Serial.printf("[cfg] api_key    = %s\n", gApiKey.isEmpty() ? "(not set)" : "(set, hidden)");
  Serial.printf("[cfg] device_id  = \"%s\"\n", gDeviceId.c_str());
}

// Called by WiFiManager when the user hits "Save" in the portal.
// Persists the three custom fields to NVS and updates the runtime copies,
// so no reboot is needed for them to take effect.
static void onPortalSave() {
  gServerUrl = paramServerUrl->getValue();
  gApiKey    = paramApiKey->getValue();
  gDeviceId  = paramDeviceId->getValue();

  gServerUrl.trim();
  gApiKey.trim();
  gDeviceId.trim();
  while (gServerUrl.endsWith("/")) gServerUrl.remove(gServerUrl.length() - 1);
  if (gDeviceId.isEmpty()) gDeviceId = DEFAULT_DEVICE_ID;

  // A blank server URL is never meaningful, and there is no way to set it again
  // at runtime once saved — so treat an empty box as "leave it alone" rather
  // than wiping a working URL. (An empty API key IS meaningful: it means the
  // server has no key configured, so that one stays overwritable.)
  if (gServerUrl.isEmpty()) {
    prefs.begin(NVS_NAMESPACE, /*readOnly=*/true);
    gServerUrl = prefs.getString("server_url", "");
    prefs.end();
    if (!gServerUrl.isEmpty()) {
      Serial.println("[cfg] server URL submitted blank — keeping the saved one");
    }
  }

  prefs.begin(NVS_NAMESPACE, /*readOnly=*/false);
  prefs.putString("server_url", gServerUrl);
  prefs.putString("api_key", gApiKey);
  prefs.putString("device_id", gDeviceId);
  prefs.end();

  Serial.println("[cfg] portal settings saved to NVS");
  loadSettings();  // re-log the effective values
}

// Called by WiFiManager the moment the config portal opens.
static void onPortalOpened(WiFiManager *w) {
  setLedMode(LED_BLINK_PORTAL);
  Serial.println("[wifi] Config portal open.");
  Serial.printf("[wifi] Join the open AP \"%s\" and browse to http://192.168.4.1\n", AP_NAME);
}

// ----------------------------------------------------------------------------
// Factory reset (button held >= 5 s)
//
// Erases ONLY the WiFi credentials, then reboots into the pairing portal.
// Server URL / API key / device id stay in NVS and are prefilled in the
// portal, so the user only has to pick a network again.
// ----------------------------------------------------------------------------
static void factoryReset() {
  Serial.println("[btn] Held 5 s -> factory reset: erasing WiFi credentials, rebooting into portal");

  // 5 rapid flashes to acknowledge. Blocking delay() is fine here — we are
  // about to reboot anyway.
  ledTicker.detach();
  for (int i = 0; i < 5; i++) {
    digitalWrite(PIN_LED, HIGH); delay(80);
    digitalWrite(PIN_LED, LOW);  delay(80);
  }

  wm.resetSettings();  // wipes WiFi credentials only — NVS "powermeter" kept
  ESP.restart();
}

// Debounced hold-timer for the button. Must be called frequently (every few
// ms). It is deliberately defensive about being called late: a hold is only
// ever honoured from samples this function actually took, never inferred from
// wall-clock time across a gap in which the pin was not read.
static void handleButton(uint32_t now) {
  static bool     debounced   = false;  // true = button held down
  static bool     lastRaw     = false;
  static uint32_t lastEdgeMs  = 0;
  static uint32_t pressStart  = 0;
  static uint32_t lastCallMs  = 0;
  static bool     everCalled  = false;

  bool raw = (digitalRead(PIN_BUTTON) == LOW);  // active-low (pull-up)

  // If we were starved (a blocking call ran between samples), we cannot know
  // what the button did in the meantime. Re-baseline instead of trusting a
  // pressStart from before the gap — otherwise a brief tap during the gap would
  // look like a completed multi-second hold and wipe the WiFi credentials.
  if (everCalled && (now - lastCallMs) > BUTTON_STARVE_MS) {
    Serial.printf("[btn] resynchronising after a %lu ms gap in sampling\n",
                  (unsigned long)(now - lastCallMs));
    debounced  = false;
    lastRaw    = raw;
    lastEdgeMs = now;
    pressStart = now;
  }
  lastCallMs = now;
  everCalled = true;

  if (raw != lastRaw) {          // raw signal changed -> restart debounce timer
    lastRaw = raw;
    lastEdgeMs = now;
  }

  // Accept the new state once it has been stable for the debounce window.
  if (raw != debounced && (now - lastEdgeMs) >= BUTTON_DEBOUNCE_MS) {
    debounced = raw;
    if (debounced) {
      pressStart = now;
      Serial.println("[btn] pressed (hold 5 s for factory reset)");
    } else {
      Serial.printf("[btn] released after %lu ms\n", (unsigned long)(now - pressStart));
    }
  }

  // `raw` must still be down: never fire on a button the user already let go of.
  if (debounced && raw && (now - pressStart) >= BUTTON_HOLD_MS) {
    factoryReset();  // does not return
  }
}

// Human-readable WiFi status, so the serial log distinguishes "router isn't
// there" from "the password is wrong" — only the latter needs the user to act.
static const char *wifiStatusName(wl_status_t s) {
  switch (s) {
    case WL_NO_SHIELD:       return "no wifi hardware";
    case WL_IDLE_STATUS:     return "idle";
    case WL_NO_SSID_AVAIL:   return "network not found (router down or out of range)";
    case WL_SCAN_COMPLETED:  return "scan completed";
    case WL_CONNECTED:       return "connected";
    case WL_CONNECT_FAILED:  return "connect failed (wrong password?)";
    case WL_CONNECTION_LOST: return "connection lost";
    case WL_DISCONNECTED:    return "disconnected";
    default:                 return "unknown";
  }
}

/**
 * Wait up to timeoutMs for WiFi to come up, sampling the button throughout.
 * Returns true if connected. This exists so nothing in the boot path ever
 * blocks without reading the button: the 5 s hold has to work even — especially
 * — while the device is stuck retrying an unreachable network.
 */
static bool waitForWifi(uint32_t timeoutMs) {
  uint32_t start = millis();
  while ((millis() - start) < timeoutMs) {     // unsigned math: rollover-safe
    if (WiFi.status() == WL_CONNECTED) return true;
    handleButton(millis());                    // may factory-reset and reboot
    delay(BUTTON_POLL_MS);
  }
  return WiFi.status() == WL_CONNECTED;
}

// ----------------------------------------------------------------------------
// WiFi supervision — log connect/disconnect transitions and nudge the radio
// while it is down. WiFi.setAutoReconnect(true) does most of the work; the
// periodic WiFi.reconnect() covers the cases where auto-reconnect gives up.
// ----------------------------------------------------------------------------
static void handleWifi(uint32_t now) {
  static bool     wasConnected = true;   // setup() only completes when connected
  static uint32_t lastNudgeMs  = 0;

  bool connected = (WiFi.status() == WL_CONNECTED);

  if (connected != wasConnected) {
    wasConnected = connected;
    if (connected) {
      Serial.printf("[wifi] reconnected: %s (RSSI %d dBm)\n",
                    WiFi.localIP().toString().c_str(), WiFi.RSSI());
    } else {
      Serial.println("[wifi] connection lost — auto-reconnect running");
      lastNudgeMs = now;
    }
  }

  if (!connected && (now - lastNudgeMs) >= WIFI_NUDGE_MS) {
    lastNudgeMs = now;
    Serial.println("[wifi] still down — nudging WiFi.reconnect()");
    WiFi.reconnect();
  }
}

// ----------------------------------------------------------------------------
// PZEM reading + ingest POST
// ----------------------------------------------------------------------------

// Put a float into the JSON document, mapping NAN (read failure) to null,
// exactly as the API contract requires.
static void setFieldOrNull(JsonDocument &doc, const char *key, float value) {
  if (isnan(value)) doc[key] = nullptr;
  else              doc[key] = value;
}

// For the serial log: show "null" where a read failed.
static String fmtReading(float v, int decimals) {
  return isnan(v) ? String("null") : String(v, decimals);
}

// Read the PZEM and POST one sample. Called every REPORT_INTERVAL_MS.
static void readAndReport() {
  // --- 1. Read the meter. The library fetches all registers in one Modbus
  //        transaction and caches them briefly, so these six calls cost only
  //        one bus round-trip (~100 ms). A failed read returns NAN.
  float voltage   = pzem.voltage();
  float current   = pzem.current();
  float power     = pzem.power();
  float energy    = pzem.energy();     // kWh, CUMULATIVE counter
  float frequency = pzem.frequency();
  float pf        = pzem.pf();

  Serial.printf("[pzem] V=%s  A=%s  W=%s  kWh=%s  Hz=%s  PF=%s\n",
                fmtReading(voltage, 1).c_str(),  fmtReading(current, 3).c_str(),
                fmtReading(power, 1).c_str(),    fmtReading(energy, 3).c_str(),
                fmtReading(frequency, 1).c_str(), fmtReading(pf, 2).c_str());

  if (isnan(voltage) && isnan(current) && isnan(power)) {
    Serial.println("[pzem] no response — check TX/RX wiring and 5 V supply");
  }

  // --- 2. Build the ingest JSON (field names straight from the API contract).
  JsonDocument doc;
  doc["device_id"] = gDeviceId;
  setFieldOrNull(doc, "voltage",   voltage);
  setFieldOrNull(doc, "current",   current);
  setFieldOrNull(doc, "power",     power);
  setFieldOrNull(doc, "energy",    energy);
  setFieldOrNull(doc, "frequency", frequency);
  setFieldOrNull(doc, "pf",        pf);
  doc["rssi"]     = WiFi.RSSI();                      // dBm, int
  doc["uptime_s"] = (uint32_t)(millis() / 1000UL);    // seconds since boot

  String body;
  serializeJson(doc, body);

  // --- 3. POST it. Skip cleanly when we can't (WiFi down / URL not set).
  if (WiFi.status() != WL_CONNECTED) {
    Serial.println("[http] skipped POST — WiFi is down");
    return;  // WiFi state drives the LED; don't count server failures
  }
  if (gServerUrl.isEmpty()) {
    gConsecutiveFailures++;
    Serial.println("[http] no server URL configured — hold the button 5 s and set it in the portal");
    return;
  }

  String url = gServerUrl + "/api/ingest";

  HTTPClient http;
  http.setConnectTimeout(HTTP_TIMEOUT_MS);
  http.setTimeout(HTTP_TIMEOUT_MS);
  http.begin(url);  // plain http:// — see README for https notes
  http.addHeader("Content-Type", "application/json");
  if (!gApiKey.isEmpty()) {
    http.addHeader("X-API-Key", gApiKey);  // only sent when a key is set
  }

  int code = http.POST(body);
  http.end();

  if (code == 200) {
    if (gConsecutiveFailures >= FAILS_BEFORE_WARNING) {
      Serial.println("[http] server reachable again");
    }
    gConsecutiveFailures = 0;
    Serial.printf("[http] POST %s -> 200 OK\n", url.c_str());
  } else {
    gConsecutiveFailures++;
    if (code > 0) {
      // Server answered but rejected us (401 bad API key, 422 bad body, ...)
      Serial.printf("[http] POST %s -> HTTP %d (consecutive failures: %d)\n",
                    url.c_str(), code, gConsecutiveFailures);
    } else {
      // Connection-level failure (refused, timeout, DNS, ...)
      Serial.printf("[http] POST %s failed: %s (consecutive failures: %d)\n",
                    url.c_str(), HTTPClient::errorToString(code).c_str(),
                    gConsecutiveFailures);
    }
  }
}

// ----------------------------------------------------------------------------
// setup()
// ----------------------------------------------------------------------------
void setup() {
  Serial.begin(115200);
  delay(200);  // give the serial monitor a moment to attach
  Serial.println();
  Serial.println("=== ESP32 Power Meter ===");

  pinMode(PIN_LED, OUTPUT);
  digitalWrite(PIN_LED, LOW);
  pinMode(PIN_BUTTON, INPUT_PULLUP);

  // Load saved settings so the portal fields can be prefilled.
  loadSettings();

  // Portal text fields. The 5th argument is extra HTML for the <input>,
  // used here to show a placeholder hint in the empty server-URL box.
  paramServerUrl = new WiFiManagerParameter(
      "server_url", "Server URL", gServerUrl.c_str(), 128,
      " placeholder=\"http://192.168.1.8:8000\"");
  paramApiKey = new WiFiManagerParameter(
      "api_key", "API key (leave empty if the server has none)",
      gApiKey.c_str(), 64);
  paramDeviceId = new WiFiManagerParameter(
      "device_id", "Device ID", gDeviceId.c_str(), 32);

  wm.addParameter(paramServerUrl);
  wm.addParameter(paramApiKey);
  wm.addParameter(paramDeviceId);

  wm.setAPCallback(onPortalOpened);        // LED -> fast blink when portal opens
  wm.setSaveConfigCallback(onPortalSave);  // fires on "Save" from the WiFi page
  wm.setSaveParamsCallback(onPortalSave);  // fires on "Save" from the params page
  wm.setConnectTimeout(WIFI_CONNECT_TIMEOUT_S);

  // WiFi.mode() also initialises the WiFi driver, which getWiFiIsSaved() needs
  // before it can read the stored SSID out of NVS.
  WiFi.mode(WIFI_STA);
  setLedMode(LED_BLINK_CONNECTING);

  if (wm.getWiFiIsSaved()) {
    // We already have credentials, so a failure here does NOT mean the device
    // needs pairing — it means the network isn't there yet. Retry forever and
    // never open the portal on our own: after a power cut the router routinely
    // takes a minute or two longer to boot than the ESP32, and a meter that
    // parks itself in pairing mode until someone walks over is useless.
    // Hold the button for 5 s at any time to force pairing deliberately.
    wm.setEnableConfigPortal(false);   // belt and braces: never auto-open it

    // Deliberately NOT wm.autoConnect() here. That blocks for the full connect
    // timeout (~20 s with an absent router) without ever sampling the button,
    // which made the documented "hold 5 s to re-pair" escape hatch unusable
    // exactly when it is needed. We drive the connect ourselves so the button
    // is polled every 10 ms for the entire retry cycle, however long it lasts.
    // A 32-char SSID is stored without a NUL terminator, so bound the log.
    String ssid = wm.getWiFiSSID();
    if (ssid.length() > 32) ssid.remove(32);
    Serial.printf("[wifi] connecting to saved network \"%s\" — will retry until it answers\n",
                  ssid.c_str());

    for (uint32_t attempt = 1; ; attempt++) {
      WiFi.begin();                    // reuses the credentials stored in NVS
      if (waitForWifi(WIFI_CONNECT_TIMEOUT_S * 1000UL)) break;

      // Report what actually went wrong: a changed router password looks
      // nothing like an absent router, and only one of them is user-fixable.
      Serial.printf("[wifi] attempt %lu failed: %s — retrying in %lu s"
                    " (hold the button 5 s to re-pair)\n",
                    (unsigned long)attempt, wifiStatusName(WiFi.status()),
                    (unsigned long)(WIFI_BOOT_RETRY_MS / 1000));
      // Explicit args: never erase the stored AP, we want to retry it forever.
      WiFi.disconnect(/*wifioff=*/false, /*eraseap=*/false);
      waitForWifi(WIFI_BOOT_RETRY_MS); // same polled wait; keeps the button live
    }
  } else {
    // Nothing saved: first boot, or straight after a factory reset. There is
    // nothing to retry, so open the portal and leave it open with no timeout —
    // rebooting out of a portal nobody has configured yet achieves nothing.
    Serial.println("[wifi] no saved credentials — opening the pairing portal");
    wm.setConfigPortalTimeout(0);
    if (!wm.autoConnect(AP_NAME)) {
      Serial.println("[wifi] pairing portal exited without a connection — rebooting");
      delay(1000);
      ESP.restart();
    }
  }

  WiFi.setAutoReconnect(true);
  Serial.printf("[wifi] connected to \"%s\": %s (RSSI %d dBm)\n",
                WiFi.SSID().c_str(), WiFi.localIP().toString().c_str(), WiFi.RSSI());

  setLedMode(LED_SOLID);  // optimistic; first failed POSTs will downgrade it
  Serial.printf("[run] reporting every %lu ms as \"%s\" to \"%s\"\n",
                (unsigned long)REPORT_INTERVAL_MS, gDeviceId.c_str(),
                gServerUrl.isEmpty() ? "(server URL not set!)" : gServerUrl.c_str());
}

// ----------------------------------------------------------------------------
// loop() — fully non-blocking, millis()-based. No delay() in steady state.
// On a healthy LAN a POST returns in tens of milliseconds, well inside the 1 s
// interval; worst case with a dead server is ~1.4 s (0.7 s connect timeout plus
// 0.7 s read timeout back-to-back), which stretches the cadence slightly but
// never blocks the button/WiFi/LED handling for longer than one cycle. Late
// cycles are skipped rather than queued, so the pace self-corrects.
// ----------------------------------------------------------------------------
void loop() {
  uint32_t now = millis();

  handleButton(now);
  handleWifi(now);

  // Report on a fixed 1-second cadence.
  static uint32_t lastReportMs = 0;
  if (now - lastReportMs >= REPORT_INTERVAL_MS) {
    lastReportMs = now;
    readAndReport();
  }

  // LED state machine: recompute the desired mode from current status.
  // (Portal mode only exists inside setup(), handled by the AP callback.)
  if (WiFi.status() != WL_CONNECTED) {
    setLedMode(LED_BLINK_CONNECTING);
  } else if (gConsecutiveFailures >= FAILS_BEFORE_WARNING) {
    setLedMode(LED_BLINK_NO_SERVER);
  } else {
    setLedMode(LED_SOLID);
  }
}
