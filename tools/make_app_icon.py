"""Push a piece of artwork out to every icon this app ships, on every platform.

    python tools/make_app_icon.py design/icon.png

Writes, from the one source:

  * windows/runner/resources/app_icon.ico — the .exe's icon AND the window's,
    at 16, 24, 32, 48, 64, 128 and 256, so the title bar, Alt-Tab, the taskbar
    and Explorer's tiles each get a version drawn at the right scale instead of
    one resampled badly from another. The 16 is the one that matters: left to
    be shrunk from the 256 it turns to mush, and the title bar is where the
    icon is looked at most.
  * web/favicon.png and web/icons/Icon-{192,512}.png — the browser tab and the
    installed-app icon.
  * web/icons/Icon-maskable-{192,512}.png — the same art inset to the maskable
    safe zone (see MASKABLE_SCALE), because a maskable icon is cropped to
    whatever shape the platform feels like and art that runs to the edge loses
    its corners.
  * android/app/src/main/res/mipmap-*/ic_launcher.png — the five densities.
  * macos/.../AppIcon.appiconset/*.png — every size its Contents.json lists.
  * ios/.../AppIcon.appiconset/*.png — likewise, but FLATTENED: iOS app icons
    may not carry an alpha channel, and a transparent one is rejected at
    submission rather than at build. See IOS_BACKDROP.

The two Apple icon sets are driven from their own Contents.json rather than
from a list written out here, so a Flutter template that adds or renames a size
is followed rather than silently half-filled.
"""

import json
import sys
from pathlib import Path

from PIL import Image

# --- Windows ---------------------------------------------------------------
# The sizes Windows actually reaches for.
ICO_SIZES = [16, 24, 32, 48, 64, 128, 256]
ICO_TARGET = Path("windows/runner/resources/app_icon.ico")

# --- Web -------------------------------------------------------------------
WEB_ICONS = Path("web/icons")
WEB_FAVICON = Path("web/favicon.png")

# How much of a maskable icon's width the art may occupy. The spec guarantees
# only the middle 80% survives the crop; the rest is the platform's to eat.
MASKABLE_SCALE = 0.8

# --- Android ---------------------------------------------------------------
# Legacy launcher icons, one per density bucket. This project has no
# mipmap-anydpi-v26 adaptive icon, so these are what Android draws.
ANDROID_RES = Path("android/app/src/main/res")
ANDROID_DENSITIES = {
    "mdpi": 48,
    "hdpi": 72,
    "xhdpi": 96,
    "xxhdpi": 144,
    "xxxhdpi": 192,
}

# --- Apple -----------------------------------------------------------------
IOS_ICONSET = Path("ios/Runner/Assets.xcassets/AppIcon.appiconset")
MACOS_ICONSET = Path("macos/Runner/Assets.xcassets/AppIcon.appiconset")

# What an iOS icon's transparency is flattened onto. White because that is what
# a transparent icon looks like on the App Store's own pages and in most of the
# places iOS draws one; change it here if the artwork ever needs a different
# ground.
IOS_BACKDROP = (255, 255, 255)


def load(source: Path) -> Image.Image:
    if source.suffix.lower() in {".ai", ".eps", ".ps"}:
        raise SystemExit(
            f"{source} is PostScript, which needs Ghostscript to rasterize.\n"
            "Export a PNG from Illustrator (1024x1024, transparent) and pass "
            "that instead."
        )
    if source.suffix.lower() == ".pdf":
        import fitz  # PyMuPDF

        page = fitz.open(source)[0]
        scale = 1024 / max(page.rect.width, page.rect.height)
        pix = page.get_pixmap(matrix=fitz.Matrix(scale, scale), alpha=True)
        return Image.frombytes("RGBA", (pix.width, pix.height), pix.samples)
    return Image.open(source).convert("RGBA")


def square(img: Image.Image) -> Image.Image:
    """Center the artwork on a transparent square.

    Padded rather than stretched: an icon that is 4% taller than it is wide is
    a logo somebody drew that way, and the squash is more noticeable at 16
    pixels than the empty margin is.
    """
    if img.width == img.height:
        return img
    side = max(img.width, img.height)
    canvas = Image.new("RGBA", (side, side), (0, 0, 0, 0))
    canvas.paste(img, ((side - img.width) // 2, (side - img.height) // 2))
    return canvas


def scaled(art: Image.Image, size: int) -> Image.Image:
    return art.resize((size, size), Image.LANCZOS)


def maskable(art: Image.Image, size: int) -> Image.Image:
    """[art] inset into the maskable safe zone on a transparent square."""
    inner = int(size * MASKABLE_SCALE)
    canvas = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    art_small = scaled(art, inner)
    offset = (size - inner) // 2
    canvas.paste(art_small, (offset, offset), art_small)
    return canvas


def flattened(img: Image.Image, backdrop: tuple[int, int, int]) -> Image.Image:
    """[img] composited onto an opaque ground, with the alpha channel gone."""
    ground = Image.new("RGBA", img.size, (*backdrop, 255))
    return Image.alpha_composite(ground, img).convert("RGB")


def iconset_targets(folder: Path) -> dict[str, int]:
    """{filename: pixel size} for an Apple .appiconset, read off Contents.json.

    A filename can appear twice — macOS uses app_icon_32 for both 16x16@2x and
    32x32@1x — and both entries resolve to the same pixel size, so the larger
    is taken and the two agree by construction.
    """
    contents = json.loads((folder / "Contents.json").read_text(encoding="utf-8"))
    targets: dict[str, int] = {}
    for image in contents.get("images", []):
        name = image.get("filename")
        if not name:
            continue  # an unfilled slot in the template
        base = float(image["size"].split("x")[0])
        scale = int(image["scale"].rstrip("x"))
        pixels = int(round(base * scale))
        targets[name] = max(targets.get(name, 0), pixels)
    return targets


def main() -> None:
    if len(sys.argv) != 2:
        raise SystemExit(__doc__)
    source = Path(sys.argv[1])
    if not source.exists():
        raise SystemExit(f"No such file: {source}")

    art = square(load(source))
    written: list[str] = []

    def note(path: Path, detail: str) -> None:
        written.append(f"{path}  ({detail})")

    # --- Windows -----------------------------------------------------------
    ICO_TARGET.parent.mkdir(parents=True, exist_ok=True)
    art.save(ICO_TARGET, format="ICO", sizes=[(s, s) for s in ICO_SIZES])
    note(ICO_TARGET, ", ".join(f"{s}px" for s in ICO_SIZES))

    # --- Web ---------------------------------------------------------------
    if WEB_FAVICON.parent.exists():
        scaled(art, 16).save(WEB_FAVICON)
        note(WEB_FAVICON, "16px")

    if WEB_ICONS.exists():
        for size in (192, 512):
            scaled(art, size).save(WEB_ICONS / f"Icon-{size}.png")
            note(WEB_ICONS / f"Icon-{size}.png", f"{size}px")
            maskable(art, size).save(WEB_ICONS / f"Icon-maskable-{size}.png")
            note(
                WEB_ICONS / f"Icon-maskable-{size}.png",
                f"{size}px, {int(MASKABLE_SCALE * 100)}% safe zone",
            )

    # --- Android -----------------------------------------------------------
    for density, size in ANDROID_DENSITIES.items():
        folder = ANDROID_RES / f"mipmap-{density}"
        if not folder.exists():
            continue
        scaled(art, size).save(folder / "ic_launcher.png")
        note(folder / "ic_launcher.png", f"{size}px")

    # --- macOS -------------------------------------------------------------
    if (MACOS_ICONSET / "Contents.json").exists():
        for name, size in sorted(iconset_targets(MACOS_ICONSET).items()):
            scaled(art, size).save(MACOS_ICONSET / name)
            note(MACOS_ICONSET / name, f"{size}px")

    # --- iOS ---------------------------------------------------------------
    if (IOS_ICONSET / "Contents.json").exists():
        for name, size in sorted(iconset_targets(IOS_ICONSET).items()):
            flattened(scaled(art, size), IOS_BACKDROP).save(IOS_ICONSET / name)
            note(IOS_ICONSET / name, f"{size}px, no alpha")

    print(f"From {source}:")
    for line in written:
        print(f"  {line}")
    print(f"{len(written)} files written.")


if __name__ == "__main__":
    main()
