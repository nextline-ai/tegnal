#!/usr/bin/env python3
"""Packs a deck-course folder into one course file that learning mode's 코스 tab imports.

A course folder is laid out like the bundled AI lab (`native-ios/TEGNAL/AILab/`): `course.json` and
`episodes/<id>.json` for every episode its seasons name. The packed file is `course.json` with
`"episodes": [ … ]` written inline, in season order (format `tegnal-lab-course`, version 1).

    python3 native-ios/scripts/pack_course.py <folder> [--id new.course-id] [-o out.tegnalcourse]

`--id` gives the course a new id; the app refuses files that use the id of a course built into it
(`ai-lab`, `2d-ai`). The app checks the file again when it is imported, and refuses it rather than
fixing anything.
"""
import argparse
import json
import pathlib
import sys

RESERVED = {"ai-lab", "2d-ai"}


def pack(folder: pathlib.Path, course_id: str | None) -> dict:
    course = json.loads((folder / "course.json").read_text(encoding="utf-8"))
    course["format"] = "tegnal-lab-course"
    course["version"] = 1
    if course_id:
        course["id"] = course_id
    if course["id"] in RESERVED:
        sys.exit(f"'{course['id']}' belongs to a course built into the app; pass --id")
    episodes = []
    for season in course["seasons"]:
        for episode_id in season["episodes"]:
            episodes.append(json.loads((folder / "episodes" / f"{episode_id}.json").read_text(encoding="utf-8")))
    course["episodes"] = episodes
    return course


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("folder", type=pathlib.Path)
    parser.add_argument("--id", dest="course_id")
    parser.add_argument("-o", "--output", type=pathlib.Path)
    args = parser.parse_args()
    course = pack(args.folder, args.course_id)
    output = args.output or pathlib.Path(f"{course['id']}.tegnalcourse")
    output.write_text(json.dumps(course, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(f"{output}: {len(course['episodes'])} episodes in {len(course['seasons'])} seasons")


if __name__ == "__main__":
    main()
