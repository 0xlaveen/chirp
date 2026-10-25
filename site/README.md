# Chirp website

The public product site is **https://araa47.github.io/chirp/**. Plain HTML, CSS and a small script for themes, keyboard-accessible tabs, screenshot reels and copy buttons. No frameworks, web fonts, analytics or third-party requests.

## Build and preview

```sh
python3 site/build.py
python3 -m unittest discover -s site -p 'test_*.py'
mkdir -p build/serve && ln -sfn ../site build/serve/chirp
python3 -m http.server 8781 --bind 127.0.0.1 --directory build/serve
```

Open the local preview under `/chirp/`. The normal build uses only Python's standard library, reads committed local inputs and makes no network requests. Only `404.html` uses a site-root path because GitHub can serve it at any depth.

## Pages and screenshots

Page fragments in `pages/` begin with a metadata comment (`title`, `description`, optional `section`, `class`, `base`). `layout.html` supplies navigation, social metadata and footer. `{{root}}` is the relative site root and `{{repo}}` is the public repository URL.

Use a committed capture from `docs/screenshots/`:

```html
<!--shot:mac/hud-listening|Description of the real capture|optional-class-->
```

The builder emits responsive WebP `srcset` and `sizes`, explicit dimensions, asynchronous decoding and lazy loading. Paired dark captures follow both system appearance and the theme toggle. iOS captures use their existing `iphone-dark-…` / `ipad-dark-…` naming. The hero Notes capture is eager and high priority. Only hero assets are preloaded.

Regenerate images when references or source captures change:

```sh
uv run --with pillow python site/prepare_images.py
```

Pillow is needed only for this authoring step. The responsive assets and source SHA-256 manifest are committed, so CI needs no imaging packages or model downloads. Screenshots are scaled without adding or changing UI. The sideways iPad sidebar captures are rotated for display. The approved pond scene is converted to WebP without cropping or redrawing; the glyph is converted losslessly. Artwork hashes and dimensions are checked against the approved sources. The committed app icon is copied unchanged.

## Checks

The build fails on broken relative links, missing anchors, duplicate IDs, stale source captures, malformed sitemap entries, missing canonical URLs, unresolved templates, missing image dimensions or alt text, mismatched encoded WebP dimensions, or **any deployed image above 400,000 bytes**. It also checks external scripts, styles and resource URLs, trackers, tailnet hosts, private addresses, tokens and personal paths. Regression tests mutate a temporary build to verify these guardrails reject invalid output.

Every indexable page appears once in `sitemap.xml`; `404.html` is excluded and marked noindex. `robots.txt` declares the public sitemap. Social cards use the approved pond artwork. External comparison citations are links, never fetched by the site or its build.

The comparison is manually researched from official sources and date-stamped. Recheck availability, pricing and platform-specific limitations when editing it. The changelog lists merged PRs after #188; it does not advertise open issues as shipped features. Install details must stay aligned with each platform README.

## Deploy and verify

`.github/workflows/pages.yml` builds changes to `site/`, screenshots and site artwork on PRs. Pushes to `main` publish through GitHub Pages; PRs validate without deploying. Site changes need the build and guardrail tests above, plus browser review at 1440, 834 and 390 CSS pixels, light and dark. Use a CDP viewport override for a true phone width on macOS. Record Lighthouse performance, accessibility, best practices and SEO before and after. Review evidence lives in `docs/review/site-v2/` and is not deployed.
