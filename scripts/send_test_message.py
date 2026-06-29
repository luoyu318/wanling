#!/usr/bin/env python3
"""
万灵消息测试工具：以 agent 身份给指定 user 发消息（用于测试 APP 消息功能）。

流程：
1. agent_id + secret_key 换 JWT (POST /api/agents/:id/token)
2. 连 WebSocket,完成 Hello → Identify 握手
3. 发送 MESSAGE_CREATE 消息到指定 user_id

依赖：websockets 库（pip install websockets）

用法：
  # 单条消息
  python3 send_test_message.py \\
      --agent-id ag_xxx \\
      --secret-key sk_xxx \\
      --user-id u_xxx \\
      --text "测试消息"

  # 连发 5 条(测试 ⬇️ N 条新消息场景);{} 占位符替换为序号
  python3 send_test_message.py \\
      --agent-id ag_xxx --secret-key sk_xxx --user-id u_xxx \\
      --text "消息 #{}" --count 5 --interval 1.0

  # 自定义 server(默认 http://localhost:18008)
  python3 send_test_message.py --server http://192.168.1.100:18008 \\
      --agent-id ... --secret-key ... --user-id ... --text "hi"
"""

import argparse
import asyncio
import json
import os
import sys
import urllib.request
from urllib.error import HTTPError, URLError

try:
    import websockets
    from websockets.exceptions import WebSocketException
except ImportError:
    print("缺少 websockets 库,请运行: pip install websockets", file=sys.stderr)
    sys.exit(2)


# WebSocket Opcode(对齐 server internal/model/opcodes.go)
OP_DISPATCH = 0
OP_HEARTBEAT = 1
OP_IDENTIFY = 2
OP_HELLO = 10

EVENT_MESSAGE_CREATE = "MESSAGE_CREATE"


def fetch_token(server: str, agent_id: str, secret_key: str) -> str:
    """agent_id + secret_key 换 JWT。失败抛 RuntimeError。"""
    url = f"{server.rstrip('/')}/api/agents/{agent_id}/token"
    body = json.dumps({"agent_id": agent_id, "secret_key": secret_key}).encode()
    req = urllib.request.Request(
        url,
        data=body,
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=10) as resp:
            data = json.loads(resp.read().decode())
            token = data.get("token")
            if not token:
                raise RuntimeError(f"换 token 响应缺字段: {data}")
            return token
    except HTTPError as e:
        body_text = ""
        try:
            body_text = e.read().decode()
        except Exception:
            pass
        raise RuntimeError(
            f"换 token 失败: HTTP {e.code} {e.reason} {body_text}"
        )
    except URLError as e:
        raise RuntimeError(f"连接服务器失败: {e}")


async def send_message(ws, user_id: str, text: str) -> None:
    """发一条 MESSAGE_CREATE。"""
    payload = {
        "op": OP_DISPATCH,
        "t": EVENT_MESSAGE_CREATE,
        "d": {
            "user_id": user_id,
            "content": {"msg_type": "text", "data": {"text": text}},
        },
    }
    await ws.send(json.dumps(payload))


async def heartbeat_loop(ws, interval_ms: int) -> None:
    """后台心跳,断开时静默退出。"""
    while True:
        await asyncio.sleep(interval_ms / 1000)
        try:
            await ws.send(json.dumps({"op": OP_HEARTBEAT}))
        except Exception:
            return


async def run(args: argparse.Namespace) -> None:
    token = fetch_token(args.server, args.agent_id, args.secret_key)
    print("✓ 已换取 agent token")

    ws_url = (
        args.server.replace("http://", "ws://").replace("https://", "wss://")
        .rstrip("/") + "/ws"
    )
    async with websockets.connect(ws_url) as ws:
        # 等 Hello
        raw = await asyncio.wait_for(ws.recv(), timeout=5)
        hello = json.loads(raw)
        if hello.get("op") != OP_HELLO:
            print(f"期望 Hello (op=10),实际: {hello}", file=sys.stderr)
            sys.exit(1)
        heartbeat_interval = hello.get("d", {}).get("heartbeat_interval", 30000)
        print(f"✓ Hello,心跳间隔 {heartbeat_interval} ms")

        # 发 Identify
        await ws.send(json.dumps({"op": OP_IDENTIFY, "d": {"token": token}}))
        print("✓ 已发送 Identify")

        # 后台心跳
        hb_task = asyncio.create_task(heartbeat_loop(ws, heartbeat_interval))

        # 给 server 一点时间完成 hub.Register(异步注册 client)
        # 不等的话 agent 立即发 MESSAGE_CREATE 也行(readPump 已就绪),
        # 但留 100ms 缓冲避免极端时序。
        await asyncio.sleep(0.1)

        try:
            for i in range(1, args.count + 1):
                text = (
                    args.text.replace("{}", str(i))
                    if "{}" in args.text
                    else args.text
                )
                await send_message(ws, args.user_id, text)
                print(f"✓ [{i}/{args.count}] 已发送: {text}")
                if i < args.count:
                    await asyncio.sleep(args.interval)
        finally:
            hb_task.cancel()

    print("✓ 完成")


def main() -> None:
    parser = argparse.ArgumentParser(
        description="万灵消息测试工具:以 agent 身份发消息"
    )
    parser.add_argument(
        "--server",
        default=os.environ.get("WANLING_SERVER", "http://localhost:18008"),
        help="server URL,默认 http://localhost:18008,或环境变量 WANLING_SERVER",
    )
    parser.add_argument(
        "--agent-id",
        default=os.environ.get("WANLING_AGENT_ID"),
        help="agent ID,或环境变量 WANLING_AGENT_ID",
    )
    parser.add_argument(
        "--secret-key",
        default=os.environ.get("WANLING_SECRET_KEY"),
        help="agent secret key,或环境变量 WANLING_SECRET_KEY",
    )
    parser.add_argument(
        "--user-id",
        default=os.environ.get("WANLING_USER_ID"),
        help="目标 user ID,或环境变量 WANLING_USER_ID",
    )
    parser.add_argument(
        "--text",
        required=True,
        help="消息文本(可用 {} 作序号占位符,配合 --count)",
    )
    parser.add_argument(
        "--count", type=int, default=1, help="发送条数,默认 1"
    )
    parser.add_argument(
        "--interval",
        type=float,
        default=1.0,
        help="多条发送间隔秒数,默认 1.0",
    )
    args = parser.parse_args()

    # 校验:agent_id / secret_key / user_id 必填(命令行或环境变量任一来源)
    missing = [
        name
        for name, val in [
            ("--agent-id", args.agent_id),
            ("--secret-key", args.secret_key),
            ("--user-id", args.user_id),
        ]
        if not val
    ]
    if missing:
        parser.error(
            f"{' / '.join(missing)} 必填(命令行参数或 "
            "WANLING_AGENT_ID / WANLING_SECRET_KEY / WANLING_USER_ID 环境变量)"
        )

    try:
        asyncio.run(run(args))
    except KeyboardInterrupt:
        print("\n中断", file=sys.stderr)
        sys.exit(130)
    except RuntimeError as e:
        print(str(e), file=sys.stderr)
        sys.exit(1)
    except WebSocketException as e:
        print(f"WebSocket 错误: {e}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
