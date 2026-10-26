extends SceneTree
## 在独立项目副本中比较胸部变形的骨骼贡献，不修改原项目。
func _initialize() -> void:
	call_deferred("_run")

## 记录局部权重和位移，并输出同视角的修正对照截图。
func _run() -> void:
	var scene = load("res://app/主界面.tscn").instantiate()
	root.add_child(scene)
	await process_frame
	var service = scene.binding_service
	if not service.directory.replace("\\", "/").contains("/build/verification/"):
		quit(1)
		return
	assert(service.open_project("binding_e7dcb8f658c34b2ef559209a").ok)
	var engine = service.get_weight_engine()
	var weights: Array = service.get_weights()
	var rest: Array = service.core.evaluate_transforms(PackedVector3Array(), Vector3.ZERO)
	var sample: Array = service.evaluate_animation(PackedVector3Array(), Vector3.ZERO)
	var transforms: Array = []
	for index in rest.size():
		transforms.append(Transform3D(Basis(sample[index].rotation), sample[index].position) * Transform3D(Basis(rest[index].rotation), rest[index].position).affine_inverse())
	for id in ["0:0:7033", "0:0:7680", "0:0:14099"]:
		var automatic: Dictionary = {}
		for bone in engine.automatic[engine.welds[engine.lookup[id]]]:
			automatic[service.bones[bone].id] = engine.automatic[engine.welds[engine.lookup[id]]][bone]
		print("AUTO ", id, " ", JSON.stringify(automatic))
	var selected: Array = []
	var records: Array = []
	for index in engine.ids.size():
		var point: Vector3 = engine.points[engine.welds[index]]
		# 当前模型胸腹主体的诊断范围，仅用于对照实验，不作为通用算法。
		if point.y < 0.60 or point.y > 0.79 or absf(point.z) > 0.075:
			continue
		var value: Dictionary = weights[index]
		var position = Vector3.ZERO
		var named: Dictionary = {}
		for bone in value:
			position += transforms[bone] * point * value[bone]
			named[service.bones[bone].id] = value[bone]
		selected.append(engine.ids[index])
		records.append({"id": engine.ids[index], "point": service._array(point), "displacement": point.distance_to(position), "weights": named, "manual": service.project.get("weight_overrides", {}).has(engine.ids[index])})
	records.sort_custom(func(a, b): return a.displacement > b.displacement)
	print("DIAG ", JSON.stringify(records.slice(0, 8)))
	var output = service.directory.get_base_dir()
	var file = FileAccess.open(output.path_join("胸部顶点.json"), FileAccess.WRITE)
	file.store_string(JSON.stringify(records))
	file.close()
	var excluded: Array = []
	for bone in service.bones:
		if bone.semantic.role in ["clavicle", "upper_arm", "forearm", "hand"]:
			excluded.append(bone.id)
	for stage in ["原始", "肩臂移除"]:
		if stage == "肩臂移除":
			assert(service.edit_weights({"vertex_ids": selected, "operation": "exclude", "excluded_bone_ids": excluded, "fallback_bone_id": "chest"}).ok)
		if stage == "肩臂移除":
			var corrected: Array = service.get_weights()
			var max_displacement = 0.0
			for id in ["0:0:7033", "0:0:7680", "0:0:14099"]:
				var index: int = engine.lookup[id]
				var point: Vector3 = engine.points[engine.welds[index]]
				var position = Vector3.ZERO
				for bone in corrected[index]:
					position += transforms[bone] * point * corrected[index][bone]
				max_displacement = maxf(max_displacement, point.distance_to(position))
			print("CORRECTED sample maximum displacement ", max_displacement)
		var result: Dictionary = await scene.commands.execute("render_binding_preview", {"project_id": service.project.id, "clip_id": "clip_1792640330_482_079539", "time_seconds": 0.0, "show_bones": false, "width": 900, "height": 900, "view": {"yaw_deg": 90, "pitch_deg": 8, "target_m": [0, 0.72, 0], "distance_m": 0.85}})
		assert(result.ok)
		file = FileAccess.open(output.path_join(stage + ".png"), FileAccess.WRITE)
		file.store_buffer(Marshalls.base64_to_raw(result.images[0].data))
		file.close()
	print("PASS 胸部诊断对照 ", selected.size())
	scene.queue_free()
	await process_frame
	quit()
