#!/usr/bin/env python3
import argparse
import os
import re
import shutil
import subprocess
import sys
import xml.etree.ElementTree as ET
from pathlib import Path
from urllib.parse import urlparse

UPDATE_CENTER = "https://api.boqinai.com/updatecenter"
APK_MIME = "application/vnd.android.package-archive"


def validate_release_options(args) -> None:
    uri = urlparse(args.update_center)
    loopback = uri.hostname in {"localhost", "127.0.0.1", "::1"}
    if not uri.hostname or (uri.scheme != "https" and not (uri.scheme == "http" and loopback)):
        raise ValueError("update center must use HTTPS (HTTP is allowed only for localhost)")
    if not 0 <= args.rollout <= 100:
        raise ValueError("rollout must be between 0 and 100")
    if args.min_version < 0:
        raise ValueError("min-version must be non-negative")


def read_version(project: Path) -> str:
    match = re.search(
        r"^version:\s*([^\s]+)\s*$",
        (project / "pubspec.yaml").read_text(encoding="utf-8"),
        re.MULTILINE,
    )
    if not match:
        raise ValueError("pubspec.yaml does not contain a version")
    return match.group(1).strip("'\"")


def read_app_name(project: Path) -> str:
    manifest = project / "android/app/src/main/AndroidManifest.xml"
    application = ET.parse(manifest).getroot().find("application")
    if application is None:
        raise ValueError("AndroidManifest.xml does not contain an application")
    label = application.get("{http://schemas.android.com/apk/res/android}label")
    if label and label.startswith("@string/"):
        resource_name = label.removeprefix("@string/")
        strings_file = project / "android/app/src/main/res/values/strings.xml"
        if strings_file.is_file():
            root = ET.parse(strings_file).getroot()
            resource = root.find(f"string[@name='{resource_name}']")
            if resource is not None and resource.text and resource.text.strip():
                return resource.text.strip()
    if not label or label.startswith("@"):
        raise ValueError("pass --app-name when the manifest label is a resource")
    return label


def build_apk(project: Path, app_name: str, version: str) -> Path:
    subprocess.run(
        [
            "flutter",
            "build",
            "apk",
            "--release",
            "--split-per-abi",
            "--target-platform",
            "android-arm64",
        ],
        cwd=project,
        check=True,
    )
    source = project / "build/app/outputs/flutter-apk/app-arm64-v8a-release.apk"
    safe_name = re.sub(r"[^\w.-]+", "_", app_name).strip("_") or "app"
    target = source.with_name(f"{safe_name}-{version}.apk")
    shutil.copy2(source, target)
    return target


def publish_github(apk: Path, repo: str, version: str, notes: str) -> None:
    normalized_version = version.lstrip("vV")
    tag = f"v{normalized_version}"
    exists = subprocess.run(
        ["gh", "release", "view", tag, "--repo", repo],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    ).returncode == 0
    if exists:
        command = [
            "gh",
            "release",
            "upload",
            tag,
            str(apk),
            "--repo",
            repo,
            "--clobber",
        ]
    else:
        command = [
            "gh",
            "release",
            "create",
            tag,
            str(apk),
            "--repo",
            repo,
            "--title",
            f"Version {normalized_version}",
            "--notes",
            notes or f"Release v{normalized_version}",
        ]
    subprocess.run(command, check=True)


def update_center_request(
    apk: Path, app_name: str, args, token: str
) -> tuple[list[str], str]:
    validate_release_options(args)
    endpoint = f"{args.update_center.rstrip('/')}/api/v1/releases"
    command = [
        "curl",
        "--fail-with-body",
        "--silent",
        "--show-error",
        "-H",
        "@-",
        "-X",
        "POST",
        endpoint,
        "-F",
        f"apk=@{apk};type={APK_MIME}",
        "--form-string",
        f"channel={args.channel}",
        "--form-string",
        f"release_notes={args.notes}",
        "--form-string",
        f"force_update={str(args.force).lower()}",
        "--form-string",
        f"rollout_percent={args.rollout}",
        "--form-string",
        f"min_supported_version_code={args.min_version}",
        "--form-string",
        f"publish={str(args.publish).lower()}",
        "--form-string",
        f"app_name={app_name}",
        "--form-string",
        f"app={app_name}",
    ]
    if "\r" in token or "\n" in token:
        raise ValueError("UPDATE_CENTER_TOKEN must not contain newlines")
    token = token.strip()
    if not token:
        raise ValueError("UPDATE_CENTER_TOKEN must not be empty")
    return command, f"Authorization: Bearer {token}\n"


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser(description="Build and publish a Flutter APK")
    result.add_argument("apk", nargs="?", help="Existing APK; omit to build arm64")
    result.add_argument("--project", default=".", help="Flutter project directory")
    result.add_argument("--repo", help="GitHub owner/repository")
    result.add_argument("--app-name")
    result.add_argument("--channel", default="stable")
    result.add_argument("--notes", default="")
    result.add_argument("--force", action="store_true")
    result.add_argument("--rollout", type=int, default=100)
    result.add_argument("--min-version", type=int, default=0)
    result.add_argument("--publish", action="store_true")
    result.add_argument(
        "--update-center",
        default=os.environ.get("UPDATE_CENTER_URL", UPDATE_CENTER),
    )
    result.add_argument("--no-update-center", action="store_true")
    return result


def main() -> int:
    args = parser().parse_args()
    project = Path(args.project).resolve()
    version = read_version(project)
    app_name = args.app_name or read_app_name(project)
    apk = Path(args.apk).resolve() if args.apk else build_apk(project, app_name, version)
    if not apk.is_file():
        raise FileNotFoundError(apk)

    token = os.environ.get("UPDATE_CENTER_TOKEN")
    if not args.repo and (args.no_update_center or not token):
        parser().error("provide --repo or UPDATE_CENTER_TOKEN")
    if args.repo:
        publish_github(apk, args.repo, version, args.notes)
    if token and not args.no_update_center:
        command, headers = update_center_request(apk, app_name, args, token)
        subprocess.run(command, input=headers, text=True, check=True)
    print(f"Published {apk.name} ({version})")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        print(f"release failed: {error}", file=sys.stderr)
        raise SystemExit(1)
