#!/usr/bin/env bash
# 重新生成 emoji 字体子集。
#
# 用途:当 emoji_span.dart 的 _forceEmojiChars 新增字符后,运行此脚本
#       重新裁剪字体子集,把新字符的彩色字形纳入打包字体。
#
# 依赖:fonttools (pip install fonttools)
#
# 用法:
#   cd app && bash scripts/subset-emoji.sh
#
# 原理:从完整 NotoColorEmoji.ttf 裁剪出 _forceEmojiChars 对应的字形,
#       保留 CBDT/CBLC 彩色位图表。完整字体首次需自行获取(见下方 SOURCE_FONT)。

set -euo pipefail

cd "$(dirname "$0")/.."

# 完整字体来源:首次运行前需准备。优先用本机系统的,否则提示从哪下载。
# Ubuntu/Debian: /usr/share/fonts/truetype/noto/NotoColorEmoji.ttf
# 下载: https://github.com/googlefonts/noto-emoji (取 CBDT/CBLC 版,非 COLRv1)
SOURCE_FONT="${SOURCE_FONT:-/usr/share/fonts/truetype/noto/NotoColorEmoji.ttf}"
OUT_FONT="fonts/NotoColorEmoji.ttf"

if [[ ! -f "$SOURCE_FONT" ]]; then
  echo "✗ 找不到完整字体: $SOURCE_FONT" >&2
  echo "  请从 https://github.com/googlefonts/noto-emoji 下载 CBDT/CBLC 版" >&2
  echo "  或设置 SOURCE_FONT 环境变量指向完整字体路径" >&2
  exit 1
fi

# 需要保留的字符(裸字符,不含 FE0F)。
# ★ 新增单色字符时,只改这一行 ★
# 与 lib/utils/emoji_span.dart 的 _forceEmojiChars 保持一致。
TARGET_CHARS='©®‼⁉™ℹ↔↕↖↗↘↙↩↪⌨⏏⏭⏮⏯⏱⏲⏸⏹⏺Ⓜ▪▫▶◀◻◼☀☁☂☃☄☎☑☘☝☠☢☣☦☪☮☯☸☹☺♀♂♟♠♣♥♦♨♻♾⚒⚔⚕⚖⚗⚙⚛⚜⚠⚧⚰⚱⛈⛏⛑⛓⛩⛰⛱⛴⛷⛸⛹✂✈✉✌✍✏✒✔✖✝✡✳✴❄❇❣❤➡⤴⤵⬅⬆⬇〰〽㊗㊙'

echo "源字体: $SOURCE_FONT ($(du -h "$SOURCE_FONT" | cut -f1))"
echo "目标字符: $TARGET_CHARS"

# 临时输出再覆盖,避免 pyftsubset 输出到同文件
TMP=$(mktemp)
trap 'rm -f "$TMP"' EXIT

python3 - "$SOURCE_FONT" "$TMP" "$TARGET_CHARS" << 'PYEOF'
import sys
from fontTools.subset import Subsetter, Options
from fontTools.ttLib import TTFont

src, out, chars = sys.argv[1], sys.argv[2], sys.argv[3]
# 字符 + FE0F 变体选择符(FE0F 本身无字形,但保留以防 GSUB 组合)
text = chars + '\uFE0F'

options = Options()
options.layout_tables = []
options.notdef_outline = False
options.recalc_timestamp = False
options.drop_tables = ['GSUB']

subsetter = Subsetter(options=options)
subsetter.populate(text=text)

font = TTFont(src)
subsetter.subset(font)
font.save(out)

# 校验:cmap 覆盖 + CBDT 在
font2 = TTFont(out)
cmap = font2.getBestCmap()
missing = [hex(ord(c)) for c in chars if ord(c) not in cmap]
assert not missing, f'子集缺失字符: {missing}'
assert 'CBDT' in font2 and 'CBLC' in font2, '子集缺少 CBDT/CBLC 彩色表'
print(f'✓ 校验通过: {len(chars)} 个字符全覆盖, CBDT/CBLC 保留')
PYEOF

mv "$TMP" "$OUT_FONT"
echo "✓ 子集已生成: $OUT_FONT ($(du -h "$OUT_FONT" | cut -f1))"
echo ""
echo "下一步:"
echo "  1. 同步更新 lib/utils/emoji_span.dart 的 _forceEmojiChars"
echo "  2. flutter clean && flutter build apk 重新打包验证"
