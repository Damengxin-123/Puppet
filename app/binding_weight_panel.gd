extends VBoxContainer
## 权重查看与局部修正面板，所有持久编辑经过绑定服务并支持撤销。

## 所属绑定工作台。
var page
## 左键表面选区模式开关。
var edit_toggle: CheckBox
## 当前骨骼热图开关。
var heat_toggle: CheckBox
## 沿表面扩展的选区半径，单位米。
var radius: SpinBox
## 是否选择完整连通表面。
var whole: CheckBox
## 权重修改类型。
var operation: OptionButton
## 目标权重或每次增加、减少的数值。
var amount: SpinBox
## 移除权重后的接收骨骼。
var fallback: OptionButton
## 显示种子顶点、选区数量与实际权重。
var details: Label
## 当前选区起点的稳定顶点标识。
var seed_id: String = ""
## 当前选区全部稳定顶点标识。
var selection: Array = []
## 当前面板所属项目，切换项目时清空选区。
var project_id: String = ""

## 创建操作控件并接入三维表面拾取。
func initialize(workspace) -> void:
	page = workspace
	add_child(HSeparator.new())
	add_child(page.host._label("蒙皮权重", 16))
	edit_toggle = CheckBox.new()
	edit_toggle.text = "左键选择模型权重区域"
	edit_toggle.toggled.connect(_edit_mode)
	add_child(edit_toggle)
	heat_toggle = CheckBox.new()
	heat_toggle.text = "显示所选骨骼权重热图"
	heat_toggle.toggled.connect(_heat_changed)
	add_child(heat_toggle)
	var legend = page.host._label("蓝 0 → 青 → 黄 → 红 1\n选区提亮；左侧列表选择骨骼。", 11)
	add_child(legend)
	add_child(page.host._label("选区半径 / 米（沿表面）", 12))
	radius = page._spin(0.01, 100)
	radius.value = 0.03
	radius.value_changed.connect(_radius_changed)
	add_child(radius)
	page._format_spin(radius.value, radius)
	whole = CheckBox.new()
	whole.text = "选择整个连通表面"
	whole.tooltip_text = "连通表面可能同时包括外套和袖子；请先看选区再修改。"
	whole.toggled.connect(_whole_changed)
	add_child(whole)
	details = page.host._label("打开选区模式后点击模型。", 11)
	details.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	add_child(details)
	operation = OptionButton.new()
	for item in ["设置当前骨骼权重", "增加当前骨骼权重", "减少当前骨骼权重", "沿表面平滑权重", "清除选区的手臂影响"]:
		operation.add_item(item)
	add_child(operation)
	add_child(page.host._label("权重 / 平滑强度（0—1）", 12))
	amount = page._spin(0, 1)
	amount.value = 1.0
	add_child(amount)
	page._format_spin(amount.value, amount)
	add_child(page.host._label("清除影响时转交给", 12))
	fallback = OptionButton.new()
	fallback.fit_to_longest_item = false
	add_child(fallback)
	add_child(page.host._button("应用到选区", _apply))
	add_child(page.host._button("选区恢复自动权重", _reset))
	add_child(page.host._button("重新计算自动蒙皮", _recalculate))
	var note = page.host._label("权重自动保存，可撤销。\n重新计算保留手工权重和关节。\n可暂停动作后修正并立即观察。", 11)
	add_child(note)
	page.view.weight_vertex_picked.connect(_picked)

## 项目切换时清空选择，普通权重修改后保留选区和接收骨骼。
func refresh() -> void:
	var current_id = str(page.service.project.get("id", ""))
	if current_id != project_id:
		project_id = current_id
		seed_id = ""
		selection = []
	var previous = str(fallback.get_item_metadata(fallback.selected)) if fallback.selected >= 0 else "pelvis"
	fallback.clear()
	for bone in page.service.bones:
		fallback.add_item(bone.name)
		fallback.set_item_metadata(fallback.item_count - 1, bone.id)
		if str(bone.id) == previous:
			fallback.select(fallback.item_count - 1)
	update_bone()

## 当前骨骼改变后热图同步刷新，不改变任何顶点权重。
func update_bone() -> void:
	var bone = ""
	if heat_toggle.button_pressed and page.selected >= 0 and page.selected < page.service.bones.size():
		bone = str(page.service.bones[page.selected].id)
	page.view.set_weight_display(bone, selection)
	_refresh_details()

## 进入选区模式自动开启热图，并禁止左键拖动参考关节。
func _edit_mode(enabled: bool) -> void:
	page.view.weight_edit_mode = enabled
	if enabled:
		if page.selected < 0 and page.service.bones.size() > 1:
			page.view.select_joint(1)
		heat_toggle.button_pressed = true
	update_bone()

## 热图只改变查看方式，关闭后恢复原有材质。
func _heat_changed(_enabled: bool) -> void:
	update_bone()

## 拾取表面时暂停动作，选区使用原始拓扑而非空间球形穿透。
func _picked(id: String) -> void:
	page.playing = false
	if not page.preview_clip.is_empty():
		page._apply_preview()
	seed_id = id
	_select_region()

## 半径调整只更新选区，不直接写入权重。
func _radius_changed(_value: float) -> void:
	_select_region()

## 连通表面选项变化时重新显示实际受影响范围。
func _whole_changed(_enabled: bool) -> void:
	_select_region()

## 在共享拓扑上计算选区，使 UI 与 MCP 完全一致。
func _select_region() -> void:
	if seed_id.is_empty() or page.service.project.is_empty():
		return
	var result: Dictionary = page.service.weight_selection({"seed_vertex_id": seed_id, "radius_m": radius.value, "whole_component": whole.button_pressed})
	if result.ok:
		selection = result.vertex_ids
		update_bone()
	else:
		page.show_result(result)

## 显示命中顶点的实际骨骼百分比，避免只靠颜色猜测权重。
func _refresh_details() -> void:
	if seed_id.is_empty() or page.service.project.is_empty():
		details.text = "打开选区模式后点击模型。"
		return
	var result: Dictionary = page.service.query_weights({"vertex_ids": [seed_id], "limit": 1})
	if not result.ok or result.vertices.is_empty():
		return
	var vertex: Dictionary = result.vertices[0]
	var text = "%s · 选区 %d 顶点\n%s" % [seed_id, selection.size(), "手工权重" if vertex.manual else "自动权重"]
	for id in vertex.weights:
		var index = page.service.bone_index(id)
		text += "\n%s：%.1f%%" % [page.service.bones[index].name, float(vertex.weights[id]) * 100]
	details.text = text

## 将整组选区作为一次撤销操作保存，预览保持当前动画时刻。
func _apply() -> void:
	if selection.is_empty():
		page.show_result({"ok": false, "error": "请先点击模型选择要修改的区域。"})
		return
	var params = {"vertex_ids": selection, "operation": ["set", "add", "subtract", "smooth", "exclude_arms"][operation.selected], "value": amount.value, "fallback_bone_id": str(fallback.get_item_metadata(fallback.selected))}
	if page.selected >= 0:
		params.bone_id = page.service.bones[page.selected].id
	page.show_result(page.service.edit_weights(params))

## 只恢复选区的自动解，其他手工精修保持原样。
func _reset() -> void:
	page.show_result(page.service.reset_weights({"vertex_ids": selection}))

## 显式重算自动解，保留已保存关节与所有手工覆盖。
func _recalculate() -> void:
	if page.service.project.is_empty():
		return
	page.status.text = "正在沿模型表面重新计算权重……"
	await get_tree().process_frame
	page.show_result(page.service.recalculate_weights())
