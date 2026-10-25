"""Regression checks for the public site's link, privacy and delivery guardrails.

Run after building: python3 -m unittest discover -s site -p 'test_*.py'
"""
import os
import shutil
import tempfile
import unittest
from pathlib import Path

import build


class PublicSiteChecks(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.site = Path(self.temp.name) / 'site'
        shutil.copytree(build.ROOT / os.environ.get('CHIRP_SITE_TEST_OUTPUT', 'build/site'), self.site)

    def change(self, file, old, new):
        path = self.site / file
        text = path.read_text()
        self.assertIn(old, text)
        path.write_text(text.replace(old, new, 1))

    def test_valid_build(self):
        self.assertEqual(build.check(self.site), [])

    def test_missing_anchor_and_responsive_candidate_fail(self):
        self.change('index.html', 'href="#start"', 'href="#missing"')
        self.change('index.html', 'notes-library-light-320.webp', 'missing-320.webp')
        errors = '\n'.join(build.check(self.site))
        self.assertIn('missing anchor #missing', errors)
        self.assertIn('missing-320.webp', errors)

    def test_private_content_and_external_requests_fail(self):
        with (self.site / 'index.html').open('a') as file:
            file.write('<p>example.ts.net /Users/example token=secret 172.16.1.1</p><script src="https://example.com/app.js"></script><picture><source srcset="https://example.com/image.webp 320w"></picture>')
        errors = '\n'.join(build.check(self.site))
        for label in ['tailnet host name', 'personal path', 'pairing token', 'private address', 'external request']:
            self.assertIn(label, errors)

    def test_oversized_image_fails(self):
        (self.site / 'assets/oversized.png').write_bytes(b'x' * 400_001)
        self.assertIn('assets/oversized.png: image exceeds 400 KB', build.check(self.site))

    def test_wrong_encoded_dimensions_fail(self):
        manifest = build.json.loads((self.site / 'assets/screenshots/manifest.json').read_text())
        entry = next(iter(manifest.values()))['variants'][0]
        target = self.site / 'assets/screenshots' / entry['file']
        other = next((self.site / 'assets/screenshots').rglob('*640.webp'))
        target.write_bytes(other.read_bytes())
        self.assertTrue(any('invalid responsive image dimensions' in error for error in build.check(self.site)))

    def test_sitemap_and_robots_drift_fail(self):
        self.change('sitemap.xml', 'changelog.html', 'missing.html')
        self.change('robots.txt', 'Allow: /', 'Disallow: /')
        errors = '\n'.join(build.check(self.site))
        self.assertIn('sitemap.xml:', errors)
        self.assertIn('robots.txt:', errors)

    def test_missing_dimensions_and_duplicate_ids_fail(self):
        self.change('index.html', 'width="256"', 'width="0"')
        with (self.site / 'index.html').open('a') as file:
            file.write('<div id="main"></div>')
        errors = '\n'.join(build.check(self.site))
        self.assertIn('duplicate IDs', errors)
        self.assertIn('positive dimensions', errors)


if __name__ == '__main__':
    unittest.main()
