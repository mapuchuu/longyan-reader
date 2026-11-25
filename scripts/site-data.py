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
    "今天我请客，你们随便点。",
    "他上班摸鱼，被老板发现了。",
    "过年回家，爷爷给了我一个大红包。",
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
    "今天我请客，你们随便点。",
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
    "过年回家，爷爷给了我一个大红包。",
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
# sense's own short gloss; 0 for none ticked, with the meaning written out). It applies to the word's card, to "Part of" rows, and to its row
# in every phrase card. "word@start" limits it to the word at that character position, where
# the same word comes twice in a sentence with different meanings.
DEMO_FIX = {
    "最近工作太卷了，我想躺平。": {
        "太": (1, None),               # was "very": the translation itself says "too cutthroat"
        "工作": (4, None),             # "work", as every translation has it (was "task", then "job")
        "想": (2, "to want (to)"),     # was "to desire": the translation says "want to"
        "最": (1, None),               # in 最近: "most", not "best or most extreme example"
        "近": (1, None),               # in 最近: "near"
        "躺": (2, None),               # in 躺平: "to lie down"
        "平": (1, None),               # in 躺平: "flat", not "calm"
        "了": ("g", 'with 太: "too …"'),  # the 太…了 frame, not "action done"
    },
    "他上班摸鱼，被老板发现了。": {
        "摸鱼": (2, None),             # some phrase cards had "to catch fish"
        "摸": (1, "to feel around (for)"),  # in 摸鱼 (from 浑水摸鱼, feeling for fish); not "to grope"
        "老": (0, 'a prefix here, not "old" (as in 老师)'),  # no sense in the list fits; none ticked
        "板": (0, "the simplified form of 闆, as in 老闆"),  # none ticked
        "发现": (1, "to find out"),    # the boss noticed him: sense 1 "to notice", not "to discover"
        "上班": (2, "to be at work"),  # 上班摸鱼: slacking while at work, not "to go to work"
        "上": (4, "to go to (work)"),  # in 上班; sense 4 is "to attend"
        "发": (0, "to bring out, to reveal"),  # in 发现; no sense in the list fits ("to show" was ticked)
    },
    "今天我请客，你们随便点。": {
        "请客": (3, "to treat (someone) to a meal"),  # was "to give a dinner party": here it means paying
        "你们": (1, "you (plural)"),    # was "you": the plural is the point
        "今": (5, None),               # in 今天: "this" (this day)
        "客": (1, "guest"),            # in 请客: "customer, guest", not the measure word
        "随": (1, None),               # in 随便: "to follow", not "to allow"
        "便": (4, None),               # in 随便: "convenient", not "informal"
    },
    "过年回家，爷爷给了我一个大红包。": {
        "红": (1, None),               # in 红包: "red", not "bonus"
        "大": (1, "big (lots of money inside)"),  # 大红包: a generous one; some phrase cards had "greatly"
        "年": (1, "year, here the New Year"),  # in 过年
        "包": (13, None),              # in 红包: "packet", not "bag"
        "了": ("g", "action done"),    # 给了: only completion here
    },
}
# Dictionary senses reworded where the ticked one says the opposite of the card:
# (sentence, word, sense number) -> wording.
SENSE_FIX = {
    ("今天我请客，你们随便点。", "请客", 3): "to treat (someone) to a meal",  # was "to invite to dinner", which its note rules out
}
# Notes reworded: word -> (old start, new start).
NOTE_FIX = {
    "过年": ("Means going home", "Usually means going home"),  # 过年 is to celebrate the New Year; going home is what most do
}
# The eye's sentences (pointing at a word shows its meaning): (sentence, start) -> meaning.
PAGE_FIX = {
    ("周末早上，楼下的咖啡店总是排着长队。", 13): "to line up",
    ("最近工作太卷了，我想躺平。", 4): "too",
    ("最近工作太卷了，我想躺平。", 9): "to want (to)",
    ("今天我请客，你们随便点。", 3): "to treat (someone) to a meal",
    ("最近工作太卷了，我想躺平。", 2): "work",
    ("他上班摸鱼，被老板发现了。", 9): "to find out",
    ("他上班摸鱼，被老板发现了。", 1): "to be at work",
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


def widen(d):
    """A selection that starts or ends inside a word reads the whole word. The app does this for
    most cuts but not all (年回 read 年回家, splitting 过年), so the site makes sure of it."""
    toks = [t["range"] for t in d["tokens"]]
    for k, (a, b, one) in list(d["selections"].items()):
        if one:
            continue
        a2 = next((s for s, e in toks if s < a < e), a)
        b2 = next((e for s, e in toks if s < b < e), b)
        if (a2, b2) != (a, b) and f"{a2}-{b2}" in d["phrases"]:
            d["selections"][k] = [a2, b2, 0]
    used = {f"{a}-{b}" for a, b, one in d["selections"].values() if not one}
    for k in [k for k in d["phrases"] if k not in used]:
        del d["phrases"][k]


def fix(data):
    for d in data["demo"]:
        for (sent, word, n), text in SENSE_FIX.items():
            if sent == d["sentence"]:
                d["words"][word][n - 1].update(short=text, listed=text, readable=text)
        for word, (old, new) in NOTE_FIX.items():
            for sn in d["words"].get(word, []):
                if sn.get("note") and sn["note"]["text"].startswith(old):
                    sn["note"]["text"] = new + sn["note"]["text"][len(old):]
        widen(d)
        # A grammar word's card lists its senses in plain words; a phrase row opening the same
        # word should read the same, not the dictionary's "(completed action marker)".
        for c in d["cards"].values():
            if c.get("grammar") and c["grammar"].get("listed"):
                for i in c["grammar"]["listed"]:
                    sn = d["words"][c["word"]][i]
                    sn["listed"] = sn["short"]
        for key, (n, meaning) in DEMO_FIX.get(d["sentence"], {}).items():
            word, _, at = key.partition("@")
            at = int(at) if at else None
            if n == "g":
                # A grammar word: its summary, on its card and in every phrase row.
                for c in d["cards"].values():
                    if c["word"] == word and c.get("grammar"):
                        c["grammar"]["summary"] = c["meaning"] = meaning
                for p in d["phrases"].values():
                    for r in p["rows"]:
                        if r["text"] == word and r.get("grammar"):
                            r["grammar"] = r["gloss"] = meaning
                continue
            senses = d["words"][word]
            text = meaning or senses[n - 1]["short"]
            for k, c in d["cards"].items():
                if c["word"] == word and not c.get("grammar") and (at is None or int(k.split("-")[0]) == at):
                    c["chosen"], c["meaning"] = n, text
                if c.get("partOf") and c["partOf"]["word"] == word and (at is None or c["partOf"]["range"][0] == at):
                    c["partOf"]["meaning"] = text
            for p in d["phrases"].values():
                for r in p["rows"]:
                    if r["text"] == word and not r.get("grammar") and (at is None or r["start"] == at):
                        if n == 0:
                            r["gloss"], r["shown"] = text, None
                            continue
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
