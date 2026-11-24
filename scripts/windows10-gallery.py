#!/usr/bin/env python3
"""Compares the gallery drawn as on Windows 11 with the one drawn as on Windows 10
(gallery.yml): each PNG's size, from its header. Exits 1 if a card's size differs by more
than LIMIT pixels (at the gallery's 2x), so a font change that moves the card shows up."""
import pathlib, struct, sys

LIMIT = 4

def size(path):
    with open(path, "rb") as f:
        head = f.read(24)
    return struct.unpack(">II", head[16:24])

eleven, ten = map(pathlib.Path, sys.argv[1:3])
worst = 0
bad = []
for p in sorted(eleven.glob("*.png")):
    q = ten / p.name
    if not q.exists():
        print(f"{p.name}: missing as on Windows 10")
        bad.append(p.name)
        continue
    (w1, h1), (w0, h0) = size(p), size(q)
    d = max(abs(w1 - w0), abs(h1 - h0))
    card = not p.name.startswith(("welcome", "settings", "history", "anki"))
    print(f"{p.name}\t11: {w1}x{h1}\t10: {w0}x{h0}\t{'same' if d == 0 else f'{d} px off'}")
    if card:
        worst = max(worst, d)
        if d > LIMIT:
            bad.append(p.name)
print(f"cards: at most {worst} px apart (limit {LIMIT})")
sys.exit(1 if bad else 0)
