extends HBoxContainer
## 角色绑定工作台，所有修改通过共享服务持久化，动画区域仅提供播放和定位。

## 绑定视口实现。
const ViewScript = preload("res://app/binding_view.gd")
## 权重查看和修正面板。
const WeightPanelScript = preload("res://app/binding_weight_panel.gd")
## 当前权重控件与表面选区。
var weight_panel
## 关节与权重分开显示，避免修正权重时反复滚动长表单。
var details_tabs: TabContainer
## 已显示项目标识，用于在权重修改后恢复同一动画预览。
var displayed_project_id: String = ""
## 主界面宿主。
var host
## 当前绑定数据服务。
var service
## 独立三维绑定视口。
var view
## 项目切换下拉框。
var projects: OptionButton
## 新项目所用源骨架。
var rig_picker: OptionButton
## 可编辑项目名称。
var name_input: LineEdit
## 关节选择列表。
var joints: Tree
## 树节点按骨骼索引保存，便于视口同步选择。
var joint_items: Array = []
## 最左侧功能入口。
var functions_list: ItemList
## 骨架配置区只在绑定功能中显示。
var rig_config: VBoxContainer
## 动画选择列表。
var animations: ItemList
## 当前关节坐标输入。
var coordinates: Array = []
## 当前骨长输入。
var length_input: SpinBox
## 子链联动开关。
var move_children: CheckBox
## 平滑和刚性蒙皮选项。
var skin_mode: OptionButton
## 项目状态及保存结果。
var status: Label
## 预览状态说明。
var preview_label: Label
## 当前选中关节说明。
var joint_label: Label
## 动画秒制定位。
var seek: HSlider
## 播放暂停按钮。
var play_button: Button
## 模型文件选择框。
var file_dialog: FileDialog
## 当前选中关节索引。
var selected: int = -1
## 刷新控件时屏蔽反向修改。
var refreshing: bool = false
## 独立的只读动画快照。
var preview_clip: Dictionary = {}
## 用源骨架采样动作，保留源动画约束语义。
var preview_library
## 是否推进动画时间。
var playing: bool = false
## 当前播放时间，单位秒。
var seconds: float = 0.0

## 创建功能区并接入数据服务。
func initialize(owner_node, binding_service) -> void:
	host = owner_node
	service = binding_service
	size_flags_vertical = Control.SIZE_EXPAND_FILL
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	add_theme_constant_override("separation", 12)
	functions_list = ItemList.new()
	functions_list.custom_minimum_size.x = 110
	functions_list.add_item("骨骼绑定")
	functions_list.add_item("蒙皮权重")
	functions_list.select(0)
	functions_list.item_selected.connect(_switch_function)
	add_child(functions_list)
	var left = VBoxContainer.new()
	left.custom_minimum_size.x = 210
	add_child(left)
	left.add_child(host._label("绑定项目", 17))
	projects = OptionButton.new()
	projects.item_selected.connect(_open_selected)
	left.add_child(projects)
	projects.fit_to_longest_item = false
	projects.custom_minimum_size.x = 210
	left.add_child(host._button("导入模型 · 新建项目", _choose_model, "PrimaryButton"))
	rig_config = VBoxContainer.new()
	left.add_child(rig_config)
	rig_picker = OptionButton.new()
	rig_picker.fit_to_longest_item = false
	rig_picker.item_selected.connect(_switch_rig)
	rig_config.add_child(rig_picker)
	left.add_child(host._label("关节", 15))
	joints = Tree.new()
	joints.hide_root = true
	joints.add_theme_stylebox_override("panel", host._style("ffffff", "dce5e9", 4, 4))
	joints.add_theme_color_override("font_color", host.INK)
	joints.add_theme_color_override("font_selected_color", host.ACCENT)
	joints.size_flags_vertical = Control.SIZE_EXPAND_FILL
	joints.custom_minimum_size.y = 150
	joints.item_selected.connect(_tree_selected)
	left.add_child(joints)
	left.add_child(host._label("动画 · 点击即预览（只读）", 13))
	animations = ItemList.new()
	animations.add_theme_stylebox_override("panel", host._style("ffffff", "dce5e9", 4, 4))
	animations.add_theme_color_override("font_color", host.INK)
	animations.add_theme_color_override("font_selected_color", host.ACCENT)
	animations.custom_minimum_size.y = 160
	animations.size_flags_vertical = Control.SIZE_EXPAND_FILL
	animations.item_selected.connect(_choose_animation)
	left.add_child(animations)
	var center = VBoxContainer.new()
	center.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	add_child(center)
	var toolbar = HBoxContainer.new()
	center.add_child(toolbar)
	for index in 6:
		toolbar.add_child(host._button(["透视", "正面", "左侧", "背面", "右侧", "俯视"][index], _camera_preset.bind(index)))
	view = ViewScript.new()
	view.custom_minimum_size = Vector2(330, 330)
	center.add_child(view)
	view.joint_selected.connect(_view_selected)
	view.edit_started.connect(_begin_drag)
	view.rest_joint_dragged.connect(_drag_joint)
	view.edit_finished.connect(_finish_drag)
	var playback = HBoxContainer.new()
	center.add_child(playback)
	play_button = host._button("播放", toggle_play)
	playback.add_child(play_button)
	playback.add_child(host._button("返回绑定姿态", stop_preview))
	seek = HSlider.new()
	seek.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	seek.step = 0.01
	seek.max_value = 1.0
	seek.value_changed.connect(_seek_changed)
	playback.add_child(seek)
	preview_label = host._label("绑定姿态 · 拖动关节适配角色", 12)
	center.add_child(preview_label)
	var hint = host._label("左键拖动关节 · 右键旋转视角 · Shift＋右键平移 · 滚轮缩放", 11)
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	center.add_child(hint)
	status = host._label("导入 GLB、glTF 或 FBX，或打开已有绑定项目。", 12)
	status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	center.add_child(status)
	var right_scroll = ScrollContainer.new()
	right_scroll.custom_minimum_size.x = 220
	right_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	add_child(right_scroll)
	var right = VBoxContainer.new()
	right.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	right_scroll.add_child(right)
	right.add_child(host._label("项目设置", 16))
	name_input = LineEdit.new()
	name_input.placeholder_text = "项目名称"
	name_input.max_length = 96
	name_input.text_submitted.connect(_rename)
	right.add_child(name_input)
	right.add_child(host._button("保存项目", save_project))
	var history = HBoxContainer.new()
	right.add_child(history)
	history.add_child(host._button("撤销", undo.bind(false)))
	history.add_child(host._button("重做", undo.bind(true)))
	var orientation = HBoxContainer.new()
	right.add_child(orientation)
	orientation.add_child(host._button("骨架左转 90°", _rotate_rig.bind(90.0)))
	orientation.add_child(host._button("右转 90°", _rotate_rig.bind(-90.0)))
	details_tabs = TabContainer.new()
	details_tabs.tabs_visible = false
	details_tabs.add_theme_stylebox_override("panel", host._style("ffffff", "dce5e9", 4, 6))
	for state in ["selected", "unselected", "hovered"]:
		details_tabs.add_theme_stylebox_override("tab_" + state, host._style("e0f2ed" if state == "selected" else "f5f8fa", "dce5e9", 4, 6))
		details_tabs.add_theme_color_override("font_" + state + "_color", host.ACCENT if state == "selected" else host.INK)
	right.add_child(details_tabs)
	var joint_settings = VBoxContainer.new()
	joint_settings.name = "关节设置"
	details_tabs.add_child(joint_settings)
	joint_settings.add_child(HSeparator.new())
	joint_label = host._label("选择关节", 15)
	joint_settings.add_child(joint_label)
	for axis in 3:
		var row = HBoxContainer.new()
		joint_settings.add_child(row)
		row.add_child(host._label(["X / 米", "Y / 米", "Z / 米"][axis], 12))
		var spin = _spin(-1000, 1000)
		spin.value_changed.connect(_coordinate_changed.bind(axis))
		row.add_child(spin)
		coordinates.append(spin)
	joint_settings.add_child(host._label("与父关节距离 / 米", 12))
	length_input = _spin(0.01, 100)
	length_input.value_changed.connect(_length_changed)
	joint_settings.add_child(length_input)
	move_children = CheckBox.new()
	move_children.text = "移动时带动子关节"
	move_children.tooltip_text = "关闭时只改变当前关节位置，其他关节留在原处；修改骨长时始终带动子链。"
	joint_settings.add_child(move_children)
	var axis_picker = OptionButton.new()
	for text in ["拖动：屏幕平面", "拖动：仅 X 轴", "拖动：仅 Y 轴", "拖动：仅 Z 轴"]:
		axis_picker.add_item(text)
	axis_picker.item_selected.connect(_axis_changed)
	joint_settings.add_child(axis_picker)
	joint_settings.add_child(HSeparator.new())
	joint_settings.add_child(host._label("蒙皮方式", 14))
	skin_mode = OptionButton.new()
	skin_mode.add_item("平滑 · 四权重")
	skin_mode.add_item("刚性 · 单权重")
	skin_mode.item_selected.connect(_skin_changed)
	joint_settings.add_child(skin_mode)
	weight_panel = WeightPanelScript.new()
	weight_panel.name = "蒙皮权重"
	details_tabs.add_child(weight_panel)
	weight_panel.initialize(self)
	weight_panel.brush_config.reparent(left)
	left.move_child(weight_panel.brush_config, 4)
	weight_panel.brush_config.visible = false
	details_tabs.tab_changed.connect(_details_tab_changed)
	var note = host._label("关节位置与骨长只影响当前项目。\n\n修改自动保存。预览可能因关节尚未对齐而扭曲；返回绑定姿态后显示原始模型。\n\n原模型与原动画不会被改写。", 12)
	note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	joint_settings.add_child(note)
	file_dialog = FileDialog.new()
	file_dialog.title = "导入角色模型"
	file_dialog.access = FileDialog.ACCESS_FILESYSTEM
	file_dialog.file_mode = FileDialog.FILE_MODE_OPEN_FILE
	file_dialog.filters = PackedStringArray(["*.glb, *.gltf, *.fbx ; 角色模型"])
	file_dialog.file_selected.connect(import_model)
	add_child(file_dialog)
	service.changed.connect(refresh)
	refresh()

## 创建两位小数的米制输入。
func _spin(minimum: float, maximum: float) -> SpinBox:
	var spin = SpinBox.new()
	spin.min_value = minimum
	spin.max_value = maximum
	spin.step = 0.01
	spin.value_changed.connect(_format_spin.bind(spin))
	_format_spin(0.0, spin)
	spin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	spin.custom_minimum_size.x = 125
	return spin

## 数值字段始终以两位小数显示米制长度。
func _format_spin(_value: float, spin: SpinBox) -> void:
	spin.get_line_edit().set_deferred("text", "%.2f" % spin.value)

## 打开文件选择框，导入路径不限制在工程目录。
func _choose_model() -> void:
	file_dialog.popup_centered_ratio(0.75)

## 导入文件后立即创建独立任务，保留源文件。
func import_model(path: String) -> void:
	stop_preview()
	status.text = "正在导入模型并保存资源……"
	await get_tree().process_frame
	var rig_id = str(rig_picker.get_item_metadata(rig_picker.selected))
	var result: Dictionary = service.create_project(path, path.get_file().get_basename(), rig_id)
	show_result(result)
	if result.ok:
		_camera_preset(0)

## 更新项目列表、参考骨架及只读动画列表。
func refresh() -> void:
	var restore_preview = preview_clip.duplicate(true) if displayed_project_id == str(service.project.get("id", "")) else {}
	var restore_seconds = seconds
	var restore_playing = playing
	refreshing = true
	playing = false
	preview_clip = {}
	projects.clear()
	projects.add_item("选择已保存项目")
	projects.set_item_metadata(0, "")
	for item in service.list_projects():
		projects.add_item(item.name)
		projects.set_item_metadata(projects.item_count - 1, item.project_id)
		if not service.project.is_empty() and item.project_id == service.project.id:
			projects.select(projects.item_count - 1)
	rig_picker.clear()
	for item in host.rig_registry.list_rigs():
		rig_picker.add_item("源骨架：" + str(item.name))
		rig_picker.set_item_metadata(rig_picker.item_count - 1, item.rig_id)
		if item.rig_id == service.project.get("rig_id", host.active_rig_id):
			rig_picker.select(rig_picker.item_count - 1)
	joints.clear()
	joint_items.clear()
	animations.clear()
	if not service.project.is_empty():
		view.set_binding(service)
		name_input.text = service.project.name
		skin_mode.select(1 if service.project.skin_mode == "rigid" else 0)
		var tree_root = joints.create_item()
		for bone in service.bones:
			var item = joints.create_item(tree_root)
			item.set_text(0, bone.name)
			item.set_metadata(0, joint_items.size())
			joint_items.append(item)
		for index in service.bones.size():
			var parent = int(service.bones[index].parent)
			if parent >= 0:
				tree_root.remove_child(joint_items[index])
				joint_items[parent].add_child(joint_items[index])
		var document: Dictionary = host.commands.get_document_for_rig(service.project.rig_id)
		if not document.is_empty():
			for clip in document.library.clips:
				animations.add_item(clip.name)
				animations.set_item_metadata(animations.item_count - 1, clip.id)
		status.text = "%s · %d 顶点 · 已保存（修订 %d）" % [service.project.model_name, service.project.vertices, service.project.revision]
		if selected >= service.bones.size():
			selected = -1
		if selected >= 0:
			joint_items[selected].select(0)
			view.select_joint(selected)
	preview_label.text = "绑定姿态 · 拖动关节适配角色"
	play_button.text = "播放"
	seek.set_value_no_signal(0.0)
	refreshing = false
	_refresh_joint()
	displayed_project_id = str(service.project.get("id", ""))
	weight_panel.refresh()
	if not restore_preview.is_empty():
		preview_animation(str(restore_preview.id), snappedf(restore_seconds, 0.01), restore_playing)

## 打开既有项目，源模型文件缺失也可以继续编辑。
func _open_selected(index: int) -> void:
	if refreshing or index == 0:
		return
	stop_preview()
	selected = -1
	show_result(service.open_project(str(projects.get_item_metadata(index))))
	_camera_preset(0)

## 从左侧列表选择关节。
func _select_joint(index: int) -> void:
	view.select_joint(index)

## 从视口选择关节时同步列表及细节。
func _view_selected(index: int) -> void:
	selected = index
	if index >= 0 and index < joint_items.size():
		joint_items[index].select(0)
	_refresh_joint()
	if weight_panel != null:
		weight_panel.update_bone()

## 细节面板始终显示参考关节坐标，预览时禁止编辑。
func _refresh_joint() -> void:
	var enabled = selected >= 0 and selected < service.bones.size() and not view.previewing
	for spin in coordinates:
		spin.editable = enabled
	length_input.editable = enabled and int(service.bones[selected].parent) >= 0 if enabled else false
	if not enabled:
		return
	var transforms: Array = service.core.evaluate_transforms(PackedVector3Array(), Vector3.ZERO)
	joint_label.text = service.bones[selected].name
	for axis in 3:
		coordinates[axis].set_value_no_signal(snappedf(transforms[selected].position[axis], 0.01))
		_format_spin(0.0, coordinates[axis])
	var parent = int(service.bones[selected].parent)
	length_input.set_value_no_signal(0.01 if parent < 0 else snappedf(transforms[parent].position.distance_to(transforms[selected].position), 0.01))
	_format_spin(0.0, length_input)

## 数字输入与拖动使用完全一致的项目命令。
func _coordinate_changed(_value: float, _axis: int) -> void:
	if refreshing or selected < 0 or view.previewing:
		return
	var target = [coordinates[0].value, coordinates[1].value, coordinates[2].value]
	show_result(service.move_joint(service.bones[selected].id, target, move_children.button_pressed))

## 沿当前骨段方向调整长度并联动子链。
func _length_changed(value: float) -> void:
	if not refreshing and selected >= 0 and not view.previewing:
		show_result(service.set_length(service.bones[selected].id, value))

## 开始拖动时记录撤销起点。
func _begin_drag() -> void:
	service.begin_drag()

## 实时移动参考关节并保持原始模型静止。
func _drag_joint(index: int, target: Vector3) -> void:
	var result: Dictionary = service.move_joint(service.bones[index].id, [target.x, target.y, target.z], move_children.button_pressed, true)
	if result.ok:
		view.refresh_rest()
		_refresh_joint()
	else:
		show_result(result)

## 结束拖动时保存为单次可撤销修改。
func _finish_drag() -> void:
	show_result(service.finish_drag())

## 限定拖动自由度。
func _axis_changed(index: int) -> void:
	view.move_axis = index - 1

## 适配不同导出朝向时仅旋转项目骨架。
func _rotate_rig(degrees: float) -> void:
	stop_preview()
	show_result(service.rotate_rig(degrees))

## 更改预览蒙皮方式，仍保留原始网格。
func _skin_changed(index: int) -> void:
	if not refreshing and not service.project.is_empty():
		show_result(service.update_options(service.project.name, "rigid" if index == 1 else "smooth"))

## 回车提交项目名称。
func _rename(value: String) -> void:
	if not service.project.is_empty():
		show_result(service.update_options(value, service.project.skin_mode))

## 保存按钮同时提交名称，其他编辑已经自动保存。
func save_project() -> void:
	if not service.project.is_empty() and name_input.text.strip_edges() != service.project.name:
		_rename(name_input.text)
	else:
		show_result(service.save())

## 项目撤销与重做不会触及动画编辑器历史。
func undo(redo: bool = false) -> void:
	stop_preview()
	show_result(service.undo(redo))

## 根据点击的动画开始只读播放。
func _choose_animation(index: int) -> void:
	show_result(preview_animation(str(animations.get_item_metadata(index)), 0.0, true))

## 复制所选动画快照用于播放，始终不提供关键帧编辑接口。
func preview_animation(clip_id: String, time_seconds: float = 0.0, start: bool = false) -> Dictionary:
	if service.project.is_empty():
		return {"ok": false, "error": "请先打开绑定项目。"}
	var document: Dictionary = host.commands.get_document_for_rig(service.project.rig_id)
	for clip in document.library.clips:
		if clip.id != clip_id:
			continue
		if time_seconds < 0 or not is_finite(time_seconds) or time_seconds > float(clip.duration_tick) / 60000.0 or absf(time_seconds - snappedf(time_seconds, 0.01)) > 0.000001:
			return {"ok": false, "error": "预览时间须在动画范围内，单位秒，最多两位小数。"}
		preview_clip = clip.duplicate(true)
		preview_library = document.library
		seconds = time_seconds
		playing = start
		view.begin_preview()
		seek.max_value = float(clip.duration_tick) / 60000.0
		_apply_preview()
		_refresh_joint()
		return {"ok": true}
	return {"ok": false, "error": "当前项目骨架下不存在该动画。"}

## 暂停保持当前预览姿态，返回绑定姿态需要显式点击按钮。
func toggle_play() -> void:
	if preview_clip.is_empty():
		if animations.item_count > 0:
			_choose_animation(0)
		return
	playing = not playing
	_apply_preview()

## 退出播放并恢复原模型和参考关节位置。
func stop_preview() -> void:
	playing = false
	preview_clip = {}
	seconds = 0.0
	if view != null and view.binding != null:
		view.end_preview()
	if seek != null:
		seek.set_value_no_signal(0)
		preview_label.text = "绑定姿态 · 拖动关节适配角色"
		play_button.text = "播放"
		_refresh_joint()

## 时间滑块只读定位，不记录任何关键帧。
func _seek_changed(value: float) -> void:
	if not refreshing and not preview_clip.is_empty():
		seconds = value
		playing = false
		_apply_preview()

## 使用源动作旋转和项目骨长评估最终预览。
func _apply_preview() -> void:
	var sample: Dictionary = preview_library.sample(preview_clip, roundi(seconds * 60000))
	view.set_pose(sample.pose, service.adapt_root_motion(sample.root))
	seek.set_value_no_signal(seconds)
	play_button.text = "暂停" if playing else "播放"
	preview_label.text = "%s · %.2f / %.2f 秒 · 只读预览" % [preview_clip.name, seconds, seek.max_value]

## 页面离开时暂停，避免隐藏工作区继续更新模型。
func _process(delta: float) -> void:
	if not is_visible_in_tree() or not playing or preview_clip.is_empty():
		return
	seconds += delta
	var duration = float(preview_clip.duration_tick) / 60000.0
	if seconds >= duration:
		seconds = fmod(seconds, duration) if bool(preview_clip.loop) else duration
		if not bool(preview_clip.loop):
			playing = false
	_apply_preview()

## 相机自动取景包括模型包围盒，支持原点偏移的导入文件。
func _camera_preset(index: int) -> void:
	if service.project.is_empty():
		return
	var bounds = AABB(host.rig_registry.to_vector(service.project.bounds_position_m), host.rig_registry.to_vector(service.project.bounds_size_m))
	view.set_camera_view(index)
	var center = bounds.get_center()
	var radius = maxf(0.2, bounds.size.length() * 0.5)
	var aspect = float(view.render_view.size.x) / maxf(1.0, view.render_view.size.y)
	view.configure_camera({"target_m": [center.x, center.y, center.z], "distance_m": minf(100.0, radius / sin(deg_to_rad(view.camera.fov * 0.5)) / minf(1.0, aspect) * 1.1)})

## 显示真实操作结果，失败不会冒充已经保存。
func show_result(result: Dictionary) -> void:
	if not result.get("ok", false):
		status.text = str(result.get("error", "操作失败。"))
	elif not service.project.is_empty():
		status.text = "%s · %d 顶点 · 已保存（修订 %d）" % [service.project.model_name, service.project.vertices, service.project.revision]

## 权重页启用表面选区；返回关节页时恢复原材质与关节拖动。
func _details_tab_changed(index: int) -> void:
	weight_panel.edit_toggle.button_pressed = index == 1
	weight_panel.heat_toggle.button_pressed = index == 1

## 树节点使用稳定索引选择当前骨骼。
func _tree_selected() -> void:
	var item = joints.get_selected()
	if item != null:
		_select_joint(int(item.get_metadata(0)))

## 两个功能共享模型视口，各自显示对应的配置和右侧工具。
func _switch_function(index: int) -> void:
	weight_panel._finish_stroke()
	stop_preview()
	rig_config.visible = index == 0
	weight_panel.brush_config.visible = index == 1
	details_tabs.current_tab = index
	preview_label.text = "绑定姿态 · 拖动红色关节适配模型" if index == 0 else "选择骨骼 · 左键涂抹权重 · 松开保存一笔"

## 切换项目使用的骨架，并通过撤销保留原绑定结果。
func _switch_rig(index: int) -> void:
	if refreshing or service.project.is_empty():
		return
	stop_preview()
	selected = -1
	show_result(service.switch_rig(str(rig_picker.get_item_metadata(index))))
