#!/usr/bin/env python3
"""Writes what Longyan's logic makes of a fixed set of text, without the reading model, so
two builds can be compared line for line: before and after a refactor, or the Mac app and
another platform's. Every line must match.

    python3 scripts/parity.py BINARY OUTDIR          write the outputs
    python3 scripts/parity.py BINARY OUTDIR --against REFDIR   then compare with REFDIR

Run from the repo: the CLI reads Resources/ from there. The text is every sentence in
notes/phrase-eval.tsv, notes/note-pick-eval.tsv, Resources/examples.json and the site's
demo (scripts/site-data.py), plus a few edge cases. For each it writes:
  segment      the phrase card's words
  part-of      the word each single character belongs to, with its meaning
  snap         every 2 to 5 character selection, widened to whole words
  senses-all   every word's and character's senses, in card order
  senses-model the senses the model is offered
  gloss-table  every definition in the dictionary as the card shows it, with its part of speech
  check-data   the notes, examples, cues and sense orders all still find their senses
"""
import json, os, re, subprocess, sys

def corpus():
    sents = []
    for f in ["notes/phrase-eval.tsv", "notes/note-pick-eval.tsv"]:
        for line in open(f, encoding="utf-8"):
            if line.startswith("#"):
                continue
            p = line.rstrip("\n").split("\t")
            if len(p) >= 2:
                sents.append(p[1])
    for v in json.load(open("Resources/examples.json", encoding="utf-8")).values():
        sents += v
    src = open("scripts/site-data.py", encoding="utf-8").read()
    sents += [m.group(1) for m in re.finditer(r'"([^"\n]*[一-鿿][^"\n]*)"', src)]
    # Emoji, traditional, Latin and digits, punctuation only, and known hard cases.
    sents += ["我❤️你，真的。", "他們覺得這個問題很難。", "2023年我在iPhone上用App学中文。", "，。！",
              "把门的合页撬歪了", "行不行，这一行很难", "电商平台大促时，职介部门或子公司都忙。"]
    seen, out = set(), []
    for s in sents:
        s = s.strip()
        if s and s not in seen:
            seen.add(s)
            out.append(s)
    return out

def main():
    if len(sys.argv) < 3:
        sys.exit(__doc__)
    binary, out = sys.argv[1], sys.argv[2]
    against = sys.argv[sys.argv.index("--against") + 1] if "--against" in sys.argv else None
    os.makedirs(out, exist_ok=True)
    text = corpus()
    with open(os.path.join(out, "corpus.txt"), "w", encoding="utf-8") as f:
        f.write("\n".join(text) + "\n")

    def run(name, args, extra=None):
        with open(os.path.join(out, name + ".txt"), "w", encoding="utf-8") as f:
            for i in range(0, len(extra or [None]), 400):
                chunk = extra[i:i + 400] if extra else []
                r = subprocess.run([binary] + args + chunk, capture_output=True, text=True, encoding="utf-8")
                f.write(r.stdout)
                if r.stderr:
                    f.write("STDERR " + r.stderr)

    run("check-data", ["--check-data"])
    run("segment", ["--segment-file", os.path.join(out, "corpus.txt")])
    run("gloss-table", ["--gloss-table", "Resources/cedict_ts.u8"])
    snaps, parts = [], []
    for s in text:
        for a in range(len(s)):
            parts.append(s[:a] + "【" + s[a] + "】" + s[a + 1:])
            for n in (2, 3, 4, 5):
                if a + n <= len(s):
                    snaps.append(s[:a] + "【" + s[a:a + n] + "】" + s[a + n:])
    run("part-of", ["--part-of"], parts)
    run("snap", ["--snap"], snaps)
    words = set()
    for line in open(os.path.join(out, "segment.txt"), encoding="utf-8"):
        words.update(line.split())
    for s in text:
        words.update(c for c in s if "一" <= c <= "鿿")
    words = sorted(words)
    run("senses-all", ["--senses-all"], words)
    run("senses-model", ["--senses"], words)
    print(f"{len(text)} sentences, {len(parts)} characters, {len(snaps)} selections, {len(words)} words")

    if against:
        bad = 0
        for name in sorted(os.listdir(against)):
            a, b = os.path.join(against, name), os.path.join(out, name)
            if not os.path.exists(b) or open(a, "rb").read() != open(b, "rb").read():
                bad += 1
                print("DIFF", name)
        print("all outputs match" if not bad else f"{bad} outputs differ")
        sys.exit(1 if bad else 0)

main()
