# 万灵 v1.0.4 发布说明

> **版本号**：`1.0.4+6`  
> **应用 ID**：`com.wanling.app`  
> **应用名**：万灵  
> **平台**：Android  
> **构建产物**：`app-release.apk`（92.4 MB）  
> **发布日期**：2026-06-23  
> **构建校验**：Gradle assembleRelease 138.8s，构建后无残留进程，内存稳定

---

## 一、本次更新概览

本次为 UI 体验优化与稳定性修复版本，重点解决三件事：

1. **修复部分 Emoji 显示为黑白的渲染缺陷**（♻️ ⚠️ ✂️ 等默认文本形态字符）
2. **聊天阅读区字号统一、间距优化**
3. **修复构建机内存被 Gradle 进程吃满导致死机的工程问题**

---

## 二、新功能与改进

### 1. Emoji 彩色渲染修复 ✅

**问题现象**：在消息气泡、输入框、会话列表摘要中，部分 Emoji（如 ♻️ ⚠️ ✂️）显示为单色（黑/灰），而其他 Emoji（✈️ ☀️）正常显示彩色；但同一字符在系统通知横幅中是彩色的。

**根因**：Android 系统 Roboto 字体包含这些 Unicode「默认文本形态」字符（Emoji_Presentation 属性为 text）的单色字形，渲染时被主字体优先命中；而系统 Emoji 字体无 family 名，Flutter 无法通过 `fontFamily` 直接引用。

**解决方案**（三层）：
- 捆绑 **Noto Color Emoji 字体子集**（CBDT/CBLC 格式，仅含 110 个目标字符 + FE0F，**体积仅 158 KB**，从 11 MB 完整字体裁剪）
- **精确 Span 分割**：仅对含 Emoji 字符的文本片段应用 Emoji 字体，避免污染普通文本的字宽度量
- 覆盖范围：纯文本消息、Markdown 无语法降级、消息列表预览、输入框实时输入

> 覆盖了 Unicode 16.0 emoji-data.txt 中所有「默认文本形态」字符（共 110 个），不仅限于最初发现的 ♻️⚠️✂️。

### 2. 聊天阅读区字号与间距优化

| 项目 | 调整前 | 调整后 |
|------|--------|--------|
| 消息正文字号 | 18px | **17px** |
| 输入框字号 | 18px | **17px** |
| 「正在输入…」气泡 | 18px | **17px** |
| 消息气泡上下间距 | 4px | **8px** |

字号与字重（w300 细体）在消息气泡、输入框、打字指示器间保持统一；气泡间距加大后阅读更通透。

### 3. 在线状态颜色区分

聊天页顶部 AppBar 昵称下方的在线状态指示：
- **在线 / 正在输入** → 绿色（`#07C160`，品牌主色）
- **离线** → 灰色（`#999999`）

并修复了状态文字与昵称错位（前置空白）的问题。

---

## 三、工程稳定性修复

### Gradle 内存配置导致构建死机

**问题现象**：每次构建 APK 后存在残留进程，内存占用持续攀升，开发机多次 OOM 死机。

**根因**：原 `gradle.properties` 配置 `-Xmx8G` + `MaxMetaspaceSize=4G`（面向 32GB+ 工作站），在 16GB 开发机上与模型服务、IDE、ZCode 等常驻进程争抢内存；叠加 Gradle Daemon 模式构建后不退出，强杀构建命令时残留进程继续吃内存。

**修复**：
- `-Xmx8G` → `-Xmx3G`（构建峰值实测 ~2.5G，留安全余量）
- `MaxMetaspaceSize` 4G → 1G
- `ReservedCodeCacheSize` 512m → 384m
- **新增 `org.gradle.daemon=false`**：构建结束 JVM 立即退出，**杜绝残留进程**

---

## 四、安装说明

### 最低系统要求
- Android 5.0（API 21）及以上

### 安装步骤
1. 将 `app-release.apk` 传输至手机（USB / 网盘 / 蓝牙均可）
2. 手机端点击 APK 文件
3. 首次安装若提示「未知来源应用」，按系统引导允许「从该来源安装」
4. 完成安装后打开「万灵」

### 覆盖安装（升级）
- 直接覆盖安装即可，**用户数据与登录态保留**
- 本次为纯 UI / 工程修复，无数据库迁移

---

## 五、已知限制与说明

1. **iOS 暂不支持**：本次仅构建 Android APK
2. **Emoji 子集范围**：内置字体仅含 110 个「默认文本形态」字符。如后续发现仍有单色 Emoji，需扩展子集重新裁剪字体（见 `scripts/subset-emoji.sh`）
3. **字号调节为固定值**：当前字号为应用内固定 17px，暂未提供用户自定义字号功能

---

## 六、变更文件清单

| 文件 | 类型 | 说明 |
|------|------|------|
| `lib/utils/emoji_span.dart` | 新增 | Emoji Span 分割核心逻辑 |
| `lib/utils/emoji_editing_controller.dart` | 新增 | 输入框实时 Emoji 渲染控制器 |
| `fonts/NotoColorEmoji.ttf` | 新增 | Emoji 字体子集（158 KB） |
| `scripts/subset-emoji.sh` | 新增 | 字体子集化维护脚本 |
| `lib/rendering/builtin_renderers.dart` | 修改 | 接入 Emoji 彩色渲染 + 字号 |
| `lib/widgets/markdown_config.dart` | 修改 | Markdown 正文字号 |
| `lib/widgets/message_bubble.dart` | 修改 | 气泡间距 |
| `lib/widgets/message_input_bar.dart` | 修改 | 输入框字号 + Emoji 控制器 |
| `lib/widgets/typing_bubble.dart` | 修改 | 打字气泡字号 + 间距 |
| `lib/pages/chat_page.dart` | 修改 | 在线状态颜色 |
| `lib/pages/messages_page.dart` | 修改 | 会话列表预览 Emoji 渲染 |
| `android/gradle.properties` | 修改 | Gradle 内存配置修复 |
| `pubspec.yaml` | 修改 | 注册 Emoji 字体声明 |

---

## 七、提交记录

```
（v1.0.4 本次发布）
a165c05 chore: 升版本号 1.0.4+6 + 发布说明
33b83a3 合并: 字号调优 17px + gradle 内存配置修复
1e2a7d2 修复: gradle 内存配置导致构建残留进程吃满内存死机
52f48bb 调整: 聊天正文字号统一为 17px, 气泡上下间距加大

（v1.0.3 前序版本，已发布）
7e2d7da Merge branch 'fix/emoji-color-fallback'
cd08476 fix: 修复 Android 上部分 emoji 渲染成单色 + 输入框支持 + 在线状态颜色区分
```

> 版本递进：v1.0.3（Emoji 彩色修复 + 在线状态颜色）→ **v1.0.4（字号调优 17px + 气泡间距 + gradle 内存修复）**

---

## 八、致谢与反馈

如发现 Bug 或有功能建议，请通过以下方式反馈：
- 提交 Issue 至代码仓库
- 附带：设备型号、Android 版本、复现步骤、截图

---

*万灵 · 唤灵即应*
