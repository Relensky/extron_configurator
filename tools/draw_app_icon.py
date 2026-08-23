"""Draw the Room Config Builder icon artwork.

    python tools/draw_app_icon.py            # writes design/icon.png
    python tools/make_app_icon.py design/icon.png   # then push it everywhere

This produces the ARTWORK only. Getting it onto every platform is
make_app_icon.py's job, which already knows each platform's rules — the Apple
sets driven from their own Contents.json, iOS flattened because it may not
carry alpha, the maskable web icons inset to the safe zone.

THE DRAWING. A construction helmet over a gear, arranged so the whole thing
reads as a face: the helmet is the head, the gear is a beard around the jaw,
and the gear's inner arc is the smile. Three flat colours and one charcoal
outline weight, matching the icon this replaced, plus one the outline does not
use: the face it sits on and the helmet's slots are WHITE, so they stay white
on a dark ground instead of showing it through. Nothing is knocked out to
transparent any more except the ground around the artwork itself.

The eyes and smile are drawn as two nodes joined by a link, so the face
doubles as a signal running between two points — but in the same charcoal as
every outline here, NOT in a colour of their own. That is deliberate and has
been tried both ways: given its own colour the face is the first thing the eye
lands on, and this is a helmet-and-gear mark with a face in it rather than a
face wearing a helmet. Charcoal keeps it quiet.

Everything is drawn at SUPERSAMPLE times the final size and reduced with
LANCZOS. There is no vector rasteriser in this project's toolchain, and that
is what keeps the gear teeth and the helmet's dome clean at 1024 without one.
"""

import math
import os
from PIL import Image, ImageDraw

ORANGE = (246, 146, 30, 255)     # #F6921E, off the icon this replaced
BLUE = (63, 169, 245, 255)       # #3FA9F5
CHARCOAL = (64, 64, 65, 255)     # #404041
WHITE = (255, 255, 255, 255)
NOTHING = (0, 0, 0, 0)

SIZE = 1024
SUPERSAMPLE = 4
S = SIZE * SUPERSAMPLE
STROKE = 13                       # in final pixels


def px(v):
    """A final-pixel measurement in supersampled pixels."""
    return int(round(v * SUPERSAMPLE))


def polar(cx, cy, r, deg):
    a = math.radians(deg)
    return (cx + r * math.cos(a), cy + r * math.sin(a))


def arc_points(cx, cy, r, deg0, deg1, steps=48):
    return [
        polar(cx, cy, r, deg0 + (deg1 - deg0) * i / steps)
        for i in range(steps + 1)
    ]


def gear_points(cx, cy, r_tip, r_root, teeth):
    """A gear outline: chunky trapezoidal teeth, arcs at root and tip.

    The teeth are what make the ring read as a beard rather than as a washer,
    so they are wide and shallow. Narrow ones read as spikes at icon size — the
    first attempt looked like a sun, not a chin.
    """
    pts = []
    step = 360.0 / teeth
    for i in range(teeth):
        base = i * step
        pts += arc_points(cx, cy, r_root, base, base + step * 0.20, steps=5)
        pts.append(polar(cx, cy, r_tip, base + step * 0.30))
        pts += arc_points(
            cx, cy, r_tip, base + step * 0.30, base + step * 0.70, steps=7
        )
        pts.append(polar(cx, cy, r_root, base + step * 0.80))
    return pts


def crescent(cx, cy, r_out, r_in, deg0, deg1):
    """A filled arc band — the shape a smile actually is.

    Stroking a sampled curve at this weight breaks into scallops wherever the
    samples sit closer together than the line is wide, which is what the smile
    looked like drawn as a polyline. A closed band has no such problem.
    """
    return arc_points(cx, cy, r_out, deg0, deg1, steps=64) + arc_points(
        cx, cy, r_in, deg1, deg0, steps=64
    )


def build():
    img = Image.new("RGBA", (S, S), NOTHING)
    d = ImageDraw.Draw(img)
    w = px(STROKE)
    cx = S / 2

    # ---- the gear: the beard, and the smile it closes around ---------------
    # Drawn first so the helmet's brim sits over its top, the way the two
    # overlapped in the icon this replaces.
    gear_cy = px(672)
    r_tip = px(345)
    r_root = px(272)
    r_hole = px(186)

    d.polygon(
        gear_points(cx, gear_cy, r_tip, r_root, 12),
        fill=BLUE,
        outline=CHARCOAL,
        width=w,
    )

    # The face, laid over the middle of the gear. White rather than erased
    # through: the eyes and smile need a ground of their own to be read
    # against, and knocked out they were read against whatever sat behind the
    # icon — fine on a white page, but on a dark one the face became a hole and
    # took the smile with it.
    #
    # The opening sits ABOVE the gear's own centre, which is what turns a ring
    # into a beard: the blue is left thick under the chin and thin at the
    # temples, the way a beard sits on a face. Concentric, it read as a washer
    # with a face in it.
    face_cy = gear_cy - px(40)
    d.ellipse(
        [cx - r_hole, face_cy - r_hole, cx + r_hole, face_cy + r_hole],
        fill=WHITE,
        outline=CHARCOAL,
        width=w,
    )

    # ---- the helmet --------------------------------------------------------
    brim_top = px(524)
    brim_bottom = px(624)
    dome_bottom = brim_top + px(12)
    dome_rx = px(382)
    dome_ry = px(388)

    # Crown: the top half of an ellipse, closed along the brim line.
    crown = [
        (cx + (x - cx) * dome_rx, dome_bottom + (y - dome_bottom) * dome_ry)
        for (x, y) in arc_points(cx, dome_bottom, 1.0, 180, 360, steps=180)
    ]
    d.polygon(crown, fill=ORANGE, outline=CHARCOAL, width=w)

    # The ridge along the crown, standing proud of it.
    d.rounded_rectangle(
        [cx - px(88), px(96), cx + px(88), px(330)],
        radius=px(44),
        fill=ORANGE,
        outline=CHARCOAL,
        width=w,
    )

    # The two vents either side of the ridge. Filled white rather than erased
    # through: knocked out they are the ground's colour, which is white on the
    # web and in Explorer but the wallpaper on a desktop and black in a dark
    # title bar, and the helmet loses its slots wherever that ground is dark.
    for sign in (-1, 1):
        x0 = cx + sign * px(112)
        x1 = cx + sign * px(170)
        d.rounded_rectangle(
            [min(x0, x1), px(150), max(x0, x1), px(430)],
            radius=px(29),
            fill=WHITE,
            outline=CHARCOAL,
            width=w,
        )

    # The brim, wider than the crown and sitting across it.
    d.rounded_rectangle(
        [px(30), brim_top, S - px(30), brim_bottom],
        radius=px(52),
        fill=ORANGE,
        outline=CHARCOAL,
        width=w,
    )

    # The slot the original carries on the right of its brim, white for the
    # same reason as the vents.
    d.rounded_rectangle(
        [S - px(390), brim_top + px(18), S - px(60), brim_top + px(72)],
        radius=px(27),
        fill=WHITE,
        outline=CHARCOAL,
        width=w,
    )

    # ---- the face: two nodes and the link between them ---------------------
    # The eyes are the nodes and the smile is the link, and they are one
    # figure rather than three: the link's ends stop AT the node centres, not
    # short of them, so the pair reads as two points with a signal running
    # between them, and only then as a face. Drawn apart — which is what the
    # eyes and smile were before — it was a mouth that happened to sit under
    # two dots, and the connection was not there to be read.
    #
    # The nodes are deliberately fatter than the link. Equal weights make a
    # rounded-cap stroke, which is exactly what this was; the step in width is
    # the whole reason it now reads as node-link-node.
    #
    # Solid, no outline: at 32 px an outlined node fills in and turns into a
    # blob. Charcoal, the same ink as every edge in the drawing, so the face
    # reads as part of the line work rather than as the mark's subject — see
    # the note at the top before giving it a colour of its own again.
    #
    # The one cost: charcoal on charcoal means that below about 24 px the link
    # closes up with the gear's inner outline just under it. The fat nodes are
    # what keep the figure legible down there, so do not thin them to match
    # the link.
    #
    # r_link is concentric with the gear's inner edge, so the beard still
    # reads as closing around the face rather than sitting behind it.
    r_link = px(125)
    link_half = px(15)
    node_r = px(38)
    node_deg = (20, 160)

    d.polygon(
        crescent(
            cx, face_cy, r_link + link_half, r_link - link_half, *node_deg
        ),
        fill=CHARCOAL,
    )
    for deg in node_deg:
        nx, ny = polar(cx, face_cy, r_link, deg)
        d.ellipse(
            [nx - node_r, ny - node_r, nx + node_r, ny + node_r],
            fill=CHARCOAL,
        )

    return img.resize((SIZE, SIZE), Image.LANCZOS)


if __name__ == "__main__":
    out = os.path.join("design", "icon.png")
    build().save(out)
    print("wrote", out)
    print("now: python tools/make_app_icon.py", out)
