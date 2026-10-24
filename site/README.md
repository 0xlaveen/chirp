# Chirp website

The public site at **https://araa47.github.io/chirp/**: a landing page and five beginner guides. Plain HTML and CSS with one small script (theme toggle, tabs, screenshot reels, copy buttons). No frameworks, web fonts, analytics, cookies or third-party requests.

```
site/
  build.py        stdlib-only generator and checker
  layout.html     shared head, top bar and footer
  pages/          page bodies: index.html, 404.html, guides/*.html
  assets/         style.css, site.js
```

## Build and preview

```sh
python3 site/build.py                         # → build/site/
mkdir -p build/serve && ln -sfn ../site build/serve/chirp
python3 -m http.server 8781 --bind 127.0.0.1 --directory build/serve
# open http://127.0.0.1:8781/chirp/
```

Links between pages are relative, so the site also works opened from any folder; only `404.html` uses the `/chirp/` project path, because GitHub serves it at any depth.

## How pages are written

Each file in `pages/` starts with a header comment (`title`, `description`, optional `section` for the active nav item, `class`, `base`), followed by the body HTML. `{{root}}` is the relative path to the site root and `{{repo}}` the GitHub URL.

Screenshots come only from the committed `docs/screenshots/`. Write

```html
<!--shot:mac/hud-listening|Alt text describing the capture|optional-class-->
```

and the build emits a `<picture>` with the `-dark` capture for dark mode and the `-light` one otherwise (or the single file when there is no pair), with its real width and height. Only referenced screenshots are copied. Numbers on the site come from [docs/bench.md](../docs/bench.md); update both together.

## Checks

`build.py` fails the build when the output contains:

- a broken relative link or a missing `#anchor`;
- an external script, stylesheet or CSS import, or a known analytics snippet;
- anything that looks like a tailnet host name (`name.ts.net`), a tailnet or private IP address, a `/Users/…` or `/home/…` path, or a `token=` value.

Placeholders are written escaped, for example `&lt;your-mac&gt;.&lt;tailnet&gt;.ts.net`, so they pass.

## Deploy

[`.github/workflows/pages.yml`](../.github/workflows/pages.yml) builds on every pull request that touches `site/`, `docs/screenshots/` or `docs/assets/` (checks only), and on pushes to `main` it uploads the built site and deploys it with `actions/deploy-pages`. It can also be run by hand from the Actions tab.

**One-time setting (done 2026-10-23):** Pages must use GitHub Actions as its source. A repository admin sets it in **Settings → Pages → Build and deployment → Source: GitHub Actions**, or with

```sh
gh api -X POST repos/araa47/chirp/pages -f build_type=workflow
```

The default `github-pages` environment only accepts deployments from `main`.
