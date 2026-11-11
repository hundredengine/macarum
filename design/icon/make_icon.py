"""Generates the Macarum app icon: a macaron seen from the side on a mint squircle.

Direction: docs/design/DESIGN.md (icon section).
Usage: python3 make_icon.py <out.svg> [--small]
--small draws the 16/32 px variant: no frilly feet, thicker cream, bolder shapes.
"""
import math
import sys

S = 1024
BODY = 824              # macOS icon body inside the 1024 canvas
CX = S / 2

# Palette, three tones per material (light, base, shade). Shade shifts toward violet.
MINT_TOP, MINT_BOTTOM = "#CDEFDF", "#8FD3B4"
SHELL_LIGHT, SHELL, SHELL_SHADE = "#E8798E", "#D4566F", "#A93E5E"
FEET, FEET_SHADE = "#C9506B", "#A63D57"
CREAM_LIGHT, CREAM, CREAM_SHADE = "#F9EBD0", "#F3DDB6", "#D9B98A"
GROUND = "#1F4A3A"


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


def wavy(x0, x1, y, amplitude, seed):
    """Points along an uneven edge: small irregular bumps, never a regular scallop."""
    pts = []
    x, i = x0, 0
    while x < x1:
        step = 7 + ((seed * 5 + i * 7) % 7)                         # 7..13 px apart
        off = amplitude * (((seed * 13 + i * 11) % 7) / 6.0)        # 0..amplitude
        pts.append((x, y + off))
        x += step
        i += 1
    pts.append((x1, y))
    return pts


def feet_band(x0, x1, y_shell, y_edge, seed, small):
    """The porous 'feet' under a shell: a band a little wider than the shell, flat where
    it meets the shell and rough on the side facing the cream."""
    if small:
        return f"M{x0},{y_shell} L{x1},{y_shell} L{x1 - 4},{y_edge} L{x0 + 4},{y_edge} Z"
    direction = 1 if y_edge > y_shell else -1
    edge = wavy(x0 + 10, x1 - 10, y_edge, 6 * direction, seed)
    mid = (y_shell + y_edge) / 2
    # Rounded, slightly bulging ends instead of pointed tips.
    d = f"M{x0 + 10},{y_shell} L{x1 - 10},{y_shell} "
    d += f"C{x1 + 4},{y_shell} {x1 + 4},{y_edge} {x1 - 10},{y_edge} "
    for (x, y) in reversed(edge):
        d += f"L{x:.1f},{y:.1f} "
    d += f"C{x0 - 4},{y_edge} {x0 - 4},{y_shell} {x0 + 10},{y_shell} Z"
    return d


def pores(x0, x1, y0, y1, seed):
    """A few uneven darker specks that make the feet read as airy, not as a plastic strip."""
    out = []
    i = 0
    x = x0 + 14
    while x < x1 - 14:
        r = 2.2 + ((seed * 3 + i * 5) % 4) * 0.8                    # 2.2..4.6
        y = y0 + (y1 - y0) * (0.3 + ((seed * 7 + i * 3) % 5) / 10)  # spread vertically
        out.append((x, y, r))
        x += 17 + ((seed * 11 + i * 13) % 15)                       # 17..31 apart
        i += 1
    return out


def svg(small=False):
    L, R = (222, 802) if small else (232, 792)
    # Two shells of equal height, like a real macaron.
    top_y, top_base = (326, 462) if small else (338, 462)
    feet_h = 22 if small else 30
    cream_h = 96 if small else 66
    top_feet_end = top_base + feet_h
    cream_end = top_feet_end + cream_h
    bot_top = cream_end + feet_h
    bot_y = bot_top + (top_base - top_y)

    body = squircle(BODY)
    dome = (f"M{L},{top_base} C{L},{top_y + 34} {CX - 210},{top_y} {CX},{top_y} "
            f"C{CX + 210},{top_y} {R},{top_y + 34} {R},{top_base} "
            f"C{R},{top_base + 8} {R - 6},{top_base + 10} {R - 14},{top_base + 10} "
            f"L{L + 14},{top_base + 10} C{L + 6},{top_base + 10} {L},{top_base + 8} {L},{top_base} Z")
    bottom = (f"M{L + 14},{bot_top - 10} L{R - 14},{bot_top - 10} "
              f"C{R - 6},{bot_top - 10} {R},{bot_top - 8} {R},{bot_top} "
              f"C{R},{bot_y - 34} {CX + 210},{bot_y} {CX},{bot_y} "
              f"C{CX - 210},{bot_y} {L},{bot_y - 34} {L},{bot_top} "
              f"C{L},{bot_top - 8} {L + 6},{bot_top - 10} {L + 14},{bot_top - 10} Z")
    bulge = 10
    cream = (f"M{L + 20},{top_feet_end} L{R - 20},{top_feet_end} "
             f"C{R + bulge},{top_feet_end + 6} {R + bulge},{cream_end - 6} {R - 20},{cream_end} "
             f"L{L + 20},{cream_end} "
             f"C{L - bulge},{cream_end - 6} {L - bulge},{top_feet_end + 6} {L + 20},{top_feet_end} Z")

    o = [f'<svg xmlns="http://www.w3.org/2000/svg" width="{S}" height="{S}" viewBox="0 0 {S} {S}">']
    o.append(f"""<defs>
  <linearGradient id="bg" x1="0" y1="0" x2="0" y2="1">
    <stop offset="0" stop-color="{MINT_TOP}"/><stop offset="1" stop-color="{MINT_BOTTOM}"/>
  </linearGradient>
  <linearGradient id="edgeLight" x1="0" y1="0" x2="0" y2="1">
    <stop offset="0" stop-color="#FFFFFF" stop-opacity="0.7"/>
    <stop offset="0.25" stop-color="#FFFFFF" stop-opacity="0"/>
  </linearGradient>
  <filter id="blur30" x="-50%" y="-50%" width="200%" height="200%"><feGaussianBlur stdDeviation="30"/></filter>
  <filter id="blur14" x="-50%" y="-50%" width="200%" height="200%"><feGaussianBlur stdDeviation="14"/></filter>
  <filter id="blur6" x="-50%" y="-50%" width="200%" height="200%"><feGaussianBlur stdDeviation="6"/></filter>
  <filter id="iconShadow" x="-20%" y="-20%" width="140%" height="140%">
    <feGaussianBlur in="SourceAlpha" stdDeviation="14"/><feOffset dy="10"/>
    <feComponentTransfer><feFuncA type="linear" slope="0.25"/></feComponentTransfer>
    <feMerge><feMergeNode/><feMergeNode in="SourceGraphic"/></feMerge>
  </filter>
  <clipPath id="body"><path d="{body}"/></clipPath>
  <clipPath id="dome"><path d="{dome}"/></clipPath>
  <clipPath id="bottom"><path d="{bottom}"/></clipPath>
  <clipPath id="cream"><path d="{cream}"/></clipPath>
</defs>""")

    o.append(f'<g filter="url(#iconShadow)"><path d="{body}" fill="url(#bg)"/></g>')
    o.append('<g clip-path="url(#body)">')

    # Shadows: a tight contact shadow touching the base, and a soft cast shadow to the right.
    o.append(f'<ellipse cx="{CX + 20}" cy="{bot_y + 12}" rx="262" ry="24" fill="{GROUND}" opacity="0.15" filter="url(#blur14)"/>')
    o.append(f'<ellipse cx="{CX + 4}" cy="{bot_y}" rx="250" ry="10" fill="{GROUND}" opacity="0.45" filter="url(#blur6)"/>')

    # Bottom shell: base tone, light on the upper left, a shade crescent along the underside.
    o.append(f'<path d="{bottom}" fill="{SHELL}"/>')
    o.append(f'<g clip-path="url(#bottom)">'
             f'<ellipse cx="{CX - 150}" cy="{bot_top + 10}" rx="230" ry="40" fill="{SHELL_LIGHT}" opacity="0.7" filter="url(#blur30)"/>'
             f'<ellipse cx="{CX + 60}" cy="{bot_y + 30}" rx="380" ry="70" fill="{SHELL_SHADE}" filter="url(#blur14)"/>'
             f'</g>')

    # Bottom feet, then the cream, then the top feet over it.
    bot_feet = feet_band(L - 8, R + 8, bot_top - 6, cream_end - 4, seed=3, small=small)
    o.append(f'<path d="{bot_feet}" fill="{FEET}"/>')
    if not small:
        o.append(f'<clipPath id="botFeet"><path d="{bot_feet}"/></clipPath>')
        o.append(f'<g clip-path="url(#botFeet)">'
                 f'<rect x="{L}" y="{bot_top - 16}" width="{R - L}" height="12" fill="{FEET_SHADE}" opacity="0.5" filter="url(#blur6)"/>'
                 + "".join(f'<circle cx="{x:.1f}" cy="{y:.1f}" r="{r:.1f}" fill="{FEET_SHADE}" opacity="0.55"/>'
                           for (x, y, r) in pores(L, R, cream_end - 2, bot_top - 6, seed=4))
                 + '</g>')
    o.append(f'<path d="{cream}" fill="{CREAM}"/>')
    o.append(f'<g clip-path="url(#cream)">'
             f'<rect x="{L}" y="{top_feet_end}" width="{R - L}" height="16" fill="{CREAM_SHADE}" filter="url(#blur6)"/>'
             f'<ellipse cx="{CX - 120}" cy="{(top_feet_end + cream_end) / 2 + 8}" rx="220" ry="14" fill="{CREAM_LIGHT}" filter="url(#blur6)"/>'
             f'</g>')
    top_feet = feet_band(L - 8, R + 8, top_base + 6, top_feet_end + 2, seed=1, small=small)
    o.append(f'<path d="{top_feet}" fill="{FEET}"/>')
    if not small:
        # The feet sit in the shell's shadow, so they darken softly toward the shell.
        o.append(f'<clipPath id="topFeet"><path d="{top_feet}"/></clipPath>')
        o.append(f'<g clip-path="url(#topFeet)">'
                 f'<rect x="{L}" y="{top_base + 4}" width="{R - L}" height="14" fill="{FEET_SHADE}" opacity="0.6" filter="url(#blur6)"/>'
                 + "".join(f'<circle cx="{x:.1f}" cy="{y:.1f}" r="{r:.1f}" fill="{FEET_SHADE}" opacity="0.55"/>'
                           for (x, y, r) in pores(L, R, top_base + 8, top_feet_end, seed=2))
                 + '</g>')

    # Top shell: matte, so one wide soft light and a crescent shade, no gloss spots.
    o.append(f'<path d="{dome}" fill="{SHELL}"/>')
    o.append(f'<g clip-path="url(#dome)">'
             f'<ellipse cx="{CX - 110}" cy="{top_y + 36}" rx="260" ry="70" fill="{SHELL_LIGHT}" filter="url(#blur30)"/>'
             f'<ellipse cx="{CX - 140}" cy="{top_y + 30}" rx="170" ry="34" fill="#FFFFFF" opacity="0.14" filter="url(#blur30)"/>'
             f'<path d="M{R + 30},{top_y + 20} C{R - 10},{top_base - 20} {CX + 60},{top_base + 30} {L + 40},{top_base + 40} '
             f'L{R + 40},{top_base + 60} Z" fill="{SHELL_SHADE}" opacity="0.85" filter="url(#blur14)"/>'
             f'</g>')

    # Glass edge on the top of the icon body, like the system icons.
    o.append(f'<path d="{body}" fill="none" stroke="url(#edgeLight)" stroke-width="5"/>')
    o.append('</g>')
    o.append(f'<path d="{body}" fill="none" stroke="#0B3B2A" stroke-opacity="0.10" stroke-width="2"/>')
    o.append("</svg>")
    return "\n".join(o)


if __name__ == "__main__":
    with open(sys.argv[1], "w") as f:
        f.write(svg(small="--small" in sys.argv))
