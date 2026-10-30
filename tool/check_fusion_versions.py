"""Fail CI when the Flutter ref and CocoaPods version constraints diverge."""
from pathlib import Path
import re

root = Path(__file__).resolve().parents[1]
checks = {
    "fusion_auth/pubspec.yaml": r"(?m)^version:\s*([0-9.]+)\s*$",
    "fusion_auth/ios/fusion_auth.podspec": r"s\.version\s*=\s*'([0-9.]+)'",
    "carrier_auth/pubspec.yaml": r"ref:\s*fusion_auth-v([0-9.]+)",
    "carrier_auth/ios/carrier_auth.podspec": r"s\.dependency\s+'fusion_auth',\s*'([0-9.]+)'",
}
versions = {}
for name, pattern in checks.items():
    match = re.search(pattern, (root / name).read_text(encoding="utf-8"))
    if not match:
        raise SystemExit("Missing fusion version in " + name)
    versions[name] = match.group(1)
if len(set(versions.values())) != 1:
    raise SystemExit("Fusion package, Git ref and pod versions disagree: " + str(versions))
print("Fusion dependency versions match: " + next(iter(versions.values())))
