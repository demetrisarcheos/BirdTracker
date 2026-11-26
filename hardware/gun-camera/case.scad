// Bird Tracker gun camera: cylindrical case, tight version.
//
// Three printed parts:
//   tube : the shell. Closed front with the lens window, two barrel saddles underneath.
//   tray : one rigid frame holding the camera, the Pi + PiSugar stack and the motion sensor.
//          It slides in from the back on the tube's flat floor (it cannot turn).
//   cap  : rear cover with the USB-C opening. Two screws pull cap and tray together, which
//          clamps the tray against the front wall. Recoil pushes the parts forward into
//          that wall, not into the screws.
//
// Units: mm. The X axis runs along the tube: front outer face at x = 0, rear end negative.
// Y is up, Z is across. The tube axis is y = z = 0, and the Pi board's underside sits at y = 0.
//
// Values marked MEASURE come from datasheets or estimates. Check them on the real parts
// before printing; everything else follows from them.
//
// Render one part:   openscad -o tube.stl -D 'part="tube"' case.scad
// Parts: "tube", "tray", "cap" (each in print orientation), "all" (assembly preview).

part = "all";

$fn = 96;

// ---------- general ----------
clr     = 0.4;            // sliding clearance between tray and tube
wall    = 2.0;
r_in    = 18.5;           // bore radius (36.9 mm parts envelope + clearance)
r_out   = r_in + wall;    // 41 mm outer diameter
floor_y = -16;            // flat floor inside the tube: keys the tray against turning

// ---------- camera: Raspberry Pi Camera Module 3, standard lens ----------
// Mounted upside down so the ribbon leaves the top edge (the Pi software flips the picture).
cam_w = 25;  cam_h = 24;
cam_depth      = 11.5;    // board back to lens front                       MEASURE
lens_y         = -2;      // lens centre height (below the axis to fit the circle)
lens_from_edge = 9.5;     // lens centre to the board edge without connector MEASURE
cam_hole_z     = 10.5;    // mounting holes ± from the lens centre (21 mm)   MEASURE
cam_hole_rows  = [2, 14.5]; // hole rows from the edge without connector    MEASURE
lens_gap   = 0.5;         // lens front to the inside of the front wall
front_wall = 2.0;
window_d   = 9.0;         // through hole in front of the lens
cover_d    = 12.4;        // recess for an optional 12 × 1 mm clear disc
cover_depth = 1.0;
standoff   = 2.0;         // camera board to bulkhead plate
bulk_t     = 2.0;
ribbon_gap = 3.0;         // bulkhead to the Pi's front edge (ribbon fold)

// ---------- Pi Zero 2 W + PiSugar 3 stack ----------
pi_l = 65;  pi_w = 30;  pi_t = 1.4;
pi_hole_x  = 3.5;         // holes 3.5 mm in from the ends (58 mm apart)
pi_hole_z  = 11.5;        // ± across (23 mm apart)
sugar_drop = 4.2;         // Pi underside to PiSugar board underside       MEASURE
sugar_t    = 1.2;
batt_t     = 6.0;         // battery thickness under the PiSugar            MEASURE
batt_l     = 50;          // battery length                                MEASURE
heatsink_h = 3.0;         // keep the heatsink this low (sensor above it)
sd_out     = 2.0;         // microSD card sticking out of the Pi's rear end
post_d     = 5.5;

// ---------- motion sensor: Adafruit BNO085 (25.4 × 17.8 mm) ----------
// Lies flat above the Pi, on a rail along the side away from the GPIO header.
imu_l = 25.4;  imu_w = 17.8;
imu_x_front = -23;        // front edge of the sensor
imu_z_edge  = -14;        // the sensor's outer long edge
imu_hole_in = 2.54;       // hole centres from the board edges              MEASURE
imu_hole_dx = 20.3;       // hole spacing along the board                   MEASURE
beam_y0 = 5.5;  beam_y1 = 9.0;    // rail: clears the Pi's ports, sensor sits on top
beam_z0 = -15.5; beam_z1 = -9.5;

// ---------- rear ----------
hoop_len  = 2.0;          // tray's rear ring
hoop_r_in = 13.0;
cap_t     = 2.0;
usb_y = -6;  usb_z = 0;   // PiSugar USB-C port centre                      MEASURE
usb_w = 9.6; usb_h = 3.8;
btn_y = -6;  btn_z = 10;  // PiSugar power button (pressed through a pin)   MEASURE
btn_d = 3.2;
led_y = -6;  led_z = -9;  // PiSugar charge LED window                      MEASURE
led_d = 2.0;
cap_screws = [[-13.5, 0], [15.5, 0]];   // [y, z], M2.5 × 8 self-tapping into the tray

// ---------- barrel mount ----------
barrel_d     = 19;        // barrel outside diameter where the saddles sit  MEASURE
pad_t        = 1.0;       // rubber pad in the groove
saddle_x     = [-22, -68];
saddle_l     = 16;        // along the barrel
saddle_w     = 24;
saddle_h     = 7;
groove_depth = 3;
strap_w      = 13;        // for 12 mm hook-and-loop straps
strap_t      = 2.5;

// ---------- vents (over the Pi's processor) ----------
vent_x0 = -44;  vent_n = 4;  vent_pitch = 5;  vent_w = 1.6;  vent_len = 10;  vent_angle = 55;

// ---------- derived positions along the tube ----------
x_lens_front = -(front_wall + lens_gap);
x_cam_back   = x_lens_front - cam_depth;
x_bulk_front = x_cam_back - standoff;
x_bulk_back  = x_bulk_front - bulk_t;
x_pi_front   = x_bulk_back - ribbon_gap;
x_pi_rear    = x_pi_front - pi_l;
x_tube_end   = x_pi_rear - sd_out - 0.5;
x_pi_mid     = (x_pi_front + x_pi_rear) / 2;
x_post_f     = x_pi_front - pi_hole_x;
x_post_r     = x_pi_rear + pi_hole_x;
cam_bottom   = lens_y - lens_from_edge;
batt_bottom  = -(sugar_drop + batt_t);
spine_top    = batt_bottom - 0.3;
bar_top      = -(sugar_drop + sugar_t + 2.5);
groove_r     = barrel_d / 2 + pad_t + 0.3;
groove_cy    = -(r_out + saddle_h) - groove_r + groove_depth;

echo(str("Outer diameter ", 2 * r_out, " mm, length ", -x_tube_end + cap_t, " mm (without saddles)"));

// Extrude a 2D shape drawn in (z, y) along +X, from x0 for len.
module ax(x0, len) translate([x0, 0, 0]) rotate([0, 90, 0]) linear_extrude(len) mirror([1, 0]) children();

// Bore cross-section: circle with the flat floor.
module bore2d(r) intersection() { circle(r); translate([-50, floor_y]) square(100); }

// Cylinder along +X.
module xcyl(x0, y, z, d, len) translate([x0, y, z]) rotate([0, 90, 0]) cylinder(d = d, h = len);

// Cylinder along +Y.
module ycyl(x, y0, z, d, len) translate([x, y0, z]) rotate([-90, 0, 0]) cylinder(d = d, h = len);

// ---------- tube ----------
module saddle(xs) {
    difference() {
        translate([xs - saddle_l / 2, -(r_out + saddle_h), -saddle_w / 2])
            cube([saddle_l, saddle_h + 4, saddle_w]);
        xcyl(xs - saddle_l, groove_cy, 0, 2 * groove_r, 2 * saddle_l);
    }
}

module tube() {
    difference() {
        union() {
            ax(x_tube_end, -x_tube_end) circle(r_out);
            for (xs = saddle_x) saddle(xs);
        }
        ax(x_tube_end - 1, -x_tube_end - front_wall + 1) bore2d(r_in);
        xcyl(-front_wall - 1, lens_y, 0, window_d, front_wall + 2);
        xcyl(-cover_depth, lens_y, 0, cover_d, cover_depth + 1);
        for (a = [-1, 1], i = [0 : vent_n - 1])
            rotate([a * vent_angle, 0, 0])
                translate([vent_x0 - i * vent_pitch - vent_w / 2, r_in - 1, -vent_len / 2])
                    cube([vent_w, wall + 2, vent_len]);
        for (xs = saddle_x)
            translate([xs - strap_w / 2, -(r_in + 0.5) - strap_t, -30]) cube([strap_w, strap_t, 60]);
    }
}

// ---------- tray ----------
module tray() {
    difference() {
        union() {
            intersection() {
                ax(x_tube_end, -front_wall - 0.2 - x_tube_end) bore2d(r_in - clr);
                union() {
                    // spine along the floor
                    translate([x_tube_end, floor_y, -8]) cube([x_bulk_back - x_tube_end + 0.01, spine_top - floor_y, 16]);
                    // cross bars and posts under the PiSugar's holes
                    for (xc = [x_post_f, x_post_r]) {
                        translate([xc - 3, floor_y, -20]) cube([6, bar_top - floor_y, 40]);
                        for (s = [-1, 1]) ycyl(xc, floor_y, s * pi_hole_z, post_d, -sugar_drop - floor_y);
                    }
                    // rear ring
                    ax(x_tube_end, hoop_len) difference() { circle(50); circle(hoop_r_in); }
                    // boss for the upper cap screw (above the Pi's rear end, behind the header)
                    xcyl(x_tube_end, cap_screws[1][0], cap_screws[1][1], 5.5, 7.5);
                    // sensor rail
                    translate([x_tube_end, beam_y0, beam_z0]) cube([x_bulk_back - x_tube_end, beam_y1 - beam_y0, beam_z1 - beam_z0]);
                    // camera bulkhead
                    translate([x_bulk_back, -50, -50]) cube([bulk_t, 100, 100]);
                    // legs to the front wall (axial stop)
                    translate([x_bulk_front - 0.01, floor_y, -8]) cube([-front_wall - 0.2 - x_bulk_front, cam_bottom - 1 - floor_y, 16]);
                }
            }
            // camera standoffs
            for (s = [-1, 1], row = cam_hole_rows)
                xcyl(x_bulk_front - 0.01, cam_bottom + row, s * cam_hole_z, 4.5, standoff + 0.01);
        }
        // window in the bulkhead for the camera's back and the ribbon
        translate([x_bulk_back - 1, cam_bottom + 3.5, -8.5]) cube([bulk_t + 2, 40, 17]);
        // camera screw holes (M2 self-tapping)
        for (s = [-1, 1], row = cam_hole_rows)
            xcyl(x_bulk_back - 1, cam_bottom + row, s * cam_hole_z, 1.8, bulk_t + standoff + 2);
        // Pi + PiSugar screw holes (M2.5 self-tapping)
        for (xc = [x_post_f, x_post_r], s = [-1, 1])
            ycyl(xc, -sugar_drop - 8, s * pi_hole_z, 2.2, 9);
        // sensor screw holes (M2.5 self-tapping)
        for (i = [0, 1])
            ycyl(imu_x_front - imu_hole_in - i * imu_hole_dx, beam_y0 + 0.8, imu_z_edge + imu_hole_in, 2.1, 5);
        // cap screw holes
        for (p = cap_screws) xcyl(x_tube_end - 1, p[0], p[1], 2.2, 9);
    }
}

// ---------- cap ----------
module cap() {
    difference() {
        ax(x_tube_end - cap_t, cap_t) circle(r_out);
        for (p = cap_screws) xcyl(x_tube_end - cap_t - 1, p[0], p[1], 2.9, cap_t + 2);
        hull() for (s = [-1, 1])
            xcyl(x_tube_end - cap_t - 1, usb_y, usb_z + s * (usb_w - usb_h) / 2, usb_h, cap_t + 2);
        xcyl(x_tube_end - cap_t - 1, btn_y, btn_z, btn_d, cap_t + 2);
        xcyl(x_tube_end - cap_t - 1, led_y, led_z, led_d, cap_t + 2);
    }
}

// Button pin: pushes the PiSugar's button through the cap.
module button_pin() {
    cylinder(d = btn_d - 0.4, h = cap_t + 3);
    cylinder(d = btn_d + 2, h = 0.8);
}

// ---------- stand-ins for the electronics (preview only) ----------
module electronics() {
    color("#378ADD") translate([x_cam_back, cam_bottom, -cam_w / 2]) cube([1, cam_h, cam_w]);
    color("#2C2C2A") xcyl(x_cam_back + 1, lens_y, 0, 8.5, cam_depth - 1);
    color("#1D9E75") translate([x_pi_rear, 0, -pi_w / 2]) cube([pi_l, pi_t, pi_w]);
    color("#C8A16A") translate([x_pi_mid - 6.5, pi_t + 1.2, -6.5]) cube([13, heatsink_h, 13]);
    color("#2C2C2A") translate([x_pi_mid - 25.5, pi_t, 9]) cube([51, 8.5, 5]);
    color("#EF9F27") translate([x_pi_rear, -sugar_drop, -pi_w / 2]) cube([pi_l, sugar_t, pi_w]);
    color("#BA7517") translate([x_pi_mid - batt_l / 2, batt_bottom, -15]) cube([batt_l, batt_t, 30]);
    color("#D4537E") translate([imu_x_front - imu_l, beam_y1, imu_z_edge]) cube([imu_l, 1.6, imu_w]);
}

// ---------- output ----------
if (part == "tube") rotate([0, 90, 0]) tube();                                   // front face down
else if (part == "tray") translate([0, 0, -x_tube_end]) rotate([0, -90, 0]) tray(); // rear ring down
else if (part == "cap") translate([0, 0, -x_tube_end + cap_t]) rotate([0, -90, 0]) cap();
else if (part == "pin") button_pin();
else {
    color("#888780", 0.35) tube();
    color("#B4B2A9") tray();
    color("#5F5E5A") cap();
    electronics();
}
