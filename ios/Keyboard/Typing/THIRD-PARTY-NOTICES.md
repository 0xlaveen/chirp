# Third-party notices: Chirp Keyboard (iOS)

## KeyboardKit 9.9.1

- What: the system-style typing keys (layouts, input sets, long-press callouts, shift and caps lock, space-bar cursor
  drag, delete repeat, the suggestion bar view) under Chirp's strip.
- Source: <https://github.com/KeyboardKit/KeyboardKit>, tag `9.9.1`
  (commit `a7e33ac2e6f47e16288ce09ec8d765cd329f918c`, August 2025), pulled with Swift Package Manager at that exact
  version by `ios/Keyboard/Typing/Package.swift`.
- Licence: MIT (below). 9.9.1 is the last release published as MIT source; KeyboardKit 10.0 and later are
  closed-source binaries under a commercial licence and must not be used here. Only the open-source core is used:
  no KeyboardKit Pro, no licence key, no LicenseKit. The core's `_Pro/ProPlaceholders.swift` holds MIT stub views
  that Chirp never shows.
- Where it runs: linked into the keyboard extension (and its unit tests) only, never the app or the widgets. The
  licence text also ships inside the keyboard as `KeyboardKit-LICENSE.txt`.
- Not used: KeyboardKit's emoji keyboard and other locales (Pro features in 9.x), and its next-word prediction
  request (Chirp's suggestions come from the on-device `UITextChecker` and `UILexicon`; the keyboard makes no network
  requests beyond Chirp's own app bridge).

```
MIT License

Copyright (c) 2016-2025 Daniel Saidi

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```
