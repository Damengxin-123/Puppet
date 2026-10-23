"""木偶人公开工具的 JSON Schema，接口只暴露稳定标识与米制数据。"""

from copy import deepcopy

import mcp.types as types

# 有限数值由 JSON 解码和 Godot 再次检查。
NUMBER = {"type": "number"}
# 三轴向量顺序统一为 X、Y、Z。
VECTOR = {"type": "array", "items": NUMBER, "minItems": 3, "maxItems": 3}
# 非空稳定标识，不使用界面数组索引。
IDENTIFIER = {"type": "string", "minLength": 1, "maxLength": 128}
# 骨架与动作的显式定位。
TARGET = {"rig_id": IDENTIFIER, "clip_id": IDENTIFIER}
# 乐观并发与成功请求重放需要的公共字段。
WRITE = {"document_id": IDENTIFIER, "expected_revision": {"type": "integer", "minimum": 1}, "request_id": IDENTIFIER}
# 秒定位限两位小数；精确逐帧定位使用样本序号和采样率。
TIME = {"time_seconds": {"type": "number", "minimum": 0, "maximum": 600, "description": "秒数保留两位小数，由软件校验精度，避免浮点 multipleOf 误拒绝。"}, "sample_index": {"type": "integer", "minimum": 0}, "sample_rate": {"type": "integer", "minimum": 1, "maximum": 240}}
# 两种时间定位方式互斥。
TIME_CHOICE = [{"required": ["time_seconds"], "not": {"anyOf": [{"required": ["sample_index"]}, {"required": ["sample_rate"]}]}}, {"required": ["sample_index", "sample_rate"], "not": {"required": ["time_seconds"]}}]
# 摄像机可复现参数，观察中心与距离均使用米。
VIEW = {"preset": {"enum": ["perspective", "front", "back", "left", "right", "top", "custom"]}, "target_m": VECTOR, "yaw_deg": NUMBER, "pitch_deg": {"type": "number", "minimum": -89.9, "maximum": 89.9}, "distance_m": {"type": "number", "minimum": 0.05, "maximum": 100}, "fov_deg": {"type": "number", "minimum": 5, "maximum": 120}, "projection": {"enum": ["perspective", "orthographic"]}, "orthographic_size_m": {"type": "number", "exclusiveMinimum": 0}, "frame_all": {"type": "boolean"}, "focus_bone_id": IDENTIFIER}
# 可编辑的动作基础属性。
OPTIONS = {"name": {"type": "string", "minLength": 1, "maxLength": 96}, "fps": {"type": "integer", "minimum": 1, "maximum": 240}, "loop": {"type": "boolean"}, "interpolation": {"enum": ["hold", "linear", "smooth"]}}
# 单个动作支持的时长范围。
DURATION = {"type": "number", "minimum": 0.1, "maximum": 600, "description": "动画总时长，单位秒，保留两位小数。"}


def obj(properties=None, required=(), **extra):
    """构造拒绝拼错字段的对象参数。"""
    return {"type": "object", "properties": deepcopy(properties or {}), "required": list(required), "additionalProperties": False, **extra}


def at_time(properties=None, required=()):
    """将精确时间定位加入命令参数。"""
    return obj({**TIME, **(properties or {})}, required, oneOf=deepcopy(TIME_CHOICE))


def edit(op, properties=None, required=(), timed=False):
    """构造批量事务中的一条编辑命令。"""
    fields = {"op": {"const": op}, **(properties or {})}
    return at_time(fields, ("op", *required)) if timed else obj(fields, ("op", *required))


# 同一批所有命令按顺序在副本上执行，任意失败均不落盘。
EDITS = [
    edit("set_duration", {"duration_seconds": DURATION, "mode": {"enum": ["preserve_key_times", "scale_key_times"]}}, ["duration_seconds"]),
    edit("set_clip_options", OPTIONS),
    edit("upsert_keyframe", {"rotations_deg": {"type": "object", "additionalProperties": VECTOR}, "root_m": VECTOR, "limit_policy": {"enum": ["reject", "clamp"]}}, timed=True),
    edit("delete_keyframe", timed=True),
    edit("move_keyframe", {"from": at_time(), "to": at_time()}, ["from", "to"]),
    edit("solve_ik", {"bone_id": IDENTIFIER, "target_m": VECTOR, "chain_length": {"type": "integer", "minimum": 1, "maximum": 32}}, ["bone_id", "target_m"], timed=True),
]
# 约束格式可按版本扩展，当前支持参考姿势下的 XYZ 欧拉限制。
LIMITS = obj({"type": {"const": "euler_xyz"}, "minimum_deg": VECTOR, "maximum_deg": VECTOR}, ["type", "minimum_deg", "maximum_deg"])
# 关节元数据允许语义和显示属性自然扩展，不固定手指数量。
BONE = obj({"id": IDENTIFIER, "name": {"type": "string"}, "parent_id": {"type": ["string", "null"]}, "rest_translation_m": VECTOR, "rest_rotation_xyzw": {"type": "array", "items": NUMBER, "minItems": 4, "maxItems": 4}, "limits": LIMITS, "semantic": {"type": "object"}, "display": {"type": "object"}, "ik_chain_length": {"type": "integer", "minimum": 1, "maximum": 32}}, ["id", "name", "rest_translation_m", "limits"])
# 层级和参考姿势更改需要新骨架标识，约束更改只增加修订号。
RIG = obj({"schema_version": {"const": 1}, "id": IDENTIFIER, "name": {"type": "string"}, "skeleton_version": {"type": "integer", "minimum": 1}, "revision": {"type": "integer", "minimum": 1}, "bones": {"type": "array", "items": BONE, "minItems": 1, "maxItems": 512}}, ["schema_version", "id", "name", "skeleton_version", "bones"])
# 已实现工具的定义列表，写入和只读能力分别标记。
DEFINITIONS = [
    ("list_instances", "列出当前打开且能连接的木偶人实例，不返回实例令牌。", obj(), False),
    ("select_instance", "多个实例时按 instance_id 显式选择，切换后重新读取文档。", obj({"instance_id": IDENTIFIER}, ["instance_id"]), False),
    ("get_capabilities", "读取真实可用能力、单位、骨架限制和接口版本。", obj(), False),
    ("get_document", "读取全部骨架和动画摘要、活动动画、临时姿势状态及写入所需修订号。", obj(), False),
    ("list_rigs", "列出所有骨架体系及关节数量、结构版本、约束修订。", obj(), False),
    ("get_rig", "读取完整骨架层级、稳定关节 ID、语义、参考姿势和旋转范围。", obj({"rig_id": IDENTIFIER}, ["rig_id"]), False),
    ("list_clips", "列出指定骨架的动画。", obj({"rig_id": IDENTIFIER}, ["rig_id"]), False),
    ("get_clip", "读取动画属性与准确关键帧时间码。", obj(TARGET, TARGET), False),
    ("get_keyframes", "分页读取已存关键帧，可按关节和时间过滤。", obj({**TARGET, "bone_ids": {"type": "array", "items": IDENTIFIER}, "start_seconds": NUMBER, "end_seconds": NUMBER, "offset": {"type": "integer", "minimum": 0}, "limit": {"type": "integer", "minimum": 1, "maximum": 64}}, TARGET), False),
    ("evaluate_pose", "返回插值并应用限制后的真实角度、四元数和骨架空间坐标；source=draft 读取当前未记录姿势。", obj({**TARGET, **TIME, "source": {"enum": ["clip", "draft"]}, "bone_ids": {"type": "array", "items": IDENTIFIER}}, TARGET, anyOf=[{"properties": {"source": {"const": "draft"}}, "required": ["source"]}, {"oneOf": deepcopy(TIME_CHOICE)}]), False),
    ("validate_clip", "检查已存关键帧的关节范围；不会声称执行碰撞或完整物理检查。", obj(TARGET, TARGET), False),
    ("create_clip", "创建并保存指定骨架的动画，自动建立起止参考姿势。", obj({**WRITE, "rig_id": IDENTIFIER, **OPTIONS, "duration_seconds": DURATION}, [*WRITE, "rig_id", "name", "duration_seconds"]), True),
    ("apply_edit_batch", "原子编辑动画时长、关键帧、属性和 IK。部分关节旋转按当前采样姿势补齐；全部成功才保存，返回可撤销事务编号。", obj({**WRITE, **TARGET, "commands": {"type": "array", "items": {"oneOf": EDITS}, "minItems": 1, "maxItems": 128}}, [*WRITE, *TARGET, "commands"]), True),
    ("save_clip", "保存已记录动作；include_draft=true 显式将该动画当前临时姿势记录为关键帧。", obj({**WRITE, **TARGET, "include_draft": {"type": "boolean"}}, [*WRITE, *TARGET]), True),
    ("undo_edit", "只撤销当前动画的最近指定 MCP 事务；用户介入后历史冲突会返回错误。", obj({**WRITE, **TARGET, "transaction_id": IDENTIFIER}, [*WRITE, *TARGET, "transaction_id"]), True),
    ("redo_edit", "重做当前动画的最近指定 MCP 事务。", obj({**WRITE, **TARGET, "transaction_id": IDENTIFIER}, [*WRITE, *TARGET, "transaction_id"]), True),
    ("register_rig", "注册并持久化新骨架体系，支持自定义手指和脚趾层级、语义与参考旋转。", obj({**WRITE, "definition": RIG}, [*WRITE, "definition"]), True),
    ("update_joint_limits", "修改当前骨架约束并保存，若任何已有动画不再符合范围则整体拒绝。", obj({**WRITE, "rig_id": IDENTIFIER, "changes": {"type": "array", "items": obj({"bone_id": IDENTIFIER, "limits": LIMITS}, ["bone_id", "limits"]), "minItems": 1, "maxItems": 512}}, [*WRITE, "rig_id", "changes"]), True),
    ("get_view", "读取编辑视口当前摄像机及渲染尺寸。", obj(), False),
    ("set_view", "设置编辑视口观察角度，支持六面预设、自定义、全身取景和关节特写。", obj(VIEW), False),
    ("seek_animation", "在软件界面打开指定动画并定位时刻，有临时姿势时拒绝切换。", at_time(TARGET, TARGET), False),
    ("render_preview", "从独立三维视口返回 PNG 图片及对应姿势时刻、视角、关节像素投影和快照修订号；不改变编辑器状态。", obj({**TARGET, "width": {"type": "integer", "minimum": 256, "maximum": 2048}, "height": {"type": "integer", "minimum": 256, "maximum": 2048}, "frames": {"type": "array", "items": at_time({"view": obj(VIEW)}), "minItems": 1, "maxItems": 12}}, [*TARGET, "frames"]), False),
    ("get_request_result", "读取当前实例保留的成功写入结果，用于响应丢失后的确认。", obj({"request_id": IDENTIFIER}, ["request_id"]), False),
    ("set_playback", "在软件中开始或暂停指定动画预览；循环和速度沿用软件设置，不修改动画数据。重复开始不重置播放位置。", obj({**TARGET, "playing": {"type": "boolean"}}, [*TARGET, "playing"]), False),
]


# 工具在客户端显示的简短中文名称。
TITLES = ["列出实例", "选择实例", "软件能力", "当前文档", "骨架列表", "骨架定义", "动画列表", "动画详情", "读取关键帧", "姿势求值", "检查动画", "新建动画", "批量编辑", "保存动画", "撤销事务", "重做事务", "注册骨架", "修改关节限制", "读取视角", "设置视角", "定位动画", "截图预览", "查询请求结果", "播放或暂停动画"]


# 独立绑定任务的显式定位，防止操作用户刚切换后的其他角色。
BINDING_TARGET = {"project_id": IDENTIFIER}
# 绑定项目写入统一使用已有的修订号和请求幂等约定。
BINDING_WRITE = {**WRITE, **BINDING_TARGET}
# 绑定预览时间只读，默认不传动画时渲染参考姿态。
BINDING_SAMPLE = {"clip_id": IDENTIFIER, "time_seconds": TIME["time_seconds"]}
DEFINITIONS.extend([
    ("list_binding_projects", "列出已保存角色绑定项目。每个项目拥有独立骨架、骨长和模型资源。", obj(), False),
    ("get_binding_project", "读取当前绑定项目全部参考关节位置、骨长、模型信息和预览状态。", obj(BINDING_TARGET, BINDING_TARGET), False),
    ("create_binding_project", "从本机 GLB、glTF 或 FBX 新建绑定项目，复制源骨架和模型资源，原文件保持不变。", obj({**WRITE, "model_path": {"type": "string", "minLength": 1, "maxLength": 4096}, "name": {"type": "string", "minLength": 1, "maxLength": 96}, "rig_id": IDENTIFIER}, [*WRITE, "model_path", "name", "rig_id"]), True),
    ("open_binding_project", "打开已经保存的角色绑定项目并切换角色工作区；原模型移动后仍可使用项目副本。", obj(BINDING_WRITE, BINDING_WRITE), True),
    ("move_binding_joint", "在项目模型坐标中拖动参考关节，单位米、两位小数。只改变项目骨架，模型不变；可带动子关节。自动保存并支持撤销。", obj({**BINDING_WRITE, "bone_id": IDENTIFIER, "position_m": VECTOR, "move_children": {"type": "boolean"}}, [*BINDING_WRITE, "bone_id", "position_m"]), True),
    ("set_binding_bone_length", "改变父关节到目标关节的骨段长度，沿原方向移动目标及后代，模型保持原样。", obj({**BINDING_WRITE, "bone_id": IDENTIFIER, "length_m": {"type": "number", "minimum": 0.01, "maximum": 100}}, [*BINDING_WRITE, "bone_id", "length_m"]), True),
    ("update_binding_project", "保存项目名称或选择平滑四权重、刚性单权重自动蒙皮，不修改源动画。", obj({**BINDING_WRITE, "name": {"type": "string", "minLength": 1, "maxLength": 96}, "skin_mode": {"enum": ["smooth", "rigid"]}, "yaw_delta_deg": {"type": "number", "minimum": -360, "maximum": 360}}, BINDING_WRITE), True),
    ("save_binding_project", "显式保存绑定项目，修改通常已经自动保存。", obj(BINDING_WRITE, BINDING_WRITE), True),
    ("undo_binding_edit", "撤销当前绑定项目最近一次关节或设置修改，不涉及动画历史。", obj(BINDING_WRITE, BINDING_WRITE), True),
    ("redo_binding_edit", "重做当前绑定项目最近一次修改。", obj(BINDING_WRITE, BINDING_WRITE), True),
    ("preview_binding_animation", "在当前绑定骨架上只读播放或定位源动画；按项目骨长驱动角色，不修改模型资源或动画。", obj({**BINDING_TARGET, **BINDING_SAMPLE, "playing": {"type": "boolean"}}, [*BINDING_TARGET, "clip_id"]), False),
    ("stop_binding_preview", "停止角色动画并恢复完整原模型及绑定参考姿态，以便继续拖动关节。", obj(BINDING_TARGET, BINDING_TARGET), False),
    ("evaluate_binding_pose", "回读参考姿态或动画时刻按项目骨长计算的真实关节位置和旋转。", obj({**BINDING_TARGET, **BINDING_SAMPLE}, BINDING_TARGET), False),
    ("set_binding_view", "独立设置角色绑定视口摄像机，可指定任意偏航、俯仰、距离、观察中心和正交投影。", obj({**BINDING_TARGET, "view": obj(VIEW)}, [*BINDING_TARGET, "view"]), False),
    ("render_binding_preview", "独立截图相机返回真实角色 PNG、骨架投影和项目修订。支持任意视角、关节特写、原始模型或动画预览，不改变用户视角。", obj({**BINDING_TARGET, **BINDING_SAMPLE, "view": obj(VIEW), "show_bones": {"type": "boolean"}, "weight_bone_id": IDENTIFIER, "width": {"type": "integer", "minimum": 256, "maximum": 2048}, "height": {"type": "integer", "minimum": 256, "maximum": 2048}}, BINDING_TARGET), False),
])
TITLES.extend(["绑定项目列表", "绑定项目详情", "导入角色项目", "打开绑定项目", "拖动绑定关节", "修改项目骨长", "修改绑定设置", "保存绑定项目", "撤销绑定修改", "重做绑定修改", "预览角色动画", "返回绑定姿态", "绑定姿势求值", "设置绑定视角", "角色截图相机"])


# 原始网格顶点的稳定地址，不因骨架、动画或权重修改而变化。
VERTEX_ID = {"type": "string", "pattern": r"^\d+:\d+:\d+$"}
# 表面选区只沿网格边传播；显式顶点列表会同步 UV 缝上的同位置顶点。
WEIGHT_SELECTION = {"vertex_ids": {"type": "array", "items": VERTEX_ID, "minItems": 1, "maxItems": 100000}, "seed_vertex_id": VERTEX_ID, "radius_m": {"type": "number", "minimum": 0.01, "maximum": 100, "multipleOf": 0.01}, "whole_component": {"type": "boolean"}}
# 选择器二选一，避免一个请求内出现两个不同的修改目标。
WEIGHT_CHOICE = [{"required": ["vertex_ids"], "not": {"required": ["seed_vertex_id"]}}, {"required": ["seed_vertex_id"], "not": {"required": ["vertex_ids"]}}]
DEFINITIONS.extend([
    ("get_binding_weights", "分页读取真实自动/手工权重、稳定顶点地址和参考坐标；可按骨骼阈值或表面选区过滤。", obj({**BINDING_TARGET, **WEIGHT_SELECTION, "bone_id": IDENTIFIER, "minimum_weight": {"type": "number", "minimum": 0, "maximum": 1}, "offset": {"type": "integer", "minimum": 0}, "limit": {"type": "integer", "minimum": 1, "maximum": 512}}, BINDING_TARGET), False),
    ("set_binding_weight_view", "查看指定骨骼权重热图，可选择顶点或沿表面扩展的区域；不改关节、模型、动画或权重。省略 bone_id 关闭热图。", obj({**BINDING_TARGET, **WEIGHT_SELECTION, "bone_id": IDENTIFIER, "editing": {"type": "boolean"}}, BINDING_TARGET), False),
    ("edit_binding_weights", "原子修改选区权重：set/add/subtract/smooth/exclude/exclude_arms。自动归一化至最多四骨骼，缝边同步，保存并可撤销；清除影响转交给 fallback_bone_id（默认 pelvis）。", obj({**BINDING_WRITE, **WEIGHT_SELECTION, "operation": {"enum": ["set", "add", "subtract", "smooth", "exclude", "exclude_arms"]}, "bone_id": IDENTIFIER, "value": {"type": "number", "minimum": 0, "maximum": 1}, "excluded_bone_ids": {"type": "array", "items": IDENTIFIER, "minItems": 1}, "fallback_bone_id": IDENTIFIER}, [*BINDING_WRITE, "operation"], oneOf=WEIGHT_CHOICE), True),
    ("reset_binding_weights", "恢复选区自动权重；只有显式 scope=all 才清除全项目手工权重。支持撤销，不改变关节位置。", obj({**BINDING_WRITE, **WEIGHT_SELECTION, "scope": {"enum": ["selection", "all"]}}, BINDING_WRITE, anyOf=[{"properties": {"scope": {"const": "all"}}, "required": ["scope"]}, *WEIGHT_CHOICE]), True),
    ("recalculate_binding_weights", "重新计算沿模型表面传播的自动蒙皮，保留全部手工权重、当前关节位置、骨长和源动画，自动保存并支持撤销。", obj(BINDING_WRITE, BINDING_WRITE), True),
])
TITLES.extend(["查看顶点权重", "查看权重热图", "修改选区权重", "恢复自动权重", "重新计算蒙皮"])


def build_tools():
    """生成标准 MCP 工具及明确的结构化返回值声明。"""
    return [types.Tool(name=name, title=title, description=description, input_schema=schema,
                       output_schema={"type": "object", "properties": {"ok": {"type": "boolean"}}, "required": ["ok"], "additionalProperties": True},
                       annotations=types.ToolAnnotations(read_only_hint=not write and name not in {"set_view", "seek_animation", "select_instance", "set_playback", "preview_binding_animation", "stop_binding_preview", "set_binding_view", "set_binding_weight_view"}, destructive_hint=False, idempotent_hint=not write, open_world_hint=False))
            for title, (name, description, schema, write) in zip(TITLES, DEFINITIONS)]
