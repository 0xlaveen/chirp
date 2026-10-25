# Chirp product site redesign — review evidence

Captured October 26, 2026 (local date). Before: `94f8082` on `origin/main`. After: the redesigned site in this PR. Browser widths are 1440, 834 and 390 CSS pixels, device scale 1, light and dark; CDP device-metrics overrides produce a true phone viewport. All screenshots use committed app captures; no simulator or emulator was launched.

The review found vague positioning and artwork dominating the original hero, stale iOS device status, missing Android entry points, and Mac speaker claims that exceeded current behavior. The redesign leads with the product and Mac requirement, shows real UI, adds an honest sourced comparison, and makes installation and privacy trade-offs explicit.

The first after sweep found overflow from absolutely positioned accessible labels inside the wide comparison table. Making the scroll region and cells containing blocks fixed it; the final 54 captures report zero overflow and zero missing images.

## Lighthouse

Same Lighthouse version, default mobile simulation and throttling, local static server, fresh Lighthouse browser. Scores are one controlled before/after run, not field measurements. Reports retain the original timings and findings; local preview URLs are replaced with the public canonical URL for publication.

| Metric | Before | After |
| --- | --- | --- |
| Performance | 73 | 97 |
| Accessibility | 100 | 100 |
| Best practices | 100 | 100 |
| SEO | 100 | 100 |
| Largest contentful paint | 9.3 s | 2.6 s |
| Cumulative layout shift | 0 | 0 |
| Total blocking time | 180 ms | 0 ms |
| Initial transfer | Total size was 1,664 KiB | Total size was 396 KiB |

Built site: 6.7 MB → 4.31 MB; 8 → 9 pages. Largest deployed image: 113,658 bytes (400,000-byte budget). Responsive screenshot and artwork assets retain their source hashes.

[Before Lighthouse JSON](before/lighthouse.report.json) · [After Lighthouse JSON](after/lighthouse.report.json) · [Score summary](scores.json)

## Browser checks

[Before capture results](before/browser.json) · [After capture results](after/browser.json) · [Keyboard and interaction results](after/interactions.json)

Passed: skip link is first and focuses main; theme toggle updates captures and persists across reloads; reduced motion stops the Ripple; comparison region scrolls with keyboard input; detailed comparison and FAQ open with Enter; no document overflow with the comparison expanded.

## Visual overview

| Width | Before: every page, both themes | After: every page, both themes |
| --- | --- | --- |
| 1440 | [Contact sheet](before/contact-1440.webp) | [Contact sheet](after/contact-1440.webp) |
| 834 | [Contact sheet](before/contact-834.webp) | [Contact sheet](after/contact-834.webp) |
| 390 | [Contact sheet](before/contact-390.webp) | [Contact sheet](after/contact-390.webp) |

## Every full-page capture

### Before

| Page | Desktop light / dark | Tablet light / dark | Phone light / dark |
| --- | --- | --- | --- |
| 404 | [Light](before/404-1440-light.webp) / [Dark](before/404-1440-dark.webp) | [Light](before/404-834-light.webp) / [Dark](before/404-834-dark.webp) | [Light](before/404-390-light.webp) / [Dark](before/404-390-dark.webp) |
| guides-android | [Light](before/guides-android-1440-light.webp) / [Dark](before/guides-android-1440-dark.webp) | [Light](before/guides-android-834-light.webp) / [Dark](before/guides-android-834-dark.webp) | [Light](before/guides-android-390-light.webp) / [Dark](before/guides-android-390-dark.webp) |
| guides-coding-agent | [Light](before/guides-coding-agent-1440-light.webp) / [Dark](before/guides-coding-agent-1440-dark.webp) | [Light](before/guides-coding-agent-834-light.webp) / [Dark](before/guides-coding-agent-834-dark.webp) | [Light](before/guides-coding-agent-390-light.webp) / [Dark](before/guides-coding-agent-390-dark.webp) |
| guides-index | [Light](before/guides-index-1440-light.webp) / [Dark](before/guides-index-1440-dark.webp) | [Light](before/guides-index-834-light.webp) / [Dark](before/guides-index-834-dark.webp) | [Light](before/guides-index-390-light.webp) / [Dark](before/guides-index-390-dark.webp) |
| guides-iphone | [Light](before/guides-iphone-1440-light.webp) / [Dark](before/guides-iphone-1440-dark.webp) | [Light](before/guides-iphone-834-light.webp) / [Dark](before/guides-iphone-834-dark.webp) | [Light](before/guides-iphone-390-light.webp) / [Dark](before/guides-iphone-390-dark.webp) |
| guides-live-notes | [Light](before/guides-live-notes-1440-light.webp) / [Dark](before/guides-live-notes-1440-dark.webp) | [Light](before/guides-live-notes-834-light.webp) / [Dark](before/guides-live-notes-834-dark.webp) | [Light](before/guides-live-notes-390-light.webp) / [Dark](before/guides-live-notes-390-dark.webp) |
| guides-mac | [Light](before/guides-mac-1440-light.webp) / [Dark](before/guides-mac-1440-dark.webp) | [Light](before/guides-mac-834-light.webp) / [Dark](before/guides-mac-834-dark.webp) | [Light](before/guides-mac-390-light.webp) / [Dark](before/guides-mac-390-dark.webp) |
| index | [Light](before/index-1440-light.webp) / [Dark](before/index-1440-dark.webp) | [Light](before/index-834-light.webp) / [Dark](before/index-834-dark.webp) | [Light](before/index-390-light.webp) / [Dark](before/index-390-dark.webp) |

### After

| Page | Desktop light / dark | Tablet light / dark | Phone light / dark |
| --- | --- | --- | --- |
| 404 | [Light](after/404-1440-light.webp) / [Dark](after/404-1440-dark.webp) | [Light](after/404-834-light.webp) / [Dark](after/404-834-dark.webp) | [Light](after/404-390-light.webp) / [Dark](after/404-390-dark.webp) |
| changelog | [Light](after/changelog-1440-light.webp) / [Dark](after/changelog-1440-dark.webp) | [Light](after/changelog-834-light.webp) / [Dark](after/changelog-834-dark.webp) | [Light](after/changelog-390-light.webp) / [Dark](after/changelog-390-dark.webp) |
| guides-android | [Light](after/guides-android-1440-light.webp) / [Dark](after/guides-android-1440-dark.webp) | [Light](after/guides-android-834-light.webp) / [Dark](after/guides-android-834-dark.webp) | [Light](after/guides-android-390-light.webp) / [Dark](after/guides-android-390-dark.webp) |
| guides-coding-agent | [Light](after/guides-coding-agent-1440-light.webp) / [Dark](after/guides-coding-agent-1440-dark.webp) | [Light](after/guides-coding-agent-834-light.webp) / [Dark](after/guides-coding-agent-834-dark.webp) | [Light](after/guides-coding-agent-390-light.webp) / [Dark](after/guides-coding-agent-390-dark.webp) |
| guides-index | [Light](after/guides-index-1440-light.webp) / [Dark](after/guides-index-1440-dark.webp) | [Light](after/guides-index-834-light.webp) / [Dark](after/guides-index-834-dark.webp) | [Light](after/guides-index-390-light.webp) / [Dark](after/guides-index-390-dark.webp) |
| guides-iphone | [Light](after/guides-iphone-1440-light.webp) / [Dark](after/guides-iphone-1440-dark.webp) | [Light](after/guides-iphone-834-light.webp) / [Dark](after/guides-iphone-834-dark.webp) | [Light](after/guides-iphone-390-light.webp) / [Dark](after/guides-iphone-390-dark.webp) |
| guides-live-notes | [Light](after/guides-live-notes-1440-light.webp) / [Dark](after/guides-live-notes-1440-dark.webp) | [Light](after/guides-live-notes-834-light.webp) / [Dark](after/guides-live-notes-834-dark.webp) | [Light](after/guides-live-notes-390-light.webp) / [Dark](after/guides-live-notes-390-dark.webp) |
| guides-mac | [Light](after/guides-mac-1440-light.webp) / [Dark](after/guides-mac-1440-dark.webp) | [Light](after/guides-mac-834-light.webp) / [Dark](after/guides-mac-834-dark.webp) | [Light](after/guides-mac-390-light.webp) / [Dark](after/guides-mac-390-dark.webp) |
| index | [Light](after/index-1440-light.webp) / [Dark](after/index-1440-dark.webp) | [Light](after/index-834-light.webp) / [Dark](after/index-834-dark.webp) | [Light](after/index-390-light.webp) / [Dark](after/index-390-dark.webp) |

## Validation scope

The applicable local path for this website change is `python3 site/build.py` plus `python3 -m unittest discover -s site -p 'test_*.py'`. All seven guardrail regressions pass, including mutations for broken anchors, responsive candidates, private content, external resources, oversized images, invalid encoded dimensions, sitemap/robots drift, missing dimensions and duplicate IDs. Browser checks cover all public pages and the 404. Application code was not changed, and no mobile emulator or simulator was used.

Competitor facts are linked to official vendor documentation in the comparison and dated October 26, 2026. Mac speaker issue #207 remained open at the final check. The changelog includes merged PRs #190, #191, #198, #200, #202, #204, #206 and #209 after #188.

The final visual sweep used an isolated headless Chrome through CDP; the initial audit used Ego. Both used the same Mac system fonts and explicit CSS viewport widths. The branch was refreshed onto `6328ecd` after #209 updated iOS screenshots; assets were regenerated, preserving the source-freshness check. The final hero uses the approved pond scene as a large faded backdrop and removes the redundant audience paragraph.
