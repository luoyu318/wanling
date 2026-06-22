# 万灵 · 万灵之印 Logo

万灵（Wanling）品牌标识，以「万灵之印」为核心图形。

## 设计语义

八角星轮法阵 + 中央四芒灵光 + 外环虚线流转。

- **八角星轮** — 平台是召唤万千 Agent 的中枢印记，八方之灵汇聚于此
- **中央四芒灵光** — 一声召唤即亮，"即应"的视觉回响
- **外环虚线** — 实时消息流，对应 WebSocket 的 Hello→Identify→Dispatch

## 文件清单

| 文件 | 用途 |
|------|------|
| `icon.svg` | **主图标矢量源**（深底紫版，1024 源） |
| `icon-1024.png` | App Store / Play 主图标（1024×1024） |
| `icon-{512,256,192,180,152,128,120,87,76,60}.png` | 各端所需尺寸（iOS/Android/桌面） |
| `icon-animated.svg` | **动态版**（星轮旋转 + 灵光呼吸），用于网页/启动 loading。App 图标取静帧 |
| `icon-light.svg` | 浅底反色版（米白底 + 朱砂），用于文档/浅色场景 |
| `wordmark.svg` | 横向 Wordmark（万灵 WANLING · 唤灵即应） |
| `badge-mono.svg` | **单色徽章**（用 `currentColor`，可被任意 CSS color 着色） |
| `favicon.ico` | 网站图标（含 16/32/48 三尺寸） |
| `favicon-{16,32,48}.png` | favicon 单尺寸 PNG |
| `gen.js` | 图像生成脚本（需 `sharp`，可重跑） |

## 配色

### 深底紫版（默认 / App 图标）
- 背景：`#160726` → `#2a0f44` → `#1a0830`（紫罗兰渐变）
- 星轮/外环：`#c9a3ff`（紫）
- 中央四芒/圆框：`#e6c98f`（鎏金）
- 灵光：`#f4d47c` → `#fff4d6`

### 浅底版
- 背景：`#f5ecda`（米白）
- 主体：`#b8412e` / `#7a1a0e`（朱砂）

## 使用

```html
<!-- favicon -->
<link rel="icon" href="/favicon.ico">
<link rel="apple-touch-icon" href="/icon-180.png">

<!-- 动态 loading -->
<img src="/icon-animated.svg" alt="万灵">

<!-- 单色徽章（CSS 着色） -->
<img src="/badge-mono.svg" style="color:#c9a3ff">
```

## 重新生成

```bash
npm install sharp --no-save
node gen.js
```
