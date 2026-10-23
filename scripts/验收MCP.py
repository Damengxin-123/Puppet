"""一次标准 MCP 客户端端到端验收，所有动作与新骨架均保存在隔离目录。"""

import asyncio
import base64
import copy
import json
import math
from pathlib import Path
import subprocess
import sys
import time
import uuid

from mcp.client import ClientSession
from mcp.client.stdio import StdioServerParameters, stdio_client

# 项目根目录。
PROJECT = Path(__file__).resolve().parents[1]
# 本次隔离目录，既有用户动画不会被读取或修改。
OUTPUT = PROJECT / "build/verification/mcp" / time.strftime("%Y%m%d_%H%M%S")
# 已完成的简单验收项目。
CHECKS = []


def check(condition, message):
    """失败立即报告，避免在错误状态下继续操作。"""
    assert condition, message
    CHECKS.append(message)


async def workflow():
    """启动隔离软件并通过官方 SDK 的 stdio 客户端完成一段动画。"""
    OUTPUT.mkdir(parents=True, exist_ok=True)
    directory = OUTPUT / "animations"
    directory.mkdir()
    log_path = OUTPUT / "godot.log"
    with log_path.open("w", encoding="utf-8") as log:
        process = subprocess.Popen([str(PROJECT / "tools/Godot/Godot_v4.7.2-stable_win64_console.exe"), "--path", str(PROJECT), "--resolution", "1440x900", "--", f"--workspace={directory.as_posix()}"], cwd=PROJECT, stdout=log, stderr=subprocess.STDOUT, creationflags=subprocess.CREATE_NO_WINDOW)
        try:
            instances = directory / "_mcp/instances"
            for _ in range(100):
                if list(instances.glob("*.json")):
                    break
                if process.poll() is not None:
                    raise RuntimeError(log_path.read_text(encoding="utf-8"))
                await asyncio.sleep(0.1)
            parameters = StdioServerParameters(command=sys.executable, args=[str(PROJECT / "mcp_service/server.py"), "--instances-dir", str(instances)], cwd=PROJECT)
            async with stdio_client(parameters) as streams:
                async with ClientSession(*streams) as session:
                    initialized = await session.initialize()
                    tools = await session.list_tools()
                    check(len(tools.tools) == 44, "标准 MCP 握手并发现 44 个工具")

                    async def call(name, arguments=None, error=None):
                        """读取结构化数据，确认工具没有用成功包装掩盖错误。"""
                        result = await session.call_tool(name, arguments or {})
                        data = result.structured_content
                        if error:
                            assert result.is_error and data["error"]["code"] == error, data
                        else:
                            assert not result.is_error and data["ok"], data
                        return data, result

                    async def write(name, arguments):
                        """每次写入读取当前修订号，同时给请求分配唯一编号。"""
                        document, _ = await call("get_document")
                        values = {"document_id": document["document_id"], "expected_revision": document["revision"], "request_id": uuid.uuid4().hex, **arguments}
                        data, result = await call(name, values)
                        return data, values

                    caps, _ = await call("get_capabilities")
                    check(caps["preview_features"]["available"], "图形模式可提供三维视口截图")
                    document, _ = await call("get_document")
                    skeleton = document["rigs"][0]["rig_id"]
                    rig, _ = await call("get_rig", {"rig_id": skeleton})
                    check(len(rig["rig"]["bones"]) == 23, "骨架层级、稳定标识、语义和约束可以读取")
                    created, creation_request = await write("create_clip", {"rig_id": skeleton, "name": "MCP挥手验收", "duration_seconds": 3.0, "fps": 60})
                    target = {"rig_id": skeleton, "clip_id": created["clip"]["clip_id"]}
                    repeated, _ = await call("create_clip", creation_request)
                    check(repeated["replayed"] and repeated["clip"]["clip_id"] == target["clip_id"], "相同成功请求重试不会重复创建动画")
                    batch, _ = await write("apply_edit_batch", {**target, "commands": [
                        {"op": "set_duration", "duration_seconds": 4.0, "mode": "scale_key_times"},
                        {"op": "upsert_keyframe", "time_seconds": 1.0, "rotations_deg": {"upper_arm_r": [0, 0, -80], "forearm_r": [0, 70, 0]}},
                        {"op": "upsert_keyframe", "time_seconds": 2.0, "rotations_deg": {"upper_arm_r": [0, 0, -80], "forearm_r": [0, 100, 0], "hand_r": [0, 0, 35]}},
                        {"op": "upsert_keyframe", "sample_index": 180, "sample_rate": 60, "rotations_deg": {"upper_arm_r": [0, 0, -30], "forearm_r": [0, 30, 0], "hand_r": [0, 0, -20]}},
                    ]})
                    check(batch["clip"]["duration_seconds"] == 4 and batch["clip"]["keyframe_count"] == 5, "设置时长与批量关键帧编辑已保存为一个事务")
                    keys, _ = await call("get_keyframes", {**target, "bone_ids": ["upper_arm_r", "hand_r"]})
                    check(keys["keyframes"][1]["rotations_deg"]["upper_arm_r"][2] == -80, "按稳定关节 ID 回读真实关键帧角度")
                    sampled, _ = await call("evaluate_pose", {**target, "sample_index": 90, "sample_rate": 60, "bone_ids": ["forearm_r", "hand_r"]})
                    decimal_sample, _ = await call("evaluate_pose", {**target, "time_seconds": 0.29, "bone_ids": ["hand_r"]})
                    assert decimal_sample["tick"] == 17400
                    check(sampled["tick"] == 90000 and abs(sampled["joints"][0]["local_euler_deg"][1] - 85) < 0.2, "按精确帧索引读取 C++ 插值与最终骨架空间坐标")
                    await call("apply_edit_batch", {**target, "document_id": creation_request["document_id"], "expected_revision": 1, "request_id": uuid.uuid4().hex, "commands": [{"op": "set_clip_options", "name": "不应写入"}]}, error="REVISION_CONFLICT")
                    before, _ = await call("get_document")
                    await call("apply_edit_batch", {**target, "document_id": before["document_id"], "expected_revision": before["revision"], "request_id": uuid.uuid4().hex, "commands": [{"op": "set_clip_options", "name": "不应写入"}, {"op": "upsert_keyframe", "time_seconds": 0.5, "rotations_deg": {"missing_joint": [0, 0, 0]}}]}, error="BONE_NOT_FOUND")
                    unchanged, _ = await call("get_clip", target)
                    check(unchanged["clip"]["name"] == "MCP挥手验收" and unchanged["revision"] == before["revision"], "过期写入被拒绝，批量任意一条失败不留下部分修改")
                    await write("undo_edit", {**target, "transaction_id": batch["transaction_id"]})
                    undone, _ = await call("get_clip", target)
                    await write("redo_edit", {**target, "transaction_id": batch["transaction_id"]})
                    check(undone["clip"]["duration_seconds"] == 3, "MCP 事务可以通过共用历史撤销和重做")
                    await call("seek_animation", {**target, "time_seconds": 1.5})
                    await call("set_view", {"preset": "left", "frame_all": True})
                    view_before, _ = await call("get_view")
                    editor_before, _ = await call("get_document")
                    images, media = await call("render_preview", {**target, "width": 640, "height": 640, "frames": [
                        {"time_seconds": 1.0, "view": {"preset": "front", "frame_all": True}},
                        {"time_seconds": 2.0, "view": {"preset": "left", "frame_all": True}},
                        {"time_seconds": 2.0, "view": {"preset": "perspective", "focus_bone_id": "hand_r", "distance_m": 0.5}},
                    ]})
                    for index, block in enumerate(media.content[1:]):
                        (OUTPUT / f"preview_{index + 1}.png").write_bytes(base64.b64decode(block.data))
                    view_after, _ = await call("get_view")
                    editor_after, _ = await call("get_document")
                    check(len(media.content) == 4 and images["images"][0]["width"] == 640, "MCP 返回正面、侧面和手部特写 PNG 及其视角和投影数据")
                    check(view_before["view"] == view_after["view"] and editor_before["current_tick"] == editor_after["current_tick"] and editor_before["revision"] == editor_after["revision"], "独立截图保留编辑器观察角度、时间和文档状态")

                    expanded = copy.deepcopy(rig["rig"])
                    expanded.update(id="humanoid_fingers_test_v1", name="细分手脚验收", revision=1)
                    for branch, parent in [("finger_index_l", "hand_l"), ("toe_detail_l", "toe_l")]:
                        for index in range(1, 4):
                            name = f"{branch}_{index}"
                            expanded["bones"].append({"id": name, "name": f"细分关节{index}", "parent_id": parent, "rest_translation_m": [0.04, 0, 0], "rest_rotation_xyzw": [0, 0, math.sin(math.pi / 8), math.cos(math.pi / 8)] if index == 1 else [0, 0, 0, 1], "limits": {"type": "euler_xyz", "minimum_deg": [0, 0, 0], "maximum_deg": [90, 0, 0]}, "semantic": {"role": "finger" if "finger" in branch else "toe", "side": "left", "segment": index}, "display": {"radius_m": 0.01}, "ik_chain_length": 3})
                            parent = name
                    await write("register_rig", {"definition": expanded})
                    new_clip, _ = await write("create_clip", {"rig_id": expanded["id"], "name": "手指屈曲", "duration_seconds": 2.0})
                    finger_target = {"rig_id": expanded["id"], "clip_id": new_clip["clip"]["clip_id"]}
                    rest, _ = await call("evaluate_pose", {**finger_target, "time_seconds": 0, "bone_ids": ["finger_index_l_1", "finger_index_l_2"]})
                    offset = [rest["joints"][1]["position_m"][i] - rest["joints"][0]["position_m"][i] for i in range(3)]
                    check(abs(offset[0] - 0.04 / math.sqrt(2)) < 0.00001 and abs(offset[1] - 0.04 / math.sqrt(2)) < 0.00001, "29 关节新骨架的非零参考四元数实际参与 C++ 求值")
                    await write("apply_edit_batch", {**finger_target, "commands": [{"op": "upsert_keyframe", "time_seconds": 1, "rotations_deg": {"finger_index_l_1": [45, 0, 0], "finger_index_l_2": [60, 0, 0]}}]})
                    limits, _ = await write("update_joint_limits", {"rig_id": expanded["id"], "changes": [{"bone_id": "finger_index_l_1", "limits": {"type": "euler_xyz", "minimum_deg": [0, 0, 0], "maximum_deg": [100, 0, 0]}}]})
                    await write("undo_edit", {**finger_target, "transaction_id": limits["transaction_id"]})
                    await write("redo_edit", {**finger_target, "transaction_id": limits["transaction_id"]})
                    constraints, _ = await call("get_rig", {"rig_id": expanded["id"]})
                    check(constraints["rig"]["bones"][23]["limits"]["maximum_deg"][0] == 100, "细分手脚与关节约束可以编辑、持久化、撤销和回读")
                    valid, _ = await call("validate_clip", finger_target)
                    resource = await session.read_resource("puppet://document")
                    check(valid["valid"] and json.loads(resource.contents[0].text)["ok"], "动画校验和 MCP 文档资源均可读取")
                    report = {"passed": True, "checks": CHECKS, "protocol_version": initialized.protocol_version, "tool_count": len(tools.tools), "output_directory": str(OUTPUT)}
                    (OUTPUT / "result.json").write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding="utf-8")
                    print(json.dumps(report, ensure_ascii=False))
        finally:
            # 只退出本脚本创建的隔离进程，不枚举或结束用户打开的其他窗口。
            if process.poll() is None:
                process.terminate()
                process.wait(timeout=10)
    text = log_path.read_text(encoding="utf-8")
    assert "SCRIPT ERROR" not in text and "ERROR:" not in text, text


if __name__ == "__main__":
    asyncio.run(workflow())
