/* ============================================================================
   ESP32 Power Meter — enclosure
   Parametric box + screw-on lid for OpenSCAD.

   Render / export:
     openscad -D 'part="box"' -o box.stl enclosure.scad
     openscad -D 'part="lid"' -o lid.stl enclosure.scad
   Open the file and press F5 to see both laid out side by side.

   Both parts print flat on the bed with NO SUPPORTS. See PRINTING below for
   the one orientation rule that matters.

   ---------------------------------------------------------------------------
   WHY THIS IS 32 mm TALL AND NOT 20 mm
   ---------------------------------------------------------------------------
   20 mm was the original target, and the footprint is unchanged at 150 x 100.
   But the PZEM-004T does not fit in it. Its 5.08 mm-pitch screw terminals
   stand 10.0 mm above the PCB, so the real stack is

       5.0 mm standoff + 1.6 mm PCB + 10.0 mm terminal block = 16.6 mm

   against a 16 mm cavity — over budget before a single wire is routed, and
   some vendors list the whole module at 16-18 mm tall, which would not fit
   even sitting straight on the floor. A socketed ESP32 devkit is 13-18 mm too.

   outer_z = 32 gives a 26 mm cavity: comfortable for both boards, a slack
   loop of mains cable, and a cable gland that has real material to bite into.
   If you are using different hardware, measure it and set outer_z yourself —
   everything else derives from it.
   ========================================================================= */

// ----------------------------------------------------------------- parts ----
// "box", "lid", or "both" (both = preview layout only, do not export it)
part = "both";

// ------------------------------------------------------------ dimensions ----
outer_x   = 150;  // length, outside
outer_y   = 100;  // width, outside
outer_z   = 32;   // TOTAL height including the lid — see note above
wall      = 2;    // side wall thickness  (use 3 for a mains build)
floor_t   = 2;    // base thickness       (use 3 for a mains build)
lid_t     = 3;    // lid thickness — 3 not 2, see the lid stiffness note

// Derived. box + lid == outer_z, so the lid never adds height on top.
box_h     = outer_z - lid_t;
cav_x     = outer_x - 2 * wall;
cav_y     = outer_y - 2 * wall;
cav_z     = box_h - floor_t;      // usable internal height

// Shout if the cavity gets too shallow for the hardware this project uses.
// echo() rather than assert() so you can still build a deliberately small box.
CAV_Z_MIN = 22;
if (cav_z < CAV_Z_MIN)
  echo(str("WARNING: internal height is only ", cav_z,
           " mm. A PZEM-004T needs ~17 mm before wiring. Raise outer_z to at least ",
           CAV_Z_MIN + floor_t + lid_t, "."));

// ----------------------------------------------------------------- screws ---
// M3 thread-forming screws, 12 mm long, into printed bosses.
// PILOT SIZE MATTERS: 2.5 mm is the textbook figure for M3 but it splits
// printed PLA bosses on first assembly. 2.7 is a safe middle ground.
//   PLA 2.8   |   PETG / ABS / ASA 2.6   |   nylon 2.4
// Better still, use M3 heat-set brass inserts (4.6 mm OD): set screw_pilot_d
// to your insert's bore (typically 4.0) and boss_d to 9.
screw_pilot_d = 2.7;
screw_free_d  = 3.3;   // clearance hole through the lid
boss_d        = 7;     // outside diameter of the screw posts
screw_depth   = 12;    // depth of the pilot hole

// Screw centres this far in from the outer faces. Chosen so each boss overlaps
// its wall by 0.5 mm and fuses into one solid, rather than leaving a hairline
// gap that prints as a weak seam.
boss_inset    = wall + boss_d / 2 - 0.5;

// Countersink the lid holes so the heads sit flush? Needs lid_t >= 3.5 to
// leave material behind the head, so it is off at lid_t = 3. With it off, use
// pan-head screws and let them stand proud — mechanically fine.
lid_counterbore    = false;
lid_counterbore_d  = 6.0;
lid_counterbore_h  = 1.2;

// ------------------------------------------------------------------- lid ----
// A shallow lip on the underside that drops into the opening: it locates the
// lid while you start the screws and closes the seam against dust.
lid_lip       = true;
lip_h         = 1.5;   // how far it protrudes into the box
lip_w         = 1.2;   // its wall thickness
// 0.45, not 0.3. An FDM wall bulges inward and a lip bulges outward; at 0.3 the
// two cancel and the lip binds. 0.5 if your XY compensation is uncalibrated.
lip_clear     = 0.45;
lip_taper     = 0.5;   // outer face narrows going up, so the lip self-centres

// ---------------------------------------------------------- cable entries ---
// Holes through the two short ends, as [y_position, diameter, z_centre].
// Sized 12.5 mm for PG7 / M12x1.5 cable glands, NOT bare 8 mm holes: 3-core
// 1.5 mm2 mains flex is 8.1 mm across, so it would not even pass an 8 mm hole,
// and 8 mm matches no gland thread. A bare hole is not strain relief.
//   PG7 / M12 = 12.5 mm   PG9 = 15.2   M16 = 16.2   PG11 = 18.6   M20 = 20.2
// z is explicit per hole rather than auto-centred, so a USB opening can be
// aligned to the actual connector height instead of drifting with outer_z.
usb_z    = floor_t + 8 + 1.6 + 1.3;   // 8 mm standoff + PCB + half connector
mid_z    = floor_t + cav_z / 2;

holes_x0 = [[ 30, 12.5, mid_z ]];                  // left end:  low-voltage / DC in
holes_x1 = [[ 30, 12.5, mid_z ], [ 65, 12.5, mid_z ]];  // right end: mains sense, CT lead

// ------------------------------------------------- mains / SELV divider -----
// A full-height barrier separating the PZEM's mains terminals from the ESP32,
// LED and button. Strongly recommended for any build with mains inside — a
// 3D-printed box is not a certified enclosure, and an undivided cavity puts
// live terminals and touchable low-voltage parts in the same space.
// Off by default only because the right position depends on your layout.
divider       = false;
divider_x     = 60;   // barrier centreline; mains zone is x < divider_x
divider_t     = 3;
divider_notch_w = 8;  // pass-through for the 4 UART/5 V wires
divider_notch_h = 6;
divider_notch_y = 88; // keep it far from the mains parts

// ------------------------------------------------------- board mounting -----
// Standoffs to screw your PCBs onto, as [x, y, height, outer_d, pilot_d].
// Left EMPTY on purpose: hole spacing varies between PZEM-004T and ESP32 board
// revisions, and a standoff in the wrong place is worse than none. Measure your
// boards and fill this in.
//
// NOTE ON HEIGHT: an ESP32 devkit with its male headers still fitted has ~6 mm
// of pin protruding below the PCB, so it needs a standoff of at least 7-8 mm,
// not the 4 mm you might reach for. The PZEM's terminal pins stick out 3.7 mm.
// Example, a board with 70 x 38 mm hole spacing, corner at (12, 20):
//   standoffs = [[12,20,8,6,2.2],[82,20,8,6,2.2],[12,58,8,6,2.2],[82,58,8,6,2.2]];
standoffs = [];

// External wall-mounting tabs. Off by default because they grow the footprint
// past the 150 x 100 you asked for (to 150 x 120). Never screw through the
// bare floor instead — it breaches the enclosure and cracks the 2 mm base.
mount_ears  = false;
ear_w       = 14;
ear_d       = 10;
ear_t       = 3;
ear_hole_d  = 4.5;
ear_x       = [ 25, 125 ];

// Zip-tie slots in the floor — mounting that works whatever the hole spacing.
// They PIERCE the floor, so keep them off for any mains build.
tie_slots     = false;
tie_slot_w    = 3;
tie_slot_l    = 10;
tie_slot_gap  = 20;
tie_positions = [[ 40, 50 ], [ 110, 50 ]];

$fn = 48;

/* ==========================================================================
   Screw positions — EIGHT, not four.
   Corners, plus the mid-point of every wall. Four corner screws leave a 2-3 mm
   lid unsupported across 146 mm and 96 mm spans; it bows and the seam gaps.
   Eight halves both spans and cuts deflection to ~12%.
   The mid-short-wall bosses at y = outer_y/2 are clear of the cable holes.
   ======================================================================== */
function screw_xy() = [
  [ boss_inset,           boss_inset           ],
  [ outer_x - boss_inset, boss_inset           ],
  [ boss_inset,           outer_y - boss_inset ],
  [ outer_x - boss_inset, outer_y - boss_inset ],
  [ outer_x / 2,          boss_inset           ],
  [ outer_x / 2,          outer_y - boss_inset ],
  [ boss_inset,           outer_y / 2          ],
  [ outer_x - boss_inset, outer_y / 2          ],
];

/* ------------------------------------------------------------------ box --- */
module box() {
  difference() {
    union() {
      // Shell.
      difference() {
        cube([ outer_x, outer_y, box_h ]);
        translate([ wall, wall, floor_t ])
          cube([ cav_x, cav_y, cav_z + 1 ]);   // +1: the top is fully open
      }
      // Screw bosses, floor to rim.
      for (p = screw_xy())
        translate([ p[0], p[1], floor_t ])
          cylinder(d = boss_d, h = cav_z);
      // Optional mains/SELV barrier, full height so the lid closes onto it.
      if (divider)
        translate([ divider_x - divider_t / 2, wall, floor_t ])
          cube([ divider_t, cav_y, cav_z ]);
      // Optional PCB standoffs.
      for (s = standoffs)
        translate([ s[0], s[1], floor_t ])
          cylinder(d = s[3], h = s[2]);
      // Optional wall-mount ears, flush with the bottom face.
      if (mount_ears)
        for (x = ear_x) {
          translate([ x - ear_w / 2, -ear_d, 0 ])       cube([ ear_w, ear_d, ear_t ]);
          translate([ x - ear_w / 2, outer_y, 0 ])      cube([ ear_w, ear_d, ear_t ]);
        }
    }

    // Pilot holes, down from the rim.
    for (p = screw_xy())
      translate([ p[0], p[1], box_h - screw_depth ])
        cylinder(d = screw_pilot_d, h = screw_depth + 0.1);

    // Standoff pilot holes.
    for (s = standoffs)
      translate([ s[0], s[1], floor_t + s[2] - 8 ])
        cylinder(d = s[4], h = 8 + 0.1);

    // Cable entries.
    for (h = holes_x0)
      translate([ -0.1, h[0], h[2] ]) rotate([ 0, 90, 0 ])
        cylinder(d = h[1], h = wall + 0.2);
    for (h = holes_x1)
      translate([ outer_x - wall - 0.1, h[0], h[2] ]) rotate([ 0, 90, 0 ])
        cylinder(d = h[1], h = wall + 0.2);

    // Wire pass-through in the barrier.
    if (divider)
      translate([ divider_x - divider_t / 2 - 0.1,
                  divider_notch_y - divider_notch_w / 2,
                  box_h - divider_notch_h ])
        cube([ divider_t + 0.2, divider_notch_w, divider_notch_h + 0.1 ]);

    // Ear through-holes.
    if (mount_ears)
      for (x = ear_x) {
        translate([ x, -ear_d / 2, -0.1 ])          cylinder(d = ear_hole_d, h = ear_t + 0.2);
        translate([ x, outer_y + ear_d / 2, -0.1 ]) cylinder(d = ear_hole_d, h = ear_t + 0.2);
      }

    // Zip-tie slots.
    if (tie_slots)
      for (t = tie_positions)
        for (dx = [ -tie_slot_gap / 2, tie_slot_gap / 2 ])
          translate([ t[0] + dx - tie_slot_w / 2, t[1] - tie_slot_l / 2, -0.1 ])
            cube([ tie_slot_w, tie_slot_l, floor_t + 0.2 ]);
  }
}

/* ------------------------------------------------------------------ lid ---
   PRINTING: modelled in print orientation — flat outer face on the bed, lip
   pointing UP. Print it exactly like this. Do NOT flip it lip-down: that puts
   the whole 150 x 100 plate in mid-air over the lip and needs full supports.
   If you want a nicer outer face, use a textured build plate, not a flip.
   ------------------------------------------------------------------------ */
module lid() {
  difference() {
    union() {
      cube([ outer_x, outer_y, lid_t ]);
      if (lid_lip)
        translate([ 0, 0, lid_t ]) lip();
    }

    for (p = screw_xy()) {
      translate([ p[0], p[1], -0.1 ])
        cylinder(d = screw_free_d, h = lid_t + lip_h + 0.2);
      if (lid_counterbore)
        translate([ p[0], p[1], -0.1 ])
          cylinder(d = lid_counterbore_d, h = lid_counterbore_h + 0.1);
    }
  }
}

// The locating lip: a thin frame that drops into the cavity, tapered inward as
// it rises so it self-centres, with the screw bosses cut away so it clears them.
module lip() {
  ox = wall + lip_clear;                 // outer offset from the box outside
  lx = cav_x - 2 * lip_clear;            // lip outer footprint
  ly = cav_y - 2 * lip_clear;
  difference() {
    // Tapered outer body. The taper narrows going UP, so printed lip-up it
    // introduces no overhang and costs nothing.
    hull() {
      translate([ ox, oy_(), 0 ]) cube([ lx, ly, 0.01 ]);
      translate([ ox + lip_taper, oy_() + lip_taper, lip_h - 0.01 ])
        cube([ lx - 2 * lip_taper, ly - 2 * lip_taper, 0.01 ]);
    }
    // Hollow it out.
    translate([ ox + lip_w, oy_() + lip_w, -0.1 ])
      cube([ lx - 2 * lip_w, ly - 2 * lip_w, lip_h + 0.2 ]);
    // Clear every boss. Radius is boss_d/2 + 1, not + lip_clear: at the tight
    // clearance the cut left 0.028 mm slivers of geometry in the lip corners,
    // which are degenerate and can crash a slicer. +1 mm removes them cleanly.
    for (p = screw_xy())
      translate([ p[0], p[1], -0.1 ])
        cylinder(d = boss_d + 2, h = lip_h + 0.2);
  }
}
function oy_() = wall + lip_clear;

/* ----------------------------------------------------------------- output -- */
if (part == "box")      box();
else if (part == "lid") lid();
else {
  box();
  translate([ 0, outer_y + 15, 0 ]) lid();
}
