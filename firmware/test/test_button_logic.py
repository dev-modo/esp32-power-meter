"""
Regression test for handleButton() in ../src/main.cpp.

Run it with:  python3 firmware/test/test_button_logic.py     (no dependencies)

Why this exists
---------------
The factory-reset button is the only way back into pairing mode, so it has to be
exactly right in both directions: a real 5-second hold must always work, and
nothing else may ever trigger it. An earlier version of the firmware got this
wrong twice at once, because it serviced the button only in 5-second islands
around a ~20-second blocking wm.autoConnect() call:

  * a real hold could never complete, since the polling window was exactly
    BUTTON_HOLD_MS long and the debounce latch consumed the first 30 ms; and
  * a brief tap during the blind gap looked like a finished multi-second hold
    and wiped the WiFi credentials.

Neither is visible in a compiler and neither is cheap to catch on hardware, so
the state machine is mirrored here and driven through the awkward cases. The
logic below is a line-by-line port -- keep it in sync when main.cpp changes.
uint32_t arithmetic is emulated with explicit masking so the 49.7-day millis()
rollover is genuinely exercised rather than assumed.
"""

M32 = 0xFFFFFFFF

BUTTON_HOLD_MS = 5000
BUTTON_DEBOUNCE_MS = 30
BUTTON_STARVE_MS = 250


def u32(x):
    return x & M32


class Btn:
    """handleButton()'s static state."""

    def __init__(self):
        self.debounced = False
        self.lastRaw = False
        self.lastEdgeMs = 0
        self.pressStart = 0
        self.lastCallMs = 0
        self.everCalled = False
        self.fired_at = None
        self.resyncs = 0

    def handle(self, now, raw):
        """Verbatim port. `now` is a uint32 millis() value, `raw` the pin state."""
        if self.fired_at is not None:
            return  # factoryReset() does not return (device reboots)

        # --- starvation resync ---
        if self.everCalled and u32(now - self.lastCallMs) > BUTTON_STARVE_MS:
            self.resyncs += 1
            self.debounced = False
            self.lastRaw = raw
            self.lastEdgeMs = now
            self.pressStart = now
        self.lastCallMs = now
        self.everCalled = True

        # --- edge -> restart debounce timer ---
        if raw != self.lastRaw:
            self.lastRaw = raw
            self.lastEdgeMs = now

        # --- accept state once stable ---
        if raw != self.debounced and u32(now - self.lastEdgeMs) >= BUTTON_DEBOUNCE_MS:
            self.debounced = raw
            if self.debounced:
                self.pressStart = now

        # --- hold expiry; `raw` must STILL be down (the fix) ---
        if self.debounced and raw and u32(now - self.pressStart) >= BUTTON_HOLD_MS:
            self.fired_at = now


results = {"pass": 0, "fail": 0}


def run(name, duration, polled, pin_down, expect_fire, start=0):
    b = Btn()
    for dt in range(duration):
        now = u32(start + dt)
        if polled(dt):
            b.handle(now, pin_down(dt))
        if b.fired_at is not None:
            break
    fired = b.fired_at is not None
    ok = fired == expect_fire
    results["pass" if ok else "fail"] += 1
    when = f"fired at +{u32(b.fired_at - start)} ms" if fired else "no fire"
    extra = f", {b.resyncs} resync(s)" if b.resyncs else ""
    print(f"  {'PASS' if ok else 'FAIL'}  {name:<58} {when}{extra}")


# The FIXED call schedule: waitForWifi() polls every 10 ms continuously for the
# whole retry cycle, so there is no blind gap at all.
poll10 = lambda t: t % 10 == 0

print("\n== FIXED schedule: continuous 10 ms polling (waitForWifi drives connect) ==")
run("genuine 5 s hold -> MUST fire", 12000, poll10, lambda t: t >= 1000, True)
run("hold 4.9 s then release -> must NOT fire", 12000, poll10,
    lambda t: 1000 <= t < 5900, False)
run("brief 200 ms tap -> must NOT fire", 12000, poll10,
    lambda t: 1000 <= t < 1200, False)
run("10 repeated taps -> must NOT fire", 12000, poll10,
    lambda t: (t // 300) % 2 == 1 and t < 6000, False)
run("30 ms contact bounce then steady hold -> MUST fire", 12000, poll10,
    lambda t: False if t < 1000 else ((t % 8) < 4 if t < 1030 else True), True)
run("never pressed -> must NOT fire", 12000, poll10, lambda t: False, False)
run("press, release at 4.9s, press again -> must NOT fire early", 12000, poll10,
    lambda t: (1000 <= t < 5900) or (6000 <= t < 8000), False)

print("\n== millis() rollover (start at 0xFFFFF000, wraps ~4 s in) ==")
NEAR = 0xFFFFF000
run("5 s hold across the wrap -> MUST fire", 12000, poll10,
    lambda t: t >= 1000, True, NEAR)
run("brief tap across the wrap -> must NOT fire", 12000, poll10,
    lambda t: 1000 <= t < 1200, False, NEAR)
run("hold 4.9s then release across the wrap -> must NOT fire", 12000, poll10,
    lambda t: 1000 <= t < 5900, False, NEAR)

print("\n== starvation: 20 s blind gaps (models the OLD autoConnect schedule) ==")
# 5 s polled, then 20 s blind, repeating -- what the code did BEFORE this fix.
# These two cases document the original bug in both directions, and confirm the
# hardened handleButton() no longer false-fires even on that broken schedule.
starved = lambda t: (t % 25000) < 5000 and t % 10 == 0
run("tap during blind gap -> no false reset (pre-fix: DID fire)", 60000, starved,
    lambda t: 8000 <= t < 8200, False)
# Reproduces the original defect: with a 5 s poll window equal to BUTTON_HOLD_MS,
# even a permanently held button can never complete a hold. This is exactly why
# the connect had to stop being delegated to wm.autoConnect().
run("sustained hold on old schedule -> never fires (the bug)", 60000,
    starved, lambda t: t >= 8000, False)

print(f"\n{results['pass']} passed, {results['fail']} failed\n")
raise SystemExit(1 if results["fail"] else 0)
