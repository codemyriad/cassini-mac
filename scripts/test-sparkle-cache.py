#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Exercise verified atomic SwiftPM cache staging without network or real caches."""
import hashlib
import importlib.util
import io
import urllib.error
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('sparkle', Path(__file__).with_name('fetch-sparkle.py'))
sparkle = importlib.util.module_from_spec(spec)
spec.loader.exec_module(sparkle)

class SparkleCache(unittest.TestCase):
    def test_verified_download_is_reused_and_repairs_a_damaged_cache(self):
        payload = b'pinned test artifact'
        with tempfile.TemporaryDirectory() as folder, patch.object(sparkle, 'SPM_SHA256', hashlib.sha256(payload).hexdigest()):
            root = Path(folder)
            with patch.object(sparkle.urllib.request, 'urlopen', return_value=io.BytesIO(payload)) as fetch:
                target = sparkle.fetch_spm(root/'downloads', root/'cache')
                self.assertEqual(target.name, 'https___github_com_sparkle_project_Sparkle_releases_download_2_10_1_Sparkle_for_Swift_Package_Manager_zip')
                self.assertEqual(target.read_bytes(), payload)
                target.write_bytes(b'partial previous cache')
                self.assertEqual(sparkle.fetch_spm(root/'downloads', root/'cache').read_bytes(), payload)
                fetch.assert_called_once_with(sparkle.SPM_URL, timeout=sparkle.DOWNLOAD_TIMEOUT)
                self.assertEqual(sorted(p.name for p in target.parent.iterdir()), [target.name])

    def test_gateway_error_uses_same_immutable_asset_and_verifies_it(self):
        payload = b'API artifact'
        with tempfile.TemporaryDirectory() as folder, patch.object(sparkle, 'SPM_SHA256', hashlib.sha256(payload).hexdigest()):
            root = Path(folder)
            error = urllib.error.HTTPError(sparkle.SPM_URL, 504, 'Gateway Time-out', {}, None)
            def api(request, timeout):
                if isinstance(request, str):
                    self.assertEqual(request, sparkle.SPM_URL)
                    raise error
                self.assertEqual(timeout, sparkle.DOWNLOAD_TIMEOUT)
                self.assertEqual(request.full_url, sparkle.SPM_ASSET_API)
                self.assertEqual(request.get_header('Accept'), 'application/octet-stream')
                return io.BytesIO(payload)
            with patch.object(sparkle.urllib.request, 'urlopen', side_effect=api):
                self.assertEqual(sparkle.fetch_spm(root/'downloads', root/'cache').read_bytes(), payload)

    def test_bad_download_never_replaces_verified_cache_or_retains_partial_file(self):
        with tempfile.TemporaryDirectory() as folder, patch.object(sparkle, 'SPM_SHA256', hashlib.sha256(b'keep').hexdigest()):
            root = Path(folder)
            cache = root/'cache'; cache.mkdir()
            existing = cache/'https___github_com_sparkle_project_Sparkle_releases_download_2_10_1_Sparkle_for_Swift_Package_Manager_zip'
            existing.write_bytes(b'keep')
            with patch.object(sparkle.urllib.request, 'urlopen', return_value=io.BytesIO(b'bad artifact')):
                with self.assertRaisesRegex(ValueError, 'digest mismatch'):
                    sparkle.fetch_spm(root/'downloads', cache)
            self.assertEqual(existing.read_bytes(), b'keep')
            self.assertEqual(list((root/'downloads').iterdir()), [])
            self.assertEqual(list(cache.iterdir()), [existing])

    def test_connect_and_read_timeouts_remove_partial_downloads(self):
        class StalledRead(io.BytesIO):
            def read(self, size=-1):
                if self.tell():
                    raise TimeoutError('stalled socket read')
                return super().read(size)
        for mode in ['distribution', 'spm']:
            for phase in ['connect', 'read']:
                with self.subTest(mode=mode, phase=phase), tempfile.TemporaryDirectory() as folder:
                    root = Path(folder)
                    cache = root/'cache'; cache.mkdir()
                    existing = cache/'keep'; existing.write_bytes(b'previous cache')
                    options = {'side_effect': TimeoutError('stalled connect')} if phase == 'connect' else {'return_value': StalledRead(b'partial')}
                    with patch.object(sparkle.urllib.request, 'urlopen', **options) as opened:
                        with self.assertRaises(TimeoutError):
                            if mode == 'spm':
                                sparkle.fetch_spm(root/'downloads', cache)
                            else:
                                sparkle.fetch(root/'downloads')
                    self.assertEqual(opened.call_args.kwargs['timeout'], sparkle.DOWNLOAD_TIMEOUT)
                    self.assertEqual(opened.call_count, 1)
                    self.assertEqual(list((root/'downloads').iterdir()), [])
                    self.assertEqual(existing.read_bytes(), b'previous cache')

if __name__ == '__main__':
    unittest.main()
