extends Control
## 木偶人的独立桌面界面与第一版骨骼动画编辑流程。

## 角色绑定项目的独立数据服务。
const BindingServiceScript = preload("res://app/binding_service.gd")
## 角色绑定工作区。
const BindingWorkspaceScript = preload("res://app/binding_workspace.gd")
## 当前绑定项目服务。
var binding_service
## 角色模型的实际编辑页面。
var binding_page

## 本地动作库脚本。
const LibraryScript = preload("res://app/animation_library.gd")
## 三维交互视口脚本。
const RigViewScript = preload("res://app/rig_view.gd")
## 秒制时间轨道脚本。
const TimelineScript = preload("res://app/timeline.gd")
## 本地工作台矢量图标。
const IconScript = preload("res://app/editor_icons.gd")
## 字体和界面缩放的独立持久化设置。
const PreferencesScript = preload("res://app/ui_preferences.gd")
## 可扩展骨架注册表。
const RegistryScript = preload("res://app/rig_registry.gd")
## 界面和 MCP 共用的文档命令。
const CommandsScript = preload("res://app/command_service.gd")
## 本机实例与 Python MCP 适配器之间的通道。
const BridgeScript = preload("res://app/mcp_bridge.gd")
## 以稳定标识索引的骨架定义。
var rig_registry
## 当前使用的骨架体系。
var active_rig_id: String = "standard_humanoid_v1"
## 文档命令服务。
var commands
## 本机 MCP 服务节点。
var mcp_bridge
## 当前骨架选择菜单。
var rig_selector: OptionButton
## 当前骨架关节数量说明。
var rig_summary: Label
## MCP 服务状态说明。
var mcp_status: Label
## 视口提示层中的当前骨架名称。
var rig_caption: Label
## 视口右上角的外壳透明度滑块，百分之百表示完全透明。
var shell_transparency_slider: HSlider
## 外壳透明度当前百分比，辅助精确调整。
var shell_transparency_label: Label
## 文本主色。
const INK = Color("293e49")
## 次要文本颜色。
const MUTED = Color("6d808a")
## 青绿色操作强调色。
const ACCENT = Color("128f82")
## 当前动画核心实例。
var core
## 当前固定标准骨架。
var rig: Array = []
## 载入的动作库。
var library
## 正在编辑的动画索引。
var clip_index: int = 0
## 当前编辑姿势的局部旋转。
var working_pose: PackedVector3Array = PackedVector3Array()
## 当前编辑姿势的根位移，单位为米。
var working_root: Vector3 = Vector3.ZERO
## 当前精确播放时间。
var current_tick: int = 0
## 当前姿势是否尚未记录为关键帧。
var pose_dirty: bool = false
## 动画是否正在播放。
var playing: bool = false
## 连续播放使用的秒制累积位置。
var playback_seconds: float = 0.0
## 当前播放速度倍率。
var playback_speed: float = 1.0
## 防止程序刷新细节数值触发编辑信号。
var refreshing: bool = false
## 当前顶部功能页，便于取消切换时恢复正确高亮。
var current_page: int = 0
## 三维视口。
var rig_view
## 时间轨道。
var timeline
## 主编辑布局。
var editor_page: HBoxContainer
## 视口下方的动画编辑区域。
var timeline_panel: PanelContainer
## 动画资源列表所在容器。
var animation_list: VBoxContainer
## 关键姿势卡片容器。
var key_cards: HBoxContainer
## 关节树。
var joint_tree: Tree
## 关节树中各骨骼对应的行。
var joint_items: Array = []
## 顶部导航按钮。
var nav_buttons: Array = []
## 左侧工作区按钮。
var workspace_buttons: Array = []
## 左侧姿势工具按钮。
var tool_buttons: Array = []
## 动画列表按钮。
var clip_buttons: Array = []
## 时间卡片按钮。
var key_buttons: Array = []
## 当前所选关节的标题。
var joint_title: Label
## 当前所选关节的补充说明。
var joint_description: Label
## 三轴旋转输入。
var rotation_inputs: Array = []
## 根位置三轴输入。
var root_inputs: Array = []
## 当前动画名称。
var clip_title: Label
## 当前时间文字。
var time_label: Label
## 当前姿势记录状态。
var draft_label: Label
## 播放按钮。
var play_button: Button
## 动作时长输入。
var duration_input: SpinBox
## 插值方式选择。
var interpolation_option: OptionButton
## 循环播放开关。
var loop_toggle: CheckBox
## 自动关键帧开关。
var auto_key: CheckBox
## 状态栏文字。
var status_label: Label
## 新建或重命名动作的对话框。
var name_dialog: ConfirmationDialog
## 动作名称输入框。
var name_input: LineEdit
## 名称对话框当前操作。
var name_action: String = "new"
## 保留未记录姿势的确认框。
var draft_dialog: ConfirmationDialog
## 等待姿势处理后继续的动作。
var pending_action: Callable
## 可撤销的当前动作快照。
var undo_stack: Array = []
## 可重做的当前动作快照。
var redo_stack: Array = []

## 填满真实窗口的根布局。
var shell_root: VBoxContainer
## 左侧骨骼与动画资源栏。
var resources_panel: PanelContainer
## 右侧关节细节栏。
var details_panel: PanelContainer
## 中央视口与时间轴列。
var center_column: VBoxContainer
## 视口的容器和叠放提示层。
var viewport_host: Control
## 视口当前子功能名称。
var viewport_caption: Label
## 视口下方的操作提示。
var viewport_hint: Label
## 当前工具的辅助文字。
var toolbar_caption: Label
## 资源栏显隐按钮。
var resources_toggle: Button
## 细节栏显隐按钮。
var details_toggle: Button
## 专注视口切换按钮。
var focus_button: Button
## 地面网格切换按钮。
var grid_toggle: Button
## 是否临时收起两侧面板。
var focused_workspace: bool = false
## 资源栏偏好：零表示自动，正数表示打开，负数表示关闭。
var resources_preference: int = 0
## 细节栏偏好：零表示自动，正数表示打开，负数表示关闭。
var details_preference: int = 0
## 角色根位移的折叠区。
var root_section: VBoxContainer
## 根位移折叠按钮。
var root_fold_button: Button
## 选中关节三轴活动范围的真实数值。
var limit_labels: Array = []
## 动画库数量标签。
var animation_count: Label
## 动画面板内的选项按钮。
var options_button: Button
## 自动关键帧和插值设置的弹出面板。
var animation_options: PopupPanel
## 状态栏右侧的单位说明。
var footer_unit: Label
## 当前用户外观偏好。
var ui_preferences
## 保持顶部导航可见的工作区滚动容器。
var body_scroll: ScrollContainer
## 动画、角色与设置页面的公共容器。
var page_stack: VBoxContainer
## 实际设置页面。
var settings_page: MarginContainer
## 设置项描述及输入的响应式网格。
var settings_grid: GridContainer
## 设置内容限制在可读宽度内，并在窄窗口中继续收缩。
var settings_column: VBoxContainer
## 正文字号输入。
var font_size_input: SpinBox
## 全局界面缩放选择。
var interface_scale_option: OptionButton
## 外观设置保存结果。
var appearance_status: Label
## 左上角品牌表面，窄逻辑窗口中缩为图标。
var brand_panel: PanelContainer
## 可在窄窗口中隐藏的品牌文字。
var brand_copy: VBoxContainer
## 顶部导航行，用来测量文字放大后的实际宽度。
var navigation_row: HBoxContainer
## 关键帧列表的滚动容器，字体放大时同步增加行高。
var key_scroll: ScrollContainer
## 防止外观控件同步时再次写入设置。
var syncing_appearance: bool = false

## 初始化扩展、界面与本地动画资源。
func _ready() -> void:
	DisplayServer.window_set_title("木偶人")
	get_window().min_size = Vector2i(900, 620)
	get_tree().auto_accept_quit = false
	var storage_override = ""
	var preferences_override = ""
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--workspace="):
			storage_override = argument.trim_prefix("--workspace=")
		elif argument.begins_with("--settings="):
			preferences_override = argument.trim_prefix("--settings=")
	if preferences_override.is_empty() and not storage_override.is_empty():
		preferences_override = storage_override.path_join("settings.cfg")
	ui_preferences = PreferencesScript.new()
	ui_preferences.load_settings(preferences_override)
	theme = _create_theme()
	if not ClassDB.class_exists("PuppetAnimator"):
		var failure = _label("动画组件尚未构建。请先运行项目 scripts/构建.ps1。", 20)
		add_child(failure)
		return
	core = ClassDB.instantiate("PuppetAnimator")
	rig_registry = RegistryScript.new()
	rig_registry.initialize(core, "" if storage_override.is_empty() else storage_override.path_join("_rigs"))
	core = rig_registry.create_core(active_rig_id)
	rig = rig_registry.native_definition(active_rig_id)
	library = LibraryScript.new()
	library.initialize(core, rig, storage_override)
	commands = CommandsScript.new()
	commands.initialize(self, rig_registry, core, library, storage_override)
	mcp_bridge = BridgeScript.new()
	add_child(mcp_bridge)
	var instance_directory = ProjectSettings.globalize_path("res://workspace/mcp/instances") if storage_override.is_empty() else storage_override.path_join("_mcp/instances")
	mcp_bridge.initialize(commands, instance_directory)
	binding_service = BindingServiceScript.new()
	binding_service.initialize(rig_registry, "" if storage_override.is_empty() else storage_override.path_join("_bindings"))
	binding_service.changed.connect(commands.note_draft_changed)
	_build_interface()
	commands.initialize_binding()
	get_window().files_dropped.connect(_on_model_files_dropped)
	_build_dialogs()
	_apply_display_preferences()
	_refresh_animation_list()
	_switch_clip(0)
	rig_view.select_joint(4)
	if ui_preferences.mcp_enabled:
		mcp_bridge.start()
	_update_mcp_status(mcp_bridge.status_text)
	_set_status("选择关节开始摆姿势；在任意时刻记录关键帧。")
	if not binding_service.last_project_id.is_empty():
		var opened: Dictionary = binding_service.open_project(binding_service.last_project_id)
		if opened.ok:
			_show_page(1)
			binding_page._camera_preset(0)

## 创建紧凑的浅色桌面主题，统一按钮、输入框与面板间距。
func _create_theme() -> Theme:
	var result = Theme.new()
	var font = SystemFont.new()
	font.font_names = PackedStringArray(["Microsoft YaHei UI", "Microsoft YaHei", "Noto Sans CJK SC"])
	result.default_font = font
	result.default_font_size = ui_preferences.font_size
	for type_name in ["Label", "Button", "LineEdit", "Tree", "CheckBox", "OptionButton"]:
		result.set_color("font_color", type_name, INK)
	for state in ["font_hover_color", "font_pressed_color", "font_hover_pressed_color"]:
		result.set_color(state, "Button", ACCENT)
	result.set_color("icon_normal_color", "Button", INK)
	for state in ["icon_hover_color", "icon_pressed_color", "icon_hover_pressed_color"]:
		result.set_color(state, "Button", ACCENT)
	result.set_stylebox("normal", "Button", _style("ffffff", "dce5e9", 5, 6))
	result.set_stylebox("hover", "Button", _style("eef3f5", "dce5e9", 5, 6))
	result.set_stylebox("pressed", "Button", _style("e0f2ed", "a4d9ce", 5, 6))
	result.set_stylebox("hover_pressed", "Button", _style("d7eee7", "a4d9ce", 5, 6))
	result.set_stylebox("focus", "Button", _style("ffffff00", "76bfb2", 5, 0))
	result.set_constant("h_separation", "Button", 6)
	result.set_constant("icon_max_width", "Button", 16)
	result.set_type_variation("PrimaryButton", "Button")
	result.set_stylebox("normal", "PrimaryButton", _style("128f82", "128f82", 5, 7))
	result.set_stylebox("hover", "PrimaryButton", _style("0b9d8c", "0b9d8c", 5, 7))
	result.set_stylebox("pressed", "PrimaryButton", _style("08796d", "08796d", 5, 7))
	for state in ["font_color", "font_hover_color", "font_pressed_color", "icon_normal_color", "icon_hover_color", "icon_pressed_color"]:
		result.set_color(state, "PrimaryButton", Color.WHITE)
	for variant in ["QuietButton", "ToolButton", "RailButton", "NavButton"]:
		result.set_type_variation(variant, "Button")
		result.set_stylebox("normal", variant, _style("ffffff00", "ffffff00", 5, 5))
		result.set_stylebox("hover", variant, _style("eef3f5", "eef3f5", 5, 5))
		result.set_stylebox("pressed", variant, _style("e0f2ed", "e0f2ed", 5, 5))
		result.set_stylebox("hover_pressed", variant, _style("d7eee7", "d7eee7", 5, 5))
	result.set_constant("icon_max_width", "RailButton", 24)
	var nav_normal = _style("ffffff00", "ffffff00", 0, 12)
	nav_normal.content_margin_top = 0
	nav_normal.content_margin_bottom = 0
	result.set_stylebox("normal", "NavButton", nav_normal)
	result.set_stylebox("hover", "NavButton", nav_normal)
	var nav_selected = nav_normal.duplicate()
	nav_selected.border_color = ACCENT
	nav_selected.set_border_width_all(0)
	nav_selected.border_width_bottom = 3
	result.set_stylebox("pressed", "NavButton", nav_selected)
	result.set_stylebox("hover_pressed", "NavButton", nav_selected)
	result.set_stylebox("panel", "PanelContainer", _style("ffffff", "dce5e9", 0, 0))
	result.set_stylebox("normal", "LineEdit", _style("f7f9fa", "dce5e9", 4, 5))
	result.set_stylebox("focus", "LineEdit", _style("f7f9fa", "7cc3b6", 4, 5))
	result.set_color("font_selected_color", "Tree", Color("087d70"))
	result.set_color("guide_color", "Tree", Color("dce5e9"))
	result.set_stylebox("panel", "Tree", _style("ffffff00", "ffffff00", 0, 2))
	result.set_stylebox("selected", "Tree", _style("e0f2ed", "e0f2ed", 4, 2))
	result.set_stylebox("selected_focus", "Tree", _style("e0f2ed", "e0f2ed", 4, 2))
	result.set_constant("v_separation", "Tree", 4)
	result.set_constant("item_margin", "Tree", 10)
	result.set_color("font_color", "TooltipLabel", INK)
	result.set_font_size("font_size", "TooltipLabel", ui_preferences.text_size(12))
	result.set_stylebox("panel", "TooltipPanel", _style("ffffff", "cbdadf", 5, 7))
	result.set_stylebox("panel", "PopupPanel", _style("ffffff", "cbdadf", 6, 12))
	for state in ["normal", "hover", "pressed", "hover_pressed"]:
		result.set_stylebox(state, "CheckBox", _style("ffffff00", "ffffff00", 0, 1))
	result.set_constant("separation", "VBoxContainer", 6)
	result.set_constant("separation", "HBoxContainer", 6)
	return result

## 构建具有明确内边距的面板或按钮样式。
func _style(background: String, border: String, radius: int, padding: int) -> StyleBoxFlat:
	var style = StyleBoxFlat.new()
	style.bg_color = Color(background)
	style.border_color = Color(border)
	style.set_border_width_all(1)
	style.set_corner_radius_all(radius)
	style.content_margin_left = padding
	style.content_margin_right = padding
	style.content_margin_top = padding
	style.content_margin_bottom = padding
	return style

## 创建统一文字样式的标签。
func _label(text: String, font_size: int = 13, color: Color = INK) -> Label:
	var label = Label.new()
	label.text = text
	_set_font_size(label, font_size)
	label.add_theme_color_override("font_color", color)
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return label

## 记录控件的设计字号，使每次修改外观都从原始值计算而不累加误差。
func _set_font_size(control: Control, design_size: int) -> void:
	control.set_meta("design_font_size", design_size)
	control.add_theme_font_size_override("font_size", ui_preferences.text_size(design_size))

## 创建带中文说明的紧凑操作按钮。
func _button(text: String, action: Callable, variant: String = "", width: float = 0) -> Button:
	var button = Button.new()
	button.text = text
	button.custom_minimum_size = Vector2(width, 28)
	button.focus_mode = Control.FOCUS_NONE
	if not variant.is_empty():
		button.theme_type_variation = variant
	if action.is_valid():
		button.pressed.connect(action)
	return button

## 创建具有悬停说明的图标操作，统一使用本地矢量资源。
func _icon_button(icon_name: String, tooltip: String, action: Callable, variant: String = "ToolButton", edge: int = 30) -> Button:
	var button = _button("", action, variant, edge)
	button.custom_minimum_size.y = edge
	button.icon = IconScript.get_icon(icon_name)
	button.expand_icon = false
	button.tooltip_text = tooltip
	return button

## 为内容添加明确的四边内边距。
func _margin(parent: Node, left: int, top: int, right: int, bottom: int) -> MarginContainer:
	var margin = MarginContainer.new()
	for pair in [["left", left], ["top", top], ["right", right], ["bottom", bottom]]:
		margin.add_theme_constant_override("margin_" + pair[0], pair[1])
	parent.add_child(margin)
	return margin

## 创建无圆角的大面积工作台表面，避免卡片留白挤占视口。
func _surface(parent: Node, background: String = "ffffff") -> PanelContainer:
	var panel = PanelContainer.new()
	panel.add_theme_stylebox_override("panel", _style(background, "dce5e9", 0, 0))
	parent.add_child(panel)
	return panel

## 为容器添加占用剩余宽度或高度的空白。
func _spacer(parent: Node, vertical: bool = false) -> Control:
	var space = Control.new()
	if vertical:
		space.size_flags_vertical = Control.SIZE_EXPAND_FILL
	else:
		space.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	parent.add_child(space)
	return space

## 构建左侧图标与资源、中央视口、右侧细节的自适应工作台。
func _build_interface() -> void:
	var background = ColorRect.new()
	background.color = Color("f7f9fa")
	background.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	background.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(background)
	shell_root = VBoxContainer.new()
	shell_root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	shell_root.add_theme_constant_override("separation", 0)
	add_child(shell_root)
	var header = HBoxContainer.new()
	header.custom_minimum_size.y = 52
	header.add_theme_constant_override("separation", 0)
	shell_root.add_child(header)
	_build_brand(header)
	var navigation = _surface(header)
	navigation.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	navigation_row = HBoxContainer.new()
	navigation_row.add_theme_constant_override("separation", 4)
	navigation.add_child(navigation_row)
	for index in 3:
		var button = _button(["骨骼动画", "角色模型", "设置"][index], _request_page.bind(index), "NavButton")
		button.icon = IconScript.get_icon(["bone", "model", "settings"][index])
		button.expand_icon = false
		button.toggle_mode = true
		button.button_pressed = index == 0
		nav_buttons.append(button)
		navigation_row.add_child(button)
	_spacer(navigation_row)
	body_scroll = ScrollContainer.new()
	body_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	body_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	shell_root.add_child(body_scroll)
	page_stack = VBoxContainer.new()
	page_stack.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	page_stack.size_flags_vertical = Control.SIZE_EXPAND_FILL
	page_stack.add_theme_constant_override("separation", 0)
	body_scroll.add_child(page_stack)
	editor_page = HBoxContainer.new()
	editor_page.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	editor_page.size_flags_vertical = Control.SIZE_EXPAND_FILL
	editor_page.add_theme_constant_override("separation", 0)
	page_stack.add_child(editor_page)
	_build_sidebar()
	_build_resource_panel()
	var workspace = VBoxContainer.new()
	workspace.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	workspace.add_theme_constant_override("separation", 0)
	editor_page.add_child(workspace)
	_build_toolbar(workspace)
	var content = HBoxContainer.new()
	content.size_flags_vertical = Control.SIZE_EXPAND_FILL
	content.add_theme_constant_override("separation", 0)
	workspace.add_child(content)
	center_column = VBoxContainer.new()
	center_column.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	center_column.add_theme_constant_override("separation", 0)
	content.add_child(center_column)
	_build_viewport(center_column)
	_build_timeline(center_column)
	_build_details(content)
	binding_page = BindingWorkspaceScript.new()
	page_stack.add_child(binding_page)
	binding_page.initialize(self, binding_service)
	binding_page.visible = false
	_build_settings_page()
	var footer_panel = _surface(shell_root)
	footer_panel.custom_minimum_size.y = 23
	var footer = HBoxContainer.new()
	_margin(footer_panel, 10, 0, 10, 0).add_child(footer)
	status_label = _label("", 11, MUTED)
	status_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	status_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	footer.add_child(status_label)
	footer_unit = _label("标准人形  ·  单位：米 / 秒", 11, MUTED)
	footer.add_child(footer_unit)
	resized.connect(_apply_responsive_layout)
	center_column.resized.connect(_update_center_density)
	_apply_responsive_layout.call_deferred()

## 将原有品牌压缩到固定五十二像素高的窗口左上角。
func _build_brand(parent: Node) -> void:
	brand_panel = _surface(parent)
	brand_panel.custom_minimum_size.x = 240
	var row = HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	_margin(brand_panel, 12, 6, 10, 6).add_child(row)
	var icon = TextureRect.new()
	icon.texture = load("res://assets/木偶人.svg")
	icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	icon.custom_minimum_size = Vector2(34, 34)
	row.add_child(icon)
	brand_copy = VBoxContainer.new()
	brand_copy.alignment = BoxContainer.ALIGNMENT_CENTER
	brand_copy.add_theme_constant_override("separation", 0)
	brand_copy.add_child(_label("木偶人", 21))
	brand_copy.add_child(_label("让每一个姿势，连成动作", 11, MUTED))
	row.add_child(brand_copy)

## 创建只显示大图标的子功能栏，并通过悬停展示名称。
func _build_sidebar() -> void:
	var rail = _surface(editor_page)
	rail.custom_minimum_size.x = 56
	var column = VBoxContainer.new()
	column.add_theme_constant_override("separation", 8)
	_margin(rail, 5, 10, 5, 10).add_child(column)
	for index in 2:
		var button = _icon_button(["skeleton", "animation"][index], ["骨架预览", "动画制作"][index], _set_workspace.bind(index), "RailButton", 42)
		button.toggle_mode = true
		button.button_pressed = index == 1
		workspace_buttons.append(button)
		column.add_child(button)
	_spacer(column, true)
	focus_button = _icon_button("frame", "专注视口：收起或恢复两侧面板", _toggle_focus, "RailButton", 42)
	focus_button.toggle_mode = true
	column.add_child(focus_button)

## 将只读骨骼层级和本地动画库统一放在视口左侧。
func _build_resource_panel() -> void:
	resources_panel = _surface(editor_page, "f7f9fa")
	resources_panel.custom_minimum_size.x = 184
	var column = VBoxContainer.new()
	column.add_theme_constant_override("separation", 5)
	_margin(resources_panel, 6, 4, 6, 5).add_child(column)
	var heading = HBoxContainer.new()
	heading.add_child(_label("骨骼列表", 13))
	_spacer(heading)
	heading.add_child(_icon_button("panel_left", "收起资源列表", _toggle_resources, "QuietButton", 28))
	column.add_child(heading)
	var preset = _surface(column)
	var preset_row = HBoxContainer.new()
	_margin(preset, 8, 7, 6, 7).add_child(preset_row)
	var icon = TextureRect.new()
	icon.texture = IconScript.get_icon("skeleton")
	icon.modulate = ACCENT
	icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	icon.custom_minimum_size = Vector2(20, 26)
	icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	preset_row.add_child(icon)
	var description = VBoxContainer.new()
	description.add_theme_constant_override("separation", 1)
	rig_selector = OptionButton.new()
	rig_selector.custom_minimum_size.x = 110
	rig_selector.fit_to_longest_item = false
	rig_selector.clip_text = true
	rig_selector.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	rig_selector.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	rig_selector.item_selected.connect(_request_rig)
	description.add_child(rig_selector)
	rig_summary = _label("", 11, MUTED)
	description.add_child(rig_summary)
	refresh_rig_selector()
	preset_row.add_child(description)
	joint_tree = Tree.new()
	joint_tree.size_flags_vertical = Control.SIZE_EXPAND_FILL
	joint_tree.size_flags_stretch_ratio = 1.5
	joint_tree.hide_root = true
	joint_tree.custom_minimum_size.y = 170
	joint_tree.select_mode = Tree.SELECT_ROW
	joint_tree.hide_folding = false
	column.add_child(joint_tree)
	_populate_joint_tree()
	joint_tree.item_selected.connect(_on_tree_selected)
	column.add_child(HSeparator.new())
	_build_animation_list(column)

## 将当前子功能对应的姿势工具放在视口正上方。
func _build_toolbar(parent: Node) -> void:
	var panel = _surface(parent)
	panel.custom_minimum_size.y = 38
	var row = HBoxContainer.new()
	row.add_theme_constant_override("separation", 4)
	_margin(panel, 8, 3, 8, 3).add_child(row)
	for index in 3:
		var button = _icon_button(["select", "rotate", "orbit"][index], ["选择与拖拽 · W", "旋转关节 · E", "观察视角 · Q"][index], _set_tool.bind(index))
		button.toggle_mode = true
		button.button_pressed = index == 0
		tool_buttons.append(button)
		row.add_child(button)
	row.add_child(VSeparator.new())
	row.add_child(_icon_button("frame", "聚焦骨架 · F", _focus_camera))
	toolbar_caption = _label("选择与拖拽", 11, MUTED)
	row.add_child(toolbar_caption)
	_spacer(row)
	grid_toggle = _icon_button("grid", "显示或隐藏地面网格", _toggle_grid)
	grid_toggle.toggle_mode = true
	grid_toggle.button_pressed = true
	row.add_child(grid_toggle)
	row.add_child(VSeparator.new())
	resources_toggle = _icon_button("panel_left", "显示或收起资源列表", _toggle_resources)
	resources_toggle.toggle_mode = true
	row.add_child(resources_toggle)
	details_toggle = _icon_button("panel_right", "显示或收起细节面板", _toggle_details)
	details_toggle.toggle_mode = true
	row.add_child(details_toggle)

## 使用真实三维视口填充剩余区域，提示与视角选择叠放在视口内。
func _build_viewport(parent: Node) -> void:
	viewport_host = Control.new()
	viewport_host.custom_minimum_size = Vector2(360, 260)
	viewport_host.size_flags_vertical = Control.SIZE_EXPAND_FILL
	viewport_host.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	parent.add_child(viewport_host)
	rig_view = RigViewScript.new()
	rig_view.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	viewport_host.add_child(rig_view)
	rig_view.initialize(core, rig)
	rig_view.joint_selected.connect(_on_joint_selected)
	rig_view.edit_started.connect(_push_undo)
	rig_view.pose_edited.connect(_on_pose_edited)
	rig_view.edit_finished.connect(_on_edit_finished)
	var top = HBoxContainer.new()
	top.set_anchors_and_offsets_preset(Control.PRESET_TOP_WIDE)
	top.offset_left = 12
	top.offset_right = -12
	top.offset_top = 10
	top.offset_bottom = 38
	top.mouse_filter = Control.MOUSE_FILTER_IGNORE
	viewport_host.add_child(top)
	viewport_caption = _label("动画制作", 12)
	top.add_child(viewport_caption)
	rig_caption = _label(str(rig_registry.definitions[active_rig_id].name), 11, MUTED)
	rig_caption.clip_text = true
	top.add_child(rig_caption)
	_spacer(top).mouse_filter = Control.MOUSE_FILTER_IGNORE
	var shell_label = _label("外壳", 11, MUTED)
	shell_label.tooltip_text = "视觉外壳透明度，不影响内部骨骼"
	top.add_child(shell_label)
	shell_transparency_slider = HSlider.new()
	shell_transparency_slider.min_value = 0
	shell_transparency_slider.max_value = 100
	shell_transparency_slider.step = 1
	shell_transparency_slider.value = roundf((1.0 - rig_view.shell_opacity) * 100.0)
	shell_transparency_slider.custom_minimum_size = Vector2(76, 26)
	shell_transparency_slider.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	shell_transparency_slider.tooltip_text = "外壳透明度：0% 为不透明，100% 为完全透明"
	shell_transparency_slider.value_changed.connect(_on_shell_transparency_changed)
	top.add_child(shell_transparency_slider)
	shell_transparency_label = _label("%d%%" % roundi(shell_transparency_slider.value), 11, MUTED)
	shell_transparency_label.custom_minimum_size.x = 39
	shell_transparency_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	top.add_child(shell_transparency_label)
	var camera_option = OptionButton.new()
	camera_option.custom_minimum_size = Vector2(74, 26)
	camera_option.tooltip_text = "切换观察视角"
	for item in ["透视", "正面", "侧面", "背面"]:
		camera_option.add_item(item)
	camera_option.item_selected.connect(rig_view.set_camera_view)
	top.add_child(camera_option)
	viewport_hint = _label("拖动关节调整姿势 · 右键观察 · 滚轮缩放", 11, MUTED)
	viewport_hint.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_WIDE)
	viewport_hint.offset_left = 12
	viewport_hint.offset_right = -12
	viewport_hint.offset_top = -29
	viewport_hint.offset_bottom = -8
	viewport_hint.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	viewport_host.add_child(viewport_hint)

## 创建视口左侧的动画库，保留新建、切换和重命名操作。
func _build_animation_list(parent: Node) -> void:
	var heading = HBoxContainer.new()
	heading.add_child(_label("动画库", 13))
	animation_count = _label("", 11, MUTED)
	heading.add_child(animation_count)
	_spacer(heading)
	heading.add_child(_icon_button("plus", "新建动画", _show_name_dialog.bind("new"), "QuietButton", 26))
	heading.add_child(_icon_button("rename", "重命名当前动画", _show_name_dialog.bind("rename"), "QuietButton", 26))
	parent.add_child(heading)
	var scroll = ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.custom_minimum_size.y = 136
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	parent.add_child(scroll)
	animation_list = VBoxContainer.new()
	animation_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	animation_list.add_theme_constant_override("separation", 3)
	scroll.add_child(animation_list)

## 在动画制作面板集中保存、撤销、关键帧、时间和播放操作。
func _build_timeline(parent: Node) -> void:
	timeline_panel = _surface(parent)
	timeline_panel.custom_minimum_size.y = 184
	var column = VBoxContainer.new()
	column.add_theme_constant_override("separation", 3)
	_margin(timeline_panel, 8, 4, 8, 4).add_child(column)
	var heading = HFlowContainer.new()
	heading.add_theme_constant_override("h_separation", 4)
	heading.add_theme_constant_override("v_separation", 4)
	clip_title = _label("", 13)
	clip_title.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	clip_title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	clip_title.custom_minimum_size.x = 60
	heading.add_child(clip_title)
	draft_label = _label("已记录", 11, ACCENT)
	heading.add_child(draft_label)
	heading.add_child(_icon_button("undo", "撤销 · Ctrl+Z", _undo, "QuietButton", 28))
	heading.add_child(_icon_button("redo", "重做 · Ctrl+Shift+Z", _redo, "QuietButton", 28))
	heading.add_child(VSeparator.new())
	var save_button = _icon_button("save", "保存动画 · Ctrl+S", _save_animation, "QuietButton", 28)
	save_button.text = "保存"
	heading.add_child(save_button)
	heading.add_child(_icon_button("delete", "删除当前关键帧 · Delete", _delete_key, "QuietButton", 28))
	var key_button = _icon_button("key", "记录或更新当前时刻的关键帧", _save_keyframe, "PrimaryButton", 28)
	key_button.text = "关键帧"
	heading.add_child(key_button)
	options_button = _icon_button("more", "动画选项：自动关键帧与过渡方式", _open_animation_options, "QuietButton", 28)
	heading.add_child(options_button)
	column.add_child(heading)
	key_scroll = ScrollContainer.new()
	key_scroll.custom_minimum_size.y = 31
	key_scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	column.add_child(key_scroll)
	key_cards = HBoxContainer.new()
	key_cards.add_theme_constant_override("separation", 5)
	key_scroll.add_child(key_cards)
	timeline = TimelineScript.new()
	timeline.size_flags_vertical = Control.SIZE_EXPAND_FILL
	timeline.seek_requested.connect(_request_seek)
	timeline.key_move_requested.connect(_move_key)
	column.add_child(timeline)
	var controls = HFlowContainer.new()
	controls.add_theme_constant_override("h_separation", 4)
	controls.add_theme_constant_override("v_separation", 4)
	controls.add_child(_icon_button("previous", "后退一帧", _step_frame.bind(-1), "QuietButton", 28))
	play_button = _icon_button("play", "播放或暂停 · 空格", _toggle_play, "ToolButton", 28)
	controls.add_child(play_button)
	controls.add_child(_icon_button("next", "前进一帧", _step_frame.bind(1), "QuietButton", 28))
	time_label = _label("0.00 / 2.00 秒", 11)
	controls.add_child(time_label)
	_spacer(controls)
	var speed = OptionButton.new()
	speed.tooltip_text = "播放速度"
	_set_font_size(speed, 11)
	for value in [0.25, 0.5, 1.0, 1.5, 2.0]:
		speed.add_item("%s×" % str(value))
	speed.select(2)
	speed.item_selected.connect(_on_speed_selected)
	controls.add_child(speed)
	loop_toggle = CheckBox.new()
	loop_toggle.text = "循环"
	_set_font_size(loop_toggle, 11)
	loop_toggle.toggled.connect(_on_loop_changed)
	controls.add_child(loop_toggle)
	controls.add_child(_label("时长", 11, MUTED))
	duration_input = _spin(0.1, 600.0, 0.01)
	duration_input.custom_minimum_size.x = 82
	duration_input.suffix = "秒"
	duration_input.value_changed.connect(_on_duration_changed)
	controls.add_child(duration_input)
	column.add_child(controls)
	_build_animation_options()

## 将不常改动的动画选项放入动画面板内的弹出菜单。
func _build_animation_options() -> void:
	animation_options = PopupPanel.new()
	animation_options.title = "动画选项"
	add_child(animation_options)
	var column = VBoxContainer.new()
	column.custom_minimum_size.x = 220
	column.add_child(_label("动画选项", 13))
	auto_key = CheckBox.new()
	auto_key.text = "自动关键帧"
	auto_key.tooltip_text = "每次姿势调整结束时，自动记录到当前关键帧"
	column.add_child(auto_key)
	var row = HBoxContainer.new()
	row.add_child(_label("过渡方式", 12, MUTED))
	interpolation_option = OptionButton.new()
	interpolation_option.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	for item in ["保持", "线性过渡", "平滑过渡"]:
		interpolation_option.add_item(item)
	interpolation_option.item_selected.connect(_on_interpolation_changed)
	row.add_child(interpolation_option)
	column.add_child(row)
	animation_options.add_child(column)

## 在选项图标附近打开弹出菜单，并由 Godot 将窗口限制在屏幕范围内。
func _open_animation_options() -> void:
	animation_options.popup(Rect2i(Vector2i(options_button.get_screen_position()) + Vector2i(-220, 30), Vector2i(246, 126)))

## 更新实际播放倍率，不改变保存的动画时长。
func _on_speed_selected(index: int) -> void:
	playback_speed = [0.25, 0.5, 1.0, 1.5, 2.0][index]

## 以可滚动、可折叠的细节面板保留关节和角色根位移编辑。
func _build_details(parent: Node) -> void:
	details_panel = _surface(parent)
	details_panel.custom_minimum_size.x = 212
	var scroll = ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	details_panel.add_child(scroll)
	var column = VBoxContainer.new()
	column.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	column.add_theme_constant_override("separation", 7)
	_margin(scroll, 11, 7, 11, 10).add_child(column)
	var heading = HBoxContainer.new()
	heading.add_child(_label("细节", 13))
	_spacer(heading)
	heading.add_child(_icon_button("panel_right", "收起细节面板", _toggle_details, "QuietButton", 26))
	column.add_child(heading)
	column.add_child(HSeparator.new())
	joint_title = _label("选择一个关节", 14)
	column.add_child(joint_title)
	joint_description = _label("在视口中点击关节点", 11, MUTED)
	column.add_child(joint_description)
	column.add_child(HSeparator.new())
	var rotation_heading = HBoxContainer.new()
	rotation_heading.add_child(_label("旋转", 12))
	_spacer(rotation_heading)
	rotation_heading.add_child(_label("局部坐标", 11, MUTED))
	column.add_child(rotation_heading)
	for axis in 3:
		var row = HBoxContainer.new()
		var label = _label(["X", "Y", "Z"][axis], 12, [Color("c26565"), Color("399b85"), Color("5b87b4")][axis])
		label.custom_minimum_size.x = 17
		row.add_child(label)
		var input = _spin(-180, 180, 0.01)
		input.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		input.suffix = "°"
		input.value_changed.connect(_on_rotation_changed.bind(axis))
		rotation_inputs.append(input)
		row.add_child(input)
		column.add_child(row)
	column.add_child(_label("角度受预设关节活动范围限制", 11, MUTED))
	column.add_child(HSeparator.new())
	column.add_child(_label("活动范围 / 度", 12))
	for axis in 3:
		var label = _label("", 11, MUTED)
		limit_labels.append(label)
		column.add_child(label)
	column.add_child(HSeparator.new())
	root_fold_button = _button("角色根位移 / 米", _toggle_root_section, "QuietButton")
	root_fold_button.alignment = HORIZONTAL_ALIGNMENT_LEFT
	root_fold_button.icon = IconScript.get_icon("chevron_right")
	root_fold_button.expand_icon = false
	column.add_child(root_fold_button)
	root_section = VBoxContainer.new()
	root_section.visible = false
	column.add_child(root_section)
	for axis in 3:
		var row = HBoxContainer.new()
		row.add_child(_label(["X", "Y", "Z"][axis], 12, MUTED))
		var input = _spin(-10, 10, 0.01)
		input.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		input.suffix = "米"
		input.value_changed.connect(_on_root_changed.bind(axis))
		root_inputs.append(input)
		row.add_child(input)
		root_section.add_child(row)
	column.add_child(HSeparator.new())
	column.add_child(_label("视口显示", 12))
	for option in ["core", "shell"]:
		var toggle = CheckBox.new()
		toggle.text = "骨骼核心" if option == "core" else "半透明模型"
		toggle.button_pressed = true
		toggle.toggled.connect(_on_visual_changed.bind(option))
		column.add_child(toggle)
	var reset = _icon_button("reset", "恢复全身标准姿势及角色根位移", _reset_pose, "QuietButton", 28)
	reset.text = "重置当前姿势"
	column.add_child(reset)
	column.add_child(_label("骨架结构与骨长固定", 11, MUTED))

## 展开或收起仍可编辑的角色整体位移。
func _toggle_root_section() -> void:
	root_section.visible = not root_section.visible
	root_fold_button.icon = IconScript.get_icon("chevron_down" if root_section.visible else "chevron_right")

## 同步模型外壳与骨骼核心的实际可见状态。
func _on_visual_changed(visible_value: bool, option: String) -> void:
	if option == "core":
		rig_view.show_core = visible_value
	else:
		rig_view.show_shell = visible_value
	rig_view.set_pose(working_pose, working_root)

## 外壳透明度仅改变视口显示，不写入动画、不产生姿势撤销记录。
func _on_shell_transparency_changed(value: float) -> void:
	rig_view.set_shell_opacity(1.0 - value / 100.0)
	shell_transparency_label.text = "%d%%" % roundi(value)

## 保留原有聚焦骨架操作。
func _focus_camera() -> void:
	rig_view.set_camera_view(0)

## 切换三维地面网格，不影响骨架或动画数据。
func _toggle_grid() -> void:
	rig_view.set_grid_visible(grid_toggle.button_pressed)

## 切换资源栏，窄窗口中优先为最后打开的面板留出空间。
func _toggle_resources() -> void:
	resources_preference = -1 if resources_panel.visible else 1
	if resources_preference == 1 and size.x < 1060:
		details_preference = -1
	focused_workspace = false
	_apply_responsive_layout()

## 切换细节栏，避免窄窗口中的两侧面板挤出中央工作区。
func _toggle_details() -> void:
	details_preference = -1 if details_panel.visible else 1
	if details_preference == 1 and size.x < 1060:
		resources_preference = -1
	focused_workspace = false
	_apply_responsive_layout()

## 一键进入专注视口，并在退出时恢复原有侧栏偏好。
func _toggle_focus() -> void:
	focused_workspace = not focused_workspace
	_apply_responsive_layout()

## 构建实际外观设置，保留随时恢复默认值的入口。
func _build_settings_page() -> void:
	settings_page = _margin(page_stack, 24, 22, 24, 24)
	settings_page.visible = false
	settings_page.size_flags_vertical = Control.SIZE_EXPAND_FILL
	settings_column = VBoxContainer.new()
	var column = settings_column
	column.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	column.add_theme_constant_override("separation", 16)
	settings_page.add_child(column)
	column.add_child(_label("设置", 24))
	column.add_child(_label("显示与缩放", 17))
	settings_grid = GridContainer.new()
	settings_grid.columns = 2
	settings_grid.add_theme_constant_override("h_separation", 30)
	settings_grid.add_theme_constant_override("v_separation", 20)
	column.add_child(settings_grid)
	_build_setting_description("字体大小", "调整文字大小，保留标题、正文与辅助文字的层级。")
	font_size_input = SpinBox.new()
	font_size_input.min_value = 12
	font_size_input.max_value = 24
	font_size_input.step = 1
	font_size_input.suffix = "像素"
	font_size_input.custom_minimum_size = Vector2(168, 36)
	font_size_input.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	font_size_input.value_changed.connect(_on_font_size_changed)
	settings_grid.add_child(font_size_input)
	_build_setting_description("界面缩放", "按比例放大或缩小文字、按钮、图标和菜单。")
	interface_scale_option = OptionButton.new()
	interface_scale_option.custom_minimum_size = Vector2(168, 36)
	interface_scale_option.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	for factor in PreferencesScript.SCALE_OPTIONS:
		interface_scale_option.add_item("%d%%" % roundi(factor * 100) + ("（默认）" if is_equal_approx(factor, 1.0) else ""))
	interface_scale_option.item_selected.connect(_on_interface_scale_selected)
	settings_grid.add_child(interface_scale_option)
	column.add_child(HSeparator.new())
	var preview = VBoxContainer.new()
	preview.add_theme_constant_override("separation", 8)
	preview.add_child(_label("效果预览", 16))
	preview.add_child(_label("让每一个姿势，连成动作。", 13))
	var sample = _icon_button("select", "预览当前文字与按钮大小", Callable(), "ToolButton", 32)
	sample.text = "选择与拖拽"
	sample.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	preview.add_child(sample)
	column.add_child(preview)
	var reset = _button("恢复默认", _reset_display_preferences, "QuietButton", 120)
	reset.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	column.add_child(reset)
	appearance_status = _label("调整后自动保存，下次启动继续生效。", 12, MUTED)
	appearance_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	column.add_child(appearance_status)
	column.add_child(HSeparator.new())
	column.add_child(_label("AI 与 MCP", 17))
	var enabled = CheckBox.new()
	enabled.text = "启用本机 MCP 服务"
	enabled.set_pressed_no_signal(ui_preferences.mcp_enabled)
	enabled.toggled.connect(_on_mcp_enabled)
	column.add_child(enabled)
	mcp_status = _label("", 12, MUTED)
	mcp_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	column.add_child(mcp_status)
	mcp_bridge.status_changed.connect(_update_mcp_status)
	var explanation = _label("AI 可读取骨架与动画、批量编辑关键帧、调整约束，并获取不同视角的动画截图。", 12, MUTED)
	explanation.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	column.add_child(explanation)
	var copy = _button("复制 MCP 连接配置", _copy_mcp_configuration, "QuietButton")
	copy.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	column.add_child(copy)
	var copy_codex = _button("复制 Codex 连接配置", _copy_codex_configuration, "QuietButton")
	copy_codex.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	column.add_child(copy_codex)
	_spacer(column, true)

## 允许描述文字自动换行，使大字号设置页也能适应窄窗口。
func _build_setting_description(title: String, description: String) -> void:
	var column = VBoxContainer.new()
	column.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	column.add_child(_label(title, 14))
	var detail = _label(description, 12, MUTED)
	detail.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	column.add_child(detail)
	settings_grid.add_child(column)

## 递归更新已创建控件的原始字号，包括弹出菜单和数值输入内部文本。
func _refresh_ui_fonts(node: Node) -> void:
	if node is Window:
		node.theme = theme
	if node is Control and node.has_meta("design_font_size"):
		node.add_theme_font_size_override("font_size", ui_preferences.text_size(int(node.get_meta("design_font_size"))))
	for child in node.get_children(true):
		_refresh_ui_fonts(child)

## 原位应用外观，保持当前姿势、关键帧、播放位置和撤销记录。
func _apply_display_preferences() -> void:
	syncing_appearance = true
	theme.default_font_size = ui_preferences.font_size
	theme.set_font_size("font_size", "TooltipLabel", ui_preferences.text_size(12))
	_refresh_ui_fonts(self)
	timeline.set_label_font_size(ui_preferences.text_size(11))
	get_window().content_scale_size = Vector2i.ZERO
	get_window().content_scale_factor = ui_preferences.interface_scale
	font_size_input.set_value_no_signal(ui_preferences.font_size)
	for index in PreferencesScript.SCALE_OPTIONS.size():
		if is_equal_approx(PreferencesScript.SCALE_OPTIONS[index], ui_preferences.interface_scale):
			interface_scale_option.select(index)
	syncing_appearance = false
	_apply_responsive_layout.call_deferred()

## 自动保存设置，同时明确显示实际保存结果。
func _save_display_preferences() -> void:
	if ui_preferences.save_settings():
		appearance_status.text = "已自动保存，下次启动继续生效。"
		appearance_status.add_theme_color_override("font_color", MUTED)
	else:
		appearance_status.text = ui_preferences.last_error
		appearance_status.add_theme_color_override("font_color", Color("ba615a"))

## 即时更新正文字号，使用原始设计字号避免多次放大造成漂移。
func _on_font_size_changed(value: float) -> void:
	if syncing_appearance:
		return
	ui_preferences.font_size = clampi(roundi(value), 12, 24)
	_apply_display_preferences()
	_save_display_preferences()

## 使用引擎原生缩放同步处理界面显示与鼠标坐标。
func _on_interface_scale_selected(index: int) -> void:
	if syncing_appearance or index < 0 or index >= PreferencesScript.SCALE_OPTIONS.size():
		return
	ui_preferences.interface_scale = PreferencesScript.SCALE_OPTIONS[index]
	_apply_display_preferences()
	_save_display_preferences()

## 恢复更清晰的默认十六像素字号和百分之百界面缩放。
func _reset_display_preferences() -> void:
	ui_preferences.reset_defaults()
	_apply_display_preferences()
	_save_display_preferences()

## 按缩放后的可用宽度和实际字号收放侧栏，新增空间由中央视口占用。
func _apply_responsive_layout() -> void:
	if not is_instance_valid(details_panel):
		return
	var extra_font = maxi(ui_preferences.font_size - 13, 0)
	resources_panel.custom_minimum_size.x = 184 + extra_font * 6
	details_panel.custom_minimum_size.x = 212 + extra_font * 8
	resources_panel.visible = not focused_workspace and (size.x >= 920 + extra_font * 8 if resources_preference == 0 else resources_preference > 0)
	details_panel.visible = not focused_workspace and (size.x >= 1080 + extra_font * 16 if details_preference == 0 else details_preference > 0)
	resources_toggle.set_pressed_no_signal(resources_panel.visible)
	details_toggle.set_pressed_no_signal(details_panel.visible)
	focus_button.set_pressed_no_signal(focused_workspace)
	brand_copy.visible = size.x >= brand_copy.get_combined_minimum_size().x + navigation_row.get_combined_minimum_size().x + 88
	brand_panel.custom_minimum_size.x = 240 if brand_copy.visible else 56
	settings_grid.columns = 2 if size.x >= 700 + extra_font * 12 else 1
	settings_column.custom_minimum_size.x = minf(720, maxf(240, size.x - 64))
	toolbar_caption.visible = size.x >= 1100
	footer_unit.visible = size.x >= 1000
	_update_center_density()

## 等待容器完成宽度分配后，再调整动画面板中的辅助文字。
func _update_center_density() -> void:
	draft_label.visible = center_column.size.x >= 560
	if is_instance_valid(viewport_caption):
		viewport_caption.visible = center_column.size.x >= 480
	if is_instance_valid(rig_caption):
		rig_caption.visible = center_column.size.x >= 560
	if is_instance_valid(key_scroll):
		var scrollbar_height = 14 if key_cards.get_combined_minimum_size().x > center_column.size.x - 20 else 0
		key_scroll.custom_minimum_size.y = maxi(31, ui_preferences.text_size(11) + 16) + scrollbar_height


## 创建保持两位小数的数值输入。
func _spin(minimum: float, maximum: float, step: float) -> SpinBox:
	var input = SpinBox.new()
	input.min_value = minimum
	input.max_value = maximum
	input.step = step
	input.custom_minimum_size.y = 28
	_set_font_size(input, 12)
	_set_font_size(input.get_line_edit(), 12)
	input.alignment = HORIZONTAL_ALIGNMENT_RIGHT
	input.custom_arrow_step = 1.0 if maximum == 180 else step
	input.get_line_edit().focus_exited.connect(func(): _format_spin.call_deferred(input))
	input.ready.connect(func(): _format_spin.call_deferred(input))
	input.resized.connect(func(): _format_spin.call_deferred(input))
	return input

## 在显示层统一保留两位小数，不改变内部采样精度。
func _format_spin(input: SpinBox) -> void:
	input.get_line_edit().text = "%.2f" % input.value + (" " + input.suffix if not input.suffix.is_empty() else "")

## 创建名称输入和保护尚未记录姿势的对话框。
func _build_dialogs() -> void:
	name_dialog = ConfirmationDialog.new()
	name_dialog.ok_button_text = "确定"
	name_dialog.cancel_button_text = "取消"
	name_input = LineEdit.new()
	name_input.placeholder_text = "输入动画名称"
	name_input.max_length = 40
	name_input.custom_minimum_size = Vector2(340, 40)
	name_dialog.add_child(name_input)
	name_dialog.confirmed.connect(_accept_name)
	name_input.text_submitted.connect(func(_text): _accept_name(); name_dialog.hide())
	add_child(name_dialog)
	draft_dialog = ConfirmationDialog.new()
	draft_dialog.title = "当前姿势尚未记录"
	draft_dialog.dialog_text = "当前姿势还没有记录到关键帧。\n请选择保存后继续，或放弃这次姿势调整。"
	draft_dialog.ok_button_text = "记录并继续"
	draft_dialog.cancel_button_text = "留在当前姿势"
	draft_dialog.add_button("放弃姿势", false, "discard")
	draft_dialog.confirmed.connect(_record_and_continue)
	draft_dialog.custom_action.connect(_discard_and_continue)
	draft_dialog.canceled.connect(func(): pending_action = Callable(); _sync_settings())
	add_child(draft_dialog)

## 取得当前动作资源。
func active_clip() -> Dictionary:
	return library.clips[clip_index]

## 需要切换时保留未写入关键帧的姿势。
func _with_draft_guard(action: Callable) -> void:
	if not pose_dirty:
		action.call()
	elif not draft_dialog.visible:
		pending_action = action
		draft_dialog.popup_centered(Vector2i(470, 160))

## 记录当前姿势并继续用户刚才的操作。
func _record_and_continue() -> void:
	_save_keyframe()
	if pose_dirty:
		return
	var action = pending_action
	pending_action = Callable()
	if action.is_valid():
		action.call()

## 明确放弃临时姿势后继续原操作。
func _discard_and_continue(action_name: StringName) -> void:
	if action_name != "discard":
		return
	draft_dialog.hide()
	pose_dirty = false
	var action = pending_action
	pending_action = Callable()
	if action.is_valid():
		action.call()

## 切换顶部功能栏。
func _request_page(index: int) -> void:
	for item in nav_buttons.size():
		nav_buttons[item].set_pressed_no_signal(item == current_page)
	if index == 2 or current_page == 2:
		_show_page(index)
	else:
		_with_draft_guard(_show_page.bind(index))

## 显示动画工作区、角色绑定工作区或实际设置页面。
func _show_page(index: int) -> void:
	_stop_playback()
	current_page = index
	for item in nav_buttons.size():
		nav_buttons[item].set_pressed_no_signal(item == index)
	editor_page.visible = index == 0
	binding_page.visible = index == 1
	if index != 1:
		binding_page.playing = false
	settings_page.visible = index == 2
	body_scroll.scroll_vertical = 0
	body_scroll.scroll_horizontal = 0

## 显示或收起视口下方的动画制作界面。
func _set_workspace(index: int) -> void:
	_stop_playback()
	timeline_panel.visible = index == 1
	viewport_caption.text = "动画制作" if index == 1 else "骨架预览"
	for item in workspace_buttons.size():
		workspace_buttons[item].set_pressed_no_signal(item == index)
	_set_status("动画制作：选择时间点，摆姿势并记录关键帧。" if index == 1 else "骨架预览：选择关节查看细节，通过骨骼列表切换骨架体系。")

## 切换拖动、旋转或观察工具。
func _set_tool(index: int) -> void:
	rig_view.edit_mode = ["drag", "rotate", "orbit"][index]
	for item in tool_buttons.size():
		tool_buttons[item].set_pressed_no_signal(item == index)
	rig_view.overlay.queue_redraw()
	toolbar_caption.text = ["选择与拖拽", "旋转关节", "观察视角"][index]
	viewport_hint.text = ["拖动关节调整姿势 · 右键观察 · 滚轮缩放", "拖动旋转环调整关节 · Shift 精细调整", "拖动观察视角 · 滚轮缩放 · Shift + 右键平移"][index]
	_set_status(["拖动关节调整姿势；骨长始终固定。", "拖动彩色旋转环控制对应轴；Shift 可精细调整。", "左键拖动观察，滚轮缩放；Shift + 右键平移视角。"][index])

## 同步骨架树选择到三维关节。
func _on_tree_selected() -> void:
	var item = joint_tree.get_selected()
	if item:
		var index = int(item.get_metadata(0))
		if rig_view.selected_joint != index:
			rig_view.select_joint(index)

## 同步三维选择到骨架树和细节面板。
func _on_joint_selected(index: int) -> void:
	if index >= 0:
		var ancestor = joint_items[index].get_parent()
		while ancestor:
			ancestor.collapsed = false
			ancestor = ancestor.get_parent()
		joint_items[index].select(0)
		joint_tree.scroll_to_item(joint_items[index])
	_refresh_details()

## 刷新旋转限制和根位置，不触发新的编辑。
func _refresh_details() -> void:
	if working_pose.is_empty():
		return
	refreshing = true
	var index = rig_view.selected_joint
	if index >= 0:
		joint_title.text = rig[index].name
		var parent = int(rig[index].parent)
		joint_description.text = "父关节：" + str(rig[parent].name) if parent >= 0 else "角色整体的位置与朝向"
	for axis in 3:
		rotation_inputs[axis].editable = index >= 0 and not playing
		if index >= 0:
			rotation_inputs[axis].min_value = rig[index].minimum[axis]
			rotation_inputs[axis].max_value = rig[index].maximum[axis]
			rotation_inputs[axis].set_value_no_signal(working_pose[index][axis])
			_format_spin(rotation_inputs[axis])
			rotation_inputs[axis].tooltip_text = "允许范围：%.2f° 至 %.2f°" % [rig[index].minimum[axis], rig[index].maximum[axis]]
			limit_labels[axis].text = "%s     %7.2f ～ %.2f" % [["X", "Y", "Z"][axis], rig[index].minimum[axis], rig[index].maximum[axis]]
		root_inputs[axis].editable = not playing
		root_inputs[axis].set_value_no_signal(working_root[axis])
		_format_spin(root_inputs[axis])
	refreshing = false

## 将输入的旋转应用到选中关节。
func _on_rotation_changed(value: float, axis: int) -> void:
	if refreshing or playing or rig_view.selected_joint < 0:
		return
	_push_undo()
	var next = working_pose.duplicate()
	next[rig_view.selected_joint][axis] = value
	_on_pose_edited(core.clamp_pose(next), working_root)
	_on_edit_finished()

## 修改角色整体根位移。
func _on_root_changed(value: float, axis: int) -> void:
	if refreshing or playing:
		return
	_push_undo()
	var next = working_root
	next[axis] = value
	_on_pose_edited(working_pose, next)
	_on_edit_finished()

## 接收原生求解后的实际姿势。
func _on_pose_edited(pose: PackedVector3Array, root: Vector3) -> void:
	commands.note_draft_changed()
	working_pose = pose.duplicate()
	working_root = root
	pose_dirty = true
	rig_view.set_pose(working_pose, working_root)
	_refresh_details()
	_refresh_draft_label()

## 结束一组编辑，按自动关键帧开关决定是否记录。
func _on_edit_finished() -> void:
	if auto_key.button_pressed and pose_dirty:
		_save_keyframe()
	else:
		_set_status("姿势已调整，点击“记录关键帧”保存到当前时间点。")

## 将姿势恢复为标准骨架初始姿势。
func _reset_pose() -> void:
	if playing:
		_stop_playback()
	_push_undo()
	_on_pose_edited(library.rest_pose(), Vector3.ZERO)
	_on_edit_finished()

## 更新临时姿势与已有关键帧状态提示。
func _refresh_draft_label() -> void:
	draft_label.text = "姿势待记录" if pose_dirty else ("关键帧" if library.find_key(active_clip(), current_tick) >= 0 else "过渡姿势")
	draft_label.add_theme_color_override("font_color", Color("ca8a30") if pose_dirty else Color("138f80"))

## 重新生成动画列表并保留当前选中项。
func _refresh_animation_list() -> void:
	for child in animation_list.get_children():
		animation_list.remove_child(child)
		child.queue_free()
	clip_buttons.clear()
	animation_count.text = str(library.clips.size())
	for index in library.clips.size():
		var clip: Dictionary = library.clips[index]
		var button = _button(str(clip.name) + "\n%.2f 秒 · %d 关键帧" % [float(clip.duration_tick) / 60000.0, clip.keyframes.size()], _request_clip.bind(index), "QuietButton")
		button.custom_minimum_size = Vector2(136, 44)
		_set_font_size(button, 12)
		button.icon = IconScript.get_icon("film")
		button.expand_icon = false
		button.tooltip_text = str(clip.name)
		button.alignment = HORIZONTAL_ALIGNMENT_LEFT
		button.toggle_mode = true
		button.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		animation_list.add_child(button)
		clip_buttons.append(button)
		button.set_pressed_no_signal(index == clip_index)

## 在保留临时姿势后切换动画。
func _request_clip(index: int) -> void:
	for item in clip_buttons.size():
		clip_buttons[item].set_pressed_no_signal(item == clip_index)
	if index == clip_index:
		return
	_with_draft_guard(_switch_clip.bind(index))

## 切换到指定动画并清空跨动画撤销记录。
func _switch_clip(index: int) -> void:
	_stop_playback()
	clip_index = index
	pose_dirty = false
	undo_stack.clear()
	redo_stack.clear()
	clip_title.text = active_clip().name
	_sync_settings()
	_refresh_key_cards()
	for item in clip_buttons.size():
		clip_buttons[item].set_pressed_no_signal(item == index)
	_apply_time(0)

## 刷新时间设置，避免刷新触发文件写入。
func _sync_settings() -> void:
	refreshing = true
	duration_input.set_value_no_signal(float(active_clip().duration_tick) / 60000.0)
	_format_spin(duration_input)
	interpolation_option.select(int(active_clip().interpolation))
	loop_toggle.set_pressed_no_signal(bool(active_clip().loop))
	refreshing = false

## 以时间顺序展示每一个关键姿势。
func _refresh_key_cards() -> void:
	for child in key_cards.get_children():
		key_cards.remove_child(child)
		child.queue_free()
	key_buttons.clear()
	for index in active_clip().keyframes.size():
		var tick = int(active_clip().keyframes[index].tick)
		var button = _button("%.2f" % (float(tick) / 60000.0), _request_seek.bind(tick), "", 62)
		button.custom_minimum_size.y = 26
		_set_font_size(button, 11)
		button.icon = IconScript.get_icon("diamond")
		button.expand_icon = false
		button.add_theme_constant_override("icon_max_width", 10)
		button.tooltip_text = "编辑 %.2f 秒的关键帧" % (float(tick) / 60000.0)
		button.toggle_mode = true
		key_cards.add_child(button)
		key_buttons.append(button)

## 定位到任意时刻，必要时先处理未记录姿势。
func _request_seek(tick: int) -> void:
	for index in key_buttons.size():
		key_buttons[index].set_pressed_no_signal(int(active_clip().keyframes[index].tick) == current_tick)
	if tick == current_tick:
		return
	_with_draft_guard(_seek.bind(tick))

## 停止播放并移动时间指针。
func _seek(tick: int) -> void:
	_stop_playback()
	_apply_time(tick)

## 计算时间点的实际姿势并刷新显示。
func _apply_time(tick: int) -> void:
	current_tick = clampi(tick, 0, int(active_clip().duration_tick))
	var sampled: Dictionary = library.sample(active_clip(), current_tick)
	working_pose = sampled.pose
	working_root = sampled.root
	pose_dirty = false
	rig_view.set_pose(working_pose, working_root)
	timeline.configure(int(active_clip().duration_tick), active_clip().keyframes, current_tick)
	time_label.text = "%.2f / %.2f 秒" % [float(current_tick) / 60000.0, float(active_clip().duration_tick) / 60000.0]
	for index in key_buttons.size():
		key_buttons[index].set_pressed_no_signal(int(active_clip().keyframes[index].tick) == current_tick)
	_refresh_details()
	_refresh_draft_label()

## 记录当前时刻的完整姿势，并写入按骨架索引的文件。
func _save_keyframe() -> void:
	if playing:
		_stop_playback()
	_push_undo()
	library.upsert_key(active_clip(), current_tick, core.clamp_pose(working_pose), working_root)
	if not library.save_clip(active_clip()):
		_set_status(library.last_error)
		return
	pose_dirty = false
	_refresh_key_cards()
	_refresh_animation_list()
	_apply_time(current_tick)
	_set_status("已记录 %.2f 秒关键帧，并保存到本地动画库。" % (float(current_tick) / 60000.0))

## 保存按钮也会记录当前尚未保存的姿势。
func _save_animation() -> void:
	if pose_dirty:
		_save_keyframe()
	elif library.save_clip(active_clip()):
		_set_status("动画“%s”已保存。" % active_clip().name)
	else:
		_set_status(library.last_error)

## 删除当前时间点的关键帧，至少保留一个有效姿势。
func _delete_key() -> void:
	var index = library.find_key(active_clip(), current_tick)
	if index < 0:
		_set_status("请先选择一个已有关键帧。")
		return
	if active_clip().keyframes.size() <= 1:
		_set_status("动画至少需要保留一个关键姿势。")
		return
	_push_undo()
	active_clip().keyframes.remove_at(index)
	library.save_clip(active_clip())
	_refresh_key_cards()
	_refresh_animation_list()
	_apply_time(current_tick)
	_set_status("关键帧已删除，可使用撤销恢复。")

## 拖动轨道上的标记改变关键帧时间。
func _move_key(previous: int, next: int) -> void:
	if pose_dirty:
		_set_status("请先记录当前姿势，再移动关键帧。")
		return
	var index = library.find_key(active_clip(), previous)
	if index < 0 or library.find_key(active_clip(), next) >= 0:
		_set_status("该时间点已有关键帧，未覆盖。")
		return
	_push_undo()
	active_clip().keyframes[index].tick = next
	active_clip().keyframes.sort_custom(func(a, b): return int(a.tick) < int(b.tick))
	library.save_clip(active_clip())
	_refresh_key_cards()
	_apply_time(next)

## 在当前时间处开始或暂停按时间间隔播放。
func _toggle_play() -> void:
	if playing:
		_stop_playback()
	else:
		_with_draft_guard(_start_playback)

## 从当前指针开始播放，末尾重新从起点播放。
func _start_playback() -> void:
	if current_tick >= int(active_clip().duration_tick):
		_apply_time(0)
	playback_seconds = float(current_tick) / 60000.0
	playing = true
	rig_view.editable = false
	play_button.icon = IconScript.get_icon("pause")
	play_button.tooltip_text = "暂停动画 · 空格"
	_refresh_details()

## 暂停播放并恢复姿势编辑。
func _stop_playback() -> void:
	playing = false
	if rig_view:
		rig_view.editable = true
	if play_button:
		play_button.icon = IconScript.get_icon("play")
		play_button.tooltip_text = "播放动画 · 空格"
	if not working_pose.is_empty():
		_refresh_details()

## 按整数样本索引前进或后退一帧。
func _step_frame(direction: int) -> void:
	var fps = int(active_clip().fps)
	var sample_index = roundi(float(current_tick) * fps / 60000.0) + direction
	_request_seek(clampi(core.sample_tick(sample_index, fps), 0, int(active_clip().duration_tick)))

## 连续播放保留采样精度，只在界面上按两位秒数显示。
func _process(delta: float) -> void:
	if not playing or library == null:
		return
	playback_seconds += delta * playback_speed
	var duration = float(active_clip().duration_tick) / 60000.0
	if playback_seconds >= duration:
		if bool(active_clip().loop):
			playback_seconds = fmod(playback_seconds, duration)
		else:
			playback_seconds = duration
			_stop_playback()
	_apply_time(roundi(playback_seconds * 60000.0))

## 改变时间轨道总长度，避免意外裁掉已有关键帧。
func _on_duration_changed(seconds: float) -> void:
	if refreshing:
		return
	var tick = roundi(seconds * 60000.0)
	var last_tick = int(active_clip().keyframes[-1].tick)
	if tick < last_tick:
		_sync_settings()
		_set_status("末帧位于 %.2f 秒，请先移动或删除末帧后再缩短动画。" % (float(last_tick) / 60000.0))
		return
	if pose_dirty and current_tick > tick:
		_sync_settings()
		_set_status("当前未记录姿势位于新时长之外，请先处理当前姿势。")
		return
	_push_undo()
	active_clip().duration_tick = tick
	library.save_clip(active_clip())
	timeline.configure(tick, active_clip().keyframes, current_tick)
	_refresh_animation_list()
	time_label.text = "%.2f / %.2f 秒" % [float(current_tick) / 60000.0, seconds]
	if current_tick > tick:
		_apply_time(tick)
	_format_spin(duration_input)

## 选择保持、线性或平滑过渡。
func _on_interpolation_changed(index: int) -> void:
	if refreshing:
		return
	_with_draft_guard(_change_interpolation.bind(index))

## 提交过渡模式并重新求解当前时刻。
func _change_interpolation(index: int) -> void:
	_push_undo()
	active_clip().interpolation = index
	library.save_clip(active_clip())
	_apply_time(current_tick)

## 更新循环设置并保存。
func _on_loop_changed(value: bool) -> void:
	if refreshing:
		return
	_push_undo()
	active_clip().loop = value
	library.save_clip(active_clip())

## 打开新建或重命名动画的输入窗口。
func _show_name_dialog(action: String) -> void:
	_with_draft_guard(_open_name_dialog.bind(action))

## 填充名称窗口并选中可编辑文本。
func _open_name_dialog(action: String) -> void:
	name_action = action
	name_dialog.title = "新建动画" if action == "new" else "重命名动画"
	name_input.text = "新动画 %d" % (library.clips.size() + 1) if action == "new" else str(active_clip().name)
	name_dialog.popup_centered(Vector2i(390, 140))
	name_input.grab_focus()
	name_input.select_all()

## 创建新动画或更新当前动画名称。
func _accept_name() -> void:
	var display_name = name_input.text.strip_edges()
	if display_name.is_empty():
		_set_status("动画名称不能为空。")
		return
	if name_action == "new":
		library.create_clip(display_name)
		_refresh_animation_list()
		_switch_clip(library.clips.size() - 1)
	else:
		_push_undo()
		active_clip().name = display_name
		library.save_clip(active_clip())
		clip_title.text = display_name
		_refresh_animation_list()
	_set_status("动画“%s”已保存到“%s”骨架的动作库。" % [display_name, rig_registry.definitions[active_rig_id].name])

## 生成当前动作与编辑姿势的快照。
func _snapshot() -> Dictionary:
	return {"rig_id": active_rig_id, "clip": active_clip().duplicate(true), "pose": working_pose.duplicate(), "root": working_root, "tick": current_tick, "draft": pose_dirty}

## 在一次可逆编辑前记录快照。
func _push_undo() -> void:
	undo_stack.append(_snapshot())
	if undo_stack.size() > 80:
		undo_stack.pop_front()
	redo_stack.clear()

## 恢复文档快照与尚未记录的姿势。
func _restore_snapshot(snapshot: Dictionary) -> bool:
	_stop_playback()
	var candidate: Dictionary = snapshot.clip.duplicate(true)
	if not library.save_clip(candidate):
		_set_status(library.last_error)
		return false
	if snapshot.has("rig_definition") and not commands.restore_rig_definition(snapshot.rig_definition):
		return false
	library.clips[clip_index] = candidate
	clip_title.text = active_clip().name
	_sync_settings()
	_refresh_key_cards()
	_refresh_animation_list()
	_apply_time(int(snapshot.tick))
	working_pose = snapshot.pose.duplicate()
	working_root = snapshot.root
	pose_dirty = snapshot.draft
	rig_view.set_pose(working_pose, working_root)
	_refresh_details()
	_refresh_draft_label()
	return true

## 撤销一组姿势或关键帧修改。
func _undo() -> bool:
	if undo_stack.is_empty():
		_set_status("当前动画没有可撤销的操作。")
		return false
	var previous: Dictionary = undo_stack[-1]
	var inverse = _history_inverse(previous)
	if not _restore_snapshot(previous):
		return false
	undo_stack.pop_back()
	redo_stack.append(inverse)
	_set_status("已撤销上一步操作。")
	return true

## 恢复最近撤销的修改。
func _redo() -> bool:
	if redo_stack.is_empty():
		_set_status("当前没有可重做的操作。")
		return false
	var previous: Dictionary = redo_stack[-1]
	var inverse = _history_inverse(previous)
	if not _restore_snapshot(previous):
		return false
	redo_stack.pop_back()
	undo_stack.append(inverse)
	_set_status("已重做上一步操作。")
	return true

## 保留事务身份和约束快照，使界面与 MCP 可以共用撤销重做。
func _history_inverse(previous: Dictionary) -> Dictionary:
	var inverse = _snapshot()
	if previous.has("transaction_id"):
		inverse.transaction_id = previous.transaction_id
	if previous.has("rig_definition"):
		inverse.rig_definition = rig_registry.get_definition(active_rig_id)
	return inverse

## 刷新骨架菜单，显示注册后立即可用的新骨架体系。
func refresh_rig_selector() -> void:
	if rig_selector == null:
		return
	rig_selector.clear()
	for item in rig_registry.list_rigs():
		rig_selector.add_item(item.name)
		var index = rig_selector.item_count - 1
		rig_selector.set_item_metadata(index, item.rig_id)
		if item.rig_id == active_rig_id:
			rig_selector.select(index)
	rig_summary.text = "%d 个关节 · 独立动作库" % rig.size()
	if rig_caption:
		rig_caption.text = str(rig_registry.definitions[active_rig_id].name)
	if footer_unit:
		footer_unit.text = str(rig_registry.definitions[active_rig_id].name) + "  ·  单位：米 / 秒"

## 根据当前骨架的真实父子关系建立资源树。
func _populate_joint_tree() -> void:
	joint_tree.clear()
	joint_items.clear()
	var hidden_root = joint_tree.create_item()
	for index in rig.size():
		var parent = int(rig[index].parent)
		var item = joint_tree.create_item(hidden_root if parent < 0 else joint_items[parent])
		item.set_text(0, str(rig[index].name))
		item.set_metadata(0, index)
		item.set_tooltip_text(0, str(rig[index].id))
		joint_items.append(item)
		if rig[index].get("semantic", {}).get("role", "") in ["clavicle", "thigh", "finger"]:
			item.collapsed = true

## 用户切换骨架前复用现有草稿保护。
func _request_rig(index: int) -> void:
	var id = str(rig_selector.get_item_metadata(index))
	refresh_rig_selector()
	if id != active_rig_id:
		_with_draft_guard(_activate_rig.bind(id))

## 切换独立骨架文档，首次从界面打开空动作库时创建基础站姿。
func _activate_rig(id: String) -> void:
	_stop_playback()
	var document = commands.get_document_for_rig(id)
	if document.is_empty():
		return
	if document.library.clips.is_empty() and document.library.create_clip("基础站姿").is_empty():
		_set_status(document.library.last_error)
		return
	active_rig_id = id
	core = document.core
	library = document.library
	rig = rig_registry.native_definition(id)
	rig_view.initialize(core, rig)
	_populate_joint_tree()
	refresh_rig_selector()
	clip_index = 0
	_refresh_animation_list()
	_switch_clip(0)
	rig_view.select_joint(mini(4, rig.size() - 1))
	rig_view.set_camera_view(0)
	commands.note_draft_changed()

## MCP 已验证目标后切换对应文档，相同目标保留撤销历史。
func activate_mcp_clip(id: String, clip_id: String) -> void:
	if active_rig_id != id:
		_activate_rig(id)
	for index in library.clips.size():
		if str(library.clips[index].id) == clip_id:
			if index != clip_index:
				_switch_clip(index)
			_refresh_animation_list()
			return

## 批量提交完成后按实际存储内容同步时间轴、资源列表和姿势。
func refresh_after_mcp() -> void:
	_stop_playback()
	pose_dirty = false
	clip_title.text = str(active_clip().name)
	_sync_settings()
	_refresh_animation_list()
	_refresh_key_cards()
	_apply_time(mini(current_tick, int(active_clip().duration_tick)))
	_set_status("MCP 编辑已保存。")

## 约束改变后刷新视口参数和细节范围，不重新创建关节索引。
func refresh_rig_constraints() -> void:
	rig = rig_registry.native_definition(active_rig_id)
	library.rig = rig
	rig_view.rig = rig
	working_pose = core.clamp_pose(working_pose)
	rig_view.set_pose(working_pose, working_root)
	_refresh_details()

## 设置页开关立即控制监听，同时保存用户偏好。
func _on_mcp_enabled(value: bool) -> void:
	ui_preferences.mcp_enabled = value
	ui_preferences.save_settings()
	if value:
		mcp_bridge.start()
	else:
		mcp_bridge.stop()

## 显示连接状态，不将本机鉴权令牌暴露在界面。
func _update_mcp_status(message: String) -> void:
	if mcp_status:
		mcp_status.text = message

## 复制通用 stdio 客户端配置，端口和令牌由适配器自动发现。
func _copy_mcp_configuration() -> void:
	var project = ProjectSettings.globalize_path("res://")
	var config = {"mcpServers": {"puppet": {"command": project.path_join("tools/python/Scripts/python.exe"), "args": [project.path_join("mcp_service/server.py"), "--instances-dir", mcp_bridge.instance_directory]}}}
	DisplayServer.clipboard_set(JSON.stringify(config, "  "))
	_set_status("MCP 连接配置已复制。")

## 复制 Codex 使用的 TOML 配置，字符串采用 JSON 兼容的双引号转义。
func _copy_codex_configuration() -> void:
	var project = ProjectSettings.globalize_path("res://").replace("\\", "/")
	var python = JSON.stringify(project.path_join("tools/python/Scripts/python.exe"))
	var script = JSON.stringify(project.path_join("mcp_service/server.py"))
	var directory = JSON.stringify(mcp_bridge.instance_directory.replace("\\", "/"))
	var config = "[mcp_servers.puppet]\ncommand = %s\nargs = [%s, \"--instances-dir\", %s]\nstartup_timeout_sec = 20\ntool_timeout_sec = 90\n" % [python, script, directory]
	DisplayServer.clipboard_set(config)
	_set_status("Codex MCP 配置已复制。")

## 在状态栏显示真实操作结果。
func _set_status(text: String) -> void:
	if status_label:
		status_label.text = text

## 支持保存、撤销、播放和定位等常用快捷键。
func _unhandled_key_input(event: InputEvent) -> void:
	if not event is InputEventKey or not event.pressed or event.echo or library == null:
		return
	if current_page == 1:
		if event.ctrl_pressed and event.keycode == KEY_S:
			binding_page.save_project()
		elif event.ctrl_pressed and event.keycode == KEY_Z:
			binding_page.undo(event.shift_pressed)
		elif event.ctrl_pressed and event.keycode == KEY_Y:
			binding_page.undo(true)
		elif event.keycode == KEY_SPACE:
			binding_page.toggle_play()
		elif event.keycode == KEY_ESCAPE:
			binding_page.stop_preview()
		else:
			return
		get_viewport().set_input_as_handled()
		return
	if event.ctrl_pressed and event.keycode == KEY_S:
		_save_animation()
	elif event.ctrl_pressed and event.keycode == KEY_Z:
		_redo() if event.shift_pressed else _undo()
	elif event.keycode == KEY_SPACE:
		_toggle_play()
	elif event.ctrl_pressed and event.keycode == KEY_Y:
		_redo()
	elif event.keycode == KEY_W:
		_set_tool(0)
	elif event.keycode == KEY_E:
		_set_tool(1)
	elif event.keycode == KEY_Q:
		_set_tool(2)
	elif event.keycode == KEY_F:
		_focus_camera()
	elif event.keycode == KEY_DELETE:
		_delete_key()
	else:
		return
	get_viewport().set_input_as_handled()

## 支持把角色模型拖入角色页面创建绑定项目。
func _on_model_files_dropped(paths: PackedStringArray) -> void:
	if current_page == 1 and not paths.is_empty():
		binding_page.import_model(paths[0])

## 退出前处理尚未记录的姿势。
func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST:
		if library == null:
			get_tree().quit()
		else:
			_with_draft_guard(func(): get_tree().quit())
