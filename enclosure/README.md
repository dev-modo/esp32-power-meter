# Enclosure

A 3D-printable box with a screw-on lid for the power meter.

![Box and lid](preview.png)

| | |
|---|---|
| **Outside** | 150 × 100 × 32 mm |
| **Inside** | 146 × 96 × 27 mm |
| **Walls / floor / lid** | 2 mm / 2 mm / 3 mm |
| **Fixings** | 8 × M3 self-tapping screws, 12 mm |
| **Supports** | none, either part |

> [!WARNING]
> **Read [Mains safety](#mains-safety) before you put this near mains wiring.**
> This is a bench and prototyping housing. It is not a certified mains
> enclosure, and **PLA must not be used for it.**

## Files

| File | What it is |
|---|---|
| [`enclosure.scad`](enclosure.scad) | The parametric source. Everything is a named variable at the top. |
| `box.stl` / `lid.stl` | Ready to slice, generated from the defaults. |
| [`test_variants.sh`](test_variants.sh) | Renders every optional configuration and checks each is still watertight. |

Re-export after changing anything:

```bash
openscad -D 'part="box"' -o box.stl enclosure.scad
openscad -D 'part="lid"' -o lid.stl enclosure.scad
./test_variants.sh          # 14 configurations, all must report manifold
```

## Why it is 32 mm tall and not 20

20 mm was the original target and the footprint is unchanged, but **the
PZEM-004T does not fit in it.** Its 5.08 mm-pitch screw terminals stand 10.0 mm
above the PCB, so the real stack is:

```
  5.0 mm   M3 standoff (clears the terminal's 3.7 mm pins underneath)
+ 1.6 mm   PCB
+ 10.0 mm  screw terminal block
= 16.6 mm  against a 16 mm cavity — over budget with zero room for wiring
```

Some vendors list the whole module at 16–18 mm tall, which would not fit even
sitting flat on the floor. A socketed ESP32 devkit is 13–18 mm as well. At
`outer_z = 32` the cavity is 27 mm, which takes both boards, a slack loop of
cable, and a gland with real material around it.

Using different hardware? Measure it and set `outer_z` — everything else
derives from it, and the file prints a warning if the cavity drops below 22 mm.

## Screws

**8 × M3 self-tapping, 12 mm.** Corners plus the midpoint of every wall — four
corner screws leave the lid unsupported across 146 mm and 96 mm spans, and it
bows enough to open the seam. Eight halves both spans and cuts deflection to
roughly 12%.

The pilot holes are **2.7 mm**, not the textbook 2.5 mm for M3, because 2.5
splits printed bosses on first assembly. Tune to your material:

| Material | `screw_pilot_d` |
|---|---|
| PLA | 2.8 |
| PETG / ABS / ASA | 2.6 |
| Nylon | 2.4 |

Hand-tighten to roughly 0.2 Nm with a hex or Torx driver. A Phillips cams out
and tempts you to lean on it; a power driver will strip the boss. If the box
will be opened often, use **M3 heat-set brass inserts** instead — set
`screw_pilot_d` to the insert bore (typically 4.0) and `boss_d` to 9.

## Printing

Both parts sit flat on the bed and need **no supports**.

> The lid is modelled lip-**up**, which is how it must print. Do not flip it
> lip-down — that suspends the whole 150 × 100 plate over the lip and needs
> full supports. Want a nicer outer face? Use a textured build plate.

| Setting | Value |
|---|---|
| Layer height | 0.2 mm (0.25 mm first layer, 20 mm/s) |
| Wall extrusion width | 0.50 mm |
| Wall loops | **5** for the box, 4 for the lid |
| Top / bottom solid layers | 5 / 4 |
| Infill | irrelevant — nothing in either part has any |
| Supports | off |
| Brim | 3 mm on the lid (cheap insurance); 5 mm for ABS |
| Seam position | aligned or rear, so it misses the lip's mating face |

Wall loops matter more than they look: at 4 × 0.50 mm the 2 mm wall comes out as
one continuous solid. Leave the default 0.45 mm width and you get gap-fill and a
sliver of infill inside a wall that should be solid.

The 150 × 100 mm footprint fits an Ender 3 (220²) and a Prusa MK3 (250 × 210),
but **not a Bambu A1 mini (180²)** diagonally-unfriendly — check before you slice.

If the lid binds, increase `lip_clear` (0.45 default, try 0.6). It tapers inward
as it rises so it self-centres, which forgives a little wall bow.

## Cable entries

Three holes at **12.5 mm** for **PG7 / M12×1.5 cable glands** — one in the left
end, two in the right. They are that size deliberately: 3-core 1.5 mm² mains
flex is 8.1 mm across, so it will not even pass an 8 mm hole, and 8 mm matches
no gland thread made. **A bare printed hole is not strain relief.**

| Gland | Hole | Cable range |
|---|---|---|
| PG7 / M12×1.5 | 12.5 mm | 3–6.5 mm |
| PG9 | 15.2 mm | 4–8 mm |
| M16×1.5 | 16.2 mm | 4–8 mm |
| PG11 | 18.6 mm | 5–10 mm |
| M20×1.5 | 20.2 mm | 6–12 mm |

Hole heights are set individually (`holes_x0` / `holes_x1` take `[y, dia, z]`),
so a USB opening can be aligned to the actual connector rather than drifting
whenever `outer_z` changes.

## Mounting your boards

`standoffs` is **empty by default** and that is deliberate — hole spacing varies
between PZEM-004T and ESP32 board revisions, and a standoff in the wrong place is
worse than none. Measure yours, then fill in `[x, y, height, outer_d, pilot_d]`.

One trap: an ESP32 devkit with its male headers still fitted has about **6 mm of
pin sticking out below the PCB**, so it needs a standoff of at least 7–8 mm. The
obvious 4 mm jams the pins into the floor.

`mount_ears = true` adds external wall-mounting tabs (this grows the footprint to
150 × 120). Never screw through the bare floor instead — it breaches the
enclosure and cracks the 2 mm base.

## Mains safety

The PZEM measures mains voltage, so live conductors enter this box. A review of
this design flagged the following, and the honest summary is:

**Use this printed box for bench work and prototyping. For a permanent,
unattended installation, put the electronics in an off-the-shelf ABS or PC
IP65 junction box** (UL 94 V-0, 960 °C glow-wire, moulded gland entries) — one
costs less than the filament, and the printed part can be reduced to an internal
mounting tray if you like.

If you do build it in plastic you printed yourself:

- **Never PLA.** Glass transition around 60 °C and it creeps under sustained
  screw preload. **PETG at minimum**; ABS/ASA is better; a UL 94 V-0 rated
  filament (PETG-FR, ABS-FR, PC-FR) is what the job actually calls for. Hobby
  filament carries no flammability, tracking or glow-wire rating at all.
- **Fuse the voltage tap.** An inline 500 mA–1 A **ceramic** HRC fuse, 250 V AC,
  in the live sense lead, as close to the tap as possible, in an enclosed
  holder. Ceramic specifically — a glass fuse lacks the breaking capacity. Feed
  from a fused spur or a 2 A MCB way, on a circuit behind a 30 mA RCD.
- **Separate mains from low voltage.** Set `divider = true` for a full-height
  barrier between the PZEM's terminals and the ESP32/LED/button, with a notch
  at the far edge for the UART wires. An undivided cavity puts live terminals in
  the same space as parts you can touch.
- **Use glands, not holes**, and add a slack loop inside so a tug on the cable
  cannot reach the terminal.
- **PZEM v3.0 or v4.0 only.** Older revisions lack opto-isolated TTL, which
  would put the ESP32 and its USB port at mains potential. Even on v3.0/v4.0 the
  isolation is *functional*, not safety-rated: never touch the ESP32, LED or
  button while mains is connected, and **never plug in USB while the mains side
  is live.** Flash and debug with mains fully disconnected.
- **Keep every metal part inaccessible.** The screw shafts pass into the cavity.
  Use nylon M3 screws, or raise `lid_t` to 3.5, enable `lid_counterbore` and plug
  the recesses. Plastic-bodied button and LED bezel, both on the low-voltage
  side. Nylon glands. This is a Class II design — do not try to earth a printed
  box.
- **Fix the boards down.** Nothing should be able to shift onto a live terminal.
  Keep `tie_slots = false` for any mains build; it pierces the floor.
- **The CT clamps one conductor only**, never live and neutral together. Do not
  open the clamp or unplug its lead while the conductor is carrying current.
- **Wall thickness.** For a mains build set `wall = 3` and `floor_t = 3`.
