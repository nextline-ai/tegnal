#!/usr/bin/env python3
"""Package the supplied high-resolution TEGNAL symbol for app icons.

Requires macOS's built-in sips tool. This converts and resizes the 1920px
design-output/JPG/symbol.jpg; it does not redraw the logo. Generated platform
assets are checked in, so builds do not need this script or an image library.
The Android adaptive icon wraps the foreground in tegnal_launcher_inset.xml:
keep that 108dp-to-72dp compensation so launchers preserve the source margins.
"""

from pathlib import Path
import shutil
import struct
import subprocess
import tempfile


FLUTTER = Path(__file__).resolve().parents[1]
SOURCE = FLUTTER.parent / "design-output" / "JPG" / "symbol.jpg"
BRANDING_ICON = FLUTTER / "assets" / "branding" / "app-icon.png"


def resized(size: int, destination: Path) -> None:
    destination.parent.mkdir(parents=True, exist_ok=True)
    subprocess.run(
        [
            "sips",
            "-s",
            "format",
            "png",
            "-z",
            str(size),
            str(size),
            str(SOURCE),
            "--out",
            str(destination),
        ],
        check=True,
        capture_output=True,
    )


def main() -> None:
    if shutil.which("sips") is None:
        raise SystemExit("Regeneration requires macOS sips; use the checked-in assets on other hosts.")
    resized(1024, BRANDING_ICON)
    resized(
        1024,
        FLUTTER
        / "android"
        / "app"
        / "src"
        / "main"
        / "res"
        / "drawable-nodpi"
        / "tegnal_launcher_foreground.png",
    )
    for density, size in {"mdpi": 48, "hdpi": 72, "xhdpi": 96, "xxhdpi": 144, "xxxhdpi": 192}.items():
        resized(size, FLUTTER / "android" / "app" / "src" / "main" / "res" / f"mipmap-{density}" / "ic_launcher.png")
    resized(256, FLUTTER / "linux" / "runner" / "resources" / "work.nextline.tegnal.png")
    sizes = (16, 24, 32, 48, 64, 128, 256)
    with tempfile.TemporaryDirectory(prefix="tegnal-icons-") as directory:
        images = []
        for size in sizes:
            path = Path(directory) / f"icon-{size}.png"
            resized(size, path)
            images.append(path.read_bytes())
    # ICO supports PNG-compressed entries. Keep every standard desktop size
    # without introducing an image-processing library into application builds.
    header = struct.pack("<HHH", 0, 1, len(sizes))
    offset = len(header) + len(sizes) * 16
    entries = []
    for size, image in zip(sizes, images):
        entries.append(struct.pack("<BBBBHHII", size % 256, size % 256, 0, 0, 1, 32, len(image), offset))
        offset += len(image)
    icon = FLUTTER / "windows" / "runner" / "resources" / "app_icon.ico"
    icon.write_bytes(header + b"".join(entries) + b"".join(images))
    print("Packaged the supplied TEGNAL symbol: Flutter branding, Android adaptive/density icons, Linux PNG and 7-size Windows ICO.")


if __name__ == "__main__":
    main()
