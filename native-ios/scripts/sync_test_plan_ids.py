#!/usr/bin/env python3
"""Keep test plan target references valid after XcodeGen regenerates IDs."""

import json
from pathlib import Path
import subprocess

IOS = Path(__file__).resolve().parent.parent


def sync(project=IOS / "TEGNAL.xcodeproj", plans=IOS / "TestPlans"):
    objects = json.loads(subprocess.check_output([
        "plutil", "-convert", "json", "-o", "-", str(project / "project.pbxproj")
    ]))["objects"]
    targets = {obj["name"]: key for key, obj in objects.items()
               if obj.get("isa") == "PBXNativeTarget"}
    for path in plans.glob("*.xctestplan"):
        plan = json.loads(path.read_text())
        for entry in plan["testTargets"]:
            entry["target"]["identifier"] = targets[entry["target"]["name"]]
        path.write_text(json.dumps(plan, indent=2) + "\n")


if __name__ == "__main__":
    sync()
