extends RefCounted
## 用独立三维世界渲染动画快照，不改变用户正在编辑的姿势和观察角度。

## 复用与操作视口相同的可视化实现。
const ViewScript = preload("res://app/rig_view.gd")
## 读取动画姿势的共用动作库。
const LibraryScript = preload("res://app/animation_library.gd")
## 主界面仅用于承载离屏视口节点。
var host
## 骨架格式与原生参数转换入口。
var registry

## 保存宿主与注册表，不创建持久场景对象。
func initialize(owner_node, rig_registry) -> void:
	host = owner_node
	registry = rig_registry

## 每张图片同时返回确切时刻、视角和关节屏幕投影，像素原点位于左上角。
func render(definition: Dictionary, clip: Dictionary, samples: Array, width: int, height: int) -> Dictionary:
	var core = ClassDB.instantiate("PuppetAnimator")
	var bones: Array = registry.native_from_definition(definition)
	if not core.configure_rig(bones):
		return {"ok": false, "error": "截图骨架配置失败。"}
	var library = LibraryScript.new()
	library.core = core
	library.rig = bones
	var view = ViewScript.new()
	view.position = Vector2(-20000, -20000)
	view.mouse_filter = Control.MOUSE_FILTER_IGNORE
	host.add_child(view)
	view.stretch = false
	view.size = Vector2(width, height)
	view.render_view.size = Vector2i(width, height)
	view.initialize(core, bones)
	view.overlay.visible = false
	var images: Array = []
	for sample in samples:
		var pose: Dictionary = library.sample(clip, int(sample.tick))
		view.set_pose(pose.pose, pose.root)
		var options: Dictionary = {"preset": "perspective", "frame_all": true}
		if not sample.view is Dictionary:
			view.queue_free()
			return {"ok": false, "error": "截图视角需要对象。"}
		options.merge(sample.view, true)
		var configured: Dictionary = view.configure_camera(options)
		if not configured.ok:
			view.queue_free()
			return configured
		view.render_view.render_target_update_mode = SubViewport.UPDATE_ALWAYS
		await host.get_tree().process_frame
		await RenderingServer.frame_post_draw
		var image: Image = view.render_view.get_texture().get_image()
		if image == null or image.is_empty():
			view.queue_free()
			return {"ok": false, "error": "渲染器没有返回有效图像。"}
		var projected: Array = []
		for index in bones.size():
			var point: Vector2 = view.camera.unproject_position(view.positions[index])
			projected.append({"bone_id": bones[index].id, "pixel": [point.x, point.y], "behind_camera": view.camera.is_position_behind(view.positions[index])})
		images.append({"data": Marshalls.raw_to_base64(image.save_png_to_buffer()), "mimeType": "image/png", "width": image.get_width(), "height": image.get_height(), "tick": sample.tick, "time_seconds": float(sample.tick) / 60000.0, "rig_revision": definition.revision, "view": view.get_camera_state(), "projected_joints": projected})
	view.queue_free()
	return {"ok": true, "images": images}
