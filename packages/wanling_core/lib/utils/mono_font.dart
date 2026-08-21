/// 等宽字体兜底链。
///
/// 背景:Linux 走 fontconfig 别名能解析 'monospace'(→ DejaVu Sans Mono),
/// Android 系统有 monospace;**Windows 没有 generic family 解析器**,
/// 'monospace' 找不到字体会落到非等宽兜底,代码块排版错位。
/// 因此所有 `fontFamily: 'monospace'` 必须携带本 fallback:
/// Consolas(Win10+)→ Cascadia Mono(Win11)→ Courier New(保底)。
/// 非 Windows 平台主字体已命中,fallback 不触发,无副作用。
const List<String> kMonoFontFallback = ['Consolas', 'Cascadia Mono', 'Courier New'];
