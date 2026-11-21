import json
import unittest
from pathlib import Path


ROOT = Path(__file__).parents[1]
MODULE = ROOT / "module"
RAW = "https://raw.githubusercontent.com/mimivex/revanced-zygisk-mount/master"
LATEST = (
    "https://github.com/mimivex/revanced-zygisk-mount/releases/latest/download/"
    "revanced-zygisk-mount.zip"
)


def module_prop():
    values = {}
    for line in (MODULE / "module.prop").read_text().splitlines():
        if "=" in line:
            key, value = line.split("=", 1)
            values[key] = value
    return values


class ReleaseMetadataTests(unittest.TestCase):
    def setUp(self):
        self.prop = module_prop()
        self.update = json.loads((ROOT / "update.json").read_text())

    def test_update_json_matches_the_module_version(self):
        # The in-app updater compares versionCode only; a bump in one file
        # without the other either hides the update or advertises a phantom
        # one. Keeping both in step is the whole point of this test.
        self.assertEqual(self.update["version"], self.prop["version"])
        self.assertEqual(self.update["versionCode"], int(self.prop["versionCode"]))

    def test_module_prop_points_at_the_update_json(self):
        self.assertEqual(self.prop["updateJson"], f"{RAW}/update.json")

    def test_update_json_uses_the_fixed_release_asset(self):
        # A versioned asset name would need the URL changed at every release;
        # the fixed name makes releases/latest/download stable forever.
        self.assertEqual(self.update["zipUrl"], LATEST)
        self.assertTrue(self.update["changelog"].startswith("https://"))

    def test_workflow_publishes_fixed_asset_names(self):
        workflow = (ROOT / ".github/workflows/release.yml").read_text()
        self.assertIn('zip -X -r -9 "../revanced-zygisk-mount.zip"', workflow)
        self.assertNotIn("revanced-zygisk-mount-${GITHUB_REF_NAME}.zip", workflow)
        self.assertIn("--latest", workflow)


if __name__ == "__main__":
    unittest.main()
