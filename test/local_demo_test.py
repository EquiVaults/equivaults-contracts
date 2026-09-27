#!/usr/bin/env python3
"""Unit coverage for local-demo catalog routing."""
import importlib.util
import sys
import unittest
from pathlib import Path
from unittest.mock import patch

MODULE_PATH = Path(__file__).resolve().parents[1] / "script" / "local-demo.py"
SPEC = importlib.util.spec_from_file_location("local_demo", MODULE_PATH)
assert SPEC and SPEC.loader
local_demo = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(local_demo)


class LocalDemoCatalogRoutingTest(unittest.TestCase):
    def test_asset_export_reads_decimals_not_registry_status(self):
        demo = local_demo.Demo("http://127.0.0.1:38545")
        for decimals in (6, 8, 9, 18):
            with self.subTest(decimals=decimals), patch.object(demo, "call", side_effect=[['primary', 'fallback', 'pool', 3600, decimals, 1], decimals, 'BTC']):
                exported = demo.export_asset('registry', 'token')
                self.assertEqual(exported['decimals'], decimals)

    def test_asset_export_refuses_inconsistent_decimals(self):
        demo = local_demo.Demo("http://127.0.0.1:38545")
        with patch.object(demo, "call", side_effect=[['primary', 'fallback', 'pool', 3600, 8, 1], 18]):
            with self.assertRaisesRegex(RuntimeError, 'decimals disagree'):
                demo.export_asset('registry', 'token')

    def test_export_uses_the_dedicated_rpc_and_ignored_catalog(self):
        demo = local_demo.Demo("http://127.0.0.1:38545")
        with patch.object(local_demo, "run", return_value="exported") as run:
            self.assertEqual(demo.export_deployment_addresses(), "exported")
        run.assert_called_once_with(
            sys.executable,
            "script/export-addresses.py",
            "--rpc-url",
            "http://127.0.0.1:38545",
            "--output",
            ".local-demo/addresses.json",
            timeout=600,
        )

    def test_demo_metadata_and_addresses_share_ignored_state_directory(self):
        self.assertEqual(local_demo.ADDRESSES, local_demo.DEMO_DIRECTORY / "addresses.json")
        self.assertEqual(local_demo.MANIFEST, local_demo.DEMO_DIRECTORY / "demo.json")

if __name__ == "__main__":
    unittest.main()
