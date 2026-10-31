#!/usr/bin/env python3
"""Run a deliberate subset of XCTest without creating simulator clones."""

import argparse
import json
import os
from pathlib import Path
import re
import shlex
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[2]
IOS = ROOT / "native-ios"
SCOPES = {
    "parser": ["GalleryIDParserTests"],
    "catalog": ["DocumentCatalogTests"],
    "backend": ["MangaBackendTests"],
    "content": ["NativeContentTests"],
    "reader": ["ReaderUXTests"],
    "grid": ["GridLayoutTests"],
    "downloads": ["DownloadTests"],
    "media": ["MediaInputTests"],
    "booru": ["BooruTests"],
    "booru-revision": ["BooruRevisionTests"],
    "booru-library": ["BooruLibraryTests"],
    "booru-cache": ["BooruThumbnailCacheTests"],
    "image-cache": ["PageImageDecodeQueueTests", "ViewerDownloadLifetimeTests"],
    "booru-backup": ["BooruBackupTests"],
    "backup": ["LibraryBackupTests"],
    "sync": ["LibrarySyncTests"],
    "taste": ["TasteTests"],
    "taste-feed": ["TasteFeedTests"],
    "challenge": ["ChallengeTests"],
    "presentation": ["AppPresentationTests"],
}


def discover_tests():
    """Files can contain several XCTestCase classes; never assume class == filename."""
    tests = {}
    for target in ("TEGNALTests", "TEGNALUITests"):
        for source in (IOS / target).glob("*.swift"):
            text = source.read_text()
            for match in re.finditer(r"\bclass\s+(\w+)\s*:\s*XCTestCase\b", text):
                tests.setdefault((target, match[1]), set())
        for source in (IOS / target).glob("*.swift"):
            text = source.read_text()
            declarations = list(re.finditer(
                r"^(?:@\w+\s+)?(?:(?:private|fileprivate|final)\s+)*"
                r"(?:class|extension|struct|enum)\s+(\w+)[^{]*\{", text, re.MULTILINE
            ))
            for index, match in enumerate(declarations):
                key = (target, match[1])
                if key in tests:
                    end = declarations[index + 1].start() if index + 1 < len(declarations) else len(text)
                    tests[key].update(re.findall(r"\bfunc\s+(test\w+)\s*\(", text[match.end():end]))
    return tests


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    choice = parser.add_mutually_exclusive_group()
    choice.add_argument("--scope", choices=["smoke", *SCOPES])
    choice.add_argument("--only", action="append", metavar="[TARGET/]CLASS[/METHOD]",
                        help="Repeat for multiple selectors; UI requires a method")
    parser.add_argument("--list", action="store_true", help="List feature scopes; no build")
    parser.add_argument("--dry-run", action="store_true", help="Print command; no build or boot")
    parser.add_argument("--device", help="Existing simulator UDID; default: iPhone 18 Pro")
    args = parser.parse_args()
    if args.list:
        print("smoke: 3 small tests (fallback only)")
        for name, classes in SCOPES.items():
            print(f"{name}: {', '.join(classes)}")
        return 0
    if not args.scope and not args.only:
        parser.print_help()
        return 0

    smoke = args.scope == "smoke"
    selectors = [] if smoke else (args.only or SCOPES[args.scope])
    normalized = []
    tests = discover_tests()
    for selector in selectors:
        parts = selector.removesuffix("()").split("/")
        if parts[0] not in ("TEGNALTests", "TEGNALUITests"):
            parts.insert(0, "TEGNALTests")
        if len(parts) not in (2, 3):
            parser.error(f"Select a class or method, not a whole target: {selector}")
        target, cls = parts[:2]
        if (target, cls) not in tests:
            parser.error(f"Unknown test class: {selector}")
        if target == "TEGNALUITests" and len(parts) != 3:
            parser.error("UI checks require an individual test method")
        if len(parts) == 3 and parts[2] not in tests[(target, cls)]:
            parser.error(f"Unknown test method: {selector}")
        normalized.append("/".join(parts))
    targets = {s.split("/")[0] for s in normalized}
    if len(targets) > 1:
        parser.error("Run unit and UI selections separately")
    plan = "Smoke" if smoke else ("UI" if "TEGNALUITests" in targets else "Unit")
    plan_data = json.loads((IOS / "TestPlans" / f"{plan}.xctestplan").read_text())
    skipped = set(plan_data["testTargets"][0].get("skippedTests", []))
    for selector in normalized:
        relative = selector.split("/", 1)[1] + "()"
        parts = selector.split("/")
        excluded_class = len(parts) == 2 and all(
            f"{parts[1]}/{method}()" in skipped for method in tests[tuple(parts)]
        )
        if relative in skipped or excluded_class:
            parser.error("This integration/translation check needs an explicit device validation command; see docs/testing.md")

    devices = json.loads(subprocess.check_output(["xcrun", "simctl", "list", "devices", "available", "-j"]))
    available = [d for group in devices["devices"].values() for d in group if d["isAvailable"]]
    matches = [d for d in available if d["udid"] == args.device] if args.device else [
        d for d in available if d["name"] == "iPhone 18 Pro"
    ]
    if len(matches) != 1:
        parser.error("Select one existing available simulator with --device UDID; no device was created")
    cmd = ["xcodebuild", "-project", str(IOS / "TEGNAL.xcodeproj"), "-scheme", "TEGNAL",
           "-testPlan", plan, "-destination", f"platform=iOS Simulator,id={matches[0]['udid']}",
           "-parallel-testing-enabled", "NO", "-maximum-concurrent-test-simulator-destinations", "1",
           "-enableCodeCoverage", "NO", *[f"-only-testing:{s}" for s in normalized], "test"]
    print(shlex.join(cmd), flush=True)
    if args.dry_run:
        return 0
    env = os.environ.copy()
    for key in ("TEGNAL_LIVE_TESTS", "TEGNAL_BOORU_LIVE_TESTS", "TEGNAL_CATALOG_ADDRESS"):
        env.pop(key, None)
    return subprocess.run(cmd, cwd=ROOT, env=env).returncode


if __name__ == "__main__":
    sys.exit(main())
