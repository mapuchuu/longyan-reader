#!/usr/bin/env python3
"""Writes site/data.js for longyan.app: the demo passage, looked up by the app itself (its
segmenter, the reading model's picks and translations, the dictionary and notes), and the
page the hero is printed from. Run after a release build, when the demo or data changes:

    swift build -c release && python3 scripts/site-data.py

`--fixes-only` applies the site's corrections (DEMO_FIX, PAGE_FIX) to site/data.js as it is.
"""
import json
import sys, os, subprocess

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
BIN = os.path.join(ROOT, ".build/release/LongyanReader")

DEMO = [
    "最近工作太卷了，我想躺平。",
    "她看到男朋友给别人点赞，有点吃醋。",
    "他上班摸鱼，被老板发现了。",
]

# The page the hero is printed from: everyday sentences, the demo ones among them. Keep
# only sentences the app reads right; every visitor sees these readings. Each is read
# by the app (`--site-json`) so pointing at a word shows its meaning in that sentence.
PAGE = [
    "周末早上，楼下的咖啡店总是排着长队。",
    "最近工作太卷了，我想躺平。",
    "她看到男朋友给别人点赞，有点吃醋。",
    "我妈每天晚上都给我发语音，问我吃饭了没有。",
    "他上班摸鱼，被老板发现了。",
    "这家小店的面很好吃，价格也不贵。",
    "下雨的时候，街上的人少了很多。",
    "说实话，这部剧的结局让我有点失望。",
    "奶奶养的那只猫又胖了。",
    "今年夏天特别热，空调一直开着。",
    "他说话很直，但是人不坏。",
    "学中文最难的不是汉字，是声调。",
    "楼上的邻居每天晚上都在练钢琴。",
    "我把手机忘在出租车上了。",
    "这个周末你有空吗？我们去看电影吧。",
    "他每天跑步五公里，已经坚持了三年。",
    "老师说这次考试不难，可是大家都没考好。",
    "春节快到了，火车票越来越难买。",
    "别着急，慢慢来，事情总会解决的。",
    "他拍的照片很有感觉，像电影里的画面。",
    "这条街晚上特别热闹，到处都是小吃摊。",
    "她一边听歌一边写作业。",
    "我觉得这个想法不错，可以试试。",
    "门口的快递已经放了两天了。",
    "有空的时候，我喜欢一个人去书店坐坐。",
]


def read(s):
    r = subprocess.run([BIN, "--site-words", s], capture_output=True, text=True, cwd=ROOT)
    return json.loads(r.stdout)


def page(cache):
    """Each sentence's words as [start, end, pinyin syllables with tones, meaning here]."""
    out = []
    for s in PAGE:
        d = cache[s] if s in cache else read(s)
        words = []
        for t in d["tokens"]:
            c = d["cards"].get(f'{t["range"][0]}-{t["range"][1]}')
            if not c:
                continue
            words.append([t["range"][0], t["range"][1], [[x["t"], x["tone"]] for x in c["header"]], c["meaning"]])
        out.append({"s": s, "w": words})
        print("page:", s, len(words), "words")
    return out


def written(d):
    """The demo's phrase translations from scripts/demo-translations.tsv, in place of the app's:
    the translator can add words from outside a selection, and these say only what's selected."""
    rows = {}
    with open(os.path.join(ROOT, "scripts/demo-translations.tsv"), encoding="utf-8") as f:
        for line in f:
            if line.strip() and not line.startswith("#"):
                s, k, text, tr = line.rstrip("\n").split("\t")
                rows[(s, k)] = (text, tr)
    for k, p in d["phrases"].items():
        text, tr = rows.get((d["sentence"], k), (None, None))
        if text != p["text"]:
            sys.exit(f"scripts/demo-translations.tsv has no translation for {p['text']} ({k}) in {d['sentence']}")
        p["translation"] = tr
    return d


# The site's own corrections, where the app's pick is wrong for the sentence. The app is being
# fixed separately; until then the site shows these. Each one is a sense from the dictionary
# (CC-CEDICT) or plain wording of it. Remove a line once the app gets it right on its own.
#
# The demo: word -> (sense number in its card's list, 1-based; meaning shown, or None for the
# sense's own short gloss). It applies to the word's card, to "Part of" rows, and to its row
# in every phrase card.
DEMO_FIX = {
    "最近工作太卷了，我想躺平。": {
        "太": (1, None),               # was "very": the translation itself says "too cutthroat"
        "工作": (3, None),             # was "task" in the selections starting at 最近
        "想": (2, "to want (to)"),     # was "to desire": the translation says "want to"
        "最": (1, None),               # in 最近: "most", not "best or most extreme example"
        "近": (1, None),               # in 最近: "near"
        "躺": (2, None),               # in 躺平: "to lie down"
        "平": (1, None),               # in 躺平: "flat", not "calm"
    },
}
# The eye's sentences (pointing at a word shows its meaning): (sentence, start) -> meaning.
PAGE_FIX = {
    ("周末早上，楼下的咖啡店总是排着长队。", 13): "to line up",
    ("最近工作太卷了，我想躺平。", 4): "too",
    ("最近工作太卷了，我想躺平。", 9): "to want (to)",
    ("我妈每天晚上都给我发语音，问我吃饭了没有。", 1): "mom",
    ("我妈每天晚上都给我发语音，问我吃饭了没有。", 18): "haven't",
    ("下雨的时候，街上的人少了很多。", 3): "time",
    ("下雨的时候，街上的人少了很多。", 9): "people",
    ("下雨的时候，街上的人少了很多。", 13): "a lot",
    ("说实话，这部剧的结局让我有点失望。", 6): "TV series",
    ("说实话，这部剧的结局让我有点失望。", 8): "ending",
    ("学中文最难的不是汉字，是声调。", 11): "to be",
    ("学中文最难的不是汉字，是声调。", 12): "tone",
    ("这个周末你有空吗？我们去看电影吧。", 15): "makes a suggestion: let's",
    ("老师说这次考试不难，可是大家都没考好。", 2): "to say",
    ("老师说这次考试不难，可是大家都没考好。", 17): "well",
    ("春节快到了，火车票越来越难买。", 3): "to arrive",
    ("别着急，慢慢来，事情总会解决的。", 8): "matter",
    ("别着急，慢慢来，事情总会解决的。", 10): "eventually",
    ("别着急，慢慢来，事情总会解决的。", 14): "ends a statement, for emphasis",
    ("他拍的照片很有感觉，像电影里的画面。", 6): "to have",
    ("这条街晚上特别热闹，到处都是小吃摊。", 13): "to be",
    ("我觉得这个想法不错，可以试试。", 5): "idea",
    ("有空的时候，我喜欢一个人去书店坐坐。", 3): "time",
}


def fix(data):
    for d in data["demo"]:
        for word, (n, meaning) in DEMO_FIX.get(d["sentence"], {}).items():
            senses = d["words"][word]
            text = meaning or senses[n - 1]["short"]
            for c in d["cards"].values():
                if c["word"] == word and not c.get("grammar"):
                    c["chosen"], c["meaning"] = n, text
                if c.get("partOf") and c["partOf"]["word"] == word:
                    c["partOf"]["meaning"] = text
            for p in d["phrases"].values():
                for r in p["rows"]:
                    if r["text"] == word and not r.get("grammar"):
                        r["shown"], r["gloss"] = n - 1, text
                        if n - 1 not in r["collapsed"]:
                            r["collapsed"] = sorted(r["collapsed"] + [n - 1])
    for pg in data["page"]:
        for w in pg["w"]:
            if (pg["s"], w[0]) in PAGE_FIX:
                w[3] = PAGE_FIX[(pg["s"], w[0])]
    missing = [k for k in PAGE_FIX if not any(pg["s"] == k[0] and any(w[0] == k[1] for w in pg["w"]) for pg in data["page"])]
    if missing:
        sys.exit(f"PAGE_FIX names words that aren't there: {missing}")
    return data


def demo():
    """Each sentence as the app's cards show it: `--site-json` runs the cards' own state classes
    on every selection the sentence allows (trimmed and widened to whole words as the app does
    it), with the reading model's picks and translations."""
    out = []
    for s in DEMO:
        r = subprocess.run([BIN, "--site-json", s], capture_output=True, text=True, cwd=ROOT)
        out.append(written(json.loads(r.stdout)))
        print("demo:", s, "->", out[-1]["phrases"].get(max(out[-1]["phrases"], key=lambda k: len(out[-1]["phrases"][k]["text"])), {}).get("translation"))
    return out


def main():
    path = os.path.join(ROOT, "site/data.js")
    if "--fixes-only" in sys.argv:
        # Just the corrections above, on the site/data.js there is, without running the app.
        with open(path, encoding="utf-8") as f:
            src = f.read()
        data = fix(json.loads(src[src.index("{"):src.rstrip().rindex(";")]))
    else:
        d = demo()
        data = fix({"demo": d, "page": page({x["sentence"]: x for x in d})})
    with open(path, "w", encoding="utf-8") as f:
        f.write("// Made by scripts/site-data.py from the app's own lookups. Don't edit by hand.\n")
        f.write("window.LONGYAN = " + json.dumps(data, ensure_ascii=False, separators=(",", ":")) + ";\n")
    print("wrote site/data.js:", len(data["page"]), "page sentences,", os.path.getsize(path) // 1024, "KB")


if __name__ == "__main__":
    main()
