extends RefCounted
## MCP 与界面共用的文档命令入口，负责版本、事务、稳定标识与实际结果。

## 绑定项目工具入口。
const BindingCommandsScript = preload("res://app/binding_commands.gd")
## 绑定项目命令服务。
var binding_commands

## 可复用的本地动作库。
const LibraryScript = preload("res://app/animation_library.gd")
## 独立三维预览渲染器。
const PreviewScript = preload("res://app/preview_renderer.gd")
## 对外接口版本，与骨架格式版本分别演进。
const API_VERSION: String = "1.2"
## 必须具备文档版本和请求编号的写入工具。
const WRITE_TOOLS: Array[String] = ["create_clip", "apply_edit_batch", "save_clip", "undo_edit", "redo_edit", "register_rig", "update_joint_limits"]
## 当前主界面宿主，所有场景更新都在 Godot 主线程发生。
var host
## 骨架注册表。
var registry
## 标准骨架使用的兼容动作目录覆盖路径。
var workspace_override: String = ""
## 每个骨架独立的求解器与动作库。
var documents: Dictionary = {}
## 当前进程唯一标识，重启后不会误用旧会话的请求编号。
var instance_id: String = ""
## 工程数据目录的稳定标识。
var document_id: String = ""
## 手动编辑与 MCP 共用的文档修订号。
var revision: int = 1
## 已成功执行的写入请求及其内容摘要。
var completed_requests: Dictionary = {}
## 有界请求缓存的先进先出顺序。
var request_order: Array[String] = []
## 成功请求缓存的近似字节数。
var request_bytes: int = 0
## 不改动编辑视口的独立截图服务。
var preview_renderer

## 接入当前已经打开的标准动作库，其他骨架按需加载。
func initialize(owner_node, rig_registry, initial_core, initial_library, override_path: String) -> void:
	host = owner_node
	registry = rig_registry
	workspace_override = override_path
	instance_id = "puppet_%d_%s" % [OS.get_process_id(), Crypto.new().generate_random_bytes(8).hex_encode()]
	var identity_path = override_path if not override_path.is_empty() else ProjectSettings.globalize_path("res://workspace")
	document_id = "document_" + identity_path.simplify_path().sha256_text().left(20)
	documents[initial_library.rig_id] = {"core": initial_core, "library": initial_library}
	initial_library.clip_saved.connect(_on_clip_saved)
	preview_renderer = PreviewScript.new()
	preview_renderer.initialize(host, registry)

## 在绑定页面就绪后接入共享工具入口。
func initialize_binding() -> void:
	binding_commands = BindingCommandsScript.new()
	binding_commands.initialize(host, self)

## 成功的手动保存与接口保存都使旧的写入快照失效。
func _on_clip_saved(_clip_id: String, _clip_revision: int) -> void:
	revision += 1

## 临时姿势也属于可观察的编辑状态，修改后递增文档修订号。
func note_draft_changed() -> void:
	revision += 1

## 按骨架标识获取求解器和动作库；读取不会自动创建动画资产。
func get_document_for_rig(rig_id: String) -> Dictionary:
	if documents.has(rig_id):
		return documents[rig_id]
	if not registry.definitions.has(rig_id):
		return {}
	var animator = registry.create_core(rig_id)
	var library = LibraryScript.new()
	var directory = "" if workspace_override.is_empty() else workspace_override.path_join(rig_id)
	library.initialize(animator, registry.native_definition(rig_id), directory, rig_id, int(registry.definitions[rig_id].skeleton_version), false)
	library.clip_saved.connect(_on_clip_saved)
	documents[rig_id] = {"core": animator, "library": library}
	return documents[rig_id]

## 分发公开工具，只有白名单命令可以访问工程。
func execute(method: String, params: Dictionary) -> Dictionary:
	if method in BindingCommandsScript.TOOLS:
		if method in BindingCommandsScript.WRITES:
			var binding_check = _check_write_request(method, params)
			if not binding_check.is_empty():
				return binding_check
		var binding_result: Dictionary = await binding_commands.execute(method, params)
		if method in BindingCommandsScript.WRITES and binding_result.get("ok", false):
			_remember_request(method, params, binding_result)
		return binding_result
	if host.current_page == 1 and method in WRITE_TOOLS:
		return _error("BINDING_ANIMATION_READ_ONLY", "绑定工作区中的动画仅供预览，请回到骨骼动画页面编辑动画资产。")
	if method in WRITE_TOOLS:
		var check = _check_write_request(method, params)
		if not check.is_empty():
			return check
	var result: Dictionary
	match method:
		"ping", "get_capabilities":
			result = _capabilities()
		"get_document":
			result = _document_state()
		"list_rigs":
			result = _success({"rigs": registry.list_rigs(), "load_errors": registry.load_errors})
		"get_rig":
			var definition = registry.get_definition(str(params.get("rig_id", "")))
			result = _error("RIG_NOT_FOUND", "骨架不存在。") if definition.is_empty() else _success({"rig": definition, "rotation_convention": "rest_rotation * Rz(z) * Ry(y) * Rx(x)", "angle_unit": "degree", "length_unit": "meter", "position_space": "skeleton", "up_axis": "+Y", "forward_axis": "+Z"})
		"list_clips":
			result = _list_clips(params)
		"get_clip":
			var target = _target(params)
			result = target if not target.ok else _success({"clip": _clip_summary(target.clip), "key_times": _key_times(target.clip)})
		"get_keyframes":
			result = _get_keyframes(params)
		"evaluate_pose":
			result = _evaluate_pose(params)
		"validate_clip":
			result = _validate_clip(params)
		"create_clip":
			result = _create_clip(params)
		"apply_edit_batch":
			result = _apply_edit_batch(params)
		"save_clip":
			result = _save_clip(params)
		"undo_edit", "redo_edit":
			result = _undo_redo(params, method == "redo_edit")
		"register_rig":
			result = _register_rig(params)
		"update_joint_limits":
			result = _update_joint_limits(params)
		"get_view":
			result = _success({"view": host.rig_view.get_camera_state()})
		"set_view":
			var changed: Dictionary = host.rig_view.configure_camera(params)
			result = _success({"view": host.rig_view.get_camera_state()}) if changed.ok else _error("INVALID_VIEW", changed.error)
		"seek_animation":
			result = _seek_animation(params)
		"set_playback":
			result = _set_playback(params)
		"render_preview":
			result = await _render_preview(params)
		"get_request_result":
			var id = str(params.get("request_id", ""))
			result = _success({"request_result": completed_requests[id].result}) if completed_requests.has(id) else _error("REQUEST_NOT_FOUND", "该成功请求不在当前进程的保留记录中。")
		_:
			result = _error("UNKNOWN_TOOL", "未实现的接口：" + method)
	if method in WRITE_TOOLS and result.get("ok", false):
		_remember_request(method, params, result)
	return result

## 只公布实际实现的能力，未来骨架与约束模型可以按版本增加。
func _capabilities() -> Dictionary:
	return _success({
		"name": "木偶人", "tools": ["get_capabilities", "get_document", "list_rigs", "get_rig", "list_clips", "get_clip", "get_keyframes", "evaluate_pose", "validate_clip", "create_clip", "apply_edit_batch", "save_clip", "undo_edit", "redo_edit", "register_rig", "update_joint_limits", "get_view", "set_view", "seek_animation", "set_playback", "render_preview", "get_request_result"] + BindingCommandsScript.TOOLS,
		"binding_features": {"formats": ["glb", "gltf", "fbx"], "independent_projects": true, "auto_save": true, "editable_rest_positions": true, "variable_bone_lengths": true, "source_mesh_immutable": true, "animation_read_only": true, "skin_modes": ["smooth", "rigid"], "weight_algorithm": "surface_geodesic_v2", "weight_heatmap": true, "editable_weights": true, "weight_selection_space": "rest_surface_geodesic", "manual_weights_preserved_on_recalculate": true, "position_precision_m": 0.01},
		"rig_features": {"variable_joint_count": true, "max_joints": 512, "stable_bone_ids": true, "semantic_metadata": true, "rest_quaternion": true, "constraint_models": ["euler_xyz"], "constraint_editing": true, "topology_editing": false},
		"animation_features": {"time_unit": "second", "ticks_per_second": 60000, "time_precision": 0.01, "sample_addressing": true, "fps_range": [1, 240], "max_batch_commands": 128, "limit_policies": ["reject", "clamp"], "duration_modes": ["preserve_key_times", "scale_key_times"], "undoable_operations": ["apply_edit_batch", "update_joint_limits", "save_draft"]},
		"preview_features": {"available": DisplayServer.get_name() != "headless", "views": ["perspective", "front", "back", "left", "right", "top", "custom"], "max_images": 12, "max_resolution": 2048, "isolated_from_editor": true},
		"idempotency": {"scope": "current_instance_successful_writes", "max_requests": 256, "max_bytes": 16777216}, "engine": Engine.get_version_info().string
	})

## 返回当前选择与所有骨架下的动作摘要，不依赖窗口焦点定位写入。
func _document_state() -> Dictionary:
	var clips: Array = []
	for rig_id in registry.definitions:
		for clip in get_document_for_rig(rig_id).library.clips:
			clips.append(_clip_summary(clip))
	var selected = ""
	if host.rig_view.selected_joint >= 0:
		selected = str(host.rig[host.rig_view.selected_joint].id)
	return _success({"active_workspace": "binding" if host.current_page == 1 else "animation", "binding_project_id": str(host.binding_service.project.get("id", "")), "binding_projects": host.binding_service.list_projects(), "rigs": registry.list_rigs(), "clips": clips, "active_rig_id": host.active_rig_id, "active_clip_id": str(host.active_clip().id), "selected_bone_id": selected, "current_tick": host.current_tick, "time_seconds": float(host.current_tick) / 60000.0, "draft_dirty": host.pose_dirty, "playing": host.playing, "playback_speed": host.playback_speed})

## 列出指定骨架下的动画资产。
func _list_clips(params: Dictionary) -> Dictionary:
	var document = get_document_for_rig(str(params.get("rig_id", "")))
	if document.is_empty():
		return _error("RIG_NOT_FOUND", "骨架不存在。")
	var clips: Array = []
	for clip in document.library.clips:
		clips.append(_clip_summary(clip))
	return _success({"clips": clips})

## 通过稳定骨架和动作标识取得真实文档对象。
func _target(params: Dictionary) -> Dictionary:
	var rig_id = str(params.get("rig_id", ""))
	var document = get_document_for_rig(rig_id)
	if document.is_empty():
		return _error("RIG_NOT_FOUND", "骨架不存在：" + rig_id)
	for index in document.library.clips.size():
		if str(document.library.clips[index].id) == str(params.get("clip_id", "")):
			return {"ok": true, "document": document, "clip": document.library.clips[index], "index": index, "rig_id": rig_id}
	return _error("CLIP_NOT_FOUND", "该骨架下不存在指定动画。")

## 生成不包含全量姿势的动作摘要。
func _clip_summary(clip: Dictionary) -> Dictionary:
	return {"clip_id": str(clip.id), "name": str(clip.name), "rig_id": str(clip.skeleton_id), "skeleton_version": int(clip.skeleton_version), "clip_revision": int(clip.get("revision", 0)), "duration_tick": int(clip.duration_tick), "duration_seconds": float(clip.duration_tick) / 60000.0, "fps": int(clip.fps), "loop": bool(clip.loop), "interpolation": ["hold", "linear", "smooth"][int(clip.interpolation)], "keyframe_count": clip.keyframes.size()}

## 返回关键帧准确时间码，避免按显示秒数重新舍入。
func _key_times(clip: Dictionary) -> Array:
	var result: Array = []
	for key in clip.keyframes:
		result.append({"tick": int(key.tick), "time_seconds": float(key.tick) / 60000.0})
	return result

## 分页读取指定关节的已保存关键帧。
func _get_keyframes(params: Dictionary) -> Dictionary:
	var target = _target(params)
	if not target.ok:
		return target
	var filtered: Array = []
	var minimum = float(params.get("start_seconds", 0))
	var maximum = float(params.get("end_seconds", float(target.clip.duration_tick) / 60000.0))
	var selected: Array = params.get("bone_ids", [])
	for id in selected:
		if not target.clip.joint_ids.has(id):
			return _error("BONE_NOT_FOUND", "关节不存在：" + str(id))
	for key in target.clip.keyframes:
		if float(key.tick) / 60000.0 >= minimum and float(key.tick) / 60000.0 <= maximum:
			filtered.append(key)
	var offset = maxi(0, int(params.get("offset", 0)))
	var limit = clampi(int(params.get("limit", 32)), 1, 64)
	var result: Array = []
	for key in filtered.slice(offset, offset + limit):
		result.append(_key_data(target.clip, key, selected))
	return _success({"clip_id": target.clip.id, "rig_id": target.rig_id, "source": "stored_keyframes", "keyframes": result, "total": filtered.size(), "next_offset": offset + result.size() if offset + result.size() < filtered.size() else null})

## 将完整姿势数组映射为稳定关节标识，不向接口暴露数组编号。
func _key_data(clip: Dictionary, key: Dictionary, selected: Array = []) -> Dictionary:
	var joints: Dictionary = {}
	for index in clip.joint_ids.size():
		if selected.is_empty() or selected.has(clip.joint_ids[index]):
			joints[clip.joint_ids[index]] = key.rotations_deg[index].duplicate()
	return {"tick": int(key.tick), "time_seconds": float(key.tick) / 60000.0, "rotations_deg": joints, "root_m": key.root_m.duplicate()}

## 区分已记录动画的求值姿势与尚未记录的当前编辑姿势。
func _evaluate_pose(params: Dictionary) -> Dictionary:
	var target = _target(params)
	if not target.ok:
		return target
	var source = str(params.get("source", "clip"))
	var sampled: Dictionary
	var tick: int
	if source == "draft":
		if host.active_rig_id != target.rig_id or str(host.active_clip().id) != str(target.clip.id):
			return _error("DRAFT_TARGET_MISMATCH", "临时姿势只属于当前正在编辑的动画。")
		tick = host.current_tick
		sampled = {"pose": host.working_pose.duplicate(), "root": host.working_root}
	elif source == "clip":
		var located = _locate_time(params, int(target.clip.duration_tick))
		if not located.ok:
			return located
		tick = located.tick
		sampled = target.document.library.sample(target.clip, tick)
	else:
		return _error("INVALID_SOURCE", "姿势来源需为 clip 或 draft。")
	var selected: Array = params.get("bone_ids", [])
	for id in selected:
		if not target.clip.joint_ids.has(id):
			return _error("BONE_NOT_FOUND", "关节不存在：" + str(id))
	var transforms: Array = target.document.core.evaluate_transforms(sampled.pose, sampled.root)
	var rotations: Array = target.document.core.local_rotations(sampled.pose)
	var joints: Array = []
	for index in target.clip.joint_ids.size():
		var id = str(target.clip.joint_ids[index])
		if selected.is_empty() or selected.has(id):
			joints.append({"bone_id": id, "local_euler_deg": _vector(sampled.pose[index]), "local_delta_quaternion_xyzw": _quaternion(rotations[index]), "position_m": _vector(transforms[index].position), "rotation_xyzw": _quaternion(transforms[index].rotation)})
	return _success({"rig_id": target.rig_id, "clip_id": target.clip.id, "rig_revision": registry.definitions[target.rig_id].revision, "clip_revision": int(target.clip.get("revision", 0)), "source": source, "dirty": source == "draft" and host.pose_dirty, "tick": tick, "time_seconds": float(tick) / 60000.0, "position_space": "skeleton", "rotation_space": "rest_relative_local", "root_m": _vector(sampled.root), "joints": joints})

## 在已保存关键帧上检查真实关节限制，明确报告检查范围。
func _validate_clip(params: Dictionary) -> Dictionary:
	var target = _target(params)
	if not target.ok:
		return target
	var issues: Array = []
	for key in target.clip.keyframes:
		var pose = target.document.library.key_pose(key)
		var clamped = target.document.core.clamp_pose(pose)
		for index in pose.size():
			if not pose[index].is_equal_approx(clamped[index]) and issues.size() < 64:
				issues.append({"code": "JOINT_LIMIT", "tick": int(key.tick), "bone_id": target.clip.joint_ids[index], "stored_deg": _vector(pose[index]), "limited_deg": _vector(clamped[index])})
	return _success({"clip_id": target.clip.id, "valid": issues.is_empty(), "checks": ["stored_keyframe_rotation_limits"], "issues": issues, "continuous_collision_check": false})

## 秒数与帧定位互斥，帧定位不先四舍五入到两位秒数。
func _locate_time(params: Dictionary, duration_tick: int) -> Dictionary:
	var tick: int
	if params.has("time_seconds"):
		var seconds = params.time_seconds
		if params.has("sample_index") or params.has("sample_rate") or not _finite_number(seconds) or absf(float(seconds) - snappedf(float(seconds), 0.01)) > 0.000001:
			return _error("INVALID_TIME", "秒数需保留两位小数，并与样本定位互斥。")
		tick = roundi(float(seconds) * 60000.0)
	elif params.has("sample_index") and params.has("sample_rate"):
		if not _finite_number(params.sample_index) or not _finite_number(params.sample_rate) or float(params.sample_index) != floorf(float(params.sample_index)) or float(params.sample_rate) != floorf(float(params.sample_rate)) or params.sample_rate < 1 or params.sample_rate > 240:
			return _error("INVALID_TIME", "样本索引和采样率需为整数，采样率范围为 1 至 240。")
		tick = roundi(float(params.sample_index) * 60000.0 / float(params.sample_rate))
	else:
		return _error("INVALID_TIME", "需要 time_seconds，或 sample_index 与 sample_rate。")
	return {"ok": true, "tick": tick} if tick >= 0 and tick <= duration_tick else _error("TIME_OUT_OF_RANGE", "定位时间超出动画范围。")

## 统一附带可供后续写入核对的实例、文档和修订信息。
func _success(payload: Dictionary = {}) -> Dictionary:
	var result = {"ok": true, "api_version": API_VERSION, "instance_id": instance_id, "document_id": document_id, "revision": revision}
	result.merge(payload, true)
	return result

## 统一提供可纠正的结构化错误，不用成功文字掩盖失败。
func _error(code: String, message: String, details: Dictionary = {}) -> Dictionary:
	var result = _success()
	result.ok = false
	result.error = {"code": code, "message": message, "details": details}
	return result

## 校验有限标量，防止错误向量污染求解器。
func _finite_number(value) -> bool:
	return (value is int or value is float) and is_finite(float(value))

## 将向量转换成跨进程数值数组。
func _vector(value: Vector3) -> Array:
	return [value.x, value.y, value.z]

## 将旋转转换成明确为 XYZW 顺序的四元数数组。
func _quaternion(value: Quaternion) -> Array:
	return [value.x, value.y, value.z, value.w]

## 写入先核对实例内请求记录，再核对文档版本，重复投递不会重复修改。
func _check_write_request(method: String, params: Dictionary) -> Dictionary:
	var id = str(params.get("request_id", ""))
	if id.is_empty() or id.length() > 128:
		return _error("INVALID_REQUEST_ID", "写入需要不超过 128 字符的 request_id。")
	if completed_requests.has(id):
		if completed_requests[id].digest != _request_digest(method, params):
			return _error("REQUEST_ID_CONFLICT", "同一请求编号不能用于不同内容。")
		var replay: Dictionary = completed_requests[id].result.duplicate(true)
		replay.replayed = true
		replay.current_revision = revision
		return replay
	if str(params.get("document_id", "")) != document_id:
		return _error("DOCUMENT_MISMATCH", "请先读取当前实例的 document_id。")
	if not _finite_number(params.get("expected_revision")) or float(params.expected_revision) != revision:
		return _error("REVISION_CONFLICT", "文档已变化，请重新读取后再提交。", {"current_revision": revision})
	if host.pose_dirty and method not in BindingCommandsScript.WRITES and not (method == "save_clip" and params.get("include_draft", false)):
		return _error("UNRECORDED_POSE", "当前界面有未记录姿势，请先显式保存草稿或由用户处理。")
	return {}

## 使用排序后的规范 JSON 识别同一请求。
func _request_digest(method: String, params: Dictionary) -> String:
	return (method + JSON.stringify(params, "", true)).sha256_text()

## 只保留有界的成功结果，方便连接中断后的安全重试。
func _remember_request(method: String, params: Dictionary, result: Dictionary) -> void:
	var id = str(params.request_id)
	var entry = {"digest": _request_digest(method, params), "result": result.duplicate(true), "bytes": JSON.stringify(result).to_utf8_buffer().size()}
	completed_requests[id] = entry
	request_order.append(id)
	request_bytes += int(entry.bytes)
	while request_order.size() > 256 or request_bytes > 16777216:
		var oldest = request_order.pop_front()
		request_bytes -= int(completed_requests[oldest].bytes)
		completed_requests.erase(oldest)

## 校验时长输入的范围与显示精度。
func _duration_tick(value) -> int:
	if not _finite_number(value) or value < 0.1 or value > 600 or absf(float(value) - snappedf(float(value), 0.01)) > 0.000001:
		return -1
	return roundi(float(value) * 60000.0)

## 校验动作属性，所有候选变更在持久化前完成。
func _apply_options(candidate: Dictionary, options: Dictionary) -> Dictionary:
	if options.has("name"):
		if not options.name is String or options.name.strip_edges().is_empty() or options.name.length() > 96:
			return _error("INVALID_NAME", "动画名称需要 1 至 96 个字符。")
		candidate.name = options.name.strip_edges()
	if options.has("fps"):
		if not _finite_number(options.fps) or options.fps != floorf(options.fps) or options.fps < 1 or options.fps > 240:
			return _error("INVALID_FPS", "采样帧率需为 1 至 240 的整数。")
		candidate.fps = int(options.fps)
	if options.has("interpolation"):
		var index = ["hold", "linear", "smooth"].find(options.interpolation)
		if index < 0:
			return _error("INVALID_INTERPOLATION", "插值需为 hold、linear 或 smooth。")
		candidate.interpolation = index
	if options.has("loop"):
		if not options.loop is bool:
			return _error("INVALID_LOOP", "loop 需为布尔值。")
		candidate.loop = options.loop
	return {"ok": true}

## 创建指定骨架的动画并直接保存，创建资产不进入姿势撤销历史。
func _create_clip(params: Dictionary) -> Dictionary:
	var document = get_document_for_rig(str(params.get("rig_id", "")))
	if document.is_empty():
		return _error("RIG_NOT_FOUND", "骨架不存在。")
	var tick = _duration_tick(params.get("duration_seconds", 2.0))
	if tick < 0:
		return _error("INVALID_DURATION", "时长需为 0.10 至 600.00 秒，保留两位小数。")
	var options = {"name": params.get("name", "新动画"), "fps": 30, "loop": true, "interpolation": 2}
	var checked = _apply_options(options, params)
	if not checked.ok:
		return checked
	var clip: Dictionary = document.library.create_clip(options.name, float(tick) / 60000.0, options)
	if clip.is_empty():
		return _error("SAVE_FAILED", document.library.last_error)
	host.activate_mcp_clip(str(params.rig_id), str(clip.id))
	return _success({"clip": _clip_summary(clip), "persisted": true, "undoable": false})

## 对候选动作执行一组命令，成功后仅保存一次并生成一条撤销事务。
func _apply_edit_batch(params: Dictionary) -> Dictionary:
	var target = _target(params)
	if not target.ok:
		return target
	var edits = params.get("commands", [])
	if not edits is Array or edits.is_empty() or edits.size() > 128:
		return _error("INVALID_BATCH", "每批需要 1 至 128 条命令。")
	var candidate: Dictionary = target.clip.duplicate(true)
	var adjustments: Array = []
	for index in edits.size():
		if not edits[index] is Dictionary:
			return _error("INVALID_COMMAND", "命令必须是对象。", {"command_index": index})
		var checked = _edit_candidate(candidate, target.document, edits[index], adjustments)
		if not checked.ok:
			checked.error.details.command_index = index
			return checked
	if candidate.keyframes.size() > 10000 or not target.document.library._is_valid_clip(candidate):
		return _error("INVALID_CLIP", "候选动画数据无效或关键帧超过一万个。")
	host.activate_mcp_clip(target.rig_id, str(target.clip.id))
	host._push_undo()
	var transaction = "edit_" + Crypto.new().generate_random_bytes(12).hex_encode()
	host.undo_stack[-1].transaction_id = transaction
	if not target.document.library.save_clip(candidate):
		host.undo_stack.pop_back()
		return _error("SAVE_FAILED", target.document.library.last_error)
	target.document.library.clips[target.index] = candidate
	host.refresh_after_mcp()
	return _success({"clip": _clip_summary(candidate), "transaction_id": transaction, "persisted": true, "key_times": _key_times(candidate), "limit_adjustments": adjustments})

## 在副本上执行单条编辑，不改动场景或磁盘。
func _edit_candidate(clip: Dictionary, document: Dictionary, command: Dictionary, adjustments: Array) -> Dictionary:
	var library = document.library
	match str(command.get("op", "")):
		"set_duration":
			var duration = _duration_tick(command.get("duration_seconds"))
			if duration < 0:
				return _error("INVALID_DURATION", "时长需为 0.10 至 600.00 秒，保留两位小数。")
			var mode = str(command.get("mode", "preserve_key_times"))
			if mode == "scale_key_times":
				var used: Dictionary = {}
				for key in clip.keyframes:
					key.tick = roundi(float(key.tick) * duration / float(clip.duration_tick))
					if used.has(int(key.tick)):
						return _error("KEY_TIME_COLLISION", "缩放后关键帧重叠。")
					used[int(key.tick)] = true
			elif mode == "preserve_key_times":
				if int(clip.keyframes[-1].tick) > duration:
					return _error("KEY_OUT_OF_RANGE", "缩短时长会截断关键帧，请先移动关键帧或选择 scale_key_times。")
			else:
				return _error("INVALID_DURATION_MODE", "未知时长调整方式。")
			clip.duration_tick = duration
		"set_clip_options":
			return _apply_options(clip, command)
		"upsert_keyframe", "solve_ik":
			var located = _locate_time(command, int(clip.duration_tick))
			if not located.ok:
				return located
			var sampled: Dictionary = library.sample(clip, located.tick)
			if command.op == "solve_ik":
				var joint = clip.joint_ids.find(str(command.get("bone_id", "")))
				if joint < 0 or not registry.numeric_vector(command.get("target_m"), 3):
					return _error("INVALID_IK", "IK 需要有效关节和骨架空间目标坐标。")
				var length = int(command.get("chain_length", library.rig[joint].ik_chain_length))
				if length < 1 or length > 32:
					return _error("INVALID_IK", "IK 链长需为 1 至 32。")
				sampled.pose = document.core.solve_ik(sampled.pose, joint, registry.to_vector(command.target_m), sampled.root, length)
				var actual: Vector3 = document.core.evaluate_positions(sampled.pose, sampled.root)[joint]
				adjustments.append({"bone_id": command.bone_id, "tick": located.tick, "ik_actual_m": _vector(actual), "target_error_m": actual.distance_to(registry.to_vector(command.target_m))})
			else:
				var rotations = command.get("rotations_deg", {})
				if not rotations is Dictionary:
					return _error("INVALID_ROTATIONS", "rotations_deg 需要关节 ID 到三轴角度的对象。")
				for id in rotations:
					var joint = clip.joint_ids.find(id)
					if joint < 0:
						return _error("BONE_NOT_FOUND", "关节不存在：" + str(id))
					if not registry.numeric_vector(rotations[id], 3):
						return _error("INVALID_ROTATIONS", "关节角度需要三个有限数值。")
					sampled.pose[joint] = registry.to_vector(rotations[id])
				var policy = str(command.get("limit_policy", "reject"))
				if policy not in ["reject", "clamp"]:
					return _error("INVALID_LIMIT_POLICY", "限制策略需为 reject 或 clamp。")
				var limited = document.core.clamp_pose(sampled.pose)
				for joint in sampled.pose.size():
					if not sampled.pose[joint].is_equal_approx(limited[joint]):
						if policy == "reject":
							return _error("JOINT_LIMIT", "角度超出旋转限制。", {"bone_id": clip.joint_ids[joint], "requested_deg": _vector(sampled.pose[joint]), "limited_deg": _vector(limited[joint])})
						adjustments.append({"bone_id": clip.joint_ids[joint], "tick": located.tick, "requested_deg": _vector(sampled.pose[joint]), "actual_deg": _vector(limited[joint])})
				sampled.pose = limited
			if command.has("root_m"):
				if not registry.numeric_vector(command.root_m, 3):
					return _error("INVALID_ROOT", "根位移需要三个有限的米制数值。")
				sampled.root = registry.to_vector(command.root_m)
			library.upsert_key(clip, located.tick, sampled.pose, sampled.root)
		"delete_keyframe":
			var located = _locate_time(command, int(clip.duration_tick))
			if not located.ok:
				return located
			var index = library.find_key(clip, located.tick)
			if index < 0 or clip.keyframes.size() <= 1:
				return _error("KEY_NOT_FOUND", "关键帧不存在，或正在删除最后一帧。")
			clip.keyframes.remove_at(index)
		"move_keyframe":
			var from = _locate_time(command.get("from", {}), int(clip.duration_tick))
			var to = _locate_time(command.get("to", {}), int(clip.duration_tick))
			if not from.ok:
				return from
			if not to.ok:
				return to
			var index = library.find_key(clip, from.tick)
			if index < 0 or (from.tick != to.tick and library.find_key(clip, to.tick) >= 0):
				return _error("KEY_TIME_COLLISION", "源关键帧不存在或目标时刻已有关键帧。")
			clip.keyframes[index].tick = to.tick
			clip.keyframes.sort_custom(func(a, b): return int(a.tick) < int(b.tick))
		_:
			return _error("INVALID_COMMAND", "未支持的编辑命令：" + str(command.get("op", "")))
	return {"ok": true}

## 显式记录当前草稿，或者重新保存已记录的动作。
func _save_clip(params: Dictionary) -> Dictionary:
	var target = _target(params)
	if not target.ok:
		return target
	var candidate: Dictionary = target.clip.duplicate(true)
	var transaction = ""
	if params.get("include_draft", false):
		if host.active_rig_id != target.rig_id or str(host.active_clip().id) != str(candidate.id):
			return _error("DRAFT_TARGET_MISMATCH", "不能将其他动画的草稿写入该动作。")
		if host.pose_dirty:
			host._push_undo()
			transaction = "draft_" + Crypto.new().generate_random_bytes(12).hex_encode()
			host.undo_stack[-1].transaction_id = transaction
			target.document.library.upsert_key(candidate, host.current_tick, host.working_pose, host.working_root)
	if not target.document.library.save_clip(candidate):
		if not transaction.is_empty():
			host.undo_stack.pop_back()
		return _error("SAVE_FAILED", target.document.library.last_error)
	target.document.library.clips[target.index] = candidate
	if host.active_rig_id == target.rig_id and str(host.active_clip().id) == str(candidate.id):
		host.refresh_after_mcp()
	return _success({"clip": _clip_summary(candidate), "persisted": true, "transaction_id": transaction})

## 只撤销指定的最近 MCP 事务，避免越过用户刚完成的手动修改。
func _undo_redo(params: Dictionary, redo: bool) -> Dictionary:
	var target = _target(params)
	if not target.ok:
		return target
	if host.active_rig_id != target.rig_id or str(host.active_clip().id) != str(target.clip.id):
		return _error("HISTORY_TARGET_MISMATCH", "撤销历史属于当前打开的动画。")
	var stack: Array = host.redo_stack if redo else host.undo_stack
	if stack.is_empty() or str(stack[-1].get("transaction_id", "")) != str(params.get("transaction_id", "")) or str(params.get("transaction_id", "")).is_empty():
		return _error("HISTORY_CONFLICT", "指定事务不是最近可撤销或重做的操作。")
	var restored: bool = host._redo() if redo else host._undo()
	if not restored:
		return _error("SAVE_FAILED", "恢复事务失败，保留原文档。")
	return _success({"clip": _clip_summary(host.active_clip()), "transaction_id": params.transaction_id, "action": "redo" if redo else "undo", "persisted": true})

## 注册新骨架体系，层级与手脚细分关节均由定义提供。
func _register_rig(params: Dictionary) -> Dictionary:
	if not params.get("definition") is Dictionary:
		return _error("INVALID_RIG", "需要完整骨架定义。")
	var registered = registry.register_definition(params.definition)
	if not registered.ok:
		return _error("INVALID_RIG", registered.error)
	revision += 1
	host.refresh_rig_selector()
	return _success({"rig": registry.get_definition(registered.rig_id), "persisted": true, "undoable": false})

## 约束修改先检查该骨架的全部动画，不允许新限制静默截断已有关键帧。
func _update_joint_limits(params: Dictionary) -> Dictionary:
	var rig_id = str(params.get("rig_id", ""))
	var changes = params.get("changes", [])
	if not changes is Array or changes.is_empty() or changes.size() > 512:
		return _error("INVALID_LIMITS", "需要 1 至 512 条关节限制修改。")
	var checked = registry.preview_limits(rig_id, changes)
	if not checked.ok:
		return _error("INVALID_LIMITS", checked.error)
	var candidate: Dictionary = checked.definition
	var document = get_document_for_rig(rig_id)
	var temporary = ClassDB.instantiate("PuppetAnimator")
	if not temporary.configure_rig(registry.native_from_definition(candidate)):
		return _error("INVALID_LIMITS", "原生求解器拒绝该骨架限制。")
	for clip in document.library.clips:
		for key in clip.keyframes:
			var pose = document.library.key_pose(key)
			var limited = temporary.clamp_pose(pose)
			for index in pose.size():
				if not pose[index].is_equal_approx(limited[index]):
					return _error("LIMITS_INVALIDATE_CLIP", "新限制会改变已有关键帧，请先编辑动作。", {"clip_id": clip.id, "tick": key.tick, "bone_id": clip.joint_ids[index]})
	if host.active_rig_id != rig_id:
		return _error("RIG_NOT_ACTIVE", "修改约束前请打开该骨架的动画，以关联撤销记录。")
	var previous = registry.get_definition(rig_id)
	var saved = registry.persist_definition(candidate)
	if not saved.ok:
		return _error("SAVE_FAILED", saved.error)
	host._push_undo()
	var transaction = "limits_" + Crypto.new().generate_random_bytes(12).hex_encode()
	host.undo_stack[-1].transaction_id = transaction
	host.undo_stack[-1].rig_definition = previous
	registry.definitions[rig_id] = candidate
	document.core.configure_rig(registry.native_definition(rig_id))
	revision += 1
	host.refresh_rig_constraints()
	return _success({"rig_id": rig_id, "rig_revision": candidate.revision, "transaction_id": transaction, "persisted": true})

## 撤销约束时恢复内容并生成新的修订号，拓扑标识仍保持稳定。
func restore_rig_definition(definition: Dictionary) -> bool:
	var candidate = definition.duplicate(true)
	candidate.revision = int(registry.definitions[candidate.id].revision) + 1
	var saved = registry.persist_definition(candidate)
	if not saved.ok:
		return false
	registry.definitions[candidate.id] = candidate
	get_document_for_rig(candidate.id).core.configure_rig(registry.native_definition(candidate.id))
	revision += 1
	host.refresh_rig_constraints()
	return true

## 切换预览时间前检查草稿，定位成功后返回真实编辑器状态。
func _seek_animation(params: Dictionary) -> Dictionary:
	var target = _target(params)
	if not target.ok:
		return target
	if host.pose_dirty:
		return _error("UNRECORDED_POSE", "请先记录当前临时姿势。")
	var located = _locate_time(params, int(target.clip.duration_tick))
	if not located.ok:
		return located
	host.activate_mcp_clip(target.rig_id, str(target.clip.id))
	host._seek(located.tick)
	return _document_state()

## 播放和暂停只改变预览状态，重复开始不会重置正在播放的时间。
func _set_playback(params: Dictionary) -> Dictionary:
	var target = _target(params)
	if not target.ok:
		return target
	if not params.get("playing") is bool:
		return _error("INVALID_PLAYBACK", "playing 必须为布尔值。")
	if params.playing:
		if host.pose_dirty:
			return _error("UNRECORDED_POSE", "开始播放前请先记录或处理临时姿势。")
		host.activate_mcp_clip(target.rig_id, str(target.clip.id))
		if not host.playing:
			host._start_playback()
	else:
		if host.active_rig_id != target.rig_id or str(host.active_clip().id) != str(target.clip.id):
			return _error("PLAYBACK_TARGET_MISMATCH", "暂停目标必须是当前打开的动画。")
		host._stop_playback()
	return _document_state()

## 截图使用独立的骨架、动画和视角快照，异步渲染期间仍可操作主界面。
func _render_preview(params: Dictionary) -> Dictionary:
	var target = _target(params)
	if not target.ok:
		return target
	if DisplayServer.get_name() == "headless":
		return _error("RENDERING_UNAVAILABLE", "无图形模式可读取数据，截图需要正常图形模式启动软件。")
	var frames = params.get("frames", [])
	if not frames is Array or frames.is_empty() or frames.size() > 12:
		return _error("INVALID_PREVIEW", "每次截图需要 1 至 12 个时间与视角组合。")
	var samples: Array = []
	for frame in frames:
		if not frame is Dictionary:
			return _error("INVALID_PREVIEW", "截图帧需要对象。")
		var located = _locate_time(frame, int(target.clip.duration_tick))
		if not located.ok:
			return located
		samples.append({"tick": located.tick, "view": frame.get("view", {"preset": "perspective", "frame_all": true})})
	var width = int(params.get("width", 768))
	var height = int(params.get("height", 768))
	if width < 256 or width > 2048 or height < 256 or height > 2048:
		return _error("INVALID_PREVIEW", "截图宽高需为 256 至 2048 像素。")
	var snapshot_revision = revision
	var snapshot_clip_revision = int(target.clip.get("revision", 0))
	var rendered: Dictionary = await preview_renderer.render(registry.get_definition(target.rig_id), target.clip.duplicate(true), samples, width, height)
	if not rendered.ok:
		return _error("INVALID_PREVIEW", rendered.error)
	return _success({"rig_id": target.rig_id, "clip_id": target.clip.id, "clip_revision": snapshot_clip_revision, "snapshot_revision": snapshot_revision, "source": "stored_clip", "images": rendered.images})
