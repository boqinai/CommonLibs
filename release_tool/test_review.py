import argparse
import tempfile
import unittest
from pathlib import Path

import release


class ReleaseRegressionTest(unittest.TestCase):
    def test_preserves_build_number(self):
        with tempfile.TemporaryDirectory() as raw:
            project = Path(raw)
            (project / "pubspec.yaml").write_text(
                "name: sample\nversion: 1.2.3+1002003\n", encoding="utf-8"
            )
            self.assertEqual(release.read_version(project), "1.2.3+1002003")

    def test_header_uses_a_real_newline_and_text_fields_are_literal(self):
        args = argparse.Namespace(
            update_center="https://example.test",
            channel="stable",
            notes="@secret.txt",
            force=False,
            rollout=100,
            min_version=0,
            publish=False,
        )
        command, headers = release.update_center_request(
            Path("app.apk"), "Example", args, "secret"
        )
        self.assertEqual(headers, "Authorization: Bearer secret\n")
        self.assertIn("--form-string", command)


if __name__ == "__main__":
    unittest.main()
