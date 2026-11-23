# The model's sense picks for every word of the gallery's passages (windows/gallery/cases.tsv),
# to compare across machines (windows.yml's pick parity step).
#   pick-parity.py phrases CASES > phrases.txt          each passage whole, for BridgeCheck without a model
#   pick-parity.py words CASES PHRASES OUT > words.txt  every row of those cards as a word lookup
#   pick-parity.py picks WORDS OUT                      one line per word: passage, word, pick, meaning
# Offsets are UTF-16 units, as BridgeCheck takes them.
import json, sys

def u16(s): return len(s.encode('utf-16-le')) // 2

def cases(path):
    for line in open(path, encoding='utf-8'):
        if line.startswith('#') or not line.strip(): continue
        p = line.rstrip('\n').split('\t')
        yield p[1], p[2]

def lookups(path):
    for line in open(path, encoding='utf-8'):
        if line.startswith('#') or not line.strip(): continue
        p, a, b = line.rstrip('\n').split('\t')
        yield p, int(a), int(b)

cmd = sys.argv[1]
if cmd == 'phrases':
    seen = []
    for passage, _ in cases(sys.argv[2]):
        if passage not in seen: seen.append(passage)
    for p in seen: print(f'{p}\t0\t{u16(p)}')
elif cmd == 'words':
    out, seen = [], set()
    def add(p, a, b):
        if (p, a, b) not in seen: seen.add((p, a, b)); out.append((p, a, b))
    for passage, sel in cases(sys.argv[2]):
        if sel != passage and sel in passage:
            i = passage.index(sel); add(passage, u16(passage[:i]), u16(passage[:i]) + u16(sel))
    for (p, _, _), line in zip(lookups(sys.argv[3]), open(sys.argv[4], encoding='utf-8')):
        card = json.loads(line).get('card') or {}
        at = 0
        for r in card.get('rows', []):
            i = p.find(r['text'], at)
            if i < 0: continue
            at = i + len(r['text'])
            add(p, u16(p[:i]), u16(p[:at]))
    for p, a, b in out: print(f'{p}\t{a}\t{b}')
elif cmd == 'picks':
    for (p, a, b), line in zip(lookups(sys.argv[2]), open(sys.argv[3], encoding='utf-8')):
        card = json.loads(line).get('card') or {}
        word = card.get('word', '?')
        senses = card.get('senses', [])
        chosen = [s['number'] for s in senses if s.get('chosen')]
        pick = str(chosen[0]) if chosen else ('-' if len(senses) > 1 else 'only')
        print(f"{p}\t{word}\tpick {pick}\t{card.get('meaning') or card.get('status') or ''}")
