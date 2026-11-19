#!/usr/bin/env python3
"""Brings the home scene's film, music and drawings into the Android app.

    python3 flutter/tool/sync_home_assets.py [folder with the Flutter films and the music]

The drawings are the iOS app's own (`native-ios/scripts/home_art.py` writes them), turned into
pictures here because Flutter has no reader for them. Each is made twice a phone's width for the
largest place it stands in; soft, painted shapes need no more. The films and the music are brought
over only when their folder is given, as it is kept outside the repository.

The films are 864x1878, and Android's decoders work in blocks: a width that is not a multiple of 128
(or a height that is not a multiple of 32) is padded, and Flutter's video texture can show the padding
as a coloured band down one edge. So each film is encoded again at 896x1952. The app lays the film
over the picture's own frame, whatever the file's size, so nothing looks stretched.
"""

import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
DRAWINGS = ROOT / "native-ios" / "TEGNAL" / "Assets.xcassets" / "Home"
OUT = ROOT / "flutter" / "assets" / "home"

# Width in pixels: the widest the drawing stands on a phone, in the scene's units of 450 points, at 2x.
WIDTHS = {
    "HomeCeiling": 1170, "HomeCloudBank": 1170, "HomeGroundEdge": 900,
    "HomeStrataA": 900, "HomeStrataB": 900, "HomeGems": 900, "HomeStarfield": 900,
    "HomeCloudA": 940, "HomeCloudB": 1100, "HomeCloudC": 990,
    "HomeCrystals": 500, "HomeLantern": 400, "HomeMushrooms": 310, "HomeRelicFrame": 270, "HomeRelicBooks": 270,
    "HomeRockSide": 400, "HomeShootingStar": 450, "HomeMoon": 540, "HomeConstellation": 500, "HomeSparkle": 310,
}
# Each film with the bitrate that keeps it near its original size.
FILMS = {
    "magic_hour_splash_flutter.mp4": ("home_intro.mp4", "1500k"),
    "magic_hour_splash_flutter_loop.mp4": ("home_loop.mp4", "1100k"),
}
MUSIC = {"Starlit Waves & Night Whispers.mp3": "home_theme.mp3"}


def film(source, target, bitrate, work):
    """Encodes one film at a size Android does not pad, in two passes."""
    common = ["ffmpeg", "-v", "error", "-y", "-i", str(source), "-an", "-vf", "scale=896:1952:flags=lanczos,setsar=1",
              "-c:v", "libx264", "-profile:v", "high", "-pix_fmt", "yuv420p", "-preset", "slow", "-b:v", bitrate, "-g", "30",
              "-passlogfile", str(Path(work) / "pass")]
    subprocess.run(common + ["-pass", "1", "-f", "null", "/dev/null"], check=True)
    subprocess.run(common + ["-pass", "2", "-movflags", "+faststart", str(target)], check=True)


def main():
    art = OUT / "art"
    art.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory() as work:
        tool = Path(work) / "home_art"
        subprocess.run(["swiftc", "-O", str(Path(__file__).with_name("home_art.swift")), "-o", str(tool)], check=True)
        for name, width in WIDTHS.items():
            png = Path(work) / f"{name}.png"
            subprocess.run([str(tool), str(DRAWINGS / f"{name}.imageset" / f"{name}.svg"), str(png), str(width)], check=True)
            subprocess.run(["cwebp", "-quiet", "-q", "88", "-alpha_q", "92", "-m", "6", str(png), "-o", str(art / f"{name}.webp")], check=True)
        print(f"{len(WIDTHS)} drawings written to {art}")
        if len(sys.argv) > 1:
            for source, (name, bitrate) in FILMS.items():
                film(Path(sys.argv[1]) / source, OUT / name, bitrate, work)
            for source, name in MUSIC.items():
                shutil.copyfile(Path(sys.argv[1]) / source, OUT / name)
            print(f"{len(FILMS)} films and the music brought to {OUT}")


if __name__ == "__main__":
    main()
