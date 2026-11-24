# Per pick request: tokens and ms at the first and last row, from "pickrow I/N: T tok, M ms" lines.
import re, sys, statistics as st
reqs, cur = [], []
for line in open(sys.argv[1], errors='replace'):
    m = re.match(r'pickrow (\d+)/(\d+): (\d+) tok, (\d+) ms', line)
    if not m: continue
    i, n, t, ms = map(int, m.groups())
    if i == 1: cur = []
    cur.append((t, ms))
    if i == n: reqs.append((n, cur))
def show(label, rs):
    if not rs: return
    f = lambda k, j: st.mean(r[1][j][k] for r in rs)
    med = lambda k, j: st.median(r[1][j][k] for r in rs)
    print(f"{label}: {len(rs)} requests, {st.mean(r[0] for r in rs):.1f} words; first row {f(0,0):.0f} tok {f(1,0)/1000:.2f} s (median {med(1,0)/1000:.2f}); last row {f(0,-1):.0f} tok {f(1,-1)/1000:.2f} s (median {med(1,-1)/1000:.2f})")
show("all", reqs)
show("2+ words", [r for r in reqs if r[0] >= 2])
show("4+ words", [r for r in reqs if r[0] >= 4])
