"""Draw the Room Config Builder icon artwork.

    python tools/draw_app_icon.py            # writes design/icon.png
    python tools/make_app_icon.py design/icon.png   # then push it everywhere

This produces the ARTWORK only. Getting it onto every platform is
make_app_icon.py's job, which already knows each platform's rules — the Apple
sets driven from their own Contents.json, iOS flattened because it may not
carry alpha, the maskable web icons inset to the safe zone.

THE DRAWING. A construction helmet over a gear, arranged so the whole thing
reads as a face: the helmet is the head, the gear is a beard around the jaw,
and the gear's inner arc is the smile. Three flat colors and one charcoal
outline weight, matching the icon this replaced, plus one the outline does not
use: the face it sits on and the helmet's slots are WHITE, so they stay white
on a dark ground instead of showing it through. Nothing is knocked out to
transparent any more except the ground around the artwork itself.

The eyes and smile are drawn as two nodes joined by a link, so the face
doubles as a signal running between two points — but in the same charcoal as
every outline here, NOT in a color of their own. That is deliberate and has
been tried both ways: given its own color the face is the first thing the eye
lands on, and this is a helmet-and-gear mark with a face in it rather than a
face wearing a helmet. Charcoal keeps it quiet.

THE LIGHT. The mark is shaded rather than flat, from one source at the upper
left. Every shape is drawn in three passes — fill, then shading, then outline
— instead of one fill-and-outline call. The order is the whole point: shading
laid over a finished shape washes out its outline, and a white highlight over
charcoal is very obviously wrong, so the outline goes on last and stays exactly
the weight it was. That is also why the geometry is named up front: each shape
is needed twice, once to draw and once as a stencil clipping its own shading.

Depth comes from three kinds of pass and nothing else:

  * a vertical ramp inside a shape, for the turn of a surface — the dome
    darkening into the brim, the brim's own thickness;
  * a soft blob, for the sheen on the dome;
  * a blurred silhouette of one shape laid on the shape beneath it, for the
    ridge standing proud of the crown and for the helmet sitting down over
    the gear and the face.

Shading is warm on the orange and cool on the blue and the white. One neutral
grey over both goes muddy on the orange, which is the only color here
saturated enough to notice.

THE SPACE. The mark is drawn wide: the gear and the face are flattened
ellipses rather than circles, so the gear spreads out under the brim it hangs
from instead of stacking a second circle below the helmet and forcing the
whole drawing smaller to fit. What is left over is then taken back — the
finished artwork is cropped to its own ink and scaled up until it meets the
edges of the square (fill_canvas). Both exist for the same reason: at 16 and
24 pixels there is no detail to spare, and every pixel of margin comes
straight off the vents, the brim slot and the gear teeth.

Everything is drawn at SUPERSAMPLE times the final size and reduced with
LANCZOS. There is no vector rasterizer in this project's toolchain, and that
is what keeps the gear teeth and the helmet's dome clean at 1024 without one.
"""

import math
import os
from PIL import Image, ImageChops, ImageDraw, ImageFilter

ORANGE = (246, 146, 30, 255)     # #F6921E, off the icon this replaced
BLUE = (63, 169, 245, 255)       # #3FA9F5
CHARCOAL = (64, 64, 65, 255)     # #404041
WHITE = (255, 255, 255, 255)
NOTHING = (0, 0, 0, 0)

# What the shading passes lay down. Not blacks: these are composited normally
# rather than multiplied, so the color laid down is the color a surface tends
# towards as it darkens. Warm keeps the orange orange on the way down.
SHADE_WARM = (146, 68, 0)
SHADE_COOL = (18, 42, 74)
GLINT = (255, 255, 255)

SIZE = 1024
SUPERSAMPLE = 4
S = SIZE * SUPERSAMPLE
STROKE = 14                       # in final pixels
GEAR_STROKE = 20                  # heavier, and see stroke_closed()

# How close the finished artwork comes to the edge of the square, in final
# pixels. See fill_canvas().
MARGIN = 4

# Soft masks are built full size, shrunk by this, blurred, then scaled back up.
# A Gaussian wide enough to read as soft at 4096 square costs seconds each; a
# blur has no detail left worth preserving, so the round trip is free in kind.
BLUR_SCALE = 4


def px(v):
    """A final-pixel measurement in supersampled pixels."""
    return int(round(v * SUPERSAMPLE))


# Every curve here takes a SEPARATE x and y radius, and its angle is the
# ellipse's parameter rather than the angle you would measure at the center.
# Nothing below needs the difference: a flattened gear is a round one scaled,
# and scaling is what keeps all twelve of its teeth the same shape.


def polar(cx, cy, rx, ry, deg):
    a = math.radians(deg)
    return (cx + rx * math.cos(a), cy + ry * math.sin(a))


def arc_points(cx, cy, rx, ry, deg0, deg1, steps=48):
    return [
        polar(cx, cy, rx, ry, deg0 + (deg1 - deg0) * i / steps)
        for i in range(steps + 1)
    ]


def gear_points(cx, cy, rx_tip, ry_tip, rx_root, ry_root, teeth):
    """A gear outline: chunky trapezoidal teeth, arcs at root and tip.

    The teeth are what make the ring read as a beard rather than as a washer,
    so they are wide and shallow. Narrow ones read as spikes at icon size — the
    first attempt looked like a sun, not a chin.
    """
    pts = []
    step = 360.0 / teeth
    for i in range(teeth):
        base = i * step
        pts += arc_points(
            cx, cy, rx_root, ry_root, base, base + step * 0.20, steps=5
        )
        pts.append(polar(cx, cy, rx_tip, ry_tip, base + step * 0.30))
        pts += arc_points(
            cx,
            cy,
            rx_tip,
            ry_tip,
            base + step * 0.30,
            base + step * 0.70,
            steps=7,
        )
        pts.append(polar(cx, cy, rx_root, ry_root, base + step * 0.80))
    return pts


def crescent(cx, cy, rx_out, ry_out, rx_in, ry_in, deg0, deg1):
    """A filled arc band — the shape a smile actually is.

    Stroking a sampled curve at this weight breaks into scallops wherever the
    samples sit closer together than the line is wide, which is what the smile
    looked like drawn as a polyline. A closed band has no such problem.
    """
    return arc_points(
        cx, cy, rx_out, ry_out, deg0, deg1, steps=64
    ) + arc_points(cx, cy, rx_in, ry_in, deg1, deg0, steps=64)


def stroke_closed(d, pts, color, width):
    """[pts] outlined as ONE closed, joined stroke.

    polygon(outline=..., width=...) strokes each edge on its own and INSET,
    which is fine on a rectangle and wrong on a gear: every tooth corner is a
    joint, PIL leaves the joints unfilled, and the seventy-odd of them around
    the teeth come out as notches — the outline breaks up into dashes long
    before the icon reaches its smallest size. Stroked here instead, centered on
    the path rather than inside it, so the weight asked for is the weight that
    lands, the whole way round.

    The joints are plugged with a disc apiece rather than left to line()'s own
    joint="curve", which rounds them but still parts along a hairline where two
    segments meet at a shallow angle — visible as a light thread across the
    stroke at the tooth roots, where the angles are shallowest. A disc the
    width of the stroke cannot leave a gap: everything within half a width of
    the vertex is covered, and that is where a joint crack has to be.
    """
    pts = list(pts) + [pts[0]]
    d.line(pts, fill=color, width=width)
    r = width / 2.0
    for x, y in pts:
        d.ellipse([x - r, y - r, x + r, y + r], fill=color)


def fill_canvas(img, margin):
    """[img]'s artwork scaled up until it just fits the square.

    The drawing below is laid out in round numbers rather than against the
    edges, so it finishes with an uneven margin — and margin is the one thing
    an icon cannot afford. At 16 and 24 pixels a tenth of the width spent on
    air is a tenth off every feature in the mark, and the brim slot, the vents
    and the gear teeth are what go first. So the finished artwork is measured,
    not trusted: cropped to its own ink and blown back up to the full square.

    Uniform scale, centered. The aspect ratio is the drawing's, not the
    canvas's — squashing the mark to fill both axes is a different request
    from filling the space, and looks it.
    """
    box = img.getbbox()
    if box is None:
        return img
    art = img.crop(box)
    room = img.width - 2 * margin
    scale = min(room / art.width, room / art.height)
    size = (max(1, round(art.width * scale)), max(1, round(art.height * scale)))
    out = Image.new("RGBA", img.size, NOTHING)
    out.paste(
        art.resize(size, Image.LANCZOS),
        ((img.width - size[0]) // 2, (img.height - size[1]) // 2),
    )
    return out


# ---------------------------------------------------------------------------
#  SHADING
# ---------------------------------------------------------------------------
#  These all deal in 8-bit masks the size of the canvas, where the value is
#  opacity. They compose by multiplication, so a pass reads as "this much
#  light, THERE, but only on that shape".


def stencil(shape):
    """A mask with [shape] drawn into it — what clips a pass to one shape.

    [shape] is handed an ImageDraw and fills itself. It picks its own fill
    value, so a stencil doubles as a strength.
    """
    m = Image.new("L", (S, S), 0)
    shape(ImageDraw.Draw(m))
    return m


def vramp(y0, y1, a0, a1):
    """A mask holding [a0] above [y0], ramping to [a1] by [y1], [a1] below.

    Held flat outside the band, so a pass can be aimed at one edge of a shape
    without knowing where that shape's other edge is — which is what lets one
    ramp be reused across shapes of different heights.
    """
    y0, y1 = int(round(y0)), int(round(y1))
    m = Image.new("L", (S, S), a1)
    top = max(0, min(y0, S))
    if top > 0:
        m.paste(a0, (0, 0, S, top))
    height = min(y1, S) - top
    if height > 0:
        band = Image.linear_gradient("L").point(
            lambda v: int(round(a0 + (a1 - a0) * v / 255.0))
        )
        m.paste(band.resize((S, height), Image.BILINEAR), (0, top))
    return m


def soft(mask, blur):
    """[mask], blurred. See BLUR_SCALE for why it takes the scenic route."""
    small = S // BLUR_SCALE
    out = mask.resize((small, small), Image.BILINEAR)
    out = out.filter(ImageFilter.GaussianBlur(blur / BLUR_SCALE))
    return out.resize((S, S), Image.BILINEAR)


def clip(*masks):
    """The intersection of masks: a pass, cut to the shape it belongs on."""
    out = masks[0]
    for m in masks[1:]:
        out = ImageChops.multiply(out, m)
    return out


def lay(img, color, alpha):
    """Composite flat [color] over [img] at the per-pixel opacity [alpha].

    In place, so the ImageDraw already bound to [img] stays valid across it.
    """
    layer = Image.new("RGBA", (S, S), (*color, 255))
    layer.putalpha(alpha)
    img.alpha_composite(layer)


def build():
    img = Image.new("RGBA", (S, S), NOTHING)
    d = ImageDraw.Draw(img)
    w = px(STROKE)
    gw = px(GEAR_STROKE)
    cx = S / 2

    # ---- geometry ----------------------------------------------------------
    # The gear and the face are ELLIPSES, wider than they are tall, and drawn
    # round they were the wrong shape twice over. The gear was as tall as the
    # helmet above it, so the mark was two stacked circles and the whole thing
    # had to be shrunk to fit them both in — while the brim, the widest part
    # of the drawing, left the gear's sides looking pinched. Flattened, the
    # gear spreads out under the brim it hangs from and gives back the height,
    # and the face it rings gains a jaw instead of reading as a ball. Face and
    # gear share the same x:y ratio, so the beard stays an even band.
    gear_cy = px(686)
    rx_tip, ry_tip = px(396), px(306)
    rx_root, ry_root = px(312), px(241)
    rx_hole, ry_hole = px(220), px(170)

    # The face sits ABOVE the gear's own center, which is what turns a ring
    # into a beard: the blue is left thick under the chin and thin at the
    # temples, the way a beard sits on a face. Concentric, it read as a washer
    # with a face in it. The drop is smaller than it was only because the gear
    # is shorter — it is a fraction of the height, not a fixed distance.
    face_cy = gear_cy - px(32)
    gear_poly = gear_points(cx, gear_cy, rx_tip, ry_tip, rx_root, ry_root, 12)
    face_box = [
        cx - rx_hole,
        face_cy - ry_hole,
        cx + rx_hole,
        face_cy + ry_hole,
    ]

    brim_top = px(524)
    brim_bottom = px(624)
    dome_bottom = brim_top + px(12)
    dome_rx = px(382)
    dome_ry = px(388)
    crown_poly = arc_points(
        cx, dome_bottom, dome_rx, dome_ry, 180, 360, steps=180
    )
    ridge_box = [cx - px(88), px(96), cx + px(88), px(330)]
    ridge_r = px(44)
    brim_box = [px(30), brim_top, S - px(30), brim_bottom]
    brim_r = px(52)
    slot_box = [S - px(390), brim_top + px(18), S - px(60), brim_top + px(72)]
    slot_r = px(27)
    vent_r = px(29)
    vent_boxes = [
        [
            min(cx + s * px(112), cx + s * px(170)),
            px(150),
            max(cx + s * px(112), cx + s * px(170)),
            px(430),
        ]
        for s in (-1, 1)
    ]

    gear_mask = stencil(lambda m: m.polygon(gear_poly, fill=255))
    face_mask = stencil(lambda m: m.ellipse(face_box, fill=255))
    crown_mask = stencil(lambda m: m.polygon(crown_poly, fill=255))
    ridge_mask = stencil(
        lambda m: m.rounded_rectangle(ridge_box, radius=ridge_r, fill=255)
    )
    brim_mask = stencil(
        lambda m: m.rounded_rectangle(brim_box, radius=brim_r, fill=255)
    )
    slot_mask = stencil(
        lambda m: m.rounded_rectangle(slot_box, radius=slot_r, fill=255)
    )
    vent_mask = stencil(
        lambda m: [
            m.rounded_rectangle(b, radius=vent_r, fill=255) for b in vent_boxes
        ]
    )

    # ---- the gear: the beard, and the smile it closes around ---------------
    # Drawn first so the helmet's brim sits over its top, the way the two
    # overlapped in the icon this replaces.
    d.polygon(gear_poly, fill=BLUE)
    lay(img, SHADE_COOL, clip(gear_mask, vramp(px(620), px(868), 76, 0)))
    lay(img, SHADE_COOL, clip(gear_mask, vramp(px(878), px(998), 0, 42)))
    stroke_closed(d, gear_poly, CHARCOAL, gw)

    # ---- the face ----------------------------------------------------------
    # White rather than erased through: the eyes and smile need a ground of
    # their own to be read against, and knocked out they were read against
    # whatever sat behind the icon — fine on a white page, but on a dark one
    # the face became a hole and took the smile with it.
    d.ellipse(face_box, fill=WHITE)

    # The eyes are the nodes and the smile is the link, and they are one
    # figure rather than three: the link's ends stop AT the node centers, not
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
    # the note at the top before giving it a color of its own again.
    #
    # The one cost: charcoal on charcoal means that below about 24 px the link
    # closes up with the gear's inner outline just under it. The fat nodes are
    # what keep the figure legible down there, so do not thin them to match
    # the link.
    #
    # The link is concentric with the face, and so with the gear's inner edge
    # — the beard still reads as closing around the face rather than sitting
    # behind it. Flattening the face and leaving the link round would have
    # opened a gap under the chin and crowded the temples.
    rx_link, ry_link = px(151), px(117)
    link_half = px(16)
    node_r = px(40)
    node_deg = (20, 160)

    # Drawn BEFORE the face is shaded, so the same light falls across the
    # features as across the face they sit on. Drawn after, they float.
    d.polygon(
        crescent(
            cx,
            face_cy,
            rx_link + link_half,
            ry_link + link_half,
            rx_link - link_half,
            ry_link - link_half,
            *node_deg,
        ),
        fill=CHARCOAL,
    )
    for deg in node_deg:
        nx, ny = polar(cx, face_cy, rx_link, ry_link, deg)
        d.ellipse(
            [nx - node_r, ny - node_r, nx + node_r, ny + node_r],
            fill=CHARCOAL,
        )

    lay(img, SHADE_COOL, clip(face_mask, vramp(px(612), px(796), 58, 0)))
    d.ellipse(face_box, outline=CHARCOAL, width=w)

    # The helmet sitting down over both of them. Laid before the crown and the
    # brim are drawn, so it only has to be clipped to what it falls ON, and the
    # helmet then covers its top edge for free.
    lay(
        img,
        SHADE_COOL,
        clip(
            ImageChops.lighter(gear_mask, face_mask),
            vramp(brim_bottom - px(30), brim_bottom + px(70), 84, 0),
        ),
    )

    # ---- the helmet --------------------------------------------------------
    # Crown: the top half of an ellipse, closed along the brim line.
    d.polygon(crown_poly, fill=ORANGE)
    lay(img, SHADE_WARM, clip(crown_mask, vramp(px(360), dome_bottom, 0, 86)))
    lay(
        img,
        GLINT,
        clip(
            crown_mask,
            soft(
                stencil(
                    lambda m: m.ellipse(
                        [cx - px(310), px(186), cx - px(16), px(384)], fill=150
                    )
                ),
                px(66),
            ),
        ),
    )
    d.polygon(crown_poly, outline=CHARCOAL, width=w)

    # The ridge along the crown, standing proud of it — which is the cast
    # shadow's job, not the outline's. Thrown down and to the right, away from
    # the light, and clipped to the crown so the part of it that would fall off
    # the dome's top edge does not hang in the air.
    lay(
        img,
        SHADE_WARM,
        clip(
            crown_mask,
            soft(
                stencil(
                    lambda m: m.rounded_rectangle(
                        [
                            ridge_box[0] + px(18),
                            ridge_box[1],
                            ridge_box[2] + px(18),
                            ridge_box[3] + px(20),
                        ],
                        radius=ridge_r,
                        fill=120,
                    )
                ),
                px(24),
            ),
        ),
    )

    d.rounded_rectangle(ridge_box, radius=ridge_r, fill=ORANGE)
    lay(img, GLINT, clip(ridge_mask, vramp(px(96), px(246), 62, 0)))
    lay(img, SHADE_WARM, clip(ridge_mask, vramp(px(252), px(330), 0, 58)))
    d.rounded_rectangle(ridge_box, radius=ridge_r, outline=CHARCOAL, width=w)

    # The two vents either side of the ridge. Filled white rather than erased
    # through: knocked out they are the ground's color, which is white on the
    # web and in Explorer but the wallpaper on a desktop and black in a dark
    # title bar, and the helmet loses its slots wherever that ground is dark.
    # Shaded from the top, so they read as cut into the crown rather than
    # painted onto it.
    for box in vent_boxes:
        d.rounded_rectangle(box, radius=vent_r, fill=WHITE)
    lay(img, SHADE_COOL, clip(vent_mask, vramp(px(150), px(268), 112, 0)))
    for box in vent_boxes:
        d.rounded_rectangle(box, radius=vent_r, outline=CHARCOAL, width=w)

    # The brim, wider than the crown and sitting across it. The ramp on its
    # underside is what gives it thickness — without it the brim is a stripe.
    d.rounded_rectangle(brim_box, radius=brim_r, fill=ORANGE)
    lay(img, GLINT, clip(brim_mask, vramp(brim_top, brim_top + px(24), 66, 0)))
    lay(
        img,
        SHADE_WARM,
        clip(brim_mask, vramp(brim_bottom - px(52), brim_bottom, 0, 98)),
    )
    d.rounded_rectangle(brim_box, radius=brim_r, outline=CHARCOAL, width=w)

    # The slot the original carries on the right of its brim, white for the
    # same reason as the vents.
    d.rounded_rectangle(slot_box, radius=slot_r, fill=WHITE)
    lay(
        img,
        SHADE_COOL,
        clip(slot_mask, vramp(slot_box[1], slot_box[1] + px(28), 112, 0)),
    )
    d.rounded_rectangle(slot_box, radius=slot_r, outline=CHARCOAL, width=w)

    return fill_canvas(img, px(MARGIN)).resize((SIZE, SIZE), Image.LANCZOS)


if __name__ == "__main__":
    out = os.path.join("design", "icon.png")
    build().save(out)
    print("wrote", out)
    print("now: python tools/make_app_icon.py", out)
