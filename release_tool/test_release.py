import argparse
import tempfile
import unittest
from pathlib import Path

import release


class ReleaseToolTest(unittest.TestCase):
    def test_reads_flutter_version_and_manifest_label(self):
        with tempfile.TemporaryDirectory() as raw:
            project = Path(raw)
            (project / "pubspec.yaml").write_text(
                "name: sample\nversion: 1.2.3+1002003\n", encoding="utf-8"
            )
            manifest = project / "android/app/src/main/AndroidManifest.xml"
            manifest.parent.mkdir(parents=True)
            manifest.write_text(
                '<manifest xmlns:android="http://schemas.android.com/apk/res/android">'
                '<application android:label="示例" /></manifest>',
                encoding="utf-8",
            )

            self.assertEqual(release.read_version(project), "1.2.3+1002003")
            self.assertEqual(release.read_app_name(project), "示例")

    def test_update_center_command_preserves_release_options(self):
        args = argparse.Namespace(
            update_center="https://example.test/",
            channel="stable",
            notes="notes",
            force=True,
            rollout=25,
            min_version=100,
            publish=True,
        )

        command, headers = release.update_center_request(
            Path("app.apk"), "Example", args, "secret"
        )

        self.assertIn("https://example.test/api/v1/releases", command)
        self.assertIn("force_update=true", command)
        self.assertIn("rollout_percent=25", command)
        self.assertIn("min_supported_version_code=100", command)
        self.assertNotIn("secret", command)
        self.assertEqual(headers, "Authorization: Bearer secret\n")

    def test_reads_quoted_version_and_string_resource_label(self):
        with tempfile.TemporaryDirectory() as raw:
            project = Path(raw)
            (project / "pubspec.yaml").write_text(
                'name: sample\nversion: "1.2.3+4"\n', encoding="utf-8"
            )
            manifest = project / "android/app/src/main/AndroidManifest.xml"
            manifest.parent.mkdir(parents=True)
            manifest.write_text(
                '<manifest xmlns:android="http://schemas.android.com/apk/res/android">'
                '<application android:label="@string/app_name" /></manifest>',
                encoding="utf-8",
            )
            strings = project / "android/app/src/main/res/values/strings.xml"
            strings.parent.mkdir(parents=True)
            strings.write_text(
                '<resources><string name="app_name">示例应用</string></resources>',
                encoding="utf-8",
            )

            self.assertEqual(release.read_version(project), "1.2.3+4")
            self.assertEqual(release.read_app_name(project), "示例应用")


if __name__ == "__main__":
    unittest.main()

