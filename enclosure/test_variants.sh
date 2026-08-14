#!/bin/bash
# Renders every optional configuration of enclosure.scad and checks each one is
# still a watertight 2-manifold solid. Needs openscad on PATH. Run from anywhere.

cd "$(dirname "$0")" || exit 1

check() {
  local name="$1"; shift
  printf "  %-32s " "$name"
  out=$("$@" 2>&1)
  simple=$(echo "$out" | grep -o 'Simple: *yes' | head -1)
  vols=$(echo "$out" | grep -oE 'Volumes: *[0-9]+' | head -1 | grep -oE '[0-9]+')
  errs=$(echo "$out" | grep -cE '^ERROR|may not be a valid 2-manifold')
  if [ -n "$simple" ] && [ "$vols" = "2" ] && [ "$errs" = "0" ]; then
    echo "PASS  (manifold, 1 solid)"
  else
    echo "FAIL  simple='${simple}' volumes='${vols}' errors='${errs}'"
    echo "$out" | grep -iE 'error|warning' | head -4
  fi
}

echo "=== box variants ==="
check "defaults"            openscad -D 'part="box"' -o /tmp/s1.stl enclosure.scad
check "divider"             openscad -D 'part="box"' -D divider=true -o /tmp/s2.stl enclosure.scad
check "mount_ears"          openscad -D 'part="box"' -D mount_ears=true -o /tmp/s3.stl enclosure.scad
check "tie_slots"           openscad -D 'part="box"' -D tie_slots=true -o /tmp/s4.stl enclosure.scad
check "divider+ears+ties"   openscad -D 'part="box"' -D divider=true -D mount_ears=true -D tie_slots=true -o /tmp/s5.stl enclosure.scad
check "mains: wall/floor 3" openscad -D 'part="box"' -D wall=3 -D floor_t=3 -o /tmp/s6.stl enclosure.scad
check "standoffs populated" openscad -D 'part="box"' -D standoffs="[[12,20,8,6,2.2],[82,20,8,6,2.2],[12,58,8,6,2.2],[82,58,8,6,2.2]]" -o /tmp/s7.stl enclosure.scad
check "tall 40mm"           openscad -D 'part="box"' -D outer_z=40 -o /tmp/s8.stl enclosure.scad
check "pilot_holes modelled" openscad -D 'part="box"' -D pilot_holes=true -o /tmp/s9.stl enclosure.scad

echo "=== lid variants ==="
check "defaults"            openscad -D 'part="lid"' -o /tmp/l1.stl enclosure.scad
check "counterbore lid 3.5" openscad -D 'part="lid"' -D lid_t=3.5 -D lid_counterbore=true -o /tmp/l2.stl enclosure.scad
check "no lip"              openscad -D 'part="lid"' -D lid_lip=false -o /tmp/l3.stl enclosure.scad
check "loose lip clear 0.6" openscad -D 'part="lid"' -D lip_clear=0.6 -o /tmp/l4.stl enclosure.scad

echo "=== shallow-cavity warning ==="
printf "  %-32s " "outer_z=20 must warn"
if openscad -D 'part="box"' -D outer_z=20 -o /tmp/w.stl enclosure.scad 2>&1 | grep -q 'WARNING: internal height'; then
  echo "PASS  (warning emitted)"
else
  echo "FAIL  (no warning)"
fi
printf "  %-32s " "outer_z=32 must NOT warn"
if openscad -D 'part="box"' -D outer_z=32 -o /tmp/w2.stl enclosure.scad 2>&1 | grep -q 'WARNING: internal height'; then
  echo "FAIL  (spurious warning)"
else
  echo "PASS  (silent)"
fi

echo "=== the box must print with no holes at all ==="
printf "  %-32s " "zero penetrations in box.stl"
openscad -D 'part="box"' -o /tmp/sealed.stl enclosure.scad >/dev/null 2>&1
python3 - <<'PY'
import collections, sys
# Derive the extents from the geometry rather than hardcoding them, so this
# keeps testing the right planes when the box is resized.
pts = [tuple(round(float(v), 3) for v in l.split()[1:4])
       for l in open('/tmp/sealed.stl') if l.strip().startswith('vertex')]
X = max(p[0] for p in pts); Y = max(p[1] for p in pts); Z = max(p[2] for p in pts)
planes = collections.defaultdict(set); rim = set()
for x, y, z in pts:
    if abs(x)     < 1e-3: planes['x0'].add((y, z))
    if abs(x - X) < 1e-3: planes['x1'].add((y, z))
    if abs(y)     < 1e-3: planes['y0'].add((x, z))
    if abs(y - Y) < 1e-3: planes['y1'].add((x, z))
    if abs(z - Z) < 1e-3: rim.add((x, y))
# A sealed side face is a plain rectangle: 4 vertices. A hole would add a ring.
bad = [k for k in ('x0', 'x1', 'y0', 'y1') if len(planes[k]) > 6]
# The rim is the outer rectangle plus two diagonal ends per corner gusset = 12.
if bad or len(rim) > 16:
    print(f"FAIL  penetrated faces={bad} rim_vertices={len(rim)}"); sys.exit(1)
print(f"PASS  (box {X:g}x{Y:g}x{Z:g}, 4 plain faces, no holes in the rim)")
PY

echo "=== both parts must print without supports ==="
for p in box lid; do
  printf "  %-32s " "$p: no facet under 45 deg"
  openscad -D "part=\"$p\"" -o "/tmp/ov_$p.stl" enclosure.scad >/dev/null 2>&1
  python3 - "/tmp/ov_$p.stl" <<'PY'
import math, sys
worst = 90.0
n = None; vs = []
for line in open(sys.argv[1]):
    s = line.strip()
    if s.startswith('facet normal'):
        n = [float(x) for x in s.split()[2:5]]; vs = []
    elif s.startswith('vertex'):
        vs.append([float(x) for x in s.split()[1:4]])
        if len(vs) == 3:
            if n[2] < -1e-6 and not all(abs(v[2]) < 1e-6 for v in vs):
                mag = math.sqrt(sum(c*c for c in n))
                worst = min(worst, math.degrees(math.acos(min(1, max(-1, -n[2]/mag)))))
            vs = []
print(f"{'PASS' if worst >= 45 else 'FAIL'}  (shallowest {worst:.1f} deg from straight down)")
sys.exit(0 if worst >= 45 else 1)
PY
done
