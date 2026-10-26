extends SceneTree
## 在隔离项目副本中验证涂抹事务、树状布局及平滑锚点。
func _initialize() -> void:
	call_deferred("_run")

## 执行实际工作台操作并检查持久化与撤销。
func _run() -> void:
	var scene = load("res://app/主界面.tscn").instantiate()
	root.add_child(scene)
	await process_frame
	var service = scene.binding_service
	if not service.directory.replace("\\", "/").contains("/build/verification/"):
		push_error("验收必须使用 build/verification 下的隔离工作区。")
		quit(1)
		return
	assert(service.open_project("binding_e7dcb8f658c34b2ef559209a").ok)
	var page = scene.binding_page
	page._switch_function(1)
	assert(page.joint_items.size() == service.bones.size())
	assert(page.view.weight_edit_mode and page.weight_panel.brush_config.visible)
	var panel = page.weight_panel
	page.view.select_joint(service.bone_index("forearm_r"))
	var before = service.project.duplicate(true)
	var count = service.undo_stack.size()
	panel._start_stroke()
	panel._picked("0:0:2146")
	panel._picked("0:0:2147")
	assert(service.project.revision == before.revision)
	panel._finish_stroke()
	assert(service.undo_stack.size() == count + 1)
	assert(service.project.revision == before.revision + 1)
	var painted = service.project.weight_overrides.duplicate(true)
	assert(service.undo().ok)
	assert(service.project.get("weight_overrides", {}) == before.get("weight_overrides", {}))
	assert(service.undo(true).ok)
	assert(service.project.weight_overrides == painted)
	assert(service.smooth_manual_boundaries().ok)
	for id in painted:
		assert(service.project.weight_overrides[id] == painted[id])
	for weights in service.get_weights():
		var total = 0.0
		for bone in weights:
			total += weights[bone]
		assert(absf(total - 1.0) < 0.00001)
	var saved = service.project.weight_overrides.duplicate(true)
	assert(service.open_project(service.project.id).ok)
	assert(service.project.weight_overrides.size() == saved.size())
	for id in saved:
		for bone in saved[id]:
			assert(absf(service.project.weight_overrides[id][bone] - saved[id][bone]) < 0.000001)
	# 使用真实项目顶点验证减少上臂后，锁骨不会因归一化被动增加。
	var vertex_id = "0:0:8092"
	var old_weights: Dictionary = service.query_weights({"vertex_ids": [vertex_id], "limit": 1}).vertices[0].weights
	assert(service.edit_weights({"vertex_ids": [vertex_id], "operation": "subtract", "bone_id": "upper_arm_r", "value": 0.05, "fallback_bone_id": "chest", "transfer_reduced": true}).ok)
	var new_weights: Dictionary = service.query_weights({"vertex_ids": [vertex_id], "limit": 1}).vertices[0].weights
	var removed = minf(0.05, float(old_weights.get("upper_arm_r", 0)))
	assert(absf(new_weights.get("clavicle_r", 0) - old_weights.get("clavicle_r", 0)) < 0.000001)
	assert(absf(new_weights.get("chest", 0) - old_weights.get("chest", 0) - removed) < 0.000001)
	var params = {"vertex_ids": [vertex_id], "operation": "exclude", "fallback_bone_id": "chest"}
	panel._configure_transfer(params)
	assert("clavicle_r" in params.excluded_bone_ids and "hand_l" in params.excluded_bone_ids)
	assert(service.edit_weights(params).ok)
	var cleared: Dictionary = service.query_weights({"vertex_ids": [vertex_id], "limit": 1}).vertices[0].weights
	assert(not cleared.has("clavicle_r") and not cleared.has("upper_arm_r"))
	assert(page.preview_animation("clip_1792640330_482_079539", 0.20, false).ok)
	panel._start_stroke()
	assert(page.view.previewing and is_equal_approx(page.seconds, 0.20))
	panel._finish_stroke()
	print("PASS: 减少权重转交胸部、锁骨权重不反增、肩臂清除含锁骨、落笔保持动画姿态")
	page._switch_function(0)
	assert(not page.view.weight_edit_mode and not panel.brush_config.visible)
	print("PASS: 功能切换、骨骼树、两次采样一笔撤销、重做、平滑保留锚点、归一化、重开持久化")
	scene.queue_free()
	await process_frame
	quit()
