"""最小 wanling agent 插件:连接 → 收到消息回 markdown → 注册 echo RPC。"""

import asyncio
import os
import sys

from wanling_sdk import WanlingClient

SERVER_URL = os.environ.get("WANLING_SERVER_URL", "http://localhost:18008")
AGENT_ID = os.environ.get("WANLING_AGENT_ID", "")
SECRET_KEY = os.environ.get("WANLING_SECRET_KEY", "")


def _log_task_exc(task: asyncio.Task) -> None:
    if task.cancelled():
        return
    exc = task.exception()
    if exc:
        print(f"[template] message handler error: {exc}", file=sys.stderr)


async def on_message(client: WanlingClient, msg: dict) -> None:
    print(f"[template] message {msg['conversation_id']}: {msg['content']}")
    await client.send_typed(msg["conversation_id"], "markdown", {"text": "你好,我是模板 agent"})


async def main() -> None:
    client = WanlingClient(SERVER_URL, AGENT_ID, SECRET_KEY)
    client.on("connected", lambda: print("[template] connected"))

    def _handle_message(msg: dict) -> None:
        t = asyncio.ensure_future(on_message(client, msg))
        t.add_done_callback(_log_task_exc)

    client.on("message", _handle_message)
    client.register_method("echo", lambda params: {"echoed": params})
    await client.start()
    try:
        await asyncio.Future()  # 永远挂起,靠任务循环重连
    finally:
        await client.stop()


if __name__ == "__main__":
    asyncio.run(main())
