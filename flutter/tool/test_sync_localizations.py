"""Hermetic regression checks for runtime copy retirement and shared catalogs."""

from contextlib import redirect_stdout
import io
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

import sync_localizations as sync


class LocalizationRetirementTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.repository = Path(self.directory.name)
        self.flutter = self.repository / "flutter"
        for language in sync.LANGUAGES:
            source = self.repository / "native-ios" / "Shared" / f"{language}.lproj"
            source.mkdir(parents=True)
            (source / "Localizable.strings").write_text(
                '"Anime Boxes" = "Anime Boxes";\n'
                '"Runtime failure %@" = "Runtime failure %@";\n', encoding="utf-8")
            override = self.flutter / "tool" / "l10n_overrides" / f"{language}.json"
            override.parent.mkdir(parents=True, exist_ok=True)
            override.write_text(json.dumps({"Current generic import": "Current generic import"}), encoding="utf-8")
        (self.flutter / "tool" / "l10n_exclusions.json").write_text(
            json.dumps({"Anime Boxes": "Retired UI label; data compatibility is unchanged."}), encoding="utf-8")
        self.ui = self.flutter / "lib" / "ui.dart"
        self.ui.parent.mkdir(parents=True)
        self.ui.write_text("void screen() { _t('Current generic import'); }", encoding="utf-8")
        for relative in ("data/drive_auth.dart", "data/drive_repository.dart", "core/drive_sync_controller.dart", "features/drive_sync_screen.dart"):
            path = self.flutter / "lib" / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text("// Fixture with no additional runtime messages.\n", encoding="utf-8")

    def run_sync(self, check=False):
        with patch.multiple(sync, FLUTTER=self.flutter, REPOSITORY=self.repository), patch("sys.argv", ["sync_localizations.py", *(["--check"] if check else [])]), redirect_stdout(io.StringIO()):
            return sync.main()

    def test_regeneration_excludes_retired_native_copy_and_keeps_dynamic_messages(self):
        self.assertEqual(self.run_sync(), 0)
        self.assertEqual(self.run_sync(check=True), 0)
        for language in sync.LANGUAGES:
            catalog = json.loads((self.flutter / "assets" / "l10n" / f"{language}.json").read_text())
            self.assertNotIn("Anime Boxes", catalog)
            self.assertEqual(catalog["Runtime failure %@"], "Runtime failure %@")
            self.assertIn("Current generic import", catalog)

    def test_retired_literal_cannot_be_reintroduced_through_a_dynamic_ui_helper(self):
        self.ui.write_text("void screen() { showLabel('Anime Boxes'); }", encoding="utf-8")
        with self.assertRaisesRegex(ValueError, "Retired UI copy is still referenced"):
            self.run_sync()

    def test_new_case_insensitive_brand_copy_requires_explicit_retirement(self):
        for language in sync.LANGUAGES:
            source = self.repository / "native-ios" / "Shared" / f"{language}.lproj" / "Localizable.strings"
            with source.open("a", encoding="utf-8") as output:
                output.write('"Import from vIoLeT" = "Import from vIoLeT";\n')
        with self.assertRaisesRegex(ValueError, "Retired import brands remain"):
            self.run_sync()

    def test_portable_ids_remain_source_data_instead_of_ui_copy(self):
        with self.ui.open("a", encoding="utf-8") as output:
            output.write("\nconst sourceId = 'anime-boxes';\nconst portableKey = 'legacy.animeBoxes.record';")
        self.assertEqual(self.run_sync(), 0)
        self.assertIn("'anime-boxes'", self.ui.read_text())
        self.assertIn("'legacy.animeBoxes.record'", self.ui.read_text())


if __name__ == "__main__":
    unittest.main()
