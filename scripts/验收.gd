extends SceneTree
## 以一次完整操作验证原生骨架、关键帧保存、过渡、撤销和播放。

## 累积本次简单验收发现的问题。
var failures: Array[String] = []
## 记录已完成的验收项。
var checks: Array[String] = []

## 在场景树准备完成后执行验收。
func _initialize() -> void:
	call_deferred("_run")

## 记录验收条件及其实际结果。
func _check(condition: bool, description: String) -> void:
	checks.append(description)
	if not condition:
		failures.append(description)
		push_error(description)

## 验证一个可保存、可修改和可播放的完整动作。
func _run() -> void:
	var scene = load("res://app/主界面.tscn").instantiate()
	root.add_child(scene)
	await process_frame
	await process_frame
	if scene.core == null:
		push_error("原生扩展未加载。")
		quit(1)
		return
	_check(scene.rig.size() == 23 and scene.rig_view.skeleton.get_bone_count() == 23, "标准人形包含 23 个固定骨骼节点")
	_check(scene.core.sample_tick(60, 60) == 60000, "60 FPS 采样一秒时间码准确")
	scene.name_action = "new"
	scene.name_input.text = "验收动作"
	scene._accept_name()
	scene.rig_view.select_joint(12)
	scene._seek(60000)
	scene._on_rotation_changed(-60.0, 2)
	scene._save_keyframe()
	_check(scene.active_clip().keyframes.size() == 3, "在任意时刻新增并保存关键帧")
	scene._seek(30000)
	_check(absf(scene.working_pose[12].z + 30.0) < 0.1, "关键姿势之间由 C++ 自动插值")
	var reference = scene.core.evaluate_positions(scene.library.rest_pose(), Vector3.ZERO)
	var target_pose = scene.library.rest_pose()
	target_pose[16].x = 90
	var evaluated = scene.core.evaluate_positions(target_pose, Vector3.ZERO)
	_check(absf(reference[17].distance_to(reference[16]) - evaluated[17].distance_to(evaluated[16])) < 0.0001, "旋转姿势不会修改固定骨长")
	var goal = Vector3(0.42, 1.42, 0.28)
	var solved = scene.core.solve_ik(scene.library.rest_pose(), 10, goal, Vector3.ZERO)
	var solved_positions = scene.core.evaluate_positions(solved, Vector3.ZERO)
	_check(solved_positions[10].distance_to(goal) < reference[10].distance_to(goal), "拖动关节通过限制内 IK 接近目标")
	var copy = load("res://app/animation_library.gd").new()
	copy.initialize(scene.core, scene.rig, scene.library.storage_path)
	var found = false
	for clip in copy.clips:
		if clip.id == scene.active_clip().id:
			found = clip.skeleton_id == "standard_humanoid_v1" and clip.keyframes.size() == 3
	_check(found, "动作可按骨架索引持久化并重新读取")
	scene._seek(60000)
	scene._on_rotation_changed(-45.0, 2)
	scene._undo()
	_check(absf(scene.working_pose[12].z + 60.0) < 0.1, "姿势编辑可以撤销")
	scene._start_playback()
	scene._process(0.25)
	_check(scene.current_tick > 60000, "播放按关键帧时间推进")
	scene._stop_playback()
	scene._set_workspace(0)
	_check(not scene.timeline_panel.visible, "左侧工作区可以切换骨架预览")
	scene._set_workspace(1)
	scene._show_page(2)
	_check(scene.settings_page.visible and scene.font_size_input.min_value == 12 and scene.interface_scale_option.item_count == 7, "设置页提供字体大小与界面缩放")
	scene._show_page(0)
	var demo_clips: Array = []
	for clip in scene.library.clips:
		if clip.name != "验收动作":
			demo_clips.append(clip)
	scene.library.clips = demo_clips
	scene.clip_index = 0
	scene._refresh_animation_list()
	for index in scene.library.clips.size():
		if scene.library.clips[index].name == "挥手示例":
			scene._switch_clip(index)
			break
	scene._seek(48000)
	scene._set_tool(0)
	var hand_screen = scene.rig_view.camera.unproject_position(scene.rig_view.positions[10])
	var press = InputEventMouseButton.new()
	press.button_index = MOUSE_BUTTON_LEFT
	press.pressed = true
	press.position = hand_screen
	scene.rig_view._gui_input(press)
	var motion = InputEventMouseMotion.new()
	motion.position = hand_screen + Vector2(-25, 30)
	motion.relative = Vector2(-25, 30)
	scene.rig_view._gui_input(motion)
	press.pressed = false
	press.position = motion.position
	scene.rig_view._gui_input(press)
	_check(scene.rig_view.selected_joint == 10 and scene.pose_dirty, "视口关节拾取与拖动能够实际更新编辑姿势")
	scene._undo()
	scene.rig_view.select_joint(13)
	scene._set_tool(1)
	await process_frame
	await process_frame
	var output_directory = ProjectSettings.globalize_path("res://build/verification")
	DirAccess.make_dir_recursive_absolute(output_directory)
	var layout_ok = true
	var default_view_width = 0.0
	var wide_view_width = 0.0
	for dimensions in [Vector2i(1440, 900), Vector2i(1920, 1080), Vector2i(960, 680)]:
		root.size = dimensions
		await process_frame
		await process_frame
		await process_frame
		var client_size = root.get_visible_rect().size
		layout_ok = layout_ok and scene.shell_root.get_global_rect().size.is_equal_approx(client_size)
		layout_ok = layout_ok and scene.editor_page.get_global_rect().end.x <= client_size.x + 1
		layout_ok = layout_ok and scene.rig_view.render_view.size == Vector2i(scene.rig_view.size)
		if dimensions.x == 1440:
			default_view_width = scene.rig_view.size.x
		elif dimensions.x == 1920:
			wide_view_width = scene.rig_view.size.x
		else:
			layout_ok = layout_ok and not scene.details_panel.visible
		if DisplayServer.get_name() != "headless":
			await RenderingServer.frame_post_draw
			root.get_texture().get_image().save_png(output_directory.path_join("木偶人界面_%dx%d.png" % [dimensions.x, dimensions.y]))
	_check(layout_ok and root.content_scale_mode == Window.CONTENT_SCALE_MODE_DISABLED, "不同窗口尺寸下界面及三维视口填满工作区，窄窗口自动收起细节栏")
	_check(wide_view_width > default_view_width + 400, "窗口加宽后中央视口得到新增宽度")
	root.size = Vector2i(1440, 900)
	await process_frame
	await process_frame
	await process_frame
	var panel_width = scene.rig_view.size.x
	scene.focus_button.pressed.emit()
	await process_frame
	await process_frame
	_check(not scene.resources_panel.visible and not scene.details_panel.visible and scene.rig_view.size.x > panel_width, "专注视口图标能够收起侧栏并扩大中央工作区")
	scene.focus_button.pressed.emit()
	scene.options_button.pressed.emit()
	await process_frame
	_check(scene.animation_options.visible and is_instance_valid(scene.auto_key) and is_instance_valid(scene.interpolation_option), "动画面板内的更多菜单保留自动关键帧与过渡设置")
	scene.animation_options.hide()
	await process_frame
	await process_frame
	scene._on_rotation_changed(15.0, 0)
	var pose_before_settings = scene.working_pose.duplicate()
	var clip_before_settings = scene.active_clip().duplicate(true)
	var tick_before_settings = scene.current_tick
	var undo_before_settings = scene.undo_stack.size()
	scene._request_page(2)
	scene.font_size_input.value = 18
	scene.interface_scale_option.item_selected.emit(3)
	await process_frame
	await process_frame
	await process_frame
	var saved_preferences = load("res://app/ui_preferences.gd").new()
	saved_preferences.load_settings(scene.ui_preferences.settings_path)
	_check(saved_preferences.font_size == 18 and is_equal_approx(saved_preferences.interface_scale, 1.25) and scene.timeline.label_font_size == 16 and is_equal_approx(root.content_scale_factor, 1.25), "字体与界面缩放即时生效，并可从独立设置文件重新读取")
	_check(scene.pose_dirty and not scene.draft_dialog.visible and scene.working_pose == pose_before_settings and scene.active_clip() == clip_before_settings and scene.current_tick == tick_before_settings and scene.undo_stack.size() == undo_before_settings, "进入设置并调整外观保留未记录姿势、动画内容、时间和撤销记录")
	if DisplayServer.get_name() != "headless":
		await RenderingServer.frame_post_draw
		root.get_texture().get_image().save_png(output_directory.path_join("木偶人设置_18像素_125.png"))
	scene._request_page(0)
	await process_frame
	await process_frame
	scene._set_tool(0)
	hand_screen = root.get_final_transform() * (scene.rig_view.get_global_transform_with_canvas() * scene.rig_view.camera.unproject_position(scene.rig_view.positions[10]))
	press.pressed = true
	press.position = hand_screen
	root.push_input(press)
	motion.position = hand_screen + Vector2(-25, 30)
	motion.relative = Vector2(-25, 30)
	root.push_input(motion)
	press.pressed = false
	press.position = motion.position
	root.push_input(press)
	_check(scene.rig_view.selected_joint == 10 and scene.working_pose != pose_before_settings, "百分之一百二十五缩放下真实窗口输入仍能正确选中并拖动关节")
	scene._undo()
	scene.rig_view.select_joint(13)
	scene._set_tool(1)
	if DisplayServer.get_name() != "headless":
		await RenderingServer.frame_post_draw
		root.get_texture().get_image().save_png(output_directory.path_join("木偶人工作台_18像素_125.png"))
	scene.options_button.pressed.emit()
	await process_frame
	if DisplayServer.get_name() != "headless":
		await RenderingServer.frame_post_draw
		root.get_texture().get_image().save_png(output_directory.path_join("木偶人菜单_125.png"))
	scene.animation_options.hide()
	scene._request_page(2)
	root.size = Vector2i(960, 680)
	scene.font_size_input.value = 24
	scene.interface_scale_option.item_selected.emit(6)
	await process_frame
	await process_frame
	await process_frame
	var logical_size = root.get_visible_rect().size
	_check(scene.shell_root.get_global_rect().size.is_equal_approx(logical_size) and scene.nav_buttons[2].get_global_rect().end.x <= logical_size.x + 1 and root.get_stretch_transform().origin.is_zero_approx(), "最大字号与百分之二百缩放仍填满窗口，顶部设置入口保持可见")
	if DisplayServer.get_name() != "headless":
		await RenderingServer.frame_post_draw
		root.get_texture().get_image().save_png(output_directory.path_join("木偶人设置_最大缩放.png"))
	scene._reset_display_preferences()
	root.size = Vector2i(1440, 900)
	await process_frame
	await process_frame
	_check(scene.ui_preferences.font_size == 16 and is_equal_approx(root.content_scale_factor, 1.0) and scene.time_label.get_theme_font_size("font_size") == 14, "恢复默认后字号和缩放准确还原，不发生重复缩放")
	scene._request_page(0)
	scene._undo()
	await process_frame
	await process_frame
	if DisplayServer.get_name() != "headless":
		await RenderingServer.frame_post_draw
		var image = root.get_texture().get_image()
		image.save_png(output_directory.path_join("木偶人首版.png"))
	var report = {"passed": failures.is_empty(), "checks": checks, "failures": failures, "engine": Engine.get_version_info().string, "bones": scene.rig.size(), "animation_directory": scene.library.storage_path}
	var file = FileAccess.open(output_directory.path_join("验收结果.json"), FileAccess.WRITE)
	file.store_string(JSON.stringify(report, "\t", false) + "\n")
	file.close()
	print("PUPPET_SMOKE_RESULT: " + JSON.stringify(report))
	quit(0 if failures.is_empty() else 1)
