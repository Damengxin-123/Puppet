"""通过标准 MCP 客户端检查新增权重工具，只操作验收目录里的项目副本。"""

import asyncio
import base64
import json
from pathlib import Path
import subprocess
import sys
import uuid

from mcp.client import ClientSession
from mcp.client.stdio import StdioServerParameters, stdio_client

# 本地工程和已准备的隔离角色副本。
PROJECT = Path(__file__).resolve().parents[1]
OUTPUT = PROJECT / "build/verification/weights"
WORKSPACE = OUTPUT / "workspace"


async def run():
    """短暂启动隔离图形实例，验证工具发现、真实读写、撤销和热图截图。"""
    with (OUTPUT / "mcp_godot.log").open("w", encoding="utf-8") as log:
        process = subprocess.Popen(
            [str(PROJECT / "tools/Godot/Godot_v4.7.2-stable_win64_console.exe"),
             "--path", str(PROJECT), "--resolution", "1500x1050", "--max-fps", "60",
             "--quit-after", "1200", "--", f"--workspace={WORKSPACE.as_posix()}"],
            cwd=PROJECT, stdout=log, stderr=subprocess.STDOUT,
            creationflags=subprocess.CREATE_NO_WINDOW)
        instances = WORKSPACE / "_mcp/instances"
        for _ in range(100):
            if list(instances.glob("*.json")):
                break
            await asyncio.sleep(0.1)
        parameters = StdioServerParameters(command=sys.executable,
            args=[str(PROJECT / "mcp_service/server.py"), "--instances-dir", str(instances)], cwd=PROJECT)
        async with stdio_client(parameters) as streams:
            async with ClientSession(*streams) as session:
                await session.initialize()
                discovered = await session.list_tools()
                assert len(discovered.tools) == 44

                async def call(name, values=None):
                    """失败立即抛错，不以空结果冒充成功。"""
                    result = await session.call_tool(name, values or {})
                    assert not result.is_error and result.structured_content["ok"], result
                    return result.structured_content, result

                capabilities, _ = await call("get_capabilities")
                assert capabilities["binding_features"]["editable_weights"]
                document, _ = await call("get_document")
                target = {"project_id": document["binding_project_id"]}
                before, _ = await call("get_binding_project", target)
                await call("get_rig", {"rig_id": before["project"]["rig_id"]})
                weights, _ = await call("get_binding_weights", {**target, "vertex_ids": ["0:0:2146"], "limit": 1})
                view, _ = await call("set_binding_weight_view", {**target, "bone_id": "forearm_r", "seed_vertex_id": "0:0:2146", "radius_m": 0.03, "editing": True})
                assert view["selected_vertex_count"] > 0
                document, _ = await call("get_document")
                edited, _ = await call("edit_binding_weights", {**target, "document_id": document["document_id"], "expected_revision": document["revision"], "request_id": uuid.uuid4().hex, "vertex_ids": ["0:0:2146"], "operation": "set", "bone_id": "pelvis", "value": 0.5, "fallback_bone_id": "spine_lower"})
                result, _ = await call("get_binding_weights", {**target, "vertex_ids": ["0:0:2146"], "limit": 1})
                assert abs(result["vertices"][0]["weights"]["pelvis"] - 0.5) < 1e-6
                document, _ = await call("get_document")
                await call("undo_binding_edit", {**target, "document_id": document["document_id"], "expected_revision": document["revision"], "request_id": uuid.uuid4().hex})
                after, _ = await call("get_binding_project", target)
                assert before["project"]["joints"] == after["project"]["joints"]
                metadata, image = await call("render_binding_preview", {**target, "weight_bone_id": "forearm_r", "width": 700, "height": 800, "view": {"yaw_deg": 90.0, "frame_all": True}})
                assert metadata["weight_bone_id"] == "forearm_r"
                png = next(item for item in image.content if item.type == "image")
                (OUTPUT / "MCP权重热图.png").write_bytes(base64.b64decode(png.data))
                report = {"passed": True, "tools": len(discovered.tools), "api_version": capabilities["api_version"], "weight_query_edit_undo": True, "heatmap_png": True, "joints_unchanged": True}
                (OUTPUT / "MCP检查结果.json").write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding="utf-8")
                print(json.dumps(report, ensure_ascii=False))
        await asyncio.to_thread(process.wait, 30)


if __name__ == "__main__":
    asyncio.run(run())
