#!/usr/bin/env python3
"""Build the Chirp GitHub Pages site into build/site (stdlib only).

Pages in site/pages/ are HTML fragments with a header comment:

    <!--
    title: Page title
    description: One sentence for search and link previews.
    -->

They are wrapped in site/layout.html. `<!--shot:mac/hud-listening|Alt text|class-->` expands to
a light/dark <picture> of docs/screenshots/mac/hud-listening-{light,dark}.png (or the single
file when only one exists). Only screenshots a page references are copied. The build fails on
broken internal links or anchors, external scripts/styles, or anything that looks like a
tailnet host, token, private address or personal path.
"""

from __future__ import annotations

import argparse
import html
import re
import shutil
import struct
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SITE = ROOT / "site"
SHOTS = ROOT / "docs" / "screenshots"
ICON = ROOT / "docs" / "assets" / "chirp-app-icon-256.png"
REPO = "https://github.com/araa47/chirp"
BASE = "/chirp/"  # Pages project path; only 404.html, served at any depth, uses it

HEADER = re.compile(r"\A\s*<!--(.*?)-->", re.S)
SHOT = re.compile(r"<!--shot:([\w/.-]+)\|([^|]*?)(?:\|([\w -]*))?-->")
FORBIDDEN = [
    (re.compile(r"[A-Za-z0-9-]\.ts\.net"), "tailnet host name"),
    (re.compile(r"/(?:Users|home)/[A-Za-z]"), "personal path"),
    (re.compile(r"token=(?!…|&hellip;|&lt;)[A-Za-z0-9_-]"), "pairing token"),
    (re.compile(r"\b100\.(?:6[4-9]|[7-9]\d|1[01]\d|12[0-7])\.\d+\.\d+\b"), "tailnet address"),
    (re.compile(r"\b(?:192\.168|10)\.\d+\.\d+\.\d+\b"), "private address"),
    (re.compile(r"<script[^>]+src=[\"']?(?:https?:)?//", re.I), "external script"),
    (re.compile(r"<link[^>]+href=[\"']?(?:https?:)?//", re.I), "external stylesheet"),
    (re.compile(r"@import|url\((?:[\"']?)(?:https?:)?//", re.I), "external CSS resource"),
    (re.compile(r"google-analytics|googletagmanager|plausible|gtag\(", re.I), "tracker"),
]


def png_size(path: Path) -> tuple[int, int]:
    with path.open("rb") as f:
        head = f.read(24)
    if head[:8] != b"\x89PNG\r\n\x1a\n":
        raise SystemExit(f"not a PNG: {path}")
    return struct.unpack(">II", head[16:24])


def parse(page: Path) -> tuple[dict[str, str], str]:
    text = page.read_text()
    m = HEADER.match(text)
    if not m:
        raise SystemExit(f"{page}: missing header comment")
    meta = dict(
        (k.strip(), v.strip())
        for k, v in (line.split(":", 1) for line in m.group(1).strip().splitlines() if ":" in line)
    )
    return meta, text[m.end() :]


def shot(name: str, alt: str, cls: str | None, root: str, used: set[str]) -> str:
    light, dark = SHOTS / f"{name}-light.png", SHOTS / f"{name}-dark.png"
    single = SHOTS / f"{name}.png"
    if light.exists():
        main = light
    elif single.exists():
        main, dark = single, None
    else:
        raise SystemExit(f"screenshot not found: docs/screenshots/{name}[-light].png")
    w, h = png_size(main)
    rel = lambda p: f"{root}screenshots/{p.relative_to(SHOTS).as_posix()}"  # noqa: E731
    used.add(main.relative_to(SHOTS).as_posix())
    source = ""
    if dark is not None and dark.exists():
        used.add(dark.relative_to(SHOTS).as_posix())
        source = (
            f'<source srcset="{rel(dark)}" media="(prefers-color-scheme: dark)" data-theme-src>'
        )
    c = f' class="{cls}"' if cls else ""
    return (
        f'<picture{c}>{source}<img src="{rel(main)}" width="{w}" height="{h}" '
        f'alt="{html.escape(alt, quote=True)}" loading="lazy" decoding="async"></picture>'
    )


def render(layout: str, page: Path, used: set[str]) -> tuple[str, str]:
    meta, body = parse(page)
    out = page.relative_to(SITE / "pages").as_posix()
    root = meta.get("base") or "../" * out.count("/")
    body = SHOT.sub(lambda m: shot(m.group(1), m.group(2), m.group(3), root, used), body)
    section = meta.get("section", "")
    doc = layout
    for key, value in {
        "content": body.strip(),
        "title": html.escape(meta["title"]),
        "description": html.escape(meta["description"], quote=True),
        "root": root,
        "repo": REPO,
        "body_class": meta.get("class", ""),
    }.items():
        doc = doc.replace("{{" + key + "}}", value)
    for name in ("home", "guides"):
        doc = doc.replace(
            f"{{{{current_{name}}}}}", ' aria-current="page"' if section == name else ""
        )
    return out, doc.replace("{{root}}", root)


def check(out_dir: Path) -> list[str]:
    errors = []
    ids = {}
    for f in out_dir.rglob("*.html"):
        ids[f] = set(re.findall(r'\bid="([^"]+)"', f.read_text()))
    for f in sorted(p for p in out_dir.rglob("*") if p.suffix in {".html", ".css", ".js"}):
        text = f.read_text()
        name = f.relative_to(out_dir)
        for pattern, label in FORBIDDEN:
            for m in pattern.finditer(text):
                errors.append(f"{name}: {label}: {m.group(0)!r}")
        if f.suffix != ".html":
            continue
        for ref in re.findall(r'(?:href|src|srcset)="([^"]+)"', text):
            if re.match(r"(?:[a-z]+:|//)", ref):
                continue
            path, _, anchor = ref.partition("#")
            if path.startswith(BASE):
                target = out_dir / path[len(BASE) :]
            else:
                target = (f.parent / path).resolve() if path else f
            if target.is_dir():
                target = target / "index.html"
            if not target.exists():
                errors.append(f"{name}: broken link {ref}")
            elif anchor and target.suffix == ".html" and anchor not in ids.get(target, set()):
                errors.append(f"{name}: missing anchor {ref}")
    return errors


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--out", type=Path, default=ROOT / "build" / "site")
    out_dir = ap.parse_args().out.resolve()
    if out_dir.exists():
        if not out_dir.is_dir() or (
            any(out_dir.iterdir()) and not (out_dir / ".nojekyll").exists()
        ):
            raise SystemExit(f"refusing to replace {out_dir}: not an earlier site build")
        shutil.rmtree(out_dir)
    shutil.copytree(SITE / "assets", out_dir / "assets")
    shutil.copy2(ICON, out_dir / "assets" / "chirp-icon.png")
    layout = (SITE / "layout.html").read_text()
    used: set[str] = set()
    for page in sorted((SITE / "pages").rglob("*.html")):
        rel, doc = render(layout, page, used)
        (out_dir / rel).parent.mkdir(parents=True, exist_ok=True)
        (out_dir / rel).write_text(doc)
    for rel in sorted(used):
        (out_dir / "screenshots" / rel).parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(SHOTS / rel, out_dir / "screenshots" / rel)
    (out_dir / ".nojekyll").write_text("")
    errors = check(out_dir)
    for e in errors:
        print(f"error: {e}", file=sys.stderr)
    if errors:
        return 1
    size = sum(p.stat().st_size for p in out_dir.rglob("*") if p.is_file())
    print(
        f"built {out_dir.relative_to(ROOT) if out_dir.is_relative_to(ROOT) else out_dir}: "
        f"{len(list(out_dir.rglob('*.html')))} pages, {len(used)} screenshots, {size / 1e6:.1f} MB"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
