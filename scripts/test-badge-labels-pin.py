#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Exercise pin drift rejection without network or app resources."""
import importlib.util
import hashlib
import json
from pathlib import Path
import shutil
import tempfile
import unittest
from unittest.mock import patch

spec=importlib.util.spec_from_file_location('badge_pin',Path(__file__).with_name('check-badge-labels-pin.py'))
pin=importlib.util.module_from_spec(spec);spec.loader.exec_module(pin)

class BadgePinTests(unittest.TestCase):
    def test_merged_snapshot(self):pin.verify()

    def test_rehashed_vectors_with_stale_copy_are_rejected(self):
        for name,section,field in [('states-vectors.json','vectors','badge'),
                                   ('format-vectors.json','previewSubtitle','out')]:
            with self.subTest(file=name),tempfile.TemporaryDirectory() as directory:
                folder=Path(directory)/'snapshot';shutil.copytree(pin.FOLDER,folder)
                file=folder/name;document=json.loads(file.read_text())
                vector=next(v for v in document[section] if
                            (v.get('badge') or {}).get('kind')=='received' or v.get('received'))
                if field=='badge':vector['badge']['text']='Received'
                else:vector['out']=vector['out'].replace('Imported','Received')
                file.write_text(json.dumps(document))
                manifest=folder/'UPSTREAM.json';metadata=json.loads(manifest.read_text())
                metadata['files'][name]['sha256']=hashlib.sha256(file.read_bytes()).hexdigest()
                manifest.write_text(json.dumps(metadata))
                with patch.object(pin,'FOLDER',folder):
                    with self.assertRaises(AssertionError):pin.verify()

    def test_catalog_vector_and_expected_drift_is_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            folder=Path(directory)/'snapshot';shutil.copytree(pin.FOLDER,folder)
            with patch.object(pin,'FOLDER',folder):
                for name in ['strings.json','states-vectors.json','format-vectors.json','library-expected/main.json']:
                    with self.subTest(file=name):
                        file=folder/name;original=file.read_bytes()
                        try:
                            file.write_bytes(original+b' ')
                            with self.assertRaises(AssertionError):pin.verify()
                        finally:file.write_bytes(original)
                pin.verify()

if __name__=='__main__':unittest.main()
