# Writes Resources/output-tokens.txt: the Qwen 3.5 tokens the built-in model may write (EmbeddedModel
# keeps only their rows of the output table). They are every token of CC-CEDICT's English definitions
# (as is, capitalized and lowercased, with and without a leading space), every one-character ASCII
# token, the control tokens, and every word of /usr/share/dict/words, with plain inflections, that is
# a single token. Picks only read digits and replies are English, so nothing else is needed.
#   python3 scripts/make-output-tokens.py path/to/tokenizer.json   (from any Qwen 3.5 model on
#   Hugging Face; they share one; needs `pip install tokenizers`)
import sys, re
from tokenizers import Tokenizer

tok = Tokenizer.from_file(sys.argv[1])
enc = lambda s: tok.encode(s, add_special_tokens=False).ids

keep = set()
for l in open("Resources/cedict_ts.u8", encoding="utf-8"):
    if l.startswith("#"): continue
    m = re.search(r"/(.*)/", l)
    if not m: continue
    for d in m.group(1).split("/"):
        if not d: continue
        for v in (d, " " + d, d.capitalize(), " " + d.capitalize(), d.lower(), " " + d.lower()):
            keep.update(enc(v))
for i in range(tok.get_vocab_size()):
    s = tok.decode([i])
    if len(s.strip()) <= 1 and all(ord(ch) < 128 for ch in s): keep.add(i)
keep |= {i for t, i in tok.get_vocab(with_added_tokens=True).items() if t.startswith("<")}

forms = set()
for x in (l.strip() for l in open("/usr/share/dict/words")):
    forms.add(x)
    if x.islower() and x.isalpha():
        forms.update([x + "s", x + "es", x + "ed", x + "d", x + "ing", x + "er", x + "ly",
                      x[:-1] + "ies" if x.endswith("y") else x + "s", x[:-1] + "ied" if x.endswith("y") else x + "ed"])
for x in forms:
    for v in (" " + x, x, " " + x.capitalize(), x.capitalize()):
        e = enc(v)
        if len(e) == 1: keep.add(e[0])   # only whole-word tokens: a longer word's pieces are kept above

open("Resources/output-tokens.txt", "w").write("\n".join(map(str, sorted(keep))) + "\n")
print(len(keep), "of", tok.get_vocab_size(), "tokens")
