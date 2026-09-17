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
        self.prepared = []

    def prepare(self, artifact):
        self.prepared.append(artifact)

    def publish(self, artifact):
        self.artifacts.append(artifact)
        return release.PublishResult("fake", "ok")


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
            self.assertEqual(publisher.prepared, [artifact])
            self.assertEqual(pipeline.results, [release.PublishResult("fake", "ok")])

    def test_prepares_every_publisher_before_publishing(self):
        events = []

        class Publisher:
            def __init__(self, name, fail=False):
                self.name = name
                self.fail = fail

            def prepare(self, artifact):
                events.append(f"prepare:{self.name}")
                if self.fail:
                    raise ValueError("not ready")

            def publish(self, artifact):
                events.append(f"publish:{self.name}")
                return release.PublishResult(self.name, "ok")

        with tempfile.TemporaryDirectory() as raw:
            project = Path(raw)
            (project / "pubspec.yaml").write_text(
                "name: sample\nversion: 2.0.0\n", encoding="utf-8"
            )
            apk = project / "app.apk"
            apk.write_bytes(b"apk")
            pipeline = release.ReleasePipeline(
                release.ProjectInspector(project),
                _Builder(),
                [Publisher("one"), Publisher("two", fail=True)],
            )

            with self.assertRaises(ValueError):
                pipeline.run(apk=apk, app_name="Example")

        self.assertEqual(events, ["prepare:one", "prepare:two"])


if __name__ == "__main__":
    unittest.main()
