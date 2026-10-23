extends SceneTree
## 使用实际 FBX 做一次绑定、动画预览和保存重开的简短端到端检查。

## 本轮失败项目。
var failures: Array = []
## 本轮已验证项目。
var checks: Array = []

## 场景树就绪后启动验收。
func _initialize() -> void:
	call_deferred("_run")

## 记录检查结果。
func _check(condition: bool, message: String) -> void:
	checks.append(message)
	if not condition:
		failures.append(message)
		push_error(message)

## 对几何数据做指纹，验证整个绑定过程没有改写原模型。
func _mesh_hash(parts: Array) -> String:
	var bytes = PackedByteArray()
	for mesh in parts:
		for surface in mesh.get_surface_count():
			bytes.append_array(mesh.surface_get_arrays(surface)[Mesh.ARRAY_VERTEX].to_byte_array())
	return bytes.hex_encode().sha256_text()

## 校验真实导入、独立骨长、预览、项目重载和 MCP 读写。
func _run() -> void:
	var scene = load("res://app/主界面.tscn").instantiate()
	root.add_child(scene)
	await process_frame
	var service = scene.binding_service
	var source = ProjectSettings.globalize_path("res://workspace/imports/角色样本/tripo_convert_a2c9acdd-51e8-48b4-9a72-60ba70c9f1da.fbx")
	var rig_hash = JSON.stringify(scene.rig_registry.get_definition("standard_humanoid_v1"))
	var animation_hash = JSON.stringify(scene.library.clips)
	var created: Dictionary = service.create_project(source, "角色绑定验收", "standard_humanoid_v1")
	_check(created.ok, "实际 FBX 与贴图导入并建立独立项目")
	if not created.ok:
		print(created)
		quit(1)
		return
	scene._show_page(1)
	scene.binding_page._camera_preset(0)
	var id = str(service.project.id)
	service.rotate_rig(90.0)
	var original_hash = _mesh_hash(service.parts)
	var initial: Dictionary = service.get_state()
	var target: Dictionary = initial.joints[10]
	var moved: Array = target.position_m.duplicate()
	moved[0] = snappedf(float(moved[0]) + 0.15, 0.01)
	moved[1] = snappedf(float(moved[1]), 0.01)
	moved[2] = snappedf(float(moved[2]), 0.01)
	var changed: Dictionary = await scene.commands.execute("move_binding_joint", {"document_id": scene.commands.document_id, "expected_revision": scene.commands.revision, "request_id": "test_move", "project_id": id, "bone_id": target.bone_id, "position_m": moved})
	_check(changed.ok, "MCP 可按稳定关节标识移动参考关节并自动保存")
	_check(_mesh_hash(service.parts) == original_hash, "改变关节和骨长后原始模型顶点完全不变")
	_check(JSON.stringify(scene.rig_registry.get_definition("standard_humanoid_v1")) == rig_hash, "项目修改不影响源骨架和其他任务")
	_check(service.undo().ok and service.undo(true).ok, "绑定项目支持独立撤销和重做")
	var new_position: Array = service.get_state().joints[10].position_m
	_check(service.open_project(id).ok and service.get_state().joints[10].position_m == new_position, "关闭并重开项目后关节位置完整保留")
	_check(_mesh_hash(service.parts) == original_hash, "重新加载自包含模型资源不改变顶点")
	var material = service.parts[0].surface_get_material(0)
	_check(material != null and material.albedo_texture != null and material.albedo_texture.get_width() > 0, "项目重新打开后仍保留自包含材质与贴图")
	var meshes: Array = service.get_skinned_parts()
	var skin: Skin = service.create_skin()
	var rest: Array = service.core.evaluate_transforms(PackedVector3Array(), Vector3.ZERO)
	var rest_error = 0.0
	var weight_error = 0.0
	var deformation = 0.0
	var clip: Dictionary = scene.library.clips[-1]
	var sample: Dictionary = scene.library.sample(clip, int(clip.duration_tick / 2))
	var posed: Array = service.core.evaluate_transforms(sample.pose, sample.root)
	for mesh in meshes:
		for surface in mesh.get_surface_count():
			var arrays: Array = mesh.surface_get_arrays(surface)
			var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
			var indices: PackedInt32Array = arrays[Mesh.ARRAY_BONES]
			var weights: PackedFloat32Array = arrays[Mesh.ARRAY_WEIGHTS]
			for index in vertices.size():
				var restored = Vector3.ZERO
				var animated = Vector3.ZERO
				var total = 0.0
				for slot in 4:
					var bone = indices[index * 4 + slot]
					var weight = weights[index * 4 + slot]
					var inverse: Transform3D = skin.get_bind_pose(bone)
					restored += (Transform3D(Basis(rest[bone].rotation), rest[bone].position) * inverse * vertices[index]) * weight
					animated += (Transform3D(Basis(posed[bone].rotation), posed[bone].position) * inverse * vertices[index]) * weight
					total += weight
				rest_error = maxf(rest_error, restored.distance_to(vertices[index]))
				weight_error = maxf(weight_error, absf(total - 1.0))
				deformation = maxf(deformation, animated.distance_to(vertices[index]))
	_check(rest_error < 0.00001 and weight_error < 0.00001, "逆绑定矩阵与归一化权重在静止时精确还原原模型")
	_check(deformation > 0.001, "动画旋转会真正驱动角色顶点而不是仅显示骨架")
	scene.binding_page.preview_animation(clip.id, float(clip.duration_tick) / 120000.0, true)
	scene.binding_page._process(0.1)
	_check(scene.binding_page.view.previewing and not scene.binding_page.view.editable, "动画预览为只读并按秒播放")
	var blocked: Dictionary = await scene.commands.execute("create_clip", {})
	_check(not blocked.ok and blocked.error.code == "BINDING_ANIMATION_READ_ONLY", "绑定工作区阻止 MCP 修改动画")
	scene.binding_page.stop_preview()
	_check(not scene.binding_page.view.previewing and _mesh_hash(service.parts) == original_hash, "返回绑定姿态后恢复原模型并可继续编辑")
	_check(JSON.stringify(scene.library.clips) == animation_hash, "绑定及预览未修改任何源动画")
	var output = ProjectSettings.globalize_path("res://build/verification/binding_result")
	DirAccess.make_dir_recursive_absolute(output)
	if DisplayServer.get_name() != "headless":
		for label in ["绑定姿态", "动画预览"]:
			var params = {"project_id": id, "width": 1000, "height": 1000, "show_bones": true, "view": {"preset": "custom", "yaw_deg": 75.0, "pitch_deg": 8.0, "frame_all": true}}
			if label == "动画预览":
				params.clip_id = clip.id
				params.time_seconds = snappedf(float(clip.duration_tick) / 120000.0, 0.01)
			var screenshot: Dictionary = await scene.commands.execute("render_binding_preview", params)
			_check(screenshot.ok, "MCP 独立截图相机：" + label)
			if screenshot.ok:
				var file = FileAccess.open(output.path_join(label + ".png"), FileAccess.WRITE)
				file.store_buffer(Marshalls.base64_to_raw(screenshot.images[0].data))
				file.close()
		await process_frame
		scene.binding_page.view.configure_camera({"yaw_deg": 75.0, "pitch_deg": 8.0, "frame_all": true})
		await RenderingServer.frame_post_draw
		root.get_texture().get_image().save_png(output.path_join("绑定工作区.png"))
	var report = {"checks": checks, "failures": failures, "vertices": service.project.vertices, "bounds_size_m": service.project.bounds_size_m, "rest_error_m": rest_error, "weight_error": weight_error, "animated_displacement_m": deformation, "project_id": id}
	var file = FileAccess.open(output.path_join("结果.json"), FileAccess.WRITE)
	file.store_string(JSON.stringify(report, "\t"))
	file.close()
	print(JSON.stringify(report))
	scene.queue_free()
	await process_frame
	quit(0 if failures.is_empty() else 1)
