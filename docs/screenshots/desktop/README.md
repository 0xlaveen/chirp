# Desktop browser captures

W22 captures were rendered on 2026-10-27 from this change's actual `desktop/ui/`
HTML/CSS/JavaScript, based on `fec63891`. The browser was Chromium through
ego-browser, with default text size and synthetic content from
`desktop/scripts/review-ui.py`. Settings and history use a 900 × 1000 CSS-pixel
viewport; settings captures include the full page. Finished-result captures use
900 × 650. Each state has light and dark appearances.

- `settings-{light,dark}.png`: full settings, history retention and saved entries.
- `history-search-{light,dark}.png`: search matching the original, with Copy original.
- `dictation-final-{light,dark}.png`: completed result, Copy and Use raw with its paste instructions.

These are frontend fixtures with mocked native commands. They do not demonstrate
native Windows/Linux window chrome, OS tray appearance, credential-store access,
or clipboard/insertion behavior. Browser review also exercised search, copying
an original, deleting an entry, cancelling the delete-all dialog, and Use raw.
The older HUD and Notes captures remain documented in `desktop/README.md`.

To reproduce, run `python3 desktop/scripts/review-ui.py` from the repository root
and open the printed URL. Choose Dictation & settings; search for “nine bring” for
the history view. Refresh to reset, then Record → Stop for the finished result.
Use browser appearance emulation to capture both color schemes. All fixture
state stays in memory and resets when the page is reloaded.
