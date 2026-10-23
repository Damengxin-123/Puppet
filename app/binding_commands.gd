extends RefCounted
## 绑定 MCP 命令与独立截图服务，手动界面和 AI 共用同一份项目。

## 绑定视口用于任意角度的离屏截图。
const ViewScript = preload("res://app/binding_view.gd")
## 实际实现的绑定工具。
const TOOLS = ["list_binding_projects", "get_binding_project", "create_binding_project", "open_binding_project", "move_binding_joint", "set_binding_bone_length", "update_binding_project", "save_binding_project", "undo_binding_edit", "redo_binding_edit", "preview_binding_animation", "stop_binding_preview", "evaluate_binding_pose", "set_binding_view", "render_binding_preview", "get_binding_weights", "set_binding_weight_view", "edit_binding_weights", "reset_binding_weights", "recalculate_binding_weights"]
## 需要乐观并发和幂等标识的持久写入。
const WRITES = ["create_binding_project", "open_binding_project", "move_binding_joint", "set_binding_bone_length", "update_binding_project", "save_binding_project", "undo_binding_edit", "redo_binding_edit", "edit_binding_weights", "reset_binding_weights", "recalculate_binding_weights"]
## 文档服务弱引用，避免双方持有造成项目资源无法释放。
var commands_reference: WeakRef
## 随用随取的共享文档服务。
var commands:
	get:
		return commands_reference.get_ref()
## 主界面。
var host
## 绑定项目服务。
var binding

## 绑定宿主和共享文档服务。
func initialize(owner_node, command_service) -> void:
	host = owner_node
	commands_reference = weakref(command_service)
	binding = host.binding_service

## 校验当前项目目标后分派绑定操作。
func execute(method: String, params: Dictionary) -> Dictionary:
	if method == "list_binding_projects":
		return commands._success({"projects": binding.list_projects()})
	if not binding.drag_snapshot.is_empty():
		return commands._error("BINDING_DRAG_ACTIVE", "用户正在拖动绑定关节，请在松开后重新读取项目。")
	if method not in ["create_binding_project", "open_binding_project"]:
		if binding.project.is_empty():
			return commands._error("NO_BINDING_PROJECT", "请先创建或打开绑定项目。")
		if str(params.get("project_id", "")) != str(binding.project.id):
			return commands._error("BINDING_PROJECT_MISMATCH", "当前绑定项目已改变，请重新打开目标项目。")
	var result: Dictionary
	match method:
		"get_binding_weights":
			result = binding.query_weights(params)
		"set_binding_weight_view":
			result = _weight_view(params)
		"edit_binding_weights":
			result = binding.edit_weights(params)
		"reset_binding_weights":
			result = binding.reset_weights(params)
		"recalculate_binding_weights":
			result = binding.recalculate_weights()
		"get_binding_project":
			return commands._success({"project": binding.get_state(), "view": host.binding_page.view.get_camera_state(), "preview": _preview_state(), "weight_view": {"bone_id": host.binding_page.view.weight_bone_id, "selected_vertices": host.binding_page.weight_panel.selection.size(), "editing": host.binding_page.view.weight_edit_mode}})
		"create_binding_project":
			result = binding.create_project(str(params.get("model_path", "")), str(params.get("name", "")), str(params.get("rig_id", "")))
		"open_binding_project":
			result = binding.open_project(str(params.get("project_id", "")))
		"move_binding_joint":
			if not params.get("position_m") is Array:
				return commands._error("INVALID_POSITION", "坐标需要三轴数组。")
			result = binding.move_joint(str(params.get("bone_id", "")), params.position_m, bool(params.get("move_children", false)))
		"set_binding_bone_length":
			result = binding.set_length(str(params.get("bone_id", "")), float(params.get("length_m", 0)))
		"update_binding_project":
			result = binding.update_options(str(params.get("name", binding.project.name)), str(params.get("skin_mode", binding.project.skin_mode)), float(params.get("yaw_delta_deg", 0.0)))
		"save_binding_project":
			result = binding.save()
		"undo_binding_edit", "redo_binding_edit":
			result = binding.undo(method == "redo_binding_edit")
		"preview_binding_animation":
			result = host.binding_page.preview_animation(str(params.get("clip_id", "")), float(params.get("time_seconds", 0)), bool(params.get("playing", false)))
			if result.ok:
				host._show_page(1)
				result.preview = _preview_state()
		"stop_binding_preview":
			host.binding_page.stop_preview()
			result = {"ok": true, "preview": _preview_state()}
		"evaluate_binding_pose":
			return _evaluate(params)
		"set_binding_view":
			result = host.binding_page.view.configure_camera(params.get("view", {}))
			if result.ok:
				result.view = host.binding_page.view.get_camera_state()
		"render_binding_preview":
			return await _render(params)
	if not result.get("ok", false):
		return commands._error("BINDING_OPERATION_FAILED", str(result.get("error", "绑定操作失败。")))
	if method in ["create_binding_project", "open_binding_project"]:
		host._show_page(1)
		host.binding_page._camera_preset(0)
	return commands._success(result)

## 返回与动画编辑区分离的播放状态。
func _preview_state() -> Dictionary:
	var page = host.binding_page
	return {"active": page.view.previewing, "playing": page.playing, "clip_id": str(page.preview_clip.get("id", "")), "time_seconds": page.seconds, "read_only": true}

## 按只读动画或零旋转参考姿态取样。
func _sample(params: Dictionary) -> Dictionary:
	var pose = PackedVector3Array()
	pose.resize(binding.bones.size())
	if str(params.get("clip_id", "")).is_empty():
		return {"ok": true, "pose": pose, "root": Vector3.ZERO, "tick": 0, "clip_revision": 0}
	var document: Dictionary = commands.get_document_for_rig(binding.project.rig_id)
	for clip in document.library.clips:
		if clip.id == params.clip_id:
			var time: Dictionary = commands._locate_time({"time_seconds": params.get("time_seconds", 0.0)}, int(clip.duration_tick))
			if not time.ok:
				return time
			var result: Dictionary = document.library.sample(clip, int(time.tick))
			result.root = binding.adapt_root_motion(result.root)
			result.ok = true
			result.tick = time.tick
			result.clip_revision = clip.get("revision", 0)
			return result
	return commands._error("CLIP_NOT_FOUND", "当前项目源骨架下不存在该动画。")

## 回读按项目骨长求值的真实关节位置，便于 AI 检查绑定结果。
func _evaluate(params: Dictionary) -> Dictionary:
	var sample = _sample(params)
	if not sample.ok:
		return sample
	var transforms: Array = binding.core.evaluate_transforms(sample.pose, sample.root) if str(params.get("clip_id", "")).is_empty() else binding.evaluate_animation(sample.pose, sample.root)
	var joints: Array = []
	for index in transforms.size():
		joints.append({"bone_id": binding.bones[index].id, "position_m": commands._vector(transforms[index].position), "rotation_xyzw": commands._quaternion(transforms[index].rotation)})
	return commands._success({"project_id": binding.project.id, "project_revision": binding.project.revision, "tick": sample.tick, "joints": joints, "source_mesh_unchanged": true})

## 在独立世界输出真实角色 PNG、摄像机参数与关节屏幕坐标。
func _render(params: Dictionary) -> Dictionary:
	if DisplayServer.get_name() == "headless":
		return commands._error("RENDER_UNAVAILABLE", "无图形渲染器的实例无法截图，请连接桌面实例。")
	var sample = _sample(params)
	if not sample.ok:
		return sample
	var width = int(params.get("width", 960))
	var height = int(params.get("height", 960))
	if width < 256 or width > 2048 or height < 256 or height > 2048:
		return commands._error("INVALID_RESOLUTION", "截图尺寸需要在 256 至 2048 像素之间。")
	var view = ViewScript.new()
	view.position = Vector2(-20000, -20000)
	view.mouse_filter = Control.MOUSE_FILTER_IGNORE
	host.add_child(view)
	view.stretch = false
	view.size = Vector2(width, height)
	view.render_view.size = Vector2i(width, height)
	view.set_binding(binding)
	view.overlay.visible = false
	view.show_core = bool(params.get("show_bones", true))
	if not str(params.get("clip_id", "")).is_empty():
		view.begin_preview()
	view.set_pose(sample.pose, sample.root)
	var weight_bone_id = str(params.get("weight_bone_id", ""))
	if not weight_bone_id.is_empty() and binding.bone_index(weight_bone_id) < 0:
		view.queue_free()
		return commands._error("INVALID_BONE", "热图骨骼不存在。")
	view.set_weight_display(weight_bone_id)
	var options: Dictionary = {"preset": "perspective", "frame_all": true}
	options.merge(params.get("view", {}), true)
	var configured: Dictionary = view.configure_camera(options)
	if not configured.ok:
		view.queue_free()
		return commands._error("INVALID_VIEW", configured.error)
	var result = commands._success({"project_id": binding.project.id, "project_revision": binding.project.revision, "clip_revision": sample.clip_revision, "weight_bone_id": weight_bone_id, "weight_legend": {"blue": 0.0, "red": 1.0}})
	var projected: Array = []
	for index in binding.bones.size():
		var point: Vector2 = view.camera.unproject_position(view.positions[index])
		projected.append({"bone_id": binding.bones[index].id, "pixel": [point.x, point.y], "position_m": commands._vector(view.positions[index]), "behind_camera": view.camera.is_position_behind(view.positions[index])})
	await host.get_tree().process_frame
	await RenderingServer.frame_post_draw
	var image: Image = view.render_view.get_texture().get_image()
	if image == null or image.is_empty():
		view.queue_free()
		return commands._error("RENDER_FAILED", "渲染器未返回图片。")
	result.images = [{"data": Marshalls.raw_to_base64(image.save_png_to_buffer()), "mimeType": "image/png", "width": width, "height": height, "tick": sample.tick, "time_seconds": float(sample.tick) / 60000.0, "view": view.get_camera_state(), "projected_joints": projected}]
	view.queue_free()
	return result

## 控制当前权重热图和表面选区，读取工具不写入项目或改变关节。
func _weight_view(params: Dictionary) -> Dictionary:
	var page = host.binding_page
	var panel = page.weight_panel
	var bone_id = str(params.get("bone_id", ""))
	var bone = binding.bone_index(bone_id)
	if not bone_id.is_empty() and bone < 0:
		return {"ok": false, "error": "热图骨骼不存在。"}
	var selected: Array = []
	if params.has("vertex_ids") or params.has("seed_vertex_id"):
		var selection: Dictionary = binding.weight_selection(params)
		if not selection.ok:
			return selection
		selected = selection.vertex_ids
	page.details_tabs.set_current_tab(1 if not bone_id.is_empty() or bool(params.get("editing", false)) else 0)
	panel.selection = selected
	panel.seed_id = str(params.get("seed_vertex_id", selected[0] if not selected.is_empty() else ""))
	panel.heat_toggle.set_pressed_no_signal(not bone_id.is_empty())
	panel.edit_toggle.set_pressed_no_signal(bool(params.get("editing", false)))
	page.view.weight_edit_mode = panel.edit_toggle.button_pressed
	if bone >= 0:
		page.view.select_joint(bone)
	panel.update_bone()
	page.view.set_weight_display(bone_id, selected)
	host._show_page(1)
	return {"ok": true, "bone_id": bone_id, "selected_vertex_count": selected.size(), "seed_vertex_id": panel.seed_id, "legend": {"blue": 0.0, "red": 1.0, "selection": "white_tint"}}
