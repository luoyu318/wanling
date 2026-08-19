# 万灵 RPC method schema 字典

plugin 端各 RPC method 的 params/result/error schema。从 [rpc-protocol.md](./rpc-protocol.md) §5.6-5.9 拆出,避免协议主文件超 200 行。本文件被 server/CLAUDE.md 与 plugin/CLAUDE.md 通过 @import 引用。

## project.list

列 OC 已知的项目清单(供 APP 用户选工作目录)。

**params**: `{}`(空)

**result**: `{projects: [{path: string, name: string}]}`

**timeout_hint_ms**: 5000(本地查询)

**错误**:
- OC 未就绪:`{code: -32603, message: "opencode client not ready"}`
- OC SDK 调用失败:`{code: -32603, message: <原始错误>}`

**字段**:
- `path`:项目绝对路径
- `name`:项目名(OC 提供或 path 末段降级)

**触发场景**:APP 用户点「新建会话」时拉,展示在 DirectoryPickerSheet。

## session.diff

返回 opencode session 累计的代码变更(plugin 直接调本地 git 算 diff,Phase 4B 起绕开 OC SDK 端点 bug)。

**diff 基准**:`git diff HEAD` + untracked 文件(整文件当 patch)。

**params**: `{wanling_conv_id: string}` — 万灵会话 ID(plugin 内部映射到 opencode sessionID + directory)

**result**: `{files: [{file, patch, additions, deletions, status}]}`

字段:
- `file`:文件路径(相对仓库根)
- `patch`:unified diff 字符串(`@@ -X,Y +A,B @@` + 行级 +/-);untracked 文件每行加 `+` 前缀
- `additions`/`deletions`:增删行数
- `status`:`added` / `modified` / `deleted`(rename/copy 映射 `modified`)

**timeout_hint_ms**: 10000(git diff 大仓库可能慢)

**错误**:
- session 未建(conv_id 在 mapper 找不到):`{code: -32601, message: "session not created"}`
- params 缺 wanling_conv_id:`{code: -32602, message: "invalid params: wanling_conv_id required"}`
- directory 未锚定(SessionMap.directory 空):`{code: -32603, message: "directory not anchored"}`
- git 命令失败(非 git 仓库 / git 异常):`{code: -32604, message: "git error: ..."}`

**directory 自动锚定**:plugin 从 SessionMap.directory 取(Phase 3 ensureSession 时存,Phase 4A Fix #2 回填老数据),APP 无需传。

**binary 文件**:numstat 行是 `-\t-\t<path>` 时跳过(不进 files 数组)。

**二进制/超大文件防护**(2026-08-19):
- untracked 二进制(前 8000 字节含 NUL):`binary: true`,patch 为空串,additions/deletions 为 0
- 单文件 patch 超 256KB:截断至 256KB 内(按行边界),`truncated: true`,末行 `…(已截断,共 N 行)`
- 两个字段均为可选,旧 APP 忽略无影响

**触发场景**:APP 会话页点「+ 变更」入口,展示本次 session 改了哪些文件。

## file.list

列 plugin session.directory 下当前层的子项(目录 + 文件,git tracked ∪ 未忽略 untracked)。

**params**: `{wanling_conv_id: string, path?: string}`(`path` 相对 session.directory,默认 `.`,越界返 -32602)

**result**:
```jsonc
{"root":"/abs/path/to/session.directory","path":".","entries":[{"name":"src","type":"dir","size":0},{"name":"README.md","type":"file","size":1024},{"name":"logo.png","type":"file","size":2048,"binary":true}],"truncated":false}
```

- `entries`: 直接子项(不递归),目录优先 + 字母序;`type` `dir`/`file`,`size` 字节(目录恒 0)
- `binary`: true 表示非图片二进制(APP 显示「不支持预览」);文本/图片不带
- `truncated`: 单层 entries > 500 截断为 true

**timeout_hint_ms**: 5000
**错误**: session 未建 -32601 / directory 未锚定 -32603 / path 越界 -32602 / git 失败 -32604
**触发场景**:APP 会话页 PlusPanel「浏览」入口,逐层进入目录。

## file.read

读 session.directory 下的单个文件,按 mime 分流。

**params**: `{wanling_conv_id: string, path: string, max_bytes?: number}`(`max_bytes` 默认 256KB,plugin 硬钳 512KB)

**result(text)**:
```jsonc
{"path":"src/main.ts","type":"text","mime":"text/x-typescript","size":1024,"content":"...","truncated":false}
```

**result(image)**:
```jsonc
{"path":"logo.png","type":"image","mime":"image/png","size":2048,"content_base64":"iVBOR...","truncated":false}
```
- 支持 jpg/png/gif/webp;> 384KB 拒绝(-32605,base64 膨胀会撑爆 server WS 帧限制)

**result(其他二进制)**:
```jsonc
{"path":"archive.zip","type":"binary","mime":"application/octet-stream","size":9999}
```
- 不读内容,APP 显示「不支持预览」

**timeout_hint_ms**: 5000
**错误**: session/directory 同 file.list / path 越界 -32602 `path escapes session.directory` / 读失败(不存在/权限/IO/图片过大)-32605 `read failed: ...`
**触发场景**:APP 文件浏览页点文件条目。
