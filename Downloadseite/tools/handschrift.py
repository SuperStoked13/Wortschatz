#!/usr/bin/env python3
"""Schreibt «spendier mir einen Kaffee :)» / «buy me a coffee :)» als Federstriche für den Kaffee im Hero.

Erzeugt public/_partials/coffee-note.html (Deutsch) und coffee-note-en.html (Englisch): je ein SVG, in dem
jeder Federstrich ein eigener Pfad ist. Die Schrift ist die einstrichige Hershey-Schreibschrift («cursive»,
gemeinfrei), darum lässt sie sich Strich für Strich zeichnen wie von Hand: Wort für Wort, die i-Punkte nach
dem Wort, mit kurzen Pausen, wo die Feder absetzt.

Alle Striche laufen in site.css mit derselben Animation (stroke-dashoffset von 1001 auf 0). Jeder Pfad
bekommt pathLength = seine Länge und stroke-dasharray = «Rest der Zeitachse ab seinem Start», so beginnt
er genau dann, wenn die Feder bei ihm ankommt (CSP: keine Inline-Styles, Attribute sind erlaubt).

Nur nötig, wenn sich der Text ändert. Braucht das Paket Hershey-Fonts (MIT):
    python3 -m venv /tmp/hs && /tmp/hs/bin/pip install Hershey-Fonts
    /tmp/hs/bin/python -I Downloadseite/tools/handschrift.py
Meldet es andere Dauern, in site.css nachführen: «.coffee-note path» (Englisch) und «.coffee-note-de path»,
dazu die Verzögerung des Pfeils (er beginnt kurz nach dem letzten Strich).
"""

import math
import os

from HersheyFonts import HersheyFonts

PARTIALS = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'public', '_partials')
NOTES = {
    'coffee-note.html': ('de', ['spendier mir', 'einen Kaffee :)']),
    'coffee-note-en.html': ('en', ['buy me', 'a coffee :)']),
}
TIMELINE = 1000      # Länge der gemeinsamen Zeitachse (in site.css: stroke-dashoffset 1001 → 0)
SPEED = 500          # Schrift-Einheiten pro Sekunde, für die gemeldete Dauer
SCALE = 1.1          # Pixel pro Schrift-Einheit (Mittellänge 9 Einheiten ≈ 10 px)
SPACE = 9            # Wortabstand (die Schrift hat einen sehr breiten)
LEADING = 33         # Zeilenabstand (Unterlänge der ersten Zeile trifft nicht die Oberlänge der zweiten)
PAD = 2.5            # Rand für die Strichbreite, in Pixeln
TOP, BOTTOM = -12, 21  # Ober- und Unterlänge der Schrift

FONT = HersheyFonts()
FONT.load_default_font('cursive')


def dist(a, b):
    return math.hypot(a[0] - b[0], a[1] - b[1])


def length(stroke):
    return sum(dist(a, b) for a, b in zip(stroke, stroke[1:]))


def is_dot(stroke):
    xs = [p[0] for p in stroke]
    ys = [p[1] for p in stroke]
    return max(xs) - min(xs) <= 2 and max(ys) - min(ys) <= 2


def word_strokes(word):
    """Die Striche eines Worts; aneinanderstossende zu einem Zug verbunden, i-Punkte ans Ende."""
    strokes = []
    for stroke in FONT.strokes_for_text(word):
        stroke = list(stroke)
        if strokes and not is_dot(stroke) and not is_dot(strokes[-1]) and dist(strokes[-1][-1], stroke[0]) < 0.01:
            strokes[-1] += stroke[1:]
        else:
            strokes.append(stroke)
    if any(c.isalpha() for c in word):
        strokes = [s for s in strokes if not is_dot(s)] + [s for s in strokes if is_dot(s)]
    return strokes


def pen_path(lines):
    """[(Strich, Pause davor)] in Schreibreihenfolge, schon an ihrer Stelle auf der Notiz."""
    path = []
    last = None
    for row, line in enumerate(lines):
        x = 0
        for col, word in enumerate(line.split(' ')):
            strokes = word_strokes(word)
            left = min(p[0] for s in strokes for p in s)
            right = max(p[0] for s in strokes for p in s)
            for stroke in strokes:
                stroke = [(px - left + x, py + row * LEADING) for px, py in stroke]
                if last is None:
                    pause = 0
                else:
                    travel = dist(last[2], stroke[0])
                    if row != last[0]:
                        pause = 10 + 0.15 * travel
                    elif col != last[1]:
                        pause = 5 + 0.2 * travel
                    else:
                        pause = 0.6 + 0.2 * travel
                path.append((stroke, pause))
                last = (row, col, stroke[-1])
            x += right - left + SPACE
    return path


def num(value):
    return f'{value:.1f}'.rstrip('0').rstrip('.')


def curve(points, corner=80):
    """Catmull-Rom-Kurve durch die Punkte; Ecken über `corner` Grad bleiben spitz."""
    pts = [points[0]] + [p for a, p in zip(points, points[1:]) if dist(a, p) > 1e-6]
    if len(pts) < 3:
        return 'M' + ' '.join(f'{num(x)} {num(y)}' for x, y in pts)
    closed = dist(pts[0], pts[-1]) < 1e-6

    def sharp(i):
        if i in (0, len(pts) - 1):
            return not closed
        a, b, c = pts[i - 1], pts[i], pts[i + 1]
        u = (b[0] - a[0], b[1] - a[1])
        v = (c[0] - b[0], c[1] - b[1])
        return abs(math.degrees(math.atan2(u[0] * v[1] - u[1] * v[0], u[0] * v[0] + u[1] * v[1]))) > corner

    out = [f'M{num(pts[0][0])} {num(pts[0][1])}']
    n = len(pts)
    for i in range(n - 1):
        p1, p2 = pts[i], pts[i + 1]
        p0 = pts[i - 1] if i > 0 else (pts[-2] if closed else p1)
        p3 = pts[i + 2] if i + 2 < n else (pts[1] if closed else p2)
        if i > 0 and sharp(i):
            p0 = p1
        if i + 2 < n and sharp(i + 1):
            p3 = p2
        c1 = (p1[0] + (p2[0] - p0[0]) / 6, p1[1] + (p2[1] - p0[1]) / 6)
        c2 = (p2[0] - (p3[0] - p1[0]) / 6, p2[1] - (p3[1] - p1[1]) / 6)
        out.append('C' + ' '.join(num(v) for v in (*c1, *c2, *p2)))
    return ''.join(out)


def note(lang, lines):
    path = pen_path(lines)
    total = sum(length(s) + pause for s, pause in path)
    unit = TIMELINE / total
    right = max(p[0] for s, _ in path for p in s)
    width = right * SCALE + 2 * PAD
    height = (BOTTOM - TOP + (len(lines) - 1) * LEADING) * SCALE + 2 * PAD
    strokes = []
    t = 0
    for stroke, pause in path:
        t += pause
        pts = [(x * SCALE + PAD, (y - TOP) * SCALE + PAD) for x, y in stroke]
        strokes.append(f'<path d="{curve(pts)}" pathLength="{num(max(length(stroke) * unit, 0.1))}" '
                       f'stroke-dasharray="{num(TIMELINE - t * unit)} {2 * TIMELINE}"/>')
        t += length(stroke)
    svg = (f'<svg class="coffee-note coffee-note-{lang}" viewBox="0 0 {num(width)} {num(height)}" '
           f'width="{width:.0f}" height="{height:.0f}" aria-hidden="true" focusable="false">'
           + ''.join(strokes) + '</svg>\n')
    return svg, total / SPEED


def main():
    for name, (lang, lines) in NOTES.items():
        svg, seconds = note(lang, lines)
        with open(os.path.join(PARTIALS, name), 'w', encoding='utf-8') as f:
            f.write(svg)
        print(f'{name}: {svg.count("<path")} Striche, etwa {seconds:.1f} s')


if __name__ == '__main__':
    main()
