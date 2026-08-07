import argparse
import unittest
from pathlib import Path

import release


class ReleaseSecurityTest(unittest.TestCase):
    def test_rejects_insecure_remote_update_center(self):
        args = argparse.Namespace(
            update_center="http://example.test",
            channel="stable",
            notes="",
            force=False,
            rollout=100,
            min_version=0,
            publish=False,
        )
        with self.assertRaises(ValueError):
            release.update_center_request(Path("app.apk"), "Example", args, "secret")


if __name__ == "__main__":
    unittest.main()
