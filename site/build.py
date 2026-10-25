#!/usr/bin/env python3
"""Build and validate Chirp's public website with Python's standard library only."""
from __future__ import annotations

import argparse
import hashlib
import html
import json
import re
import shutil
import struct
import sys
import xml.etree.ElementTree as ET
from html.parser import HTMLParser
from pathlib import Path
from urllib.parse import urlsplit, unquote

ROOT = Path(__file__).resolve().parent.parent
SITE = ROOT / "site"
SHOTS = ROOT / "docs/screenshots"
ICON = ROOT / "docs/assets/chirp-app-icon-256.png"
ART = ROOT / "android/artwork/chirp-icons"
REPO = "https://github.com/araa47/chirp"
BASE = "/chirp/"
ORIGIN = "https://araa47.github.io"
PUBLIC = ORIGIN + BASE
HEADER = re.compile(r"\A\s*<!--(.*?)-->", re.S)
SHOT = re.compile(r"<!--shot:([\w/.-]+)\|([^|]*?)(?:\|([\w -]*))?-->")
MAX_IMAGE_BYTES = 400_000
SIZES = '(max-width: 760px) calc(100vw - 32px), (max-width: 1050px) 50vw, 760px'
FORBIDDEN = [
    (re.compile(r"[A-Za-z0-9-]\.ts\.net"), "tailnet host name"),
    (re.compile(r"/(?:Users|home)/[A-Za-z]"), "personal path"),
    (re.compile(r"token=(?!…|&hellip;|&lt;)[A-Za-z0-9_-]"), "pairing token"),
    (re.compile(r"\b100\.(?:6[4-9]|[7-9]\d|1[01]\d|12[0-7])\.\d+\.\d+\b"), "tailnet address"),
    (re.compile(r"\b(?:192\.168\.\d+\.\d+|10\.\d+\.\d+\.\d+|172\.(?:1[6-9]|2\d|3[01])\.\d+\.\d+)\b"), "private address"),
    (re.compile(r"@import|url\((?:[\"']?)(?:https?:)?//", re.I), "external CSS resource"),
    (re.compile(r"google-analytics|googletagmanager|plausible|gtag\(", re.I), "tracker"),
]


def png_size(path):
    data = path.read_bytes()[:24]
    if data[:8] != b"\x89PNG\r\n\x1a\n":
        raise ValueError(f"Not a PNG: {path.name}")
    return struct.unpack(">II", data[16:24])


def webp_size(path):
    data = path.read_bytes()
    if data[:4] != b"RIFF" or data[8:12] != b"WEBP":
        raise ValueError(f"Not a WebP: {path.name}")
    if data[12:16] == b"VP8 ":
        return tuple(n & 0x3FFF for n in struct.unpack("<HH", data[26:30]))
    if data[12:16] == b"VP8L":
        bits = int.from_bytes(data[21:25], "little")
        return (bits & 0x3FFF) + 1, ((bits >> 14) & 0x3FFF) + 1
    if data[12:16] == b"VP8X":
        return int.from_bytes(data[24:27], "little") + 1, int.from_bytes(data[27:30], "little") + 1
    raise ValueError(f"Unknown WebP dimensions: {path.name}")


def parse(page):
    text = page.read_text()
    match = HEADER.match(text)
    if not match:
        raise ValueError(f"Missing header: {page.name}")
    meta = dict((k.strip(), v.strip()) for k, v in (line.split(":", 1) for line in match[1].strip().splitlines() if ":" in line))
    return meta, text[match.end():]


def shot_sources(name):
    light = f"{name}-light.png"
    single = f"{name}.png"
    main = light if (SHOTS / light).exists() else single
    dark = f"{name}-dark.png"
    if name.startswith("ios/"):
        dark = name.replace("ios/iphone-", "ios/iphone-dark-").replace("ios/ipad-", "ios/ipad-dark-") + ".png"
    return main, dark if dark != main and (SHOTS / dark).exists() else None


def srcset(entry, root):
    return ", ".join(f'{root}assets/screenshots/{v["file"]} {v["width"]}w' for v in entry["variants"])


def shot(name, alt, cls, root, manifest, used):
    main, dark = shot_sources(name)
    used.add(main)
    if dark:
        used.add(dark)
    entry = manifest[main]
    sizes = '(max-width: 760px) calc(100vw - 48px), (max-width: 1050px) 44vw, 560px' if cls == 'hero-notes' else SIZES
    attrs = f' class="{cls}"' if cls else ''
    source = f'<source srcset="{srcset(manifest[dark], root)}" sizes="{sizes}" media="(prefers-color-scheme: dark)" data-theme-src>' if dark else ''
    eager = cls == 'hero-notes'
    fallback = entry['variants'][-1]['file']
    return (f'<picture{attrs}>{source}<img src="{root}assets/screenshots/{fallback}" '
            f'srcset="{srcset(entry, root)}" sizes="{sizes}" width="{entry["width"]}" height="{entry["height"]}" '
            f'alt="{html.escape(alt, quote=True)}" loading="{"eager" if eager else "lazy"}" '
            f'{"fetchpriority=high " if eager else ""}decoding="async"></picture>')


def render(layout, page, manifest, used):
    meta, body = parse(page)
    out = page.relative_to(SITE / 'pages').as_posix()
    root = meta.get('base') or '../' * out.count('/')
    body = SHOT.sub(lambda m: shot(m[1], m[2], m[3], root, manifest, used), body)
    canonical = PUBLIC + ('' if out == 'index.html' else out)
    preload = ''
    if out == 'index.html':
        preload = '<link rel="preload" as="image" href="assets/pond-256.webp" imagesrcset="assets/pond-128.webp 128w, assets/pond-256.webp 256w" imagesizes="(max-width: 760px) 46px, 88px">\n'
        main, dark = shot_sources('mac/notes-library')
        for name, media in [(main, '(prefers-color-scheme: light)'), (dark, '(prefers-color-scheme: dark)')]:
            if name:
                entry = manifest[name]
                preload += f'<link rel="preload" as="image" href="{root}assets/screenshots/{entry["variants"][-1]["file"]}" imagesrcset="{srcset(entry, root)}" imagesizes="(max-width: 760px) calc(100vw - 48px), (max-width: 1050px) 44vw, 560px" media="{media}">\n'
    values = {'content': body.strip(), 'title': html.escape(meta['title']), 'description': html.escape(meta['description'], quote=True), 'root': root, 'repo': REPO, 'body_class': meta.get('class', ''), 'canonical': canonical, 'social_image': PUBLIC + 'assets/pond.webp', 'preload': preload, 'robots': 'noindex' if out == '404.html' else 'index, follow'}
    doc = layout
    for name in ('home', 'guides', 'changelog'):
        values[f'current_{name}'] = ' aria-current="page"' if meta.get('section') == name else ''
    for key, value in values.items():
        doc = doc.replace('{{' + key + '}}', value)
    return out, doc.replace('{{root}}', root)


class Document(HTMLParser):
    def __init__(self, text):
        super().__init__(convert_charrefs=True)
        self.tags = []
        self.ids = []
        self.refs = []
        self.feed(text)

    def handle_starttag(self, tag, attrs):
        attrs = dict(attrs)
        self.tags.append((tag, attrs))
        if 'id' in attrs:
            self.ids.append(attrs['id'])
        for key in ('href', 'src', 'poster'):
            if attrs.get(key):
                self.refs.append(attrs[key])
        for key in ('srcset', 'imagesrcset'):
            for item in attrs.get(key, '').split(','):
                if item.strip():
                    self.refs.append(item.strip().split()[0])


def check(out_dir):
    out_dir = out_dir.resolve()
    errors = []
    docs = {p.resolve(): Document(p.read_text()) for p in out_dir.rglob('*.html')}
    def local(ref, parent):
        parsed = urlsplit(ref)
        if parsed.netloc == urlsplit(PUBLIC).netloc and parsed.path.startswith(BASE):
            return out_dir / unquote(parsed.path[len(BASE):]), parsed.fragment
        if parsed.scheme or parsed.netloc:
            return None, ''
        path = unquote(parsed.path)
        return (out_dir / path[len(BASE):] if path.startswith(BASE) else parent / path).resolve(), parsed.fragment
    for path in sorted(out_dir.rglob('*')):
        if not path.is_file():
            continue
        name = path.relative_to(out_dir)
        if path.suffix in {'.png', '.webp', '.avif', '.jpg', '.jpeg', '.svg'} and path.stat().st_size > MAX_IMAGE_BYTES:
            errors.append(f'{name}: image exceeds 400 KB')
        if path.suffix not in {'.html', '.css', '.js', '.xml', '.txt', '.json'}:
            continue
        text = path.read_text()
        for pattern, label in FORBIDDEN:
            if pattern.search(text):
                errors.append(f'{name}: {label}')
        if path.suffix != '.html':
            continue
        doc = docs[path.resolve()]
        if len(doc.ids) != len(set(doc.ids)):
            errors.append(f'{name}: duplicate IDs')
        if '{{' in text:
            errors.append(f'{name}: unresolved template')
        for tag, attrs in doc.tags:
            if tag == 'img':
                if not attrs.get('alt') or not all(attrs.get(k, '').isdigit() and int(attrs[k]) > 0 for k in ('width', 'height')):
                    errors.append(f'{name}: image needs alt text and positive dimensions')
                if attrs.get('decoding') != 'async' or attrs.get('loading') not in {'lazy', 'eager'}:
                    errors.append(f'{name}: image needs explicit loading and async decoding')
            fetch = attrs.get('src') if tag in {'script', 'img', 'source', 'iframe', 'video', 'audio'} else attrs.get('href') if tag == 'link' and attrs.get('rel') in {'stylesheet', 'preload', 'icon', 'apple-touch-icon'} else None
            resources = [fetch] if fetch else []
            if tag in {'img', 'source'} or (tag == 'link' and attrs.get('rel') == 'preload'):
                for key in ('srcset', 'imagesrcset'):
                    resources.extend(item.strip().split()[0] for item in attrs.get(key, '').split(',') if item.strip())
            if any(urlsplit(resource).scheme or resource.startswith('//') for resource in resources):
                errors.append(f'{name}: external request from {tag}')
        for ref in doc.refs:
            target, anchor = (path, ref[1:]) if ref.startswith('#') else local(ref, path.parent)
            if target is None:
                continue
            if target.is_dir():
                target = target / 'index.html'
            if not target.exists():
                errors.append(f'{name}: broken link {ref}')
            elif anchor and target.suffix == '.html' and anchor not in docs[target.resolve()].ids:
                errors.append(f'{name}: missing anchor {ref}')
        canonical = [attrs.get('href') for tag, attrs in doc.tags if tag == 'link' and attrs.get('rel') == 'canonical']
        if len(canonical) != 1 or not canonical[0].startswith(PUBLIC):
            errors.append(f'{name}: missing public canonical URL')
    # Check actual encoded dimensions, not just the source manifest's claims.
    manifest = json.loads((out_dir / 'assets/screenshots/manifest.json').read_text())
    for entry in manifest.values():
        for variant in entry['variants']:
            target = out_dir / 'assets/screenshots' / variant['file']
            if not target.exists() or webp_size(target) != (variant['width'], variant['height']):
                errors.append(f'{variant["file"]}: invalid responsive image dimensions')
    try:
        tree = ET.parse(out_dir / 'sitemap.xml')
        urls = [node.text for node in tree.findall('.//{http://www.sitemaps.org/schemas/sitemap/0.9}loc')]
        expected = {PUBLIC + ('' if p.relative_to(out_dir).as_posix() == 'index.html' else p.relative_to(out_dir).as_posix()) for p in docs if p.name != '404.html'}
        if set(urls) != expected or len(urls) != len(set(urls)):
            errors.append('sitemap.xml: must list every public page exactly once, excluding 404')
        for url in urls:
            target, _ = local(url, out_dir)
            if target is None or not (target.is_file() or (target / 'index.html').is_file()):
                errors.append('sitemap.xml: invalid page URL')
        if (out_dir / 'robots.txt').read_text() != f'User-agent: *\nAllow: /\nSitemap: {PUBLIC}sitemap.xml\n':
            errors.append('robots.txt: invalid sitemap declaration')
    except (ET.ParseError, FileNotFoundError):
        errors.append('missing or invalid sitemap / robots.txt')
    return errors


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--out', type=Path, default=ROOT / 'build/site')
    out_dir = ap.parse_args().out.resolve()
    if out_dir.exists():
        if not out_dir.is_dir() or (any(out_dir.iterdir()) and not (out_dir / '.nojekyll').exists()):
            raise SystemExit('Refusing to replace a directory that is not an earlier site build')
        shutil.rmtree(out_dir)
    manifest = json.loads((SITE / 'assets/screenshots/manifest.json').read_text())
    for source, entry in manifest.items():
        if hashlib.sha256((SHOTS / source).read_bytes()).hexdigest() != entry['sha256']:
            raise SystemExit(f'Stale screenshot: {source}; run site/prepare_images.py')
    shutil.copytree(SITE / 'assets', out_dir / 'assets')
    (out_dir / '.nojekyll').write_text('')
    shutil.copy2(ICON, out_dir / 'assets/chirp-icon.png')
    # Artwork is converted for delivery without cropping or redrawing; source hashes prevent drift.
    artwork = json.loads((SITE / 'assets/artwork.json').read_text())
    for name, entry in artwork.items():
        if hashlib.sha256((ART / entry['source']).read_bytes()).hexdigest() != entry['sha256']:
            raise SystemExit('Stale approved artwork; run site/prepare_images.py')
        if webp_size(out_dir / 'assets' / name) != (entry['width'], entry['height']):
            raise SystemExit('Artwork dimensions differ from the approved source')
    layout = (SITE / 'layout.html').read_text()
    used = set()
    urls = []
    for page in sorted((SITE / 'pages').rglob('*.html')):
        rel, doc = render(layout, page, manifest, used)
        (out_dir / rel).parent.mkdir(parents=True, exist_ok=True)
        (out_dir / rel).write_text(doc)
        if rel != '404.html':
            urls.append(PUBLIC + ('' if rel == 'index.html' else rel))
    if used != set(manifest):
        raise SystemExit('Screenshot manifest differs from page references; run site/prepare_images.py')
    ET.register_namespace('', 'http://www.sitemaps.org/schemas/sitemap/0.9')
    sitemap = ET.Element('{http://www.sitemaps.org/schemas/sitemap/0.9}urlset')
    for url in sorted(urls):
        node = ET.SubElement(sitemap, 'url')
        ET.SubElement(node, 'loc').text = url
    ET.ElementTree(sitemap).write(out_dir / 'sitemap.xml', encoding='utf-8', xml_declaration=True)
    (out_dir / 'robots.txt').write_text(f'User-agent: *\nAllow: /\nSitemap: {PUBLIC}sitemap.xml\n')
    (out_dir / '.nojekyll').write_text('')
    errors = check(out_dir)
    for error in errors:
        print(f'error: {error}', file=sys.stderr)
    if errors:
        return 1
    size = sum(p.stat().st_size for p in out_dir.rglob('*') if p.is_file())
    print(f'Built {len(urls)+1} pages, {len(used)} source screenshots, {size/1e6:.2f} MB; links, privacy, SEO and image budgets passed')
    return 0


if __name__ == '__main__':
    sys.exit(main())
