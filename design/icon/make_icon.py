"""Generates the Macarum app icon: a macaron seen from the side on a squircle.

Direction: docs/design/DESIGN.md (icon section).
Usage: python3 make_icon.py <out.svg> [--small]
--small draws the 16/32 px variant: a rounder dome, feet as one dark line, a narrower cream.
"""
import math
import random
import sys

S = 1024
BODY = 824              # macOS icon body inside the 1024 canvas
CX = S / 2

# Three tones per material (light, base, shade); shades shift toward violet, lights toward yellow.
SHELL_LIGHT, SHELL, SHELL_SHADE, SHELL_DEEP = "#FFA3B4", "#F06A86", "#CC4A6C", "#A2365A"
FEET, FEET_SHADE = "#C94468", "#96305A"
CREAM_LIGHT, CREAM, CREAM_SHADE = "#FBE7BF", "#F1D39C", "#D2A869"

# Background: a pale sky blue, top to bottom, with the contact shadow and edge line in its hue.
BG_TOP, BG_BOTTOM = "#DCEEFB", "#A6D2F1"
GROUND, GROUND_OPACITY, EDGE = "#2F5F8A", 0.36, "#1F4468"


def squircle(size, n=4.6, steps=720):
    """Superellipse matched against the macOS 26 system icons."""
    a = size / 2
    pts = []
    for i in range(steps):
        t = 2 * math.pi * i / steps
        c, s = math.cos(t), math.sin(t)
        pts.append(f"{CX + a * math.copysign(abs(c) ** (2 / n), c):.2f},"
                   f"{CX + a * math.copysign(abs(s) ** (2 / n), s):.2f}")
    return "M" + " L".join(pts) + " Z"


def shell_path(L, R, flat, dome, crown=205):
    """One shell: widest a third of the way up from its flat edge, tucking in a little where it
    meets the feet, with a rounded crown at `dome`. `crown` is how far the crown's curve reaches
    sideways: smaller is rounder."""
    d = 1 if dome > flat else -1          # +1 for the bottom shell (dome points down)
    h = abs(dome - flat)
    return (f"M{L + 16},{flat} "
            f"C{L + 5},{flat + d * h * 0.05} {L},{flat + d * h * 0.17} {L},{flat + d * h * 0.33} "
            f"C{L},{flat + d * h * 0.84} {CX - crown},{dome} {CX},{dome} "
            f"C{CX + crown},{dome} {R},{flat + d * h * 0.84} {R},{flat + d * h * 0.33} "
            f"C{R},{flat + d * h * 0.17} {R - 5},{flat + d * h * 0.05} {R - 16},{flat} Z")


def feet_path(x0, x1, y_shell, y_edge, rng):
    """The feet: one matte band tucked under the shell. Its free edge is uneven, as on a baked
    macaron, and its ends taper. Returns (path, pores) with pores as (x, y, rx, ry)."""
    d = 1 if y_edge > y_shell else -1
    end = y_edge - d * 4                      # where the uneven edge meets the rounded ends
    pts = [(x0 + 14, end)]
    x = x0 + 14 + rng.uniform(13, 27)
    while x < x1 - 30:
        pts.append((x, y_edge - d * rng.uniform(0, 8)))
        x += rng.uniform(13, 27)
    pts.append((x1 - 14, end))
    path = (f"M{x0 + 14},{y_shell} L{x1 - 14},{y_shell} "
            f"C{x1 + 4},{y_shell} {x1 + 4},{end} {x1 - 14},{end} ")
    rev = pts[::-1]
    for (a, b) in zip(rev[1:], rev[2:]):      # a smooth run through the midpoints
        path += f"Q{a[0]:.1f},{a[1]:.1f} {(a[0] + b[0]) / 2:.1f},{(a[1] + b[1]) / 2:.1f} "
    path += f"L{x0 + 14},{end} C{x0 - 4},{end} {x0 - 4},{y_shell} {x0 + 14},{y_shell} Z"
    mid = (y_shell + y_edge) / 2
    pores = [(rng.uniform(x0 + 30, x1 - 30), mid + rng.uniform(-3, 3), rng.uniform(3, 5.5), rng.uniform(1.8, 2.8))
             for _ in range(11)]
    return path, pores


def svg(small=False):
    rng = random.Random(11)
    L, R = (186, 838) if small else (206, 818)
    shell_h = 168 if small else 150
    feet_h = 20 if small else 26
    cream_h = 66 if small else 56
    inset = 34 if small else 18            # the cream sits inside the shells
    over = 10 if small else 14             # the feet reach a little past them
    total = shell_h * 2 + feet_h * 2 + cream_h
    top_y = S / 2 - total / 2 - 8          # a touch above centre: the shadow sits below
    top_base = top_y + shell_h
    top_feet_end = top_base + feet_h
    cream_end = top_feet_end + cream_h
    bot_top = cream_end + feet_h
    bot_y = bot_top + shell_h

    body = squircle(BODY)
    crown = 180 if small else 205
    dome = shell_path(L, R, top_base, top_y, crown)
    bottom = shell_path(L, R, bot_top, bot_y, crown)
    cl, cr = L + inset, R - inset
    cream = (f"M{cl + 14},{top_feet_end - 8} L{cr - 14},{top_feet_end - 8} "
             f"C{cr + 8},{top_feet_end + 2} {cr + 8},{cream_end - 2} {cr - 14},{cream_end + 8} "
             f"L{cl + 14},{cream_end + 8} "
             f"C{cl - 8},{cream_end - 2} {cl - 8},{top_feet_end + 2} {cl + 14},{top_feet_end - 8} Z")

    o = [f'<svg xmlns="http://www.w3.org/2000/svg" width="{S}" height="{S}" viewBox="0 0 {S} {S}">']
    # Filters cover the whole canvas (no soft shape ends in a hard filter edge) and work in sRGB.
    blur = lambda n: (f'<filter color-interpolation-filters="sRGB" id="blur{n}" filterUnits="userSpaceOnUse" '
                      f'x="0" y="0" width="{S}" height="{S}"><feGaussianBlur stdDeviation="{n}"/></filter>')
    o.append(f"""<defs>
  <linearGradient id="bg" x1="0" y1="0" x2="0" y2="1">
    <stop offset="0" stop-color="{BG_TOP}"/><stop offset="1" stop-color="{BG_BOTTOM}"/>
  </linearGradient>
  <linearGradient id="edgeLight" x1="0" y1="0" x2="0" y2="1">
    <stop offset="0" stop-color="#FFFFFF" stop-opacity="0.6"/>
    <stop offset="0.22" stop-color="#FFFFFF" stop-opacity="0"/>
  </linearGradient>
  <linearGradient id="shellTop" x1="0" y1="0" x2="0" y2="1">
    <stop offset="0" stop-color="{SHELL_LIGHT}"/><stop offset="0.45" stop-color="{SHELL}"/>
    <stop offset="1" stop-color="{SHELL_SHADE}"/>
  </linearGradient>
  <linearGradient id="shellBottom" x1="0" y1="0" x2="0" y2="1">
    <stop offset="0" stop-color="{SHELL_SHADE}"/><stop offset="0.5" stop-color="{SHELL_SHADE}"/>
    <stop offset="1" stop-color="{SHELL_DEEP}"/>
  </linearGradient>
  <linearGradient id="creamFill" x1="0" y1="0" x2="0" y2="1">
    <stop offset="0" stop-color="{CREAM_SHADE}"/><stop offset="0.42" stop-color="{CREAM}"/>
    <stop offset="0.75" stop-color="{CREAM_LIGHT}"/><stop offset="1" stop-color="{CREAM}"/>
  </linearGradient>
  {blur(40)}{blur(24)}{blur(10)}{blur(4)}
  <clipPath id="body"><path d="{body}"/></clipPath>
  <clipPath id="dome"><path d="{dome}"/></clipPath>
  <clipPath id="bottom"><path d="{bottom}"/></clipPath>
</defs>""")

    # The icon's own drop shadow, then the body. The body is drawn outside any filter: filters
    # round dark colours to few steps and a smooth dark gradient would show bands.
    o.append(f'<path d="{body}" transform="translate(0 10)" fill="#000000" opacity="0.22" filter="url(#blur10)"/>')
    o.append(f'<path d="{body}" fill="url(#bg)"/>')
    o.append('<g clip-path="url(#body)">')

    # One contact shadow, sitting on the base and a little narrower than the macaron.
    sw = (R - L) * 0.43
    o.append(f'<ellipse cx="{CX + 8}" cy="{bot_y + 6}" rx="{sw}" ry="20" fill="{GROUND}" opacity="{GROUND_OPACITY}" filter="url(#blur10)"/>')

    # Bottom shell: one step darker than the top one, it sits in its shade.
    o.append(f'<path d="{bottom}" fill="url(#shellBottom)"/>')
    o.append(f'<g clip-path="url(#bottom)">'
             f'<rect x="{L - 20}" y="{bot_top - 10}" width="{R - L + 40}" height="30" fill="{SHELL_DEEP}" opacity="0.5" filter="url(#blur10)"/>'
             f'<ellipse cx="{CX - 170}" cy="{bot_top + shell_h * 0.5}" rx="210" ry="46" fill="{SHELL}" opacity="0.8" filter="url(#blur40)"/>'
             f'<ellipse cx="{CX + 190}" cy="{bot_y - 20}" rx="300" ry="70" fill="{SHELL_DEEP}" opacity="0.55" filter="url(#blur40)"/>'
             f'</g>')

    def feet(y_shell, y_edge):
        """One row of feet: a darker matte band with a few open pores, no highlights."""
        if small:
            return f'<rect x="{L - over}" y="{min(y_shell, y_edge)}" width="{R - L + over * 2}" height="{abs(y_edge - y_shell)}" rx="8" fill="{FEET}"/>'
        path, pores = feet_path(L - over, R + over, y_shell, y_edge, rng)
        return (f'<path d="{path}" fill="{FEET}"/>'
                + "".join(f'<ellipse cx="{x:.1f}" cy="{y:.1f}" rx="{rx:.1f}" ry="{ry:.1f}" fill="{FEET_SHADE}" opacity="0.7"/>'
                          for (x, y, rx, ry) in pores))

    # Cream first, then both rows of feet over its edges.
    o.append(f'<path d="{cream}" fill="url(#creamFill)"/>')
    o.append(feet(bot_top + 4, cream_end))
    o.append(feet(top_base - 4, top_feet_end))

    # Top shell: matte. A clear lit plane toward the top left, shade toward the lower right and
    # a darker lip where it meets the feet.
    o.append(f'<path d="{dome}" fill="url(#shellTop)"/>')
    o.append(f'<g clip-path="url(#dome)">'
             f'<ellipse cx="{CX - 120}" cy="{top_y + shell_h * 0.3}" rx="250" ry="{shell_h * 0.3}" fill="{SHELL_LIGHT}" opacity="0.85" filter="url(#blur40)"/>'
             f'<ellipse cx="{CX - 150}" cy="{top_y + shell_h * 0.2}" rx="150" ry="{shell_h * 0.11}" fill="#FFFFFF" opacity="0.3" filter="url(#blur24)"/>'
             f'<ellipse cx="{R - 30}" cy="{top_base - 20}" rx="220" ry="90" fill="{SHELL_SHADE}" opacity="0.7" filter="url(#blur40)"/>'
             f'<rect x="{L - 20}" y="{top_base - 14}" width="{R - L + 40}" height="22" fill="{SHELL_DEEP}" opacity="0.5" filter="url(#blur10)"/>'
             f'</g>')

    # Glass edge on the top of the icon body, like the system icons.
    o.append(f'<path d="{body}" fill="none" stroke="url(#edgeLight)" stroke-width="5"/>')
    o.append('</g>')
    o.append(f'<path d="{body}" fill="none" stroke="{EDGE}" stroke-opacity="0.12" stroke-width="2"/>')
    o.append("</svg>")
    return "\n".join(o)


if __name__ == "__main__":
    with open(sys.argv[1], "w") as f:
        f.write(svg(small="--small" in sys.argv))
