import tempfile
import unittest
from pathlib import Path

import release


class _Builder:
    def build(self, project, app_name, version):
        apk = project / f"{app_name}-{version}.apk"
        apk.write_bytes(b"apk")
        return apk


class _Publisher:
    def __init__(self):
        self.artifacts = []

    def publish(self, artifact):
        self.artifacts.append(artifact)


class PipelineTest(unittest.TestCase):
    def test_pipeline_inspects_builds_and_publishes(self):
        with tempfile.TemporaryDirectory() as raw:
            project = Path(raw)
            (project / "pubspec.yaml").write_text(
                "name: sample\nversion: 2.0.0+1\n", encoding="utf-8"
            )
            manifest = project / "android/app/src/main/AndroidManifest.xml"
            manifest.parent.mkdir(parents=True)
            manifest.write_text(
                '<manifest xmlns:android="http://schemas.android.com/apk/res/android">'
                '<application android:label="Example" /></manifest>',
                encoding="utf-8",
            )
            publisher = _Publisher()
            pipeline = release.ReleasePipeline(
                release.ProjectInspector(project), _Builder(), [publisher]
            )

            artifact = pipeline.run()

            self.assertEqual(artifact.version, "2.0.0+1")
            self.assertEqual(artifact.app_name, "Example")
            self.assertEqual(publisher.artifacts, [artifact])


if __name__ == "__main__":
    unittest.main()
