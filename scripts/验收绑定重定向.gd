extends SceneTree
## 用用户已调整的参考骨架回归奔跑循环，不写入用户项目、模型或动画。

## 场景树就绪后执行检查。
func _initialize() -> void:
	call_deferred("_run")

## 逐时刻比较摆臂方向和骨长，再输出实际蒙皮截图。
func _run() -> void:
	var scene = load("res://app/主界面.tscn").instantiate()
	root.add_child(scene)
	await process_frame
	var binding = scene.binding_service
	var project_path = ProjectSettings.globalize_path("res://workspace/bindings/binding_e7dcb8f658c34b2ef559209a/项目.json")
	var animation_path = ProjectSettings.globalize_path("res://workspace/animations/standard_humanoid_v1/clip_1792655871_693_564769.json")
	var project_hash = FileAccess.get_sha256(project_path)
	var animation_hash = FileAccess.get_sha256(animation_path)
	binding.project = JSON.parse_string(FileAccess.get_file_as_string(project_path))
	for resource in binding.project.model_resources:
		binding.parts.append(ResourceLoader.load(project_path.get_base_dir().path_join(resource), "ArrayMesh"))
	binding._rebuild_core()
	var saved_rig = JSON.stringify(binding.project.rig)
	scene.binding_page.refresh()
	scene._show_page(1)
	var clip: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(animation_path))
	scene.library.clips.append(clip)
	var minimum_direction_dot = 1.0
	var old_minimum_direction_dot = 1.0
	var maximum_length_error = 0.0
	var maximum_skeleton_error = 0.0
	var samples: Array = []
	for frame in 49:
		var sample: Dictionary = scene.library.sample(clip, roundi(float(clip.duration_tick) * frame / 48.0))
		var source: Array = scene.core.evaluate_transforms(sample.pose, sample.root)
		var mapped: Array = binding.evaluate_animation(sample.pose, binding.adapt_root_motion(sample.root))
		var old: Array = binding.core.evaluate_transforms(sample.pose, binding.adapt_root_motion(sample.root))
		for child in [9, 10, 13, 14, 16, 17, 20, 21]:
			var parent = int(binding.bones[child].parent)
			var wanted: Vector3 = binding.retarget_alignment * (source[child].position - source[parent].position).normalized()
			var actual: Vector3 = (mapped[child].position - mapped[parent].position).normalized()
			minimum_direction_dot = minf(minimum_direction_dot, wanted.dot(actual))
			old_minimum_direction_dot = minf(old_minimum_direction_dot, wanted.dot((old[child].position - old[parent].position).normalized()))
		for index in range(1, mapped.size()):
			var parent = int(binding.bones[index].parent)
			maximum_length_error = maxf(maximum_length_error, absf(mapped[index].position.distance_to(mapped[parent].position) - binding.bones[index].offset.length()))
		if frame % 12 == 0:
			samples.append({"time_seconds": float(clip.duration_tick) / 60000.0 * frame / 48.0, "right_hand": binding._array(mapped[14].position), "old_right_hand": binding._array(old[14].position)})
	assert(minimum_direction_dot > 0.99999, "绑定后的手脚骨段应保持源动画方向，不能二次叠加参考姿态")
	assert(maximum_length_error < 0.000001, "动画不能改变用户设定的骨长")
	var page = scene.binding_page
	assert(page.preview_animation(clip.id, 0.18, false).ok)
	page.view.skeleton.force_update_all_bone_transforms()
	var sample: Dictionary = scene.library.sample(clip, 10800)
	var mapped: Array = binding.evaluate_animation(sample.pose, binding.adapt_root_motion(sample.root))
	for index in mapped.size():
		maximum_skeleton_error = maxf(maximum_skeleton_error, page.view.skeleton.get_bone_global_pose(index).origin.distance_to(mapped[index].position))
	assert(maximum_skeleton_error < 0.00001, "GPU 蒙皮骨架与重定向求值必须一致")
	var api: Dictionary = await scene.commands.execute("evaluate_binding_pose", {"project_id": binding.project.id, "clip_id": clip.id, "time_seconds": 0.18})
	assert(api.ok and binding.registry.to_vector(api.joints[14].position_m).distance_to(mapped[14].position) < 0.000001, "MCP 回读与屏幕姿态必须一致")
	page.stop_preview()
	assert(JSON.stringify(binding.project.rig) == saved_rig, "重定向不改写参考关节位置")
	var rest: Array = binding.core.evaluate_transforms(PackedVector3Array(), Vector3.ZERO)
	assert(page.view.positions[14].distance_to(rest[14].position) < 0.000001, "退出预览必须恢复保存的绑定姿态")
	var output = ProjectSettings.globalize_path("res://build/verification/retarget")
	DirAccess.make_dir_recursive_absolute(output)
	if DisplayServer.get_name() != "headless":
		for seconds in [0.0, 0.18, 0.36]:
			var screenshot: Dictionary = await scene.commands.execute("render_binding_preview", {"project_id": binding.project.id, "clip_id": clip.id, "time_seconds": seconds, "width": 1000, "height": 1000, "view": {"yaw_deg": 90.0, "pitch_deg": 8.0, "frame_all": true}})
			assert(screenshot.ok)
			var file = FileAccess.open(output.path_join("奔跑_%.2f.png" % seconds), FileAccess.WRITE)
			file.store_buffer(Marshalls.base64_to_raw(screenshot.images[0].data))
			file.close()
	assert(FileAccess.get_sha256(project_path) == project_hash and FileAccess.get_sha256(animation_path) == animation_hash)
	var report = {"passed": true, "samples": 49, "minimum_direction_dot": minimum_direction_dot, "old_minimum_direction_dot": old_minimum_direction_dot, "max_length_error_m": maximum_length_error, "max_skeleton_error_m": maximum_skeleton_error, "reference_rig_unchanged": true, "original_animation_unchanged": true, "positions": samples}
	var file = FileAccess.open(output.path_join("检查结果.json"), FileAccess.WRITE)
	file.store_string(JSON.stringify(report, "\t"))
	file.close()
	print(JSON.stringify(report))
	scene.queue_free()
	await process_frame
	quit()
