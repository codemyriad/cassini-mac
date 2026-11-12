#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Exercise pin drift rejection without network or app resources."""
import importlib.util
from pathlib import Path
import shutil
import tempfile
import unittest
from unittest.mock import patch

spec=importlib.util.spec_from_file_location('badge_pin',Path(__file__).with_name('check-badge-labels-pin.py'))
pin=importlib.util.module_from_spec(spec);spec.loader.exec_module(pin)

class BadgePinTests(unittest.TestCase):
    def test_merged_snapshot(self):pin.verify()

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
