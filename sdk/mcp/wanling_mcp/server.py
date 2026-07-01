"""MCP Server 入口 — 注册 8 个 tools，通过 stdio 与 AI 终端通信。

用法:
    python3 -m wanling_mcp

自动从环境变量 WANLING_AGENT_ID / WANLING_SECRET_KEY / WANLING_SERVER 读取凭证，
启动时创建 Bridge（连接 WS），注册全部 tool handler。
"""

from __future__ import annotations

import asyncio
import json
import logging
import os
import sys

from mcp.server import Server
from mcp.server.stdio import stdio_server
from mcp.types import Tool, TextContent

from wanling_mcp.bridge import Bridge
from wanling_mcp import tools as tool_handlers

logger = logging.getLogger("wanling.mcp")
logging.basicConfig(level=logging.INFO, stream=sys.stderr)

# ── Tool 定义 ──

TOOL_DEFS = [
    Tool(
        name="wanling_list_conversations",
        description="列出万灵会话列表（本地缓存，WS 事件累积）",
        inputSchema={
            "type": "object",
            "properties": {},
            "required": [],
        },
    ),
    Tool(
        name="wanling_get_messages",
        description="获取指定用户的消息历史（本地缓存，WS 事件累积）",
        inputSchema={
            "type": "object",
            "properties": {
                "user_id": {"type": "string", "description": "目标用户 ID（不传则用 WANLING_USER_ID 环境变量）"},
                "limit": {"type": "integer", "description": "返回条数，默认 50"},
                "before": {"type": "string", "description": "游标: 只返回此时间之前的消息（RFC3339）"},
            },
            "required": [],
        },
    ),
    Tool(
        name="wanling_send_message",
        description="发文本消息到万灵指定用户",
        inputSchema={
            "type": "object",
            "properties": {
                "user_id": {"type": "string", "description": "目标用户 ID（不传则用 WANLING_USER_ID 环境变量）"},
                "text": {"type": "string", "description": "消息文本"},
            },
            "required": ["text"],
        },
    ),
    Tool(
        name="wanling_upload_file",
        description="上传文件到万灵",
        inputSchema={
            "type": "object",
            "properties": {
                "file_path": {"type": "string", "description": "本地文件路径"},
            },
            "required": ["file_path"],
        },
    ),
    Tool(
        name="wanling_check_new",
        description="检查万灵未读消息（非阻塞，读完即清）",
        inputSchema={
            "type": "object",
            "properties": {
                "user_id": {"type": "string", "description": "目标用户 ID（可选，不传=全部用户）"},
            },
            "required": [],
        },
    ),
    Tool(
        name="wanling_wait_reply",
        description="发消息后阻塞等待用户回复（超时默认 300 秒）",
        inputSchema={
            "type": "object",
            "properties": {
                "user_id": {"type": "string", "description": "目标用户 ID（不传则用 WANLING_USER_ID 环境变量）"},
                "text": {"type": "string", "description": "要发送的问题/消息"},
                "timeout_sec": {"type": "integer", "description": "超时秒数，默认 300"},
            },
            "required": ["text"],
        },
    ),
    Tool(
        name="wanling_ask_confirmation",
        description="发二选一确认到万灵，阻塞等用户回复并解析是/否",
        inputSchema={
            "type": "object",
            "properties": {
                "user_id": {"type": "string", "description": "目标用户 ID（不传则用 WANLING_USER_ID 环境变量）"},
                "question": {"type": "string", "description": "确认问题"},
                "timeout_sec": {"type": "integer", "description": "超时秒数，默认 300"},
            },
            "required": ["question"],
        },
    ),
    Tool(
        name="wanling_report_progress",
        description="向万灵发送进度更新（发完即返回，不等待回复）",
        inputSchema={
            "type": "object",
            "properties": {
                "user_id": {"type": "string", "description": "目标用户 ID（不传则用 WANLING_USER_ID 环境变量）"},
                "text": {"type": "string", "description": "进度描述"},
            },
            "required": ["text"],
        },
    ),
]

TOOLS_BY_NAME = {t.name: t for t in TOOL_DEFS}


# ── Server 工厂 ──

def create_server(bridge: Bridge) -> Server:
    """创建并注册所有 tool handler 的 MCP Server。"""
    server = Server("wanling-mcp")

    @server.list_tools()
    async def list_tools() -> list[Tool]:
        return TOOL_DEFS

    @server.call_tool()
    async def call_tool(name: str, arguments: dict) -> list[TextContent]:
        handler = _HANDLERS.get(name)
        if not handler:
            return [TextContent(type="text", text=f"未知 tool: {name}")]
        try:
            result = await handler(arguments, bridge)
            return [TextContent(type="text", text=result)]
        except Exception as exc:
            logger.exception("tool %s 执行失败", name)
            return [TextContent(type="text", text=json.dumps(
                {"error": str(exc)}, ensure_ascii=False))]

    return server


_HANDLERS = {
    "wanling_list_conversations": tool_handlers.list_conversations,
    "wanling_get_messages": tool_handlers.get_messages,
    "wanling_send_message": tool_handlers.send_message,
    "wanling_upload_file": tool_handlers.upload_file,
    "wanling_check_new": tool_handlers.check_new,
    "wanling_wait_reply": tool_handlers.wait_reply,
    "wanling_ask_confirmation": tool_handlers.ask_confirmation,
    "wanling_report_progress": tool_handlers.report_progress,
}


# ── 入口 ──

async def main() -> None:
    agent_id = os.environ.get("WANLING_AGENT_ID", "")
    secret_key = os.environ.get("WANLING_SECRET_KEY", "")
    base_url = os.environ.get("WANLING_SERVER", "http://localhost:18008")

    if not agent_id or not secret_key:
        logger.error("缺少凭证: 请设置 WANLING_AGENT_ID 和 WANLING_SECRET_KEY 环境变量")
        sys.exit(1)

    bridge = Bridge(agent_id, secret_key, base_url)
    # 后台连接 WS（不阻塞 MCP server 启动），失败自动重连
    _ = asyncio.create_task(bridge.run())

    server = create_server(bridge)

    async with stdio_server() as (read_stream, write_stream):
        logger.info("wanling-mcp 已启动（WS 后台连接中...）")
        await server.run(
            read_stream,
            write_stream,
            server.create_initialization_options(),
        )

    await bridge.stop()


if __name__ == "__main__":
    asyncio.run(main())
