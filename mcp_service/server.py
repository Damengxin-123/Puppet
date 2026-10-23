"""木偶人的标准 MCP stdio 服务；日志仅写 stderr，实际命令在 Godot 主线程执行。"""

from __future__ import annotations

import argparse
import asyncio
import json
import sys
from pathlib import Path

import mcp.types as types
from jsonschema import Draft202012Validator
from mcp.server import Server
from mcp.server.stdio import stdio_server

from tool_catalog import build_tools

# 网络协议的请求和响应上限与 Godot 保持一致。
MAX_BYTES = 16 * 1024 * 1024


class BridgeError(Exception):
    """携带可纠正错误码的本机通道错误。"""

    def __init__(self, code: str, message: str):
        """保留错误码，调用方可以据此重读文档或选择实例。"""
        super().__init__(message)
        # 稳定错误码。
        self.code = code


class LocalBridge:
    """发现并连接同一项目下的运行实例，不自动启动或退出用户的软件。"""

    def __init__(self, directory: Path, instance_file: Path | None):
        """保存发现目录和可选的明确实例文件。"""
        # 默认从当前项目发现实例。
        self.directory = directory
        # 指定文件时不跨实例自动重选。
        self.instance_file = instance_file
        # 选中实例的稳定进程标识。
        self.selected_id: str | None = None

    def descriptors(self) -> list[dict]:
        """读取描述文件，只允许 IPv4 本机回环地址。"""
        files = [self.instance_file] if self.instance_file else sorted(self.directory.glob("*.json"))
        result = []
        for path in files:
            try:
                if path.stat().st_size > 32768:
                    continue
                value = json.loads(path.read_text(encoding="utf-8-sig"))
                if not isinstance(value, dict) or not all(isinstance(value.get(key), str) and value[key] for key in ("instance_id", "document_id")):
                    continue
                if value.get("host") != "127.0.0.1" or not isinstance(value.get("port"), int) or not 1 <= value["port"] <= 65535 or len(value.get("token", "")) != 64:
                    continue
                result.append(value)
            except (OSError, ValueError, TypeError):
                continue
        return result

    async def exchange(self, descriptor: dict, method: str, params: dict, timeout: float = 60) -> dict:
        """每个命令建立短连接，禁止透明重试写入以外的实例切换。"""
        request = json.dumps({"token": descriptor["token"], "method": method, "params": params}, ensure_ascii=False, allow_nan=False).encode("utf-8") + b"\n"
        if len(request) > MAX_BYTES:
            raise BridgeError("REQUEST_TOO_LARGE", "请求超过 16 MiB，请减少批量内容。")
        writer = None
        try:
            async with asyncio.timeout(timeout):
                reader, writer = await asyncio.open_connection("127.0.0.1", descriptor["port"], limit=MAX_BYTES + 1)
                writer.write(request)
                await writer.drain()
                raw = await reader.readline()
                if not raw or len(raw) > MAX_BYTES:
                    raise BridgeError("INVALID_RESPONSE", "本机实例没有返回有效响应。")
                result = json.loads(raw)
                if not isinstance(result, dict):
                    raise BridgeError("INVALID_RESPONSE", "实例响应必须为对象。")
                if result.get("instance_id", descriptor["instance_id"]) != descriptor["instance_id"]:
                    raise BridgeError("INSTANCE_CHANGED", "实例已改变，请重新选择。")
                return result
        except TimeoutError as error:
            raise BridgeError("TIMEOUT", "操作超时；写入请用原 request_id 查询或重试，避免重复创建。") from error
        except (OSError, ValueError) as error:
            raise BridgeError("CONNECTION_FAILED", "无法连接木偶人，请确认软件已运行并启用 MCP。") from error
        finally:
            if writer:
                writer.close()
                try:
                    await writer.wait_closed()
                except OSError:
                    pass

    async def live_instances(self) -> list[dict]:
        """忽略已关闭程序留下的过期文件，不删除其他进程的数据。"""
        async def check(descriptor):
            """用实例令牌校验端口确实属于该软件实例。"""
            try:
                result = await self.exchange(descriptor, "ping", {}, timeout=1.5)
                return descriptor if result.get("ok") else None
            except BridgeError:
                return None
        return [item for item in await asyncio.gather(*(check(item) for item in self.descriptors())) if item]

    async def call(self, method: str, params: dict) -> dict:
        """单实例自动连接，多实例要求明确选择；不向客户端泄露令牌。"""
        instances = await self.live_instances()
        if method == "list_instances":
            return {"ok": True, "selected_instance_id": self.selected_id, "instances": [{key: item.get(key) for key in ("instance_id", "document_id", "pid", "project_path")} for item in instances]}
        if method == "select_instance":
            self.selected_id = params["instance_id"]
        if not instances:
            raise BridgeError("NO_RUNNING_INSTANCE", "没有可连接的木偶人实例，请启动软件并在设置中启用 MCP。")
        if self.selected_id:
            selected = next((item for item in instances if item["instance_id"] == self.selected_id), None)
            if not selected:
                raise BridgeError("INSTANCE_NOT_FOUND", "选中实例已关闭，请重新列出并选择。")
        elif len(instances) == 1:
            selected = instances[0]
            self.selected_id = selected["instance_id"]
        else:
            raise BridgeError("MULTIPLE_INSTANCES", "检测到多个运行实例，请先调用 list_instances 和 select_instance。")
        return await self.exchange(selected, "get_document" if method == "select_instance" else method, params if method != "select_instance" else {})


async def serve(arguments):
    """注册工具、只读资源与标准协议握手，在 stdio 上运行官方 SDK。"""
    bridge = LocalBridge(arguments.instances_dir, arguments.instance_file)
    tools = build_tools()
    schemas = {tool.name: tool.input_schema for tool in tools}
    validators = {name: Draft202012Validator(schema) for name, schema in schemas.items()}

    async def list_tools(_context, _params):
        """返回实际实现的工具及参数，不依赖软件是否已经启动。"""
        return types.ListToolsResult(tools=tools)

    async def call_tool(_context, params):
        """提供结构化数据和原生 MCP 图片内容，错误以 isError 标记。"""
        try:
            if params.name not in schemas:
                raise BridgeError("UNKNOWN_TOOL", "未知工具。")
            values = params.arguments or {}
            errors = list(validators[params.name].iter_errors(values))
            if errors:
                raise BridgeError("INVALID_ARGUMENTS", errors[0].message)
            result = await bridge.call(params.name, values)
        except BridgeError as error:
            result = {"ok": False, "error": {"code": error.code, "message": str(error)}}
        images = result.get("images", [])
        content = []
        if images:
            metadata = []
            for index, item in enumerate(images):
                metadata.append({key: value for key, value in item.items() if key not in {"data", "mimeType"}} | {"content_index": index + 1, "mime_type": item["mimeType"]})
                content.append(types.ImageContent(data=item["data"], mime_type=item["mimeType"]))
            result = {**result, "images": metadata}
        return types.CallToolResult(content=[types.TextContent(text=json.dumps(result, ensure_ascii=False, allow_nan=False)), *content], structured_content=result, is_error=not result.get("ok", False))

    async def list_resources(_context, _params):
        """文档资源用于快速读取当前软件状态。"""
        return types.ListResourcesResult(resources=[types.Resource(uri="puppet://document", name="木偶人当前文档", mime_type="application/json")])

    async def read_resource(_context, params):
        """读取资源与工具共用同一数据源。"""
        if str(params.uri) != "puppet://document":
            raise ValueError("资源不存在。")
        try:
            result = await bridge.call("get_document", {})
        except BridgeError as error:
            result = {"ok": False, "error": {"code": error.code, "message": str(error)}}
        return types.ReadResourceResult(contents=[types.TextResourceContents(uri="puppet://document", mime_type="application/json", text=json.dumps(result, ensure_ascii=False))])

    server = Server("puppet", version="1.2.0", title="木偶人动画编辑器", instructions="先读 get_capabilities、get_document 与 get_rig，使用稳定骨架和关节 ID。写入前提供最新 document_id、expected_revision 及唯一 request_id。批量编辑后用 evaluate_pose、get_keyframes 和 render_preview 回读真实结果。不要假定 IK 一定精确到达目标。角色绑定先读 list_binding_projects/get_binding_project，使用 project_id 定位；关节位置和骨长只改项目骨架。绑定预览只读动画，截图用 render_binding_preview，结束用 stop_binding_preview 恢复原模型。权重先用 get_binding_weights 读取稳定 vertex_id（网格:表面:顶点），用 set_binding_weight_view 查看选区和热图。edit_binding_weights 支持沿表面选区、权重调整、平滑与清除手臂影响；写后回读权重及截图。recalculate_binding_weights 保留全部关节与手工覆盖。",
                    get_tool_input_schema=schemas.get, on_list_tools=list_tools, on_call_tool=call_tool,
                    on_list_resources=list_resources, on_read_resource=read_resource)
    async with stdio_server() as streams:
        await server.run(*streams, server.create_initialization_options())


def main():
    """默认使用项目工作区，隔离验收可显式指定实例目录。"""
    parser = argparse.ArgumentParser(description="木偶人 MCP stdio 服务")
    parser.add_argument("--instances-dir", type=Path, default=Path(__file__).resolve().parents[1] / "workspace/mcp/instances")
    parser.add_argument("--instance-file", type=Path)
    arguments = parser.parse_args()
    asyncio.run(serve(arguments))


if __name__ == "__main__":
    main()
