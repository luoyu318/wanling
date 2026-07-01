"""万灵 Agent SDK — agent 端 Python 客户端。

用法:
    from wanling import WanlingAgentClient

    client = WanlingAgentClient("ag_xxx", "sk_xxx", "http://localhost:18008")
    await client.connect()

    conv = await client.find_or_create_conv("u_xxx")
    msg_id, _ = await client.send_message(conv["id"], "hello")
"""

from wanling.client import WanlingAgentClient

__all__ = ["WanlingAgentClient"]
