#!/usr/bin/env python3
"""
为 dev flavor 生成带「D」角标的 ic_launcher_foreground.png。

从 src/main/res/mipmap-*/ic_launcher_foreground.png 读取原图,
在右下角叠加黄底黑字 D 角标,输出到 src/dev/res/mipmap-*/ic_launcher_foreground.png。

角标规格:
- 底色 #FFD600,字色 #000000
- 边长 = 原图边长 × 0.28
- 右下边距 = 原图边长 × 0.06
- 圆角 = 边长 × 0.15
- 字号 = 边长 × 0.7

用法: python3 app/scripts/gen-dev-icon.py
"""
import os
from pathlib import Path
from PIL import Image, ImageDraw, ImageFont

MAIN_RES = Path("app/android/app/src/main/res")
DEV_RES = Path("app/android/app/src/dev/res")
DENSITIES = ["mdpi", "hdpi", "xhdpi", "xxhdpi", "xxxhdpi"]

# 角标参数(相对原图尺寸的比例)
BADGE_RATIO = 0.28          # 角标边长占原图比例
MARGIN_RATIO = 0.06         # 右下边距占原图比例
RADIUS_RATIO = 0.15         # 圆角占角标边长比例
FONT_RATIO = 0.7            # 字号占角标边长比例

BADGE_COLOR = (0xFF, 0xD6, 0x00, 0xFF)   # #FFD600 不透明
TEXT_COLOR = (0x00, 0x00, 0x00, 0xFF)    # #000000 不透明


def find_font(size: int) -> ImageFont.FreeTypeFont:
    """找系统粗体字体,失败回退 PIL 默认字体。"""
    candidates = [
        "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf",
        "/usr/share/fonts/truetype/liberation/LiberationSans-Bold.ttf",
        "/usr/share/fonts/TTF/DejaVuSans-Bold.ttf",
    ]
    for p in candidates:
        if os.path.exists(p):
            return ImageFont.truetype(p, size)
    # 回退:默认字体不支持调字号,角标字会偏小但能跑
    print(f"WARNING: 无系统粗体字体,回退 PIL 默认字体(角标 D 可能偏小)")
    return ImageFont.load_default()


def add_badge(src: Path, dst: Path) -> None:
    im = Image.open(src).convert("RGBA")
    w, h = im.size
    # adaptive-icon foreground 是正方形,取 min 防御
    side = min(w, h)

    badge_side = int(side * BADGE_RATIO)
    margin = int(side * MARGIN_RATIO)
    radius = int(badge_side * RADIUS_RATIO)
    font_size = int(badge_side * FONT_RATIO)

    # 角标方块位置(右下角)
    bx = w - badge_side - margin
    by = h - badge_side - margin

    # 画角标圆角方块
    overlay = Image.new("RGBA", im.size, (0, 0, 0, 0))
    draw = ImageDraw.Draw(overlay)
    draw.rounded_rectangle(
        [bx, by, bx + badge_side, by + badge_side],
        radius=radius,
        fill=BADGE_COLOR,
    )

    # 画 D 字(居中于角标方块)
    font = find_font(font_size)
    # 测量文字尺寸(pillow >= 8.0 用 textbbox,getbbox 兜底)
    try:
        bbox = draw.textbbox((0, 0), "D", font=font)
        tw, th = bbox[2] - bbox[0], bbox[3] - bbox[1]
        tx = bx + (badge_side - tw) // 2 - bbox[0]
        ty = by + (badge_side - th) // 2 - bbox[1]
    except AttributeError:
        # 极老 PIL 回退
        tw, th = font.getsize("D")
        tx = bx + (badge_side - tw) // 2
        ty = by + (badge_side - th) // 2
    draw.text((tx, ty), "D", font=font, fill=TEXT_COLOR)

    # 合成到原图
    result = Image.alpha_composite(im, overlay)

    dst.parent.mkdir(parents=True, exist_ok=True)
    result.save(dst, "PNG")
    print(f"  {src.relative_to(Path('app'))} ({w}×{h}) → {dst.relative_to(Path('app'))}")


def main() -> None:
    print("生成 dev flavor 图标角标...")
    for density in DENSITIES:
        src = MAIN_RES / f"mipmap-{density}" / "ic_launcher_foreground.png"
        dst = DEV_RES / f"mipmap-{density}" / "ic_launcher_foreground.png"
        if not src.exists():
            print(f"  SKIP {density}: 源文件不存在 {src}")
            continue
        add_badge(src, dst)
    print("完成。")


if __name__ == "__main__":
    main()
