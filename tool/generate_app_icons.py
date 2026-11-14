"""生成应用图标（霓虹终端风格）。

近黑方块底 + 荧光绿的方形对话气泡，气泡里是终端提示符 `>_`。
有未读时右上角多一个警告红方块。颜色和 lib/ui/app_theme.dart 一致。

用法（在仓库根目录）：
    python3 tool/generate_app_icons.py

输出：
    assets/icons/whisper.png、whisper_unread.png（256，Linux 托盘和窗口）
    assets/icons/app_icon.ico、app_icon_unread.ico（Windows 托盘）
    windows/runner/resources/app_icon.ico（Windows 程序图标）
    packaging/linux/icons/whisper.png（Linux 安装包，256）
whisper_blank.png / app_icon_blank.ico 是托盘闪烁用的全透明图，不由本脚本生成。
"""

from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter

ROOT = Path(__file__).resolve().parent.parent

BG_TOP = (10, 17, 20, 255)  # field  #0A1114
BG_BOTTOM = (5, 8, 10, 255)  # bg     #05080A
EDGE = (29, 58, 51, 255)  # border #1D3A33
ACCENT = (0, 245, 160, 255)  # accent #00F5A0
ALERT = (255, 59, 59, 255)  # alert  #FF3B3B

S = 1024  # 画布边长，最后缩小


def _background(draw: ImageDraw.ImageDraw, simple: bool) -> None:
    margin, radius = 40, 150
    # 竖直渐变底：一行一行画，再用圆角遮罩裁出来。
    grad = Image.new("RGBA", (S, S))
    gd = ImageDraw.Draw(grad)
    for y in range(S):
        t = y / (S - 1)
        color = tuple(
            round(BG_TOP[i] * (1 - t) + BG_BOTTOM[i] * t) for i in range(4)
        )
        gd.line([(0, y), (S, y)], fill=color)
    mask = Image.new("L", (S, S), 0)
    ImageDraw.Draw(mask).rounded_rectangle(
        [margin, margin, S - margin, S - margin], radius=radius, fill=255
    )
    draw._image.paste(grad, (0, 0), mask)  # noqa: SLF001
    if not simple:
        draw.rounded_rectangle(
            [margin, margin, S - margin, S - margin],
            radius=radius,
            outline=EDGE,
            width=14,
        )


def _glyph(draw: ImageDraw.ImageDraw, color, simple: bool) -> None:
    """方形气泡（左下角带尖）+ 里面的 `>_`。小尺寸时线条加粗、留白收紧。"""
    w = 64 if simple else 46
    left, top, right, bottom = (190, 230, 834, 690) if simple else (226, 262, 798, 662)
    # 气泡外框（描边向内）加左下角的实心尖。
    draw.rectangle([left, top, right, bottom], outline=color, width=w)
    tail_x0, tail_x1, tail_tip = left + 60, left + 200, (left + 40, bottom + 150)
    draw.polygon(
        [(tail_x0, bottom - w // 2), tail_tip, (tail_x1, bottom - w // 2)],
        fill=color,
    )

    # 提示符 `>`
    cx, cy = left + (110 if simple else 120), (top + bottom) // 2
    size = 92 if simple else 84
    draw.line(
        [(cx, cy - size), (cx + size, cy), (cx, cy + size)],
        fill=color,
        width=w,
        joint="curve",
    )
    # 光标 `_`
    cur_left = cx + size + (70 if simple else 80)
    draw.rectangle(
        [cur_left, cy + size - w, cur_left + (200 if simple else 190), cy + size],
        fill=color,
    )


def _badge(img: Image.Image, simple: bool) -> None:
    """未读：右上角的警告红方块，外面一圈底色把它和气泡分开。"""
    x0, y0, x1, y1 = (600, 0, 1024, 424) if simple else (700, 40, 984, 324)
    ring = 56 if simple else 36
    if not simple:
        glow = Image.new("RGBA", (S, S), (0, 0, 0, 0))
        ImageDraw.Draw(glow).rectangle([x0, y0, x1, y1], fill=(255, 59, 59, 150))
        img.alpha_composite(glow.filter(ImageFilter.GaussianBlur(40)))
    d = ImageDraw.Draw(img)
    d.rounded_rectangle([x0, y0, x1, y1], radius=24, fill=BG_BOTTOM)
    d.rounded_rectangle(
        [x0 + ring, y0 + ring, x1 - ring, y1 - ring], radius=10, fill=ALERT
    )


def render(unread: bool, simple: bool) -> Image.Image:
    img = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    _background(ImageDraw.Draw(img), simple)
    if not simple:
        # 辉光：同样的图形模糊后垫在下面。
        glow = Image.new("RGBA", (S, S), (0, 0, 0, 0))
        _glyph(ImageDraw.Draw(glow), (0, 245, 160, 170), simple)
        img.alpha_composite(glow.filter(ImageFilter.GaussianBlur(26)))
    _glyph(ImageDraw.Draw(img), ACCENT, simple)
    if unread:
        _badge(img, simple)
    return img


def sized(unread: bool, px: int) -> Image.Image:
    # 32 及以下：去掉辉光和描边，线条加粗，托盘里才看得清。
    return render(unread, simple=px <= 32).resize((px, px), Image.LANCZOS)


def write_ico(path: Path, unread: bool) -> None:
    sizes = [16, 20, 24, 32, 40, 48, 64, 128, 256]
    images = [sized(unread, s) for s in sizes]
    # 每个尺寸单独缩放，不让 Pillow 从 256 自动缩小（小尺寸要用简化版）。
    images[-1].save(
        path,
        format="ICO",
        sizes=[(s, s) for s in sizes],
        append_images=images[:-1],
    )


def main() -> None:
    icons = ROOT / "assets" / "icons"
    sized(False, 256).save(icons / "whisper.png")
    sized(True, 256).save(icons / "whisper_unread.png")
    write_ico(icons / "app_icon.ico", unread=False)
    write_ico(icons / "app_icon_unread.ico", unread=True)
    write_ico(ROOT / "windows" / "runner" / "resources" / "app_icon.ico", unread=False)
    sized(False, 256).save(ROOT / "packaging" / "linux" / "icons" / "whisper.png")
    # 预览图，不进仓库。
    preview = Image.new("RGBA", (700, 256), (5, 8, 10, 255))
    x = 0
    for img in [sized(False, 256), sized(True, 256), sized(False, 64), sized(True, 32), sized(False, 16)]:
        preview.alpha_composite(img, (x, 0))
        x += img.width + 16
    preview.save("/tmp/whisper_icon_preview.png")


if __name__ == "__main__":
    main()
