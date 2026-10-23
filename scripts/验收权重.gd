extends SceneTree
## 用当前角色的副本检查权重、保存、MCP 与渲染，不覆盖用户调好的关节。

## 实际检查报告。
var report: Dictionary = {}

## 在主循环就绪后开始。
func _initialize() -> void:
	call_deferred("_run")

## 失败时立即结束，避免断言停住后台进程。
func check(condition: bool, message: String) -> bool:
	if not condition:
		push_error(message)
		quit(1)
	return condition

## 运行一次真实角色回归，输出可视结果和关键数值。
func _run() -> void:
	var scene = load("res://app/主界面.tscn").instantiate()
	root.add_child(scene)
	await process_frame
	var service = scene.binding_service
	var id = "binding_e7dcb8f658c34b2ef559209a"
	if not check(service.open_project(id).ok, "打开测试项目副本"):
		return
	var original_rig = JSON.stringify(service.project.rig)
	var original_hash = FileAccess.get_sha256("res://workspace/bindings/" + id + "/项目.json")
	var started = Time.get_ticks_msec()
	var engine = service.get_weight_engine()
	report.calculation_seconds = (Time.get_ticks_msec() - started) / 1000.0
	var weights: Array = service.get_weights()
	var max_error = 0.0
	var coat_arm_max = 0.0
	var coat_count = 0
	var dump: Array = []
	for index in weights.size():
		var total = 0.0
		var arm = 0.0
		for bone in weights[index]:
			total += weights[index][bone]
			if engine._arm(bone):
				arm += weights[index][bone]
		max_error = maxf(max_error, absf(total - 1))
		var point: Vector3 = engine.points[engine.welds[index]]
		if point.y > 0.34 and point.y < 0.57 and absf(point.z) < 0.16 and point.x < -0.045:
			coat_count += 1
			coat_arm_max = maxf(coat_arm_max, arm)
		var named: Dictionary = {}
		for bone in weights[index]:
			named[service.bones[bone].id] = weights[index][bone]
		dump.append({"id": engine.ids[index], "position": service._array(point), "weights": named})
	report.weight_error = max_error
	report.coat_vertices = coat_count
	report.coat_arm_max = coat_arm_max
	if not check(max_error < 0.00001, "权重归一化"):
		return
	if not check(coat_count > 100 and coat_arm_max < 0.01, "外套下摆不再受手臂影响"):
		return
	var output = ProjectSettings.globalize_path("res://build/verification/weights")
	var file = FileAccess.open(output.path_join("权重.json"), FileAccess.WRITE)
	file.store_string(JSON.stringify(dump))
	file.close()
	var page = scene.binding_page
	report.default_selection_radius_m = page.weight_panel.radius.value
	report.default_weight_value = page.weight_panel.amount.value
	scene._show_page(1)
	var clip = "clip_1792655871_693_564769"
	if not check(page.preview_animation(clip, 0.31, false).ok, "奔跑只读预览"):
		return
	if DisplayServer.get_name() != "headless":
		for item in [{"name": "奔跑_0.31", "time_seconds": 0.31}, {"name": "奔跑_0.18", "time_seconds": 0.18}, {"name": "衣物修正近景", "time_seconds": 0.31, "close": true}, {"name": "右前臂权重", "weight_bone_id": "forearm_r"}]:
			var params = {"project_id": id, "width": 1000, "height": 1100, "view": {"yaw_deg": 90.0, "pitch_deg": 8.0, "frame_all": true}}
			if item.has("time_seconds"):
				params.clip_id = clip
				params.time_seconds = item.time_seconds
			else:
				params.weight_bone_id = item.weight_bone_id
			if item.has("close"):
				params.view = {"yaw_deg": 90.0, "pitch_deg": 8.0, "target_m": [0, 0.64, 0], "distance_m": 1.05}
			var image: Dictionary = await scene.commands.execute("render_binding_preview", params)
			if not check(image.ok, "实际截图"):
				return
			file = FileAccess.open(output.path_join(item.name + ".png"), FileAccess.WRITE)
			file.store_buffer(Marshalls.base64_to_raw(image.images[0].data))
			file.close()
		page.view.configure_camera({"yaw_deg": 90.0, "pitch_deg": 8.0, "target_m": [0, 0.53, 0], "distance_m": 1.7})
		# 用当前变形表面的可见顶点投影验证拾取，确保不是屏幕后面的关节被选中。
		var deformed: Array = page.view._weight_positions()
		var pick = page.view.pick_weight_vertex(page.view.camera.unproject_position(deformed[0][100]))
		if not check(not pick.is_empty(), "动画姿态表面拾取"):
			return
		page.details_tabs.current_tab = 1
		page.view.select_joint(service.bone_index("forearm_r"))
		page.weight_panel._picked(pick)
		await process_frame
		await RenderingServer.frame_post_draw
		root.get_texture().get_image().save_png(output.path_join("权重编辑界面.png"))
	var selected: Dictionary = service.weight_selection({"seed_vertex_id": "0:0:100", "radius_m": 0.03})
	if not check(selected.ok and not selected.vertex_ids.is_empty(), "沿表面选区"):
		return
	var params = {"project_id": id, "document_id": scene.commands.document_id, "expected_revision": scene.commands.revision, "request_id": "weight_edit_test", "vertex_ids": selected.vertex_ids, "operation": "set", "bone_id": "pelvis", "value": 1.0}
	var edited: Dictionary = await scene.commands.execute("edit_binding_weights", params)
	if not check(edited.ok and page.view.previewing and absf(page.seconds - 0.31) < 0.001, "MCP 修改后保持动画观察时刻"):
		return
	var repeated: Dictionary = await scene.commands.execute("edit_binding_weights", params)
	if not check(repeated.ok and repeated.get("replayed", false) and repeated.project.revision == edited.project.revision, "MCP 请求幂等"):
		return
	var query: Dictionary = await scene.commands.execute("get_binding_weights", {"project_id": id, "vertex_ids": [selected.vertex_ids[0]]})
	if not check(query.ok and query.vertices[0].weights.get("pelvis", 0) == 1.0, "MCP 回读实际手工权重"):
		return
	var manual = service.project.weight_overrides.duplicate(true)
	if not check(service.undo().ok and service.project.get("weight_overrides", {}).is_empty() and service.undo(true).ok and service.project.weight_overrides == manual, "权重撤销重做"):
		return
	if not check(service.recalculate_weights().ok and service.project.weight_overrides == manual, "重算保留手工覆盖"):
		return
	if not check(service.open_project(id).ok and service.project.weight_overrides == manual, "重开项目保留手工权重"):
		return
	if not check(JSON.stringify(service.project.rig) == original_rig and FileAccess.get_sha256("res://workspace/bindings/" + id + "/项目.json") == original_hash, "全部用户关节与原项目保持原样"):
		return
	var read: Dictionary = service.query_weights({"vertex_ids": ["0:0:2146"], "limit": 1})
	var invalid = service.edit_weights({"vertex_ids": ["0:0:2146", "invalid"], "operation": "set", "bone_id": "hand_r", "value": 1.0})
	if not check(not invalid.ok and service.query_weights({"vertex_ids": ["0:0:2146"], "limit": 1}).vertices == read.vertices, "无效批次不产生部分写入"):
		return
	if not check(service.edit_weights({"vertex_ids": ["0:0:2146"], "operation": "set", "bone_id": "forearm_r", "value": 1.0}).ok, "构造需修正的局部权重"):
		return
	if not check(service.edit_weights({"vertex_ids": ["0:0:2146"], "operation": "exclude_arms", "fallback_bone_id": "pelvis"}).ok and service.query_weights({"vertex_ids": ["0:0:2146"], "limit": 1}).vertices[0].weights.get("pelvis", 0) == 1.0, "清除衣物手臂影响并转交骨盆"):
		return
	report.passed = true
	report.joints_unchanged = true
	report.mcp_edit_query_idempotency = true
	report.undo_redo_reopen = true
	file = FileAccess.open(output.path_join("检查结果.json"), FileAccess.WRITE)
	file.store_string(JSON.stringify(report, "\t"))
	file.close()
	print(JSON.stringify(report))
	scene.queue_free()
	await process_frame
	quit()
