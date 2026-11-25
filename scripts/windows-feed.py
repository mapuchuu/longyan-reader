#!/usr/bin/env python3
"""The Windows app's update feed (appcast-windows.xml), which WinSparkle reads.

The Mac's feed is generate_appcast's, on the latest release. Windows has its own: its releases
aren't marked latest, generate_appcast rewrites the Mac's feed from scratch each release, and
WinSparkle would take the Mac's items (they have no sparkle:os, which WinSparkle reads as any OS).

  windows-feed.py new-key PRIVATE_FILE
      A new update key: the private half (base64 of the 32-byte ed25519 seed, as Sparkle's) goes
      in PRIVATE_FILE, the public half is printed. scripts/windows-update-key.sh runs this.
  windows-feed.py public-key
      The public half of $WINDOWS_UPDATE_KEY.
  windows-feed.py add FEED --version 1.0 --build 210 --notes notes.md --url-prefix URL
                  --installer x64=PATH --installer arm64=PATH [--installer-args ARGS] [--require-signature]
      Adds the version to FEED (made if missing) as the newest item, one enclosure per arch
      (sparkle:os windows-x64 / windows-arm64, which WinSparkle picks by its own arch). Each
      installer is signed with $WINDOWS_UPDATE_KEY; without the key the item goes in unsigned
      and the app, which needs a signature, won't install it. WinSparkle runs the installer with
      ARGS, by default the silent update: /VERYSILENT /SUPPRESSMSGBOXES /NORESTART /OPEN=1 (no
      windows, and the app opens again after).

      It also writes the feed for the x64 app on an ARM PC, appcast-windows-x64-on-arm64.xml
      beside FEED: the same items, each with its ARM64 installer marked windows-x64, so that
      copy moves to the native build at its next update. WinSparkle can't be told to take the
      ARM64 enclosure: it picks the one for the arch it was built for. Items with no ARM64
      installer keep their x64 one.
  windows-feed.py verify FEED PUBLIC_KEY [DIR]
      Checks the newest item's signatures against the files in DIR (by name).

Standard library only: the ed25519 code is RFC 8032's, so this runs with the Mac's python3 too.
"""
import argparse
import base64
import email.utils
import hashlib
import html
import os
import re
import secrets
import sys
import xml.etree.ElementTree as ET

# ed25519 (RFC 8032, section 5.1), with points in extended coordinates.
P = 2**255 - 19
L = 2**252 + 27742317777372353535851937790883648493
D = -121665 * pow(121666, P - 2, P) % P
SQRT_M1 = pow(2, (P - 1) // 4, P)


def _add(a, b):
    x1, y1, z1, t1 = a
    x2, y2, z2, t2 = b
    A = (y1 - x1) * (y2 - x2) % P
    B = (y1 + x1) * (y2 + x2) % P
    C = 2 * t1 * t2 * D % P
    Dd = 2 * z1 * z2 % P
    E, F, G, H = B - A, Dd - C, Dd + C, B + A
    return (E * F % P, G * H % P, F * G % P, E * H % P)


def _mul(s, pt):
    q = (0, 1, 1, 0)
    while s:
        if s & 1:
            q = _add(q, pt)
        pt = _add(pt, pt)
        s >>= 1
    return q


def _x(y, sign):
    x2 = (y * y - 1) * pow(D * y * y + 1, P - 2, P) % P
    if x2 == 0:
        return None if sign else 0
    x = pow(x2, (P + 3) // 8, P)
    if (x * x - x2) % P:
        x = x * SQRT_M1 % P
    if (x * x - x2) % P:
        return None
    return P - x if (x & 1) != sign else x


_GY = 4 * pow(5, P - 2, P) % P
_GX = _x(_GY, 0)
BASE = (_GX, _GY, 1, _GX * _GY % P)


def _encode(pt):
    x, y, z, _ = pt
    zi = pow(z, P - 2, P)
    x, y = x * zi % P, y * zi % P
    return (y | ((x & 1) << 255)).to_bytes(32, "little")


def _decode(b):
    if len(b) != 32:
        return None
    y = int.from_bytes(b, "little")
    sign = y >> 255
    y &= (1 << 255) - 1
    if y >= P:
        return None
    x = _x(y, sign)
    return None if x is None else (x, y, 1, x * y % P)


def _expand(seed):
    h = hashlib.sha512(seed).digest()
    a = int.from_bytes(h[:32], "little")
    a &= (1 << 254) - 8
    a |= 1 << 254
    return a, h[32:]


def public_key(seed):
    return _encode(_mul(_expand(seed)[0], BASE))


def sign(seed, msg):
    a, prefix = _expand(seed)
    pub = _encode(_mul(a, BASE))
    r = int.from_bytes(hashlib.sha512(prefix + msg).digest(), "little") % L
    R = _encode(_mul(r, BASE))
    k = int.from_bytes(hashlib.sha512(R + pub + msg).digest(), "little") % L
    return R + ((r + k * a) % L).to_bytes(32, "little")


def verify(pub, msg, sig):
    A, R = _decode(pub), _decode(sig[:32])
    if A is None or R is None or len(sig) != 64:
        return False
    s = int.from_bytes(sig[32:], "little")
    if s >= L:
        return False
    k = int.from_bytes(hashlib.sha512(sig[:32] + pub + msg).digest(), "little") % L
    return _encode(_mul(s, BASE)) == _encode(_add(R, _mul(k, A)))


def load_key():
    """The seed in $WINDOWS_UPDATE_KEY (base64), or None when it isn't set."""
    text = os.environ.get("WINDOWS_UPDATE_KEY", "").strip()
    if not text:
        return None
    seed = base64.b64decode(text)
    if len(seed) != 32:
        sys.exit("WINDOWS_UPDATE_KEY isn't a 32-byte ed25519 seed in base64 (scripts/windows-update-key.sh makes one)")
    return seed


# The feed.
SPARKLE = "http://www.andymatuschak.org/xml-namespaces/sparkle"
ET.register_namespace("sparkle", SPARKLE)
ARCHES = ("x64", "arm64")
# What WinSparkle runs the installer with: windows/installer/LongyanReader.iss.
UPDATE_ARGS = "/VERYSILENT /SUPPRESSMSGBOXES /NORESTART /OPEN=1"
ON_ARM_NAME = "appcast-windows-x64-on-arm64.xml"


def s(name):
    return "{%s}%s" % (SPARKLE, name)


def _inline(t):
    """Bold, `code` and [text](url) links, on escaped text."""
    t = html.escape(t, quote=False)
    t = re.sub(r"\*\*(.+?)\*\*", r"<strong>\1</strong>", t)
    t = re.sub(r"`([^`]+)`", r"<code>\1</code>", t)
    t = re.sub(r"\[([^\]]+)\]\((https?://[^)\s\"]+)\)", r'<a href="\2">\1</a>', t)
    return t


def notes_html(markdown):
    """The release notes as the small HTML WinSparkle's window shows: paragraphs, lists, bold, code and links."""
    out = []
    for block in re.split(r"\n\s*\n", markdown.strip()):
        lines = [l.rstrip() for l in block.splitlines() if l.strip()]
        inline = _inline
        if lines and all(l.lstrip().startswith(("- ", "* ")) for l in lines):
            out.append("<ul>" + "".join("<li>%s</li>" % inline(l.lstrip()[2:]) for l in lines) + "</ul>")
        else:
            out.append("<p>%s</p>" % inline(" ".join(lines)))
    style = "<style>body{font-family:'Segoe UI',sans-serif;font-size:14px;line-height:1.4}code{font-family:Consolas,monospace;font-size:13px}</style>"
    return style + "\n".join(out)


def read_feed(path):
    if os.path.exists(path) and os.path.getsize(path) > 0:
        tree = ET.parse(path)
        channel = tree.getroot().find("channel")
        if channel is None:
            sys.exit(f"{path} has no <channel>")
        return tree, channel
    rss = ET.Element("rss", {"version": "2.0"})
    channel = ET.SubElement(rss, "channel")
    ET.SubElement(channel, "title").text = "Longyan Reader for Windows"
    return ET.ElementTree(rss), channel


def add(args):
    seed = load_key()
    if seed is None:
        if args.require_signature:
            sys.exit("WINDOWS_UPDATE_KEY isn't set: no signatures, so installed copies would refuse this update")
        print("warning: WINDOWS_UPDATE_KEY isn't set, so the installers aren't signed and the app won't install them", file=sys.stderr)
    installers = dict(i.split("=", 1) for i in args.installer)
    if not installers or set(installers) - set(ARCHES):
        sys.exit("--installer ARCH=PATH, with ARCH x64 or arm64")
    if not args.build.isdigit():
        sys.exit("--build is a whole number (the commit count), which WinSparkle compares")
    tree, channel = read_feed(args.feed)
    # The same build again replaces its item.
    for old in channel.findall("item"):
        if (old.findtext(s("version")) or "").strip() == args.build:
            channel.remove(old)
    item = ET.Element("item")
    ET.SubElement(item, "title").text = args.version
    ET.SubElement(item, "pubDate").text = email.utils.formatdate(localtime=False)
    ET.SubElement(item, s("version")).text = args.build
    ET.SubElement(item, s("shortVersionString")).text = args.version
    with open(args.notes, encoding="utf-8") as f:
        ET.SubElement(item, "description").text = notes_html(f.read())
    prefix = args.url_prefix if args.url_prefix.endswith("/") else args.url_prefix + "/"
    for arch in ARCHES:
        if arch not in installers:
            continue
        path = installers[arch]
        with open(path, "rb") as f:
            data = f.read()
        attrs = {
            "url": prefix + os.path.basename(path),
            "length": str(len(data)),
            "type": "application/octet-stream",
            s("os"): "windows-" + arch,
        }
        if seed is not None:
            sig = sign(seed, data)
            if not verify(public_key(seed), data, sig):
                sys.exit("the signature didn't check out")
            attrs[s("edSignature")] = base64.b64encode(sig).decode()
        if args.installer_args:
            attrs[s("installerArguments")] = args.installer_args
        ET.SubElement(item, "enclosure", attrs)
    # Newest first: WinSparkle takes the first item it can use.
    title = channel.find("title")
    channel.insert(list(channel).index(title) + 1 if title is not None else 0, item)
    ET.indent(tree, "  ")
    tree.write(args.feed, encoding="utf-8", xml_declaration=True)
    print(f"{args.feed}: {args.version} (build {args.build}), {', '.join(a for a in ARCHES if a in installers)}"
          + ("" if seed else ", unsigned"))
    print(f"{write_on_arm(args.feed)}: the same, with the ARM64 installers for the x64 app on ARM")


def on_arm_path(feed):
    return os.path.join(os.path.dirname(feed), ON_ARM_NAME)


def write_on_arm(feed):
    """The feed for the x64 app on an ARM PC, from FEED: each item's ARM64 enclosure in the
    x64 one's place, so x64 WinSparkle takes it."""
    tree = ET.parse(feed)
    for item in tree.getroot().iter("item"):
        enclosures = item.findall("enclosure")
        arm = [e for e in enclosures if e.get(s("os")) == "windows-arm64"]
        if not arm:
            continue
        for e in enclosures:
            item.remove(e)
        arm[0].set(s("os"), "windows-x64")
        item.append(arm[0])
    path = on_arm_path(feed)
    ET.indent(tree, "  ")
    tree.write(path, encoding="utf-8", xml_declaration=True)
    return path


def check(args):
    pub = base64.b64decode(args.public_key)
    item = ET.parse(args.feed).getroot().find("channel/item")
    if item is None:
        sys.exit("no items")
    bad = 0
    for enc in item.findall("enclosure"):
        name = enc.get("url").rsplit("/", 1)[-1]
        with open(os.path.join(args.dir, name), "rb") as f:
            data = f.read()
        sig = enc.get(s("edSignature"))
        ok = sig is not None and int(enc.get("length")) == len(data) and verify(pub, data, base64.b64decode(sig))
        print(f"{name} ({enc.get(s('os'))}): {'good' if ok else 'BAD'}")
        bad += not ok
    sys.exit(1 if bad else 0)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="command", required=True)
    k = sub.add_parser("new-key")
    k.add_argument("private_file")
    sub.add_parser("public-key")
    a = sub.add_parser("add")
    a.add_argument("feed")
    a.add_argument("--version", required=True)
    a.add_argument("--build", required=True)
    a.add_argument("--notes", required=True)
    a.add_argument("--url-prefix", required=True)
    a.add_argument("--installer", action="append", default=[])
    a.add_argument("--installer-args", default=UPDATE_ARGS)
    a.add_argument("--require-signature", action="store_true")
    v = sub.add_parser("verify")
    v.add_argument("feed")
    v.add_argument("public_key")
    v.add_argument("dir", nargs="?", default=".")
    args = ap.parse_args()
    if args.command == "new-key":
        if os.path.exists(args.private_file):
            sys.exit(f"{args.private_file} already exists: a new key would stop installed copies from updating")
        seed = secrets.token_bytes(32)
        fd = os.open(args.private_file, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(fd, "w") as f:
            f.write(base64.b64encode(seed).decode() + "\n")
        print(base64.b64encode(public_key(seed)).decode())
    elif args.command == "public-key":
        seed = load_key()
        if seed is None:
            sys.exit("WINDOWS_UPDATE_KEY isn't set")
        print(base64.b64encode(public_key(seed)).decode())
    elif args.command == "add":
        add(args)
    else:
        check(args)


if __name__ == "__main__":
    main()
