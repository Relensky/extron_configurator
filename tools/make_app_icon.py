"""Build the Windows app icon from a piece of artwork.

    python tools/make_app_icon.py design/icon.png

Writes windows/runner/resources/app_icon.ico with every size Windows asks for
(16, 24, 32, 48, 64, 128, 256), so the taskbar, Alt-Tab, the title bar and the
Explorer tile all get a version drawn at the right scale instead of one
resampled badly from another.

Accepts:
  * PNG / any raster Pillow can open — square is best; anything else is
    letterboxed onto a transparent square rather than stretched.
  * PDF — rendered at 1024 px with PyMuPDF.

DOES NOT accept .ai or .eps. Illustrator's EPS is PostScript, and rasterising
PostScript needs Ghostscript, which is not part of this project's toolchain.
Export a PNG from Illustrator first (File > Export > Export As > PNG, 1024x1024,
transparent background) into design/ and hand that to this script.
"""

import sys
from pathlib import Path

from PIL import Image

# The sizes Windows actually reaches for. 256 is the Explorer "extra large"
# tile; 16 is the title bar, and it is the one that goes to mush if it is left
# to be resampled from the big one.
SIZES = [16, 24, 32, 48, 64, 128, 256]

TARGET = Path("windows/runner/resources/app_icon.ico")


def load(source: Path) -> Image.Image:
    if source.suffix.lower() in {".ai", ".eps", ".ps"}:
        raise SystemExit(
            f"{source} is PostScript, which needs Ghostscript to rasterise.\n"
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
    """Centre the artwork on a transparent square.

    Padded rather than stretched: an icon that is 10% wider than it is tall is
    a logo somebody drew that way, and squashing it is more noticeable at 16
    pixels than the empty margin is.
    """
    if img.width == img.height:
        return img
    side = max(img.width, img.height)
    canvas = Image.new("RGBA", (side, side), (0, 0, 0, 0))
    canvas.paste(img, ((side - img.width) // 2, (side - img.height) // 2))
    return canvas


def main() -> None:
    if len(sys.argv) != 2:
        raise SystemExit(__doc__)
    source = Path(sys.argv[1])
    if not source.exists():
        raise SystemExit(f"No such file: {source}")

    art = square(load(source))
    TARGET.parent.mkdir(parents=True, exist_ok=True)
    art.save(TARGET, format="ICO", sizes=[(s, s) for s in SIZES])
    print(f"Wrote {TARGET} from {source} at {', '.join(str(s) for s in SIZES)}px.")


if __name__ == "__main__":
    main()
