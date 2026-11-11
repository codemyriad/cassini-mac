#!/usr/bin/env python3
"""Hermetic download recovery regressions; no network or engine loading."""
import hashlib
import http.client
import importlib.util
import io
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('fetch_whistle', Path(__file__).with_name('fetch-whistle.py'))
fetcher = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fetcher)


class FetchRecovery(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='cassini-fetch-test-')
        self.cache = Path(self.temporary.name)
        self.good = b'verified artifact bytes'
        self.pin = dict(name='engine.whl',url='https://fixture.invalid/engine.whl',sha256=hashlib.sha256(self.good).hexdigest())

    def tearDown(self):
        self.temporary.cleanup()

    def test_valid_cache_does_not_download(self):
        path = self.cache/self.pin['name']; path.write_bytes(self.good)
        with patch.object(fetcher.urllib.request,'urlopen') as request:
            self.assertEqual(fetcher.fetch(self.pin,self.cache).read_bytes(),self.good)
            request.assert_not_called()

    def test_corrupt_cache_is_replaced_by_verified_download(self):
        path = self.cache/self.pin['name']; path.write_bytes(b'corrupt')
        with patch.object(fetcher.urllib.request,'urlopen',return_value=io.BytesIO(self.good)) as request:
            self.assertEqual(fetcher.fetch(self.pin,self.cache).read_bytes(),self.good)
            self.assertEqual(request.call_count,1)

    def test_truncated_http_200_is_retried(self):
        with patch.object(fetcher.urllib.request,'urlopen',side_effect=[io.BytesIO(self.good[:4]),io.BytesIO(self.good)]) as request, patch.object(fetcher.time,'sleep'):
            self.assertEqual(fetcher.fetch(self.pin,self.cache).read_bytes(),self.good)
            self.assertEqual(request.call_count,2)
        self.assertEqual(list(self.cache.glob('*.part')),[])

    def test_repeated_bad_download_cannot_poison_next_build(self):
        with patch.object(fetcher.urllib.request,'urlopen',side_effect=lambda *a,**k:io.BytesIO(b'bad')), patch.object(fetcher.time,'sleep'):
            with self.assertRaises(ValueError): fetcher.fetch(self.pin,self.cache)
        self.assertEqual(list(self.cache.iterdir()),[])
        with patch.object(fetcher.urllib.request,'urlopen',return_value=io.BytesIO(self.good)):
            self.assertEqual(fetcher.fetch(self.pin,self.cache).read_bytes(),self.good)

    def test_disconnected_redirector_uses_verified_mirror_without_more_attempts(self):
        mirrors=('https://mirror-one.invalid/archive','https://mirror-two.invalid/archive')
        errors=[http.client.RemoteDisconnected('no response'),OSError('mirror unavailable'),io.BytesIO(self.good)]
        with patch.object(fetcher.urllib.request,'urlopen',side_effect=errors) as request,patch.object(fetcher.time,'sleep'):
            self.assertEqual(fetcher.fetch(self.pin,self.cache,fallback_urls=mirrors).read_bytes(),self.good)
            self.assertEqual([call.args[0] for call in request.call_args_list],[self.pin['url'],*mirrors])
            self.assertTrue(all(call.kwargs['timeout']==60 for call in request.call_args_list))
        self.assertEqual(list(self.cache.glob('*.part')),[])

    def test_bad_mirrors_still_fail_and_never_publish_a_cache(self):
        mirrors=('https://mirror-one.invalid/archive','https://mirror-two.invalid/archive')
        with patch.object(fetcher.urllib.request,'urlopen',side_effect=lambda *a,**k:io.BytesIO(b'bad')) as request,patch.object(fetcher.time,'sleep'):
            with self.assertRaises(ValueError):fetcher.fetch(self.pin,self.cache,fallback_urls=mirrors)
            self.assertEqual(request.call_count,3)
        self.assertEqual(list(self.cache.iterdir()),[])


if __name__ == '__main__':
    unittest.main()
