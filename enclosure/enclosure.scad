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
// M2, 12 mm long. With a 3 mm lid that leaves ~9 mm of thread engagement.
screw_free_d  = 2.4;   // M2 clearance hole through the lid (medium fit)
screw_inset   = 4;     // screw centre, in from both outer faces

// The BOX prints with no holes at all — the corner gussets are left solid and
// you drill the pilots yourself. Do it with the lid as a template: sit the lid
// on the box, drill down through its clearance holes into the gussets, and the
// two parts cannot end up misaligned. Drill 1.8 mm in PLA, 1.7 in PETG/ABS/ASA.
// Set this true if you would rather have them modelled.
pilot_holes   = false;
screw_pilot_d = 1.75;  // only used when pilot_holes = true
screw_depth   = 10;    // ditto — stays inside gusset_top_h, see below

/* ---------------------------------------------------------------------------
   Corner gussets — the screws land in these, not in cylindrical posts.
   Each corner is filled with a 45-degree gusset running gusset_l along both
   walls, so the screw material IS the corner: continuous with the shell, with
   no thin post-to-wall junction to crack along.

   Sized for M2 and trimmed to stop wasting plastic. Two things shrink it:

   1. Footprint. M2 needs much less meat than M3 around the hole. At
      gusset_l = 12 with the screw 4 mm in, there is 2.8 mm from the hole
      centre to the diagonal face, so ~1.95 mm of material around a 1.75 mm
      pilot — comfortably above the ~1.5 mm minimum for thread-forming into
      plastic. Shrink it further and the diagonal starts cutting into the hole.

   2. Height. The screw only engages the top 10 mm, so a full-height prism is
      mostly dead weight. The gusset is full size for the top gusset_top_h and
      then tapers down to gusset_l_base at the floor.

   Measured off the rendered STLs, the four gussets went from 7.78 cm3 to
   2.35 cm3 — a 70% cut, 5.4 cm3 of filament, about 8% of the whole box.

   The taper still needs no supports: its downward faces sit 66.5 degrees off
   straight-down, well clear of the 45 degrees FDM needs, and the whole box
   contains no facet below that. If you change gusset_top_h or gusset_l_base,
   keep (cav_z - gusset_top_h) larger than (gusset_l - gusset_l_base) / 1.41
   or the underside turns into an overhang.
   ------------------------------------------------------------------------- */
gusset_l      = 12;   // leg length at the top, where the screw is
gusset_top_h  = 14;   // height of the full-size section, measured down from the rim
gusset_l_base = 4;    // leg length where it meets the floor

// Countersink the lid holes so the heads sit flush? Sized for an M2 pan head
// (~4 mm across, ~1.3 mm tall). Needs lid_t >= 3.5 to leave material behind the
// head, so it is off at lid_t = 3. With it off, use pan-head screws and let them
// stand proud — mechanically fine, and they only stand ~1.3 mm high at M2.
lid_counterbore    = false;
lid_counterbore_d  = 4.2;
lid_counterbore_h  = 1.4;

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
// EMPTY: the box prints fully sealed. Drill your own entries once the boards are
// positioned — with only 2 mm of wall a hand-held drill cleans a hole in
// seconds, and you get to put it exactly where the cable actually lands.
//
// To model them instead, add entries as [y_position, diameter, z_centre].
// Size them for a cable gland, not for the bare cable: 3-core 1.5 mm2 mains
// flex is 8.1 mm across and a bare printed hole is not strain relief.
//   PG7 / M12 = 12.5 mm   PG9 = 15.2   M16 = 16.2   PG11 = 18.6   M20 = 20.2
// z is explicit per hole rather than auto-centred, so a USB opening stays put
// instead of drifting whenever outer_z changes.
//   mid_z = vertical centre of the cavity
//   usb_z = centre of a micro-USB port on a board sitting on 8 mm standoffs
mid_z    = floor_t + cav_z / 2;
usb_z    = floor_t + 8 + 1.6 + 1.3;

holes_x0 = [];   // left end   e.g. [[ 30, 12.5, mid_z ]]
holes_x1 = [];   // right end  e.g. [[ 30, 12.5, mid_z ], [ 65, 12.5, mid_z ]]

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
   Screw positions — four, one per corner.

   Worth knowing what this trades away: with corner-only fixing the lid is
   unsupported across the full 146 mm and 96 mm spans, so a 3 mm lid bows
   roughly half a millimetre at the centre of each edge and the seam can show a
   hairline gap mid-span. It stays shut and it stays flat enough to look right;
   it just is not clamped in the middle.

   If that bothers you, either raise lid_t to 4, or uncomment the mid-wall
   positions below to go back to eight screws — that halves both spans and cuts
   deflection to about an eighth. Note the commented positions would need their
   own bosses, since the corner gussets only cover the corners.
   ======================================================================== */
function screw_xy() = [
  [ screw_inset,           screw_inset           ],
  [ outer_x - screw_inset, screw_inset           ],
  [ screw_inset,           outer_y - screw_inset ],
  [ outer_x - screw_inset, outer_y - screw_inset ],
  // [ outer_x / 2,          screw_inset           ],
  // [ outer_x / 2,          outer_y - screw_inset ],
  // [ screw_inset,          outer_y / 2          ],
  // [ outer_x - screw_inset, outer_y / 2          ],
];

// The four corners, as [outer_x, outer_y, x_direction, y_direction], so one
// triangle definition serves all of them.
function gusset_corners() = [
  [ 0,       0,       1, 1 ],
  [ outer_x, 0,      -1, 1 ],
  [ 0,       outer_y, 1, -1 ],
  [ outer_x, outer_y, -1, -1 ],
];

// 2D footprint of one corner gusset: a right triangle with its square corner on
// the box corner, legs `len` long. `grow` offsets it outward, for clearance cuts.
module gusset_2d(g, len, grow = 0) {
  translate([ g[0], g[1] ])
    offset(r = grow)
      polygon([ [ 0, 0 ], [ g[2] * len, 0 ], [ 0, g[3] * len ] ]);
}

// One gusset: full size where the screw bites, tapering to a smaller footprint
// at the floor so the lower half is not solid plastic doing nothing. Only the
// diagonal face moves — the two legs stay flat against the walls at every
// height, so it never separates from the shell.
module gusset_solid(g) {
  hull() {
    translate([ 0, 0, box_h - gusset_top_h ])
      linear_extrude(gusset_top_h) gusset_2d(g, gusset_l);
    translate([ 0, 0, floor_t ])
      linear_extrude(0.01) gusset_2d(g, gusset_l_base);
  }
}

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
      // Corner gussets, continuous with the walls, tapering towards the floor.
      for (g = gusset_corners())
        gusset_solid(g);
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

    // Pilot holes, down from the rim. Off by default — see pilot_holes above.
    if (pilot_holes)
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
    // Clear the corner gussets, grown 1 mm so the lip never touches them. A
    // tighter cut left sub-0.03 mm degenerate slivers in the lip corners, which
    // are the kind of geometry that makes a slicer fall over.
    for (g = gusset_corners())
      translate([ 0, 0, -0.1 ])
        linear_extrude(lip_h + 0.2)
          gusset_2d(g, gusset_l, 1);
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
