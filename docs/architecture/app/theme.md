# APP Theme

设计 token 集合(colors / menu / palette)。

## app_colors

应用色板集中地。把散落各页面的色值（背景 `#EDEDED`/次要文字 `#999999`/品牌绿 `#07C160` 等）收拢到一处，避免硬编码漂移

## OpenCode 模式色(v1.0.9)

agent_session 输入栏的左侧 4px 竖线 + 加号/发送按钮颜色按 OpenCode 模式切换(在 `chat_page.dart` 内联定义,未进 app_colors 集中地):

- **Build 蓝** `#597BFF`(对应 SDK agent="build",默认态)
- **Plan 橙** `#F4A742`(对应 SDK agent="plan")
- variant 橙 `#F4A742`(暂复用 Plan 橙,未来 variant 列表接入后细分)

切换入口:点击 SessionMeta 副标题条触发 `chatProvider.toggleMode()`(Build↔Plan 二态切换),发送消息时 mode 随 content.data._mode 透传给 plugin engine → SDK prompt(agent=...)。`modeOverride` 本地状态优先于 `sessionMeta.mode` 让 UI 立即响应,2s 防抖拉服务端权威值,冲突时清 override

## app_menu_style

深色菜单统一色板 token（`#262626` 0.91 背景 + 圆角 12）。`MessageContextMenu`（消息级浮动菜单）和 `AppTextSelectionToolbar`（文字级系统选区菜单）共用，保证两套深色菜单视觉一致

## account_palette

账号标记固定调色板（8 色）。`AccountMark.colorIndex` 索引此数组，存索引而非 Color 值（序列化稳定 + 便于换肤）
