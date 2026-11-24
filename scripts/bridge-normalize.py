# One JSON object per line in, the same with sorted keys and plain escapes out, so two
# platforms' JSON writers can be compared.
import json, sys
for line in sys.stdin:
    line = line.strip()
    if line: print(json.dumps(json.loads(line), ensure_ascii=False, sort_keys=True))
