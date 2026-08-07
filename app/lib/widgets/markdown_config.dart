import 'package:flutter/material.dart';
import 'package:flutter_highlight/themes/a11y-dark.dart';
import 'package:flutter_highlight/themes/a11y-light.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:markdown_widget/markdown_widget.dart';

import '../theme/app_colors.dart';
import 'image_thumb.dart';
import 'markdown_code_wrapper.dart';
import 'select_all_container.dart';
import '../utils/gallery_image.dart' show thumbUrl;

/// 允许在 markdown 中点击打开的链接 scheme 白名单。
///
/// markdown 内容来自 agent(LLM),不受信任。LinkNode 默认走 url_launcher 的
/// launchUrl,会原样打开任意 scheme(javascript:/file:/intent: 等)。这里收敛到
/// 只允许 http/https,从源头拦掉危险 scheme。
const _allowedLinkSchemes = {'http', 'https'};

/// 判断 url 是否为可信的内部 server 图片(只有这类才允许渲染成图)。
///
/// adapter 已把 agent 回复里的远程图片下载上传,替换为 /api/files/{id} 的内部
/// 链接(见 adapter._rewrite_remote_images)。其余 http(s) URL 仍是外部不可信
/// 链接(LLM 幻觉/追踪图/SSRF),一律不渲染成图,只显示文字占位。
///
/// 同时放行「拼好 baseUrl 的完整 URL」(baseUrl/api/files/xxx),因为 markdown
/// 里存的可能是相对路径,渲染时拼成完整 URL 再判断。
bool _isInternalFileUrl(String url, String baseUrl) {
  if (url.startsWith('/api/files/')) return true;
  final prefix = baseUrl.endsWith('/') ? baseUrl : '$baseUrl/';
  return url.startsWith('${prefix}api/files/');
}

/// 聊天气泡用的 markdown 渲染样式（极简墨白风格）。
///
/// 特征:
/// - 正文 16px、行高 1.5(全元素统一字号,标题靠颜色区分层级)
/// - 标题墨黑/粗体,层级靠颜色区分,**不带底部分割横线**
/// - 代码块:浅灰底圆角 6 + flutter_highlight 高亮 + 右上角复制按钮(无语言标签)
/// - 引用块灰条
/// - 表格:只保留行下方浅灰细线(无外框/竖线),表头灰字不加粗、表内容黑字不加粗,
///   宽表格横向滚动
///
/// [isDark] 控制明暗主题切换(代码块高亮主题 + 文字颜色)。
/// [isMe] 控制发送方气泡字体色:发送方气泡背景为紫色 #8B5CF6,正文/标题/表格
/// 字色强制白色(isDark 不再生效,因紫色背景在 dark/light 模式下都不变)。
/// [baseUrl] / [token] 用于渲染 markdown 内嵌的内部图片(/api/files/xxx):
/// adapter 已把 agent 回复里的远程图替换为内部链接,APP 需带 JWT 从 server 拉取。
/// [context] 用于图片点击进全屏查看页(Navigator.push)。
MarkdownConfig markdownStyle({
  required bool isDark,
  required bool isMe,
  required BuildContext context,
  String baseUrl = '',
  String token = '',
  void Function(String fileId)? openGallery,
}) {
  // 发送方气泡紫色背景,字色强制白色;接收方白底用 mdBody
  final ink = isMe
      ? Colors.white
      : (isDark ? const Color(0xFFE8E8E8) : AppColors.mdBody);
  final sub = isMe
      ? const Color(0xFFE8E0FF)
      : (isDark ? const Color(0xFF999999) : const Color(0xFF666666));
  // 表格行下方分割线:浅灰细线
  final tableDividerColor =
      isDark ? const Color(0xFF444444) : const Color(0xFFDDDDDD);
  // 分割线:比 sub 更淡的灰,避免视觉过重
  final hrColor = isDark ? const Color(0xFF444444) : const Color(0xFFCCCCCC);
  final preBase = isDark ? PreConfig.darkConfig : const PreConfig();
  final base = isDark ? MarkdownConfig.darkConfig : MarkdownConfig.defaultConfig;
  return base.copy(configs: [
    PConfig(textStyle: TextStyle(fontSize: 16, fontWeight: FontWeight.w400, height: 1.5, color: ink)),
    // 行内代码:绿色 #00B176 + 无背景(透明覆盖默认灰底) + 等宽
    const CodeConfig(style: TextStyle(
      color: AppColors.mdLink,
      backgroundColor: Colors.transparent,
      fontFamily: 'monospace',
    )),
    // 任务列表 checkbox:checked=绿底白字 ✓,unchecked=灰边框空心(与 TodoBody 风格一致)
    const CheckBoxConfig(builder: _markdownCheckBoxBuilder),
    const _NoDividerHeadingConfig(
      tag: MarkdownTag.h1,
      style: TextStyle(
          fontSize: 16, fontWeight: FontWeight.w500, color: AppColors.mdH1, height: 1.5),
    ),
    const _NoDividerHeadingConfig(
      tag: MarkdownTag.h2,
      style: TextStyle(
          fontSize: 16, fontWeight: FontWeight.w500, color: AppColors.mdH2, height: 1.5),
    ),
    const _NoDividerHeadingConfig(
      tag: MarkdownTag.h3,
      style: TextStyle(
          fontSize: 16, fontWeight: FontWeight.w500, color: AppColors.mdH3, height: 1.5),
    ),
    const _NoDividerHeadingConfig(
      tag: MarkdownTag.h4,
      style: TextStyle(
          fontSize: 16, fontWeight: FontWeight.w500, color: AppColors.mdH3, height: 1.5),
    ),
    const _NoDividerHeadingConfig(
      tag: MarkdownTag.h5,
      style: TextStyle(
          fontSize: 16, fontWeight: FontWeight.w500, color: AppColors.mdH5, height: 1.5),
    ),
    const _NoDividerHeadingConfig(
      tag: MarkdownTag.h6,
      style: TextStyle(
          fontSize: 16, fontWeight: FontWeight.w500, color: AppColors.mdH5, height: 1.5),
    ),
    // 分割线:height 1,用比 sub 更淡的灰(亮色 #CCCCCC / 暗色 #444444)
    HrConfig(height: 1, color: hrColor),
    preBase.copy(
      wrapper: markdownCodeWrapper,
      theme: isDark ? a11yDarkTheme : a11yLightTheme,
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF2A2A2A) : const Color(0xFFF2F2F2),
        borderRadius: BorderRadius.circular(6),
      ),
    ),
    BlockquoteConfig(
      sideColor: isDark ? const Color(0xFF555555) : AppColors.mdQuoteSide,
      textColor: isDark ? sub : AppColors.mdH5,
      sideWith: 2,
      padding: const EdgeInsets.fromLTRB(10, 6, 0, 6),
      margin: const EdgeInsets.symmetric(vertical: 6),
    ),
    TableConfig(
      // 只保留每行下方浅灰细线,去掉外框和竖线
      border: TableBorder(
        bottom: BorderSide(width: 0.5, color: tableDividerColor),
        horizontalInside:
            BorderSide(width: 0.5, color: tableDividerColor),
      ),
      // 行高 +5:单元格上下内边距默认 4 → 9
      headPadding: const EdgeInsets.fromLTRB(8, 9, 8, 9),
      bodyPadding: const EdgeInsets.fromLTRB(8, 9, 8, 9),
      // 注意:markdown_widget 2.3.2+8 有 bug,TBodyNode(表内容)的 style 实际读
      // headerStyle 而非 bodyStyle,所以表头表内容共用 headerStyle。
      // 字色跟随 ink(发送方气泡紫色背景时白字,接收方按 isDark 切换)。
      headerStyle: TextStyle(
          color: ink, fontSize: 16, fontWeight: FontWeight.w400),
      // bodyStyle 在当前版本不生效(被上述 bug 绕过),保留与 headerStyle 一致作记录
      bodyStyle: TextStyle(
          color: ink, fontSize: 16, fontWeight: FontWeight.w400),
      // 表格包横向滚动:宽表格可横向滑动,避免溢出气泡
      wrapper: _tableScrollWrapper,
    ),
    // 安全:只渲染内部 server 图片(/api/files/),外部 URL 仍文字占位(防追踪/SSRF)。
    // adapter 已把 agent 回复里的远程图下载上传替换为 /api/files/{id}(见 adapter),
    // 这里放行内部链接带 JWT 拉取;其余 URL 是 LLM 幻觉/追踪图,不渲染成图。
    // 见 [_markdownImageBuilder] / [_markdownImagePlaceholder]。
    ImgConfig(builder: (url, attrs) => _markdownImageBuilder(url, attrs, baseUrl, token, context, openGallery)),
    // 安全:链接点击收敛到 http/https 白名单,拦截 javascript:/file: 等危险 scheme。
    // 放行的链接仍走 markdown_widget 默认的 launchUrl 外部打开。
    // 链接色用品牌绿 #00B176 + 去下划线,对齐 IM 简洁风格。
    const LinkConfig(
      style: TextStyle(
        color: AppColors.mdLink,
        decoration: TextDecoration.none,
      ),
      onTap: _safeLaunchUrl,
    ),
  ]);
}

/// 无分割线标题配置:override divider 返回 null,去掉 H1/H2 默认的底部横线。
/// 通过 tag 区分 h1/h2/h3,共用一个类。
class _NoDividerHeadingConfig extends HeadingConfig {
  final MarkdownTag _tag;
  @override
  final TextStyle style;

  const _NoDividerHeadingConfig({
    required MarkdownTag tag,
    required this.style,
  }) : _tag = tag;

  @override
  String get tag => _tag.name;

  @override
  HeadingDivider? get divider => null;
}

/// 表格外层横向滚动包装:宽表格可横向滑动,避免溢出气泡。
/// 内层包 SelectAllOrNoneContainer:拉杆碰到表格整块选中(表格单元格是 TextSpan
/// 天然可选,复制得表格文本)。
/// 外层 Padding 提供上下间距(默认 TableConfig 无 margin 字段,统一在此控制)。
Widget _tableScrollWrapper(Widget child) {
  return Padding(
    padding: const EdgeInsets.symmetric(vertical: 8),
    child: SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: SelectAllOrNoneContainer(child: child),
    ),
  );
}

/// markdown 内嵌图片渲染器。
///
/// 安全策略(只放行内部 server 图片,防追踪/SSRF):
/// - 内部 URL(/api/files/xxx)→ CachedNetworkImage 带 JWT 拉取渲染
/// - 外部 URL(http(s):// 任意域)→ 文字占位,不发起任何网络请求
///
/// adapter 已把 agent 回复里能下载的远程图替换为内部链接;替换失败的(下载/上传
/// 失败)仍残留外部 URL,这里用文字占位兜底,保证用户至少看懂上下文。
Widget _markdownImageBuilder(
  String url,
  Map<String, String> attributes,
  String baseUrl,
  String token,
  BuildContext context,
  void Function(String fileId)? openGallery,
) {
  if (!_isInternalFileUrl(url, baseUrl)) {
    return _markdownImagePlaceholder(attributes);
  }
  // 提取 fileId：markdown 里可能是相对路径 /api/files/{id} 或拼好 baseUrl 的完整
  // URL，统一提取 fileId 后用 thumbUrl 拼（?thumb=1 缩略图，服务端无缩略图时降级原图）。
  final fileId = _extractFileIdFromUrl(url);
  final imageUrl = thumbUrl(baseUrl, fileId);
  final headers = token.isEmpty ? <String, String>{} : {'Authorization': 'Bearer $token'};
  final isDark = Theme.of(context).brightness == Brightness.dark;
  // fileId 作 Hero tag，与 image 类型 'gallery_$fileId' 同口径；点击进会话级
  // 画廊（openGallery），与 image 类型完全对称。openGallery 为 null（测试）
  // 时降级为单图全屏，避免崩溃。
  //
  // markdown 内嵌图不传 aspect（server 不补 markdown 内嵌图宽高），走 ImageThumb
  // 内的 resolve 探测兜底。用 contain 不裁切（文档插图保留完整信息）。
  return Hero(
    tag: 'gallery_$fileId',
    child: GestureDetector(
      onTap: () => openGallery?.call(fileId),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(6),
        child: ImageThumb(
          fileId: fileId,
          url: imageUrl,
          headers: headers,
          // markdown 内嵌图是文档插图，完整显示不裁切（截图/图表带文字）。
          fit: BoxFit.contain,
          isDark: isDark,
        ),
      ),
    ),
  );
}

/// 从 markdown 图片 URL 提取 fileId（/api/files/{id}）。
///
/// 与 gallery_image.dart 的 _extractFileId 同口径，确保 Hero tag 一致。
/// 无法识别时回退到原 url（保证 tag 唯一不冲突）。
String _extractFileIdFromUrl(String url) {
  const prefix = '/api/files/';
  final idx = url.indexOf(prefix);
  if (idx < 0) return url;
  final tail = url.substring(idx + prefix.length);
  final qIdx = tail.indexOf('?');
  return qIdx >= 0 ? tail.substring(0, qIdx) : tail;
}

/// 外部/不可信图片的文字占位:不发起网络请求。
///
/// - 有 alt → 显示「🖼️ alt」(保留可读性,无图也能看懂上下文)
/// - 无 alt → 显示「🖼️ 图片」
Widget _markdownImagePlaceholder(Map<String, String> attributes) {
  final alt = (attributes['alt'] ?? '').trim();
  final label = alt.isEmpty ? '图片' : alt;
  return RichText(
    text: TextSpan(
      children: [
        const WidgetSpan(
          child: Icon(Icons.image_outlined, size: 15),
          alignment: PlaceholderAlignment.middle,
        ),
        const WidgetSpan(child: SizedBox(width: 4)),
        TextSpan(text: label),
      ],
      style: const TextStyle(
        fontSize: 16,
        fontStyle: FontStyle.italic,
        color: Color(0xFF888888),
      ),
    ),
  );
}

/// 链接点击安全包装:只放行 [_allowedLinkSchemes] 内的 URL。
///
/// 非 http/https(javascript:/file:/intent: 等)静默忽略,不调 launchUrl。
/// 解析失败(非法 URI)同样忽略,避免 url_launcher 抛异常。
void _safeLaunchUrl(String url) {
  final uri = Uri.tryParse(url);
  if (uri == null) return;
  if (!_allowedLinkSchemes.contains(uri.scheme)) return;
  launchUrl(uri, mode: LaunchMode.externalApplication);
}

/// Markdown 任务列表 checkbox builder。
/// checked:绿底白字 ✓,unchecked:灰边框空心,与 TodoBody 工具卡片风格一致。
Widget _markdownCheckBoxBuilder(bool checked) {
  return Padding(
    padding: const EdgeInsets.only(right: 4),
    child: Container(
      width: 16,
      height: 16,
      margin: const EdgeInsets.only(top: 2),
      decoration: BoxDecoration(
        color: checked ? AppColors.accentGreen : Colors.transparent,
        border: Border.all(
          color: checked ? AppColors.accentGreen : const Color(0xFFCCCCCC),
          width: 1.5,
        ),
        borderRadius: BorderRadius.circular(3),
      ),
      alignment: Alignment.center,
      child: checked
          ? const Text('✓',
              style: TextStyle(fontSize: 11, color: Colors.white, height: 1))
          : null,
    ),
  );
}
