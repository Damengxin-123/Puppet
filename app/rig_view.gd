class_name PuppetRigView
extends SubViewportContainer
## 独立三维操作视口，负责固定骨架显示、观察及姿势交互。

## 用户选择关节时通知细节面板。
signal joint_selected(index: int)
## 一次姿势拖动开始，用于生成单条撤销记录。
signal edit_started
## 姿势发生实际变化时返回旋转和根位移。
signal pose_edited(pose: PackedVector3Array, root: Vector3)
## 结束拖动后通知主界面。
signal edit_finished
## 原生骨架与动画求解器。
var core
## 当前使用的不可变骨架参数。
var rig: Array = []
## 各关节的局部旋转，单位为度。
var pose: PackedVector3Array = PackedVector3Array()
## 角色根节点位移，单位为米。
var root_position: Vector3 = Vector3.ZERO
## 当前选中的关节索引。
var selected_joint: int = -1
## 当前编辑工具：拖动、旋转或观察。
var edit_mode: String = "drag"
## 是否允许修改当前播放姿势。
var editable: bool = true
## 当前关节的骨架空间位置。
var positions: PackedVector3Array = PackedVector3Array()
## 三维渲染目标。
var render_view: SubViewport
## 三维场景根节点。
var world_root: Node3D
## 实际骨骼层级节点。
var skeleton: Skeleton3D
## 观察摄像机。
var camera: Camera3D
## 地面网格的显示对象。
var ground_grid: MeshInstance3D
## 真实骨骼的粗线段显示对象。
var bone_lines: Array = []
## 真实关节点的粗点显示对象。
var joint_points: Array = []
## 半透明肢体显示对象。
var limb_shells: Array = []
## 半透明关节显示对象。
var joint_shells: Array = []
## 头部正面标记。
var face_marker: MeshInstance3D
## 用于显示旋转环的二维叠加层。
var overlay: Control
## 当前观察中心，单位为米。
var orbit_target: Vector3 = Vector3(0, 0.94, 0)
## 摄像机水平观察角。
var orbit_yaw: float = 0.28
## 摄像机俯仰观察角。
var orbit_pitch: float = 0.12
## 摄像机距离，单位为米。
var orbit_distance: float = 3.15
## 正在执行的鼠标操作。
var drag_action: String = ""
## 当前鼠标拖动所使用的空间平面。
var drag_plane: Plane
## 旋转环所控制的坐标轴，负数表示自由旋转。
var rotation_axis: int = -1
## 普通骨架的显示材质。
var core_material: StandardMaterial3D
## 所选骨架的显示材质。
var selected_material: StandardMaterial3D
## 提示不可修改根骨架的观察标记。
var show_core: bool = true
## 是否显示半透明身体外壳。
var show_shell: bool = true
## 外壳不透明度，零表示完全透明，一表示不透明。
var shell_opacity: float = 0.20
## 所有肢体圆柱共用的外壳材质，只更新材质即可实时调节透明度。
var limb_shell_material: StandardMaterial3D
## 所有关节球体共用的外壳材质，保留略清晰的关节层次。
var joint_shell_material: StandardMaterial3D
## 按语义识别的头部关节，缺少头部的骨架不绘制朝向标记。
var head_joint: int = -1
## 最近使用的视角名称，手动观察后标记为自定义。
var camera_preset: String = "perspective"

## 在三维图像上绘制交互提示，鼠标由视口自身处理。
class RigOverlay extends Control:
	## 所属三维视口。
	var rig_view
	## 委托视口绘制选择框和旋转环。
	func _draw() -> void:
		if rig_view:
			rig_view.draw_overlay(self)

## 创建独立世界和摄像机。
func _ready() -> void:
	stretch = true
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	size_flags_vertical = Control.SIZE_EXPAND_FILL
	custom_minimum_size = Vector2(300, 260)
	focus_mode = Control.FOCUS_ALL
	render_view = SubViewport.new()
	render_view.own_world_3d = true
	render_view.size = Vector2i(900, 600)
	render_view.msaa_3d = Viewport.MSAA_4X
	render_view.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	add_child(render_view)
	world_root = Node3D.new()
	world_root.name = "标准骨架预览"
	render_view.add_child(world_root)
	var environment = WorldEnvironment.new()
	environment.environment = Environment.new()
	environment.environment.background_mode = Environment.BG_COLOR
	environment.environment.background_color = Color("edf3f5")
	environment.environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	environment.environment.ambient_light_color = Color("ffffff")
	environment.environment.ambient_light_energy = 0.75
	world_root.add_child(environment)
	var light = DirectionalLight3D.new()
	light.rotation_degrees = Vector3(-45, -30, 0)
	light.light_energy = 0.65
	light.shadow_enabled = true
	world_root.add_child(light)
	camera = Camera3D.new()
	camera.fov = 42
	camera.near = 0.05
	camera.far = 80
	world_root.add_child(camera)
	camera.current = true
	_create_ground()
	_update_camera()
	overlay = RigOverlay.new()
	overlay.rig_view = self
	overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(overlay)
	resized.connect(func(): if overlay: overlay.queue_redraw())

## 根据标准定义创建真实骨骼和简约显示外壳。
func initialize(animator, definition: Array) -> void:
	for nodes in [bone_lines, joint_points, limb_shells, joint_shells]:
		for node in nodes:
			if is_instance_valid(node):
				node.free()
		nodes.clear()
	if is_instance_valid(skeleton):
		skeleton.free()
	if is_instance_valid(face_marker):
		face_marker.free()
	selected_joint = -1
	head_joint = -1
	core = animator
	rig = definition
	pose = PackedVector3Array()
	pose.resize(rig.size())
	pose = core.clamp_pose(pose)
	core_material = _material(Color("315e65"), true)
	selected_material = _material(Color("128f82"), true)
	limb_shell_material = _material(Color(0.41, 0.72, 0.69, shell_opacity))
	joint_shell_material = _material(Color(0.52, 0.76, 0.73, minf(shell_opacity * 1.15, 1.0)))
	skeleton = Skeleton3D.new()
	skeleton.name = "标准人形骨架"
	world_root.add_child(skeleton)
	for index in rig.size():
		var definition_item: Dictionary = rig[index]
		skeleton.add_bone(definition_item.id)
		skeleton.set_bone_parent(index, int(definition_item.parent))
		skeleton.set_bone_rest(index, Transform3D(Basis(definition_item.get("rest_rotation", Quaternion.IDENTITY)), definition_item.offset))
		if definition_item.get("semantic", {}).get("role", "") == "head" or definition_item.get("display", {}).get("kind", "") == "head":
			head_joint = index
		var point = _sphere(0.022 if index > 0 else 0.035, core_material)
		joint_points.append(point)
		var shell = _sphere(0.13 if index == head_joint else clampf(float(definition_item.radius) * 1.25, 0.012, 0.09), joint_shell_material)
		joint_shells.append(shell)
		if int(definition_item.parent) >= 0 and definition_item.get("display", {}).get("draw_parent_bone", index > 1):
			bone_lines.append(_cylinder(0.007, core_material))
			limb_shells.append(_cylinder(float(definition_item.radius), limb_shell_material))
		else:
			bone_lines.append(null)
			limb_shells.append(null)
	face_marker = _sphere(0.018, selected_material)
	set_pose(pose, Vector3.ZERO)

## 创建允许查看内部骨骼的半透明材质。
func _material(color: Color, unshaded: bool = false) -> StandardMaterial3D:
	var material = StandardMaterial3D.new()
	material.albedo_color = color
	material.roughness = 0.85
	if color.a < 1:
		material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		material.depth_draw_mode = BaseMaterial3D.DEPTH_DRAW_DISABLED
		material.cull_mode = BaseMaterial3D.CULL_DISABLED
	if unshaded:
		material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	return material

## 创建表示关节的球体。
func _sphere(radius: float, material: Material) -> MeshInstance3D:
	var node = MeshInstance3D.new()
	var mesh = SphereMesh.new()
	mesh.radius = radius
	mesh.height = radius * 2.0
	mesh.radial_segments = 20
	mesh.rings = 10
	node.mesh = mesh
	node.material_override = material
	world_root.add_child(node)
	return node

## 创建表示骨段或身体外壳的圆柱体。
func _cylinder(radius: float, material: Material) -> MeshInstance3D:
	var node = MeshInstance3D.new()
	var mesh = CylinderMesh.new()
	mesh.top_radius = radius
	mesh.bottom_radius = radius
	mesh.height = 1
	mesh.radial_segments = 16
	node.mesh = mesh
	node.material_override = material
	world_root.add_child(node)
	return node

## 创建米制地面与淡色参考网格。
func _create_ground() -> void:
	var ground = MeshInstance3D.new()
	var plane = PlaneMesh.new()
	plane.size = Vector2(40, 40)
	ground.mesh = plane
	ground.material_override = _material(Color("e4edef"), true)
	ground.position.y = -0.025
	world_root.add_child(ground)
	var grid_mesh = ImmediateMesh.new()
	grid_mesh.surface_begin(Mesh.PRIMITIVE_LINES, _material(Color("c2d5d8"), true))
	for index in range(-12, 13):
		var value = index * 0.25
		grid_mesh.surface_add_vertex(Vector3(value, -0.02, -3))
		grid_mesh.surface_add_vertex(Vector3(value, -0.02, 3))
		grid_mesh.surface_add_vertex(Vector3(-3, -0.02, value))
		grid_mesh.surface_add_vertex(Vector3(3, -0.02, value))
	grid_mesh.surface_end()
	ground_grid = MeshInstance3D.new()
	ground_grid.mesh = grid_mesh
	world_root.add_child(ground_grid)

## 只调整观察网格，不影响动画姿势和固定骨架。
func set_grid_visible(value: bool) -> void:
	ground_grid.visible = value

## 实时改变视觉外壳透明度，内部骨线和关节点材质保持独立。
func set_shell_opacity(value: float) -> void:
	if not is_finite(value):
		return
	shell_opacity = clampf(value, 0.0, 1.0)
	for material in [limb_shell_material, joint_shell_material]:
		if material == null:
			continue
		material.albedo_color.a = minf(shell_opacity * 1.15, 1.0) if material == joint_shell_material else shell_opacity
		var opaque = material.albedo_color.a >= 1.0
		material.transparency = BaseMaterial3D.TRANSPARENCY_DISABLED if opaque else BaseMaterial3D.TRANSPARENCY_ALPHA
		material.depth_draw_mode = BaseMaterial3D.DEPTH_DRAW_OPAQUE_ONLY if opaque else BaseMaterial3D.DEPTH_DRAW_DISABLED
		material.cull_mode = BaseMaterial3D.CULL_BACK if opaque else BaseMaterial3D.CULL_DISABLED
	if core:
		set_pose(pose, root_position)

## 将一条显示圆柱对齐到两个真实骨骼位置。
func _align_segment(node: MeshInstance3D, start: Vector3, finish: Vector3) -> void:
	var direction = finish - start
	if direction.length() < 0.0001:
		node.visible = false
		return
	var orientation = Basis(Quaternion(Vector3.UP, direction.normalized()))
	node.transform = Transform3D(orientation * Basis.from_scale(Vector3(1, direction.length(), 1)), (start + finish) * 0.5)

## 应用求解姿势并更新实际骨架及可视模型。
func set_pose(value: PackedVector3Array, root: Vector3, evaluated: Array = []) -> void:
	pose = value.duplicate()
	root_position = root
	# 绑定动画可提供经过参考姿态转换的最终变换，骨架线与蒙皮使用同一结果。
	positions = core.evaluate_positions(pose, root_position) if evaluated.is_empty() else PackedVector3Array()
	var rotations: Array = core.local_rotations(pose) if evaluated.is_empty() else []
	for index in rig.size():
		skeleton.set_bone_pose_position(index, root_position + rig[index].offset if index == 0 else rig[index].offset)
		if evaluated.is_empty():
			skeleton.set_bone_pose_rotation(index, rig[index].get("rest_rotation", Quaternion.IDENTITY) * rotations[index])
		else:
			positions.append(evaluated[index].position)
			var parent = int(rig[index].parent)
			var rotation: Quaternion = evaluated[index].rotation if parent < 0 else evaluated[parent].rotation.inverse() * evaluated[index].rotation
			skeleton.set_bone_pose_rotation(index, rotation.normalized())
		joint_points[index].position = positions[index]
		joint_points[index].visible = show_core
		joint_shells[index].position = positions[index]
		joint_shells[index].visible = show_shell and shell_opacity > 0.0 and index > 0
		joint_points[index].material_override = selected_material if index == selected_joint else core_material
		joint_points[index].scale = Vector3.ONE * (1.45 if index == selected_joint else 1.0)
		if bone_lines[index] != null:
			var parent_index = int(rig[index].parent)
			_align_segment(bone_lines[index], positions[parent_index], positions[index])
			_align_segment(limb_shells[index], positions[parent_index], positions[index])
			bone_lines[index].visible = show_core
			limb_shells[index].visible = show_shell and shell_opacity > 0.0
			bone_lines[index].material_override = selected_material if index == selected_joint else core_material
	if head_joint >= 0:
		face_marker.position = positions[head_joint] + skeleton.get_bone_global_pose(head_joint).basis * Vector3(0, 0.025, 0.13)
	face_marker.visible = show_shell and shell_opacity > 0.0 and head_joint >= 0
	if overlay:
		overlay.queue_redraw()

## 切换选中关节并刷新高亮。
func select_joint(index: int) -> void:
	selected_joint = index
	if core:
		set_pose(pose, root_position)
	joint_selected.emit(index)

## 更新绕目标观察的摄像机位置。
func _update_camera() -> void:
	camera.position = orbit_target + Vector3(sin(orbit_yaw) * cos(orbit_pitch), sin(orbit_pitch), cos(orbit_yaw) * cos(orbit_pitch)) * orbit_distance
	camera.look_at(orbit_target, Vector3.UP)
	if overlay:
		overlay.queue_redraw()

## 一键切换正面、侧面和透视观察。
func set_camera_view(view_index: int) -> void:
	configure_camera({"preset": ["perspective", "front", "left", "back", "right", "top"][clampi(view_index, 0, 5)], "frame_all": true})

## 返回可以复现截图的完整观察参数和渲染尺寸。
func get_camera_state() -> Dictionary:
	return {"preset": camera_preset, "target_m": [orbit_target.x, orbit_target.y, orbit_target.z], "position_m": [camera.position.x, camera.position.y, camera.position.z], "yaw_deg": rad_to_deg(orbit_yaw), "pitch_deg": rad_to_deg(orbit_pitch), "distance_m": orbit_distance, "fov_deg": camera.fov, "projection": "orthographic" if camera.projection == Camera3D.PROJECTION_ORTHOGONAL else "perspective", "orthographic_size_m": camera.size, "width": render_view.size.x, "height": render_view.size.y}

## 校验并设置视角，支持按全身范围或稳定关节标识自动取景。
func configure_camera(options: Dictionary) -> Dictionary:
	var preset = str(options.get("preset", "custom"))
	if preset not in ["perspective", "front", "back", "left", "right", "top", "custom"]:
		return {"ok": false, "error": "未知的视角预设。"}
	for key in ["yaw_deg", "pitch_deg", "distance_m", "fov_deg", "orthographic_size_m"]:
		if options.has(key) and (not (options[key] is int or options[key] is float) or not is_finite(float(options[key]))):
			return {"ok": false, "error": "视角数值必须有限。"}
	if options.has("target_m"):
		var target = options.target_m
		if not target is Array or target.size() != 3:
			return {"ok": false, "error": "观察中心需要三个米制数值。"}
		for value in target:
			if not (value is float or value is int) or not is_finite(float(value)):
				return {"ok": false, "error": "观察中心数值必须有限。"}
	if options.has("projection") and options.projection not in ["perspective", "orthographic"]:
		return {"ok": false, "error": "投影需为 perspective 或 orthographic。"}
	if float(options.get("distance_m", orbit_distance)) < 0.05 or float(options.get("distance_m", orbit_distance)) > 100 or absf(float(options.get("pitch_deg", rad_to_deg(orbit_pitch)))) > 89.9 or float(options.get("fov_deg", camera.fov)) < 5 or float(options.get("fov_deg", camera.fov)) > 120 or float(options.get("orthographic_size_m", camera.size)) <= 0:
		return {"ok": false, "error": "视角距离、俯仰、视野角或正交尺寸超出范围。"}
	var focus = -1
	if options.has("focus_bone_id"):
		for index in rig.size():
			if str(rig[index].id) == str(options.focus_bone_id):
				focus = index
		if focus < 0:
			return {"ok": false, "error": "取景关节不存在。"}
	camera.fov = float(options.get("fov_deg", camera.fov))
	if preset != "custom":
		orbit_yaw = {"perspective": 0.28, "front": 0.0, "back": PI, "left": PI / 2.0, "right": -PI / 2.0, "top": 0.0}[preset]
		orbit_pitch = deg_to_rad(89.0) if preset == "top" else (0.12 if preset == "perspective" else 0.0)
	if options.get("frame_all", false) and not positions.is_empty():
		var bounds = AABB(positions[0], Vector3.ZERO)
		for point in positions:
			bounds = bounds.expand(point)
		orbit_target = bounds.get_center()
		var radius = maxf(0.25, bounds.size.length() * 0.5 + 0.16)
		var aspect = float(render_view.size.x) / maxf(1.0, float(render_view.size.y))
		orbit_distance = radius / sin(deg_to_rad(camera.fov * 0.5)) / minf(1.0, aspect) * 1.05
		camera.size = radius * 2.2 / minf(1.0, aspect)
	if focus >= 0:
		orbit_target = positions[focus]
		orbit_distance = 0.65
		camera.size = 0.4
	if options.has("target_m"):
		orbit_target = Vector3(options.target_m[0], options.target_m[1], options.target_m[2])
	orbit_yaw = deg_to_rad(float(options.yaw_deg)) if options.has("yaw_deg") else orbit_yaw
	orbit_pitch = deg_to_rad(float(options.pitch_deg)) if options.has("pitch_deg") else orbit_pitch
	orbit_distance = float(options.get("distance_m", orbit_distance))
	camera.fov = float(options.get("fov_deg", camera.fov))
	camera.size = float(options.get("orthographic_size_m", camera.size))
	if options.has("projection"):
		camera.projection = Camera3D.PROJECTION_ORTHOGONAL if options.projection == "orthographic" else Camera3D.PROJECTION_PERSPECTIVE
	camera_preset = preset
	_update_camera()
	return {"ok": true}

## 以屏幕距离选取可见关节点。
func _pick_joint(mouse: Vector2) -> int:
	var best = -1
	var distance = 19.0
	for index in positions.size():
		if camera.is_position_behind(positions[index]):
			continue
		var screen = camera.unproject_position(positions[index])
		var current = screen.distance_to(mouse)
		if current < distance:
			best = index
			distance = current
	return best

## 计算所选关节的父空间轴，用于旋转环显示。
func _axis_basis() -> Basis:
	if selected_joint < 0:
		return Basis.IDENTITY
	var parent = int(rig[selected_joint].parent)
	var basis = skeleton.get_bone_global_pose(parent).basis if parent >= 0 else Basis.IDENTITY
	return basis * Basis(rig[selected_joint].get("rest_rotation", Quaternion.IDENTITY))

## 生成一个旋转轴对应的空间圆环。
func _ring_points(axis: int) -> PackedVector2Array:
	var points = PackedVector2Array()
	var basis = _axis_basis()
	var center = positions[selected_joint]
	for index in range(49):
		var angle = TAU * index / 48
		var offset = Vector3(0, cos(angle), sin(angle)) if axis == 0 else (Vector3(cos(angle), 0, sin(angle)) if axis == 1 else Vector3(cos(angle), sin(angle), 0))
		points.append(camera.unproject_position(center + basis * offset * 0.16))
	return points

## 在屏幕上拾取旋转环。
func _pick_ring(mouse: Vector2) -> int:
	if selected_joint < 0 or edit_mode != "rotate":
		return -1
	var best = -1
	var best_distance = 8.0
	for axis in 3:
		var points = _ring_points(axis)
		for index in range(points.size() - 1):
			var closest = Geometry2D.get_closest_point_to_segment(mouse, points[index], points[index + 1])
			var distance = closest.distance_to(mouse)
			if distance < best_distance:
				best_distance = distance
				best = axis
	return best

## 绘制当前关节的选择圈和可操作旋转环。
func draw_overlay(canvas: Control) -> void:
	if selected_joint < 0 or positions.is_empty():
		return
	var center = camera.unproject_position(positions[selected_joint])
	canvas.draw_arc(center, 12, 0, TAU, 40, Color("128f82"), 2, true)
	if edit_mode == "rotate":
		for axis in 3:
			canvas.draw_polyline(_ring_points(axis), [Color("e46b72"), Color("3ab08c"), Color("538bd4")][axis], 2.2, true)

## 处理观察、关节拖动和旋转交互。
func _gui_input(event: InputEvent) -> void:
	if core == null:
		return
	camera_preset = "custom"
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_WHEEL_UP or event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			orbit_distance = clampf(orbit_distance * (0.9 if event.button_index == MOUSE_BUTTON_WHEEL_UP else 1.1), 0.05, 100.0)
			_update_camera()
			accept_event()
		elif event.button_index == MOUSE_BUTTON_RIGHT or event.button_index == MOUSE_BUTTON_MIDDLE:
			drag_action = ("pan" if event.shift_pressed else "orbit") if event.pressed else ""
			accept_event()
		elif event.button_index == MOUSE_BUTTON_LEFT:
			if event.pressed:
				grab_focus()
				rotation_axis = _pick_ring(event.position)
				var picked = _pick_joint(event.position)
				if picked >= 0 and rotation_axis < 0:
					select_joint(picked)
				if editable and selected_joint >= 0 and (picked >= 0 or rotation_axis >= 0) and edit_mode != "orbit":
					drag_action = "rotate" if edit_mode == "rotate" else "joint"
					drag_plane = Plane(camera.global_basis.z, positions[selected_joint])
					edit_started.emit()
				elif edit_mode == "orbit":
					drag_action = "orbit"
			else:
				if drag_action == "joint" or drag_action == "rotate":
					edit_finished.emit()
				drag_action = ""
			accept_event()
	elif event is InputEventMouseMotion and not drag_action.is_empty():
		if drag_action == "orbit":
			orbit_yaw -= event.relative.x * 0.009
			orbit_pitch = clampf(orbit_pitch + event.relative.y * 0.006, -1.569, 1.569)
			_update_camera()
		elif drag_action == "pan":
			orbit_target += (-camera.global_basis.x * event.relative.x + camera.global_basis.y * event.relative.y) * orbit_distance * 0.0013
			_update_camera()
		elif drag_action == "rotate":
			var next = pose.duplicate()
			var scale_factor = 0.15 if event.shift_pressed else 0.55
			if rotation_axis >= 0:
				next[selected_joint][rotation_axis] += (event.relative.x - event.relative.y) * scale_factor
			else:
				next[selected_joint].x += event.relative.y * scale_factor
				next[selected_joint].y += event.relative.x * scale_factor
			next = core.clamp_pose(next)
			set_pose(next, root_position)
			pose_edited.emit(pose, root_position)
		elif drag_action == "joint":
			var hit = drag_plane.intersects_ray(camera.project_ray_origin(event.position), camera.project_ray_normal(event.position))
			if hit != null:
				if int(rig[selected_joint].parent) < 0 or rig[selected_joint].get("semantic", {}).get("role", "") == "pelvis":
					set_pose(pose, root_position + (hit - positions[selected_joint]))
				else:
					set_pose(core.solve_ik(pose, selected_joint, hit, root_position, int(rig[selected_joint].get("ik_chain_length", 2))), root_position)
				pose_edited.emit(pose, root_position)
		accept_event()
