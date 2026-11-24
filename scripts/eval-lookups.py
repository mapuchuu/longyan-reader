# The eval sets' words as BridgeCheck lookups, each the word at its place in its sentence, as
# a word card under the pointer finds it (start = end). For windows.yml's speed job.
#   eval-lookups.py notes/note-pick-eval.tsv notes/phrase-eval.tsv > lookups.txt
# Offsets are UTF-16 units, as BridgeCheck takes them.
import sys

def u16(s): return len(s.encode('utf-16-le')) // 2

seen = set()
for path in sys.argv[1:]:
    for line in open(path, encoding='utf-8'):
        if line.startswith('#') or not line.strip(): continue
        f = line.rstrip('\n').split('\t')
        if len(f) != 4 or f[2] not in f[1]: continue
        at = u16(f[1][:f[1].index(f[2])])
        if (f[1], at) in seen: continue
        seen.add((f[1], at))
        print(f'{f[1]}\t{at}\t{at}')
