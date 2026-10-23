# 木偶人 MCP 使用说明

2026-10-22 更新：角色绑定现已支持沿网格表面传播的自动蒙皮、权重热图、表面选区、权重修改与手臂影响清除；关节、模型和源动画保持独立。绑定相关 MCP 工具共 20 个，总计 44 个。操作、数据隔离、限制和验证结果见[角色绑定使用说明](角色绑定使用说明.md)。已有模型权重导入、连续涂抹画笔、布料模拟及导出仍待后续开发。

当前接口版本：`1.0`。更新日期：2026-10-22。

[项目入口](../README.md) · [功能设计](功能设计.md) · [开发计划](开发计划.md)

## 1. 连接软件

软件中的“设置 → AI 与 MCP”提供本机服务开关、连接状态和两种连接配置复制按钮。默认启用，启动软件后自动创建当前实例的信息；退出或关闭服务时移除该实例记录。

连接分两层：

```text
AI 客户端 → 标准 MCP stdio → Python 适配器 → 本机带令牌 TCP → Godot 文档命令 → C++ 求解
```

软件只监听 `127.0.0.1`，端口由系统动态分配，多个窗口可以同时运行。端口及令牌由适配器从 `workspace/mcp/instances` 自动读取，不需要用户填写。对外提供的是标准 MCP stdio，本机 TCP 是软件内部通道。

本机 Python 环境已经安装依赖；新环境运行 `scripts/准备环境.ps1` 时一起安装。单独安装可在项目根目录执行：

```powershell
& './tools/python/Scripts/python.exe' -m pip install -r './mcp_service/requirements.txt'
```

支持 `mcpServers` 的客户端可使用 [JSON 配置示例](../mcp_service/client.example.json)。客户端启动命令为项目内的 `tools/python/Scripts/python.exe`，参数是 `mcp_service/server.py` 的绝对路径。软件可以先开、后开，MCP 工具列表始终可以读取；需要操作动画时软件必须已运行。

Codex 项目级配置已放在 [Puppet/.codex/config.toml](../.codex/config.toml)，以受信任的 Puppet 目录作为项目打开时使用。当前开发会话以父级 Godot 为工作目录，因此也在该工作目录的 `.codex/config.toml` 准备了相同条目。配置示例保存在 [codex.example.toml](../mcp_service/codex.example.toml)，可复制其中的 `[mcp_servers.puppet]` 表到用户 `~/.codex/config.toml`，或其他会话实际使用的项目 `.codex/config.toml`。配置中的 command/args/cwd 含义按 [OpenAI 官方 MCP 文档](https://learn.chatgpt.com/docs/extend/mcp?surface=cli) 核对。需要由客户端重新加载 MCP 配置；现有对话是否能动态刷新取决于客户端。

迁移项目目录后，从软件设置重新复制配置，以获得新的绝对路径。项目附带的示例不会修改用户全局配置。

多个软件实例同时打开时，先 `list_instances` 再 `select_instance`。适配器选定实例后不会悄悄改连另一个窗口；选中实例退出时返回错误，重新选择即可。

## 2. 已实现工具

| 用途 | 工具 | 返回内容 |
| --- | --- | --- |
| 实例发现 | `list_instances`、`select_instance` | 已运行实例及明确选择结果 |
| 能力与文档 | `get_capabilities`、`get_document` | 接口能力、文档修订、动画摘要、活动目标与草稿状态 |
| 骨架 | `list_rigs`、`get_rig` | 骨架列表、完整层级、参考姿势、语义、关节限制 |
| 动画查询 | `list_clips`、`get_clip`、`get_keyframes` | 动画属性、精确时间码和按关节分页的关键帧 |
| 求值与检查 | `evaluate_pose`、`validate_clip` | 实际插值姿势及已存关键帧限制检查 |
| 创建与保存 | `create_clip`、`save_clip` | 已保存动作、修订号、保存结果 |
| 批量编辑 | `apply_edit_batch` | 时长、属性、关键帧与 IK 事务 |
| 撤销与重做 | `undo_edit`、`redo_edit` | 指定最近事务的恢复结果 |
| 骨架扩展 | `register_rig`、`update_joint_limits` | 新骨架定义或约束修订 |
| 直接观察 | `get_view`、`set_view`、`seek_animation` | 编辑视口摄像机及播放定位结果 |
| 播放控制 | `set_playback` | 在软件中播放或暂停指定动画，返回实际播放状态、时刻和速度 |
| 独立截图 | `render_preview` | PNG 图片、视角、时刻、快照修订、关节像素投影 |
| 请求确认 | `get_request_result` | 当前实例保留的成功写入结果 |

目前共 44 个工具，另外提供只读资源 `puppet://document`，内容与 `get_document` 相同。详细参数及 JSON Schema 集中在 [tool_catalog.py](../mcp_service/tool_catalog.py)，Godot 侧也会验证数值、骨架层级和编辑结果。

## 3. 推荐的动画工作流程

1. 调用 `get_capabilities`、`get_document`、`get_rig`。使用返回的真实骨架和关节 ID，先看旋转范围和参考坐标。
2. 使用 `create_clip` 新建动画。起止时刻自动记录符合当前限制的参考姿势。
3. 用 `apply_edit_batch` 一次写入少量关键姿势、时长和过渡设置。
4. 用 `get_keyframes` 确认存储值，用 `evaluate_pose` 读取中间时刻的实际姿势，用 `render_preview` 观察动作。
5. 继续修改需要精修的时刻，或者用 `undo_edit` 撤销最近整组操作。成功的编辑已自动保存。

所有写入需要：

```json
{
  "document_id": "从 get_document 获取",
  "expected_revision": 12,
  "request_id": "本次请求唯一编号"
}
```

动画目标需要同时给出 `rig_id` 和 `clip_id`；关节使用 `get_rig` 返回的 `id`，不使用数组下标或中文显示名。用户手动保存或修改临时姿势后，旧 `expected_revision` 会失效。此时重读数据、调整请求后再提交。

同一成功请求用原编号和完全相同内容重试会重放原结果，不重复创建资产。缓存只保留当前进程最近 256 条成功写入，总大小最多 16 MiB；重启、缓存被淘汰后应先查询资产状态。相同编号用于不同内容会返回 `REQUEST_ID_CONFLICT`。

`apply_edit_batch` 最多 128 条命令，按顺序作用在副本上，全部验证成功后保存一次，产生一条撤销记录。任何一条失败均不保存候选修改。最多保存一万个关键帧。

| 批量命令 | 功能 |
| --- | --- |
| `set_duration` | 修改时长，`preserve_key_times` 保留原时刻，`scale_key_times` 按比例缩放全部关键帧 |
| `set_clip_options` | 修改名称、帧率、循环和 `hold/linear/smooth` 插值 |
| `upsert_keyframe` | 新增或替换指定时刻，`rotations_deg` 按关节 ID 提供部分或全部角度，其他关节从候选动画采样补齐 |
| `delete_keyframe` | 删除精确时刻的关键帧，保留至少一个关键帧 |
| `move_keyframe` | 用 `from`、`to` 时间对象移动单帧，已有关键帧时拒绝覆盖 |
| `solve_ik` | 按 `bone_id`、`target_m` 和可选链长求解并记录关键帧，返回实际目标误差 |

时长范围为 `0.10–600.00` 秒，帧率为 `1–240` 的整数。保留原时刻时缩短到已有帧之前会拒绝；按比例缩放导致时间码碰撞也会拒绝，不静默删除帧。

旋转默认 `limit_policy=reject`，超出范围返回关节、请求值和限制结果；显式选择 `clamp` 时裁剪，并报告调整。IK 目标可能因骨长或限制无法到达，必须结合返回误差与实际姿势判断。

创建资产和注册骨架不进入姿势撤销历史。批量编辑、显式保存草稿、修改约束可以撤销。`undo_edit/redo_edit` 必须带原 `transaction_id`，且事务仍是当前动画历史栈的最近一条；中间有用户编辑或已切到其他动画时返回历史冲突。

如果界面有未记录姿势，写入会返回 `UNRECORDED_POSE`。可用 `evaluate_pose(source="draft")` 先读草稿，再显式 `save_clip(include_draft=true)` 保存到其所属动画；不会自动覆盖用户草稿。

## 4. 时间、旋转与坐标

- 秒定位：`time_seconds`，保留两位小数。
- 逐帧定位：同时给出 `sample_index` 和 `sample_rate`，例如第 61 个样本在 60 FPS 下为 `61/60` 秒，不先舍入到 `1.02` 秒。样本从 0 开始。
- 两种定位方式互斥，内部一秒为 60000 个整数时间刻度，返回 `tick` 表示准确位置。帧率不整除 60000 时映射到最近刻度。
- 长度使用米，角度使用度。关键帧角度和根位移按现有文件格式保存两位小数；求值与四元数保留运算精度。
- 骨架空间 +Y 向上、+Z 向前。角度为相对参考姿势的增量，局部旋转为 `rest_rotation * Rz(z) * Ry(y) * Rx(x)`。
- `evaluate_pose` 返回每个关节的局部角度、增量四元数和骨架空间位置/整体四元数；四元数分量统一为 XYZW。
- `get_keyframes` 是存储值，`evaluate_pose(source="clip")` 是指定时间求值，`source="draft"` 是当前未记录姿势，三者明确区分。

## 5. 视角与截图

用 `seek_animation` 打开动画并定位后，调用 `set_playback`，参数为 `rig_id`、`clip_id` 和布尔值 `playing`。设为 true 开始播放，false 暂停；重复开始不会把正在播放的时间归零。循环与速度沿用软件设置。通过 `get_document` 回读 `playing/current_tick/time_seconds/playback_speed` 可以确认播放确实推进；有未记录姿势时拒绝开始。播放控制只改变预览，不修改动作文件。

`get_view/set_view` 控制当前编辑视口。`set_view` 支持 `perspective/front/back/left/right/top/custom`，以及以下参数：

| 参数 | 含义 |
| --- | --- |
| `frame_all` | 按当前骨架姿势自动取景 |
| `focus_bone_id` | 观察该关节，适合手脚特写 |
| `target_m` | 自定义观察中心 |
| `yaw_deg/pitch_deg` | 绕中心观察的水平角和俯仰角 |
| `distance_m/fov_deg` | 观察距离与透视角 |
| `projection` | `perspective` 或 `orthographic` |
| `orthographic_size_m` | 正交投影的可见尺寸 |

`render_preview` 使用独立场景渲染保存的动画，不改变用户的选择、草稿、时间和摄像机。例如：

```json
{
  "rig_id": "standard_humanoid_v1",
  "clip_id": "从动画列表获取",
  "width": 768,
  "height": 768,
  "frames": [
    {"time_seconds": 0.5, "view": {"preset": "front", "frame_all": true}},
    {"time_seconds": 0.5, "view": {"preset": "left", "frame_all": true}},
    {"time_seconds": 0.5, "view": {"preset": "perspective", "focus_bone_id": "hand_r", "distance_m": 0.5}}
  ]
}
```

每次 1–12 张图片，宽高为 256–2048 像素，响应总计最多 16 MiB。适配器把 PNG 作为原生 MCP image 内容返回；结构化结果仅保留元数据和 `content_index`，不会再复制整段 base64。像素坐标原点为左上角，每个关节同时提供 `behind_camera` 标志。

响应的 `snapshot_revision`、`clip_revision` 对应截图输入快照；响应顶层 `revision` 是完成时文档状态。用户可能在渲染期间继续编辑，两者可以不同。无图形启动可读取与编辑数据，截图返回 `RENDERING_UNAVAILABLE`。

## 6. 新骨架、约束和详细手脚

骨架注册表位于 `workspace/rigs`，各骨架动画分别放在 `workspace/animations/<rig_id>`。标准人形的旧动作继续沿用原目录。

骨架定义包含 `schema_version/id/name/skeleton_version/revision/bones`。关节至少提供稳定 `id`、显示 `name`、父节点 `parent_id`（根为空）、`rest_translation_m` 和 `limits`。可选元数据示例：

```json
{
  "id": "index_l_02",
  "name": "左食指中节",
  "parent_id": "index_l_01",
  "rest_translation_m": [0.03, 0.0, 0.0],
  "rest_rotation_xyzw": [0.0, 0.0, 0.0, 1.0],
  "limits": {"type": "euler_xyz", "minimum_deg": [0.0, 0.0, 0.0], "maximum_deg": [100.0, 0.0, 0.0]},
  "semantic": {"role": "finger", "side": "left", "digit": "index", "segment": 2},
  "display": {"kind": "joint", "radius_m": 0.01, "draw_parent_bone": true},
  "ik_chain_length": 3
}
```

每个骨架支持 1–512 个关节和一个根节点，检查唯一 ID、父节点存在、层级无环、有限数值和有效四元数。关节顺序自动整理为父节点在前。ID 使用以字母开头的 ASCII 字母、数字、下划线、点、连字符，最多 96 字符，不能包含 `..`。

求解器、动画数组、资源树、视口和接口都按定义中的实际关节数量工作；手指、脚趾、额外链条无需修改工具名称或硬编码数组位置。`semantic` 允许增加手指编号等信息，`rest_rotation_xyzw` 支持不同关节的参考轴。

`register_rig` 注册新的结构；相同 ID 不能替换层级和参考姿势，修改结构应使用新 ID，旧动画仍保留骨架与结构版本引用。`skeleton_version` 表示结构版本，`revision` 表示约束/定义修订。

`update_joint_limits` 只修改约束，目前支持三轴 `euler_xyz`，范围在 -180 至 180 度、保留两位小数，锁定轴可设置上下限相等。修改前检查该骨架所有已载入动作；若任何关键帧越界，整体拒绝，调用方先调整相关动画。约束修改需在当前活动骨架上执行，以关联可撤销历史。

后续骨架编辑器可以调用同一命令服务；当前已提供约束读写和持久化基础，不包含完整可视拓扑编辑器、预制详细手脚美术、全身 IK、摆动锥或接触求解。

## 7. 简单验收与代码位置

在项目根目录执行：

```powershell
& './tools/python/Scripts/python.exe' './scripts/验收MCP.py'
```

脚本启动自己创建的软件进程，使用官方 MCP SDK 完成一次握手和完整编辑流程，并注册带细分手脚和参考旋转的 29 关节骨架。图片、日志和结果保存在 `build/verification/mcp/<时间>`，动画也在该隔离目录内；结束只关闭自己的测试进程。

| 文件 | 职责 |
| --- | --- |
| `mcp_service/server.py` | 官方 MCP stdio 协议、实例发现、连接、资源与图片内容转换 |
| `mcp_service/tool_catalog.py` | 44 个工具的参数和返回值 Schema |
| `app/mcp_bridge.gd` | 带令牌的本机 TCP、主线程串行命令、非阻塞分块传输 |
| `app/command_service.gd` | 文档修订、批量候选、保存、历史和真实数据回读 |
| `app/rig_registry.gd` | 新骨架、元数据、参考坐标和约束版本 |
| `app/preview_renderer.gd` | 独立三维世界和 PNG 快照 |
| `native/animation_core.hpp` | 不依赖 Godot 的可变骨架求值与受限 IK |

后续角色绑定、批量导出、后台任务管理、碰撞/接触诊断会按开发阶段增加真实工具；当前能力清单不宣称已经实现这些功能。
