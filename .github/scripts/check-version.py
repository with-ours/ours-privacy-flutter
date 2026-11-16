#!/usr/bin/env python3
"""Check that every release version declaration agrees.

The pubspec version, `oursPrivacySdkVersion` in lib/src/version.dart, and the
top `## X.Y.Z` heading in CHANGELOG.md must be identical. With an argument
(`1.2.3` or `v1.2.3`), that release version must match too.
"""
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
PUBSPEC = ROOT / "pubspec.yaml"
VERSION_SOURCE = ROOT / "lib/src/version.dart"
CHANGELOG = ROOT / "CHANGELOG.md"

SEMVER = r"\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?(?:\+[0-9A-Za-z.-]+)?"


def find(pattern: str, text: str, what: str) -> str:
    match = re.search(pattern, text, re.M)
    if match is None:
        raise SystemExit(f"{what} is missing or invalid")
    return match.group(1)


def main() -> int:
    if len(sys.argv) > 2:
        print("Usage: check-version.py [release-version]", file=sys.stderr)
        return 2

    pubspec_version = find(
        rf"^version:\s*['\"]?({SEMVER})['\"]?\s*$",
        PUBSPEC.read_text(),
        "pubspec.yaml version",
    )
    sdk_version = find(
        rf"^const String oursPrivacySdkVersion = '({SEMVER})';\s*$",
        VERSION_SOURCE.read_text(),
        "lib/src/version.dart oursPrivacySdkVersion",
    )
    # The first level-two heading is the newest release.
    changelog_heading = find(r"^## (.+?)\s*$", CHANGELOG.read_text(), "CHANGELOG.md release heading")

    errors = []
    if sdk_version != pubspec_version:
        errors.append(f"lib/src/version.dart has {sdk_version}, pubspec.yaml has {pubspec_version}")
    if changelog_heading != pubspec_version:
        errors.append(f"CHANGELOG.md top heading is '{changelog_heading}', pubspec.yaml has {pubspec_version}")
    if len(sys.argv) == 2:
        release_version = sys.argv[1].removeprefix("v")
        if release_version != pubspec_version:
            errors.append(f"release version {release_version} does not match pubspec.yaml {pubspec_version}")

    if errors:
        print("Version mismatch:", file=sys.stderr)
        for error in errors:
            print(f"  - {error}", file=sys.stderr)
        return 1

    print(pubspec_version)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
