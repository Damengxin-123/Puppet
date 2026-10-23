extends "res://app/rig_view.gd"
## 绑定专用视口：参考关节可以移动和改变骨长，动画姿势仅用于观察。

## 拖动参考关节时传递世界空间坐标，单位米。
signal rest_joint_dragged(index: int, target: Vector3)
## 点击可见模型表面后返回原始稳定顶点标识。
signal weight_vertex_picked(vertex_id: String)
## 权重模式下左键只选择表面，不移动关节。
var weight_edit_mode: bool = false
## 热图对应的稳定骨骼标识，空字符串表示原材质。
var weight_bone_id: String = ""
## 当前权重选区的稳定顶点标识。
var weight_selection: Array = []
## 当前项目模型实例。
var model_nodes: Array = []
## 当前绑定项目数据服务。
var binding
## 是否处于只读动画预览。
var previewing: bool = false
## 拖动轴约束：负一表示屏幕平面。
var move_axis: int = -1
## 拖动开始时的位置，约束轴使用。
var rest_drag_origin: Vector3 = Vector3.ZERO

## 打开或重新配置绑定骨架，保留用户摄像机和选择。
func set_binding(service) -> void:
	binding = service
	previewing = false
	var selected = selected_joint
	for node in model_nodes:
		node.free()
	model_nodes.clear()
	initialize(binding.core, binding.bones)
	show_shell = false
	# 关节点穿透模型显示，便于选择位于身体内部的骨骼。
	core_material.no_depth_test = true
	selected_material.no_depth_test = true
	core_material.albedo_color = Color("16a89b")
	selected_material.albedo_color = Color("f1a12d")
	# 根据角色高度调整标记尺寸，小体型角色不会被关节球遮住。
	var marker_scale = clampf(float(binding.project.bounds_size_m[1]) / 1.8, 0.1, 3.0)
	for point in joint_points:
		point.mesh.radius = 0.012 * marker_scale
		point.mesh.height = 0.024 * marker_scale
	for line in bone_lines:
		if line != null:
			line.mesh.top_radius = 0.003 * marker_scale
			line.mesh.bottom_radius = 0.003 * marker_scale
	for mesh in binding.parts:
		var node = MeshInstance3D.new()
		node.name = "角色模型"
		node.mesh = mesh
		world_root.add_child(node)
		model_nodes.append(node)
	previewing = false
	editable = true
	var zero = PackedVector3Array()
	zero.resize(rig.size())
	set_pose(zero, Vector3.ZERO)
	if selected >= 0 and selected < rig.size():
		select_joint(selected)
	refresh_weight_display()

## 播放时转换参考姿态差异，编辑状态仍严格使用用户保存的原始关节位置。
func set_pose(value: PackedVector3Array, root: Vector3, evaluated: Array = []) -> void:
	if previewing and binding != null:
		evaluated = binding.evaluate_animation(value, root)
	super.set_pose(value, root, evaluated)

## 拖动时更新参考骨架，不触碰模型网格和原始顶点。
func refresh_rest() -> void:
	rig = binding.bones
	for index in rig.size():
		skeleton.set_bone_rest(index, Transform3D(Basis(rig[index].rest_rotation), rig[index].offset))
	var zero = PackedVector3Array()
	zero.resize(rig.size())
	set_pose(zero, Vector3.ZERO)

## 动画预览使用当前项目的逆绑定矩阵，不使用源骨架骨长。
func begin_preview() -> void:
	if previewing:
		return
	var meshes: Array = binding.get_skinned_parts()
	var skin: Skin = binding.create_skin()
	for index in model_nodes.size():
		var node: MeshInstance3D = model_nodes[index]
		node.mesh = meshes[index]
		node.skeleton = node.get_path_to(skeleton)
		node.skin = skin
	previewing = true
	editable = false
	refresh_weight_display()

## 返回绑定姿态时直接显示原模型，预览不会留下顶点变形。
func end_preview() -> void:
	for index in model_nodes.size():
		var node: MeshInstance3D = model_nodes[index]
		node.skin = null
		node.skeleton = NodePath()
		node.mesh = binding.parts[index]
	previewing = false
	editable = true
	refresh_rest()
	refresh_weight_display()

## 左键移动参考关节；右键、中键和滚轮沿用观察摄像机操作。
func _gui_input(event: InputEvent) -> void:
	if binding != null and weight_edit_mode and event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed:
			grab_focus()
			var id = pick_weight_vertex(event.position)
			if not id.is_empty():
				weight_vertex_picked.emit(id)
		accept_event()
		return
	if binding == null or previewing:
		super._gui_input(event)
		return
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed:
			grab_focus()
			var picked = _pick_joint(event.position)
			if picked >= 0:
				select_joint(picked)
				drag_action = "binding"
				rest_drag_origin = positions[picked]
				drag_plane = Plane(camera.global_basis.z, rest_drag_origin)
				edit_started.emit()
		else:
			if drag_action == "binding":
				drag_action = ""
				edit_finished.emit()
		accept_event()
	elif event is InputEventMouseMotion and drag_action == "binding":
		var hit = drag_plane.intersects_ray(camera.project_ray_origin(event.position), camera.project_ray_normal(event.position))
		if hit != null:
			var target: Vector3 = hit
			if move_axis >= 0:
				target = rest_drag_origin
				target[move_axis] = hit[move_axis]
			rest_joint_dragged.emit(selected_joint, target.snapped(Vector3.ONE * 0.01))
		accept_event()
	else:
		super._gui_input(event)

## 设置权重显示，材质和选区只属于视口，不写入原模型。
func set_weight_display(bone_id: String, selected_vertices: Array = []) -> void:
	weight_bone_id = bone_id
	weight_selection = selected_vertices
	refresh_weight_display()

## 单骨骼热图从蓝色零权重过渡到红色全权重，选区用白色提亮。
func _weight_color(weight: float) -> Color:
	var colors = [Color("123f95"), Color("13b9d0"), Color("e8e94a"), Color("f03a27")]
	var value = clampf(weight, 0, 1) * 3.0
	var index = mini(2, floori(value))
	return colors[index].lerp(colors[index + 1], value - index)

## 通过临时顶点颜色显示实际参与变形的权重，动画预览沿用相同 GPU 骨架。
func refresh_weight_display() -> void:
	if binding == null or binding.project.is_empty() or model_nodes.is_empty():
		return
	var base_meshes: Array = binding.get_skinned_parts() if previewing else binding.parts
	var bone = binding.bone_index(weight_bone_id)
	if bone < 0:
		for index in model_nodes.size():
			model_nodes[index].mesh = base_meshes[index]
		return
	var engine = binding.get_weight_engine()
	var weights: Array = binding.get_weights()
	var selected: Dictionary = {}
	for id in weight_selection:
		selected[id] = true
	var material = StandardMaterial3D.new()
	material.vertex_color_use_as_albedo = true
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	for part in base_meshes.size():
		var mesh = ArrayMesh.new()
		for surface in engine.surfaces:
			if surface.mesh_index != part:
				continue
			var arrays: Array = base_meshes[part].surface_get_arrays(surface.surface_index)
			var colors = PackedColorArray()
			for index in surface.vertices.size():
				var global_index: int = surface.start + index
				var color = _weight_color(float(weights[global_index].get(bone, 0)))
				colors.append(color.lerp(Color.WHITE, 0.5) if selected.has(engine.ids[global_index]) else color)
			arrays[Mesh.ARRAY_COLOR] = colors
			mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
			mesh.surface_set_material(mesh.get_surface_count() - 1, material)
		model_nodes[part].mesh = mesh

## 取得当前实际表面坐标，暂停动画时也能准确点选已变形的衣物。
func _weight_positions() -> Array:
	var engine = binding.get_weight_engine()
	var positions_by_surface: Array = []
	var transforms: Array = []
	var weights: Array = []
	if previewing:
		skeleton.force_update_all_bone_transforms()
		var skin = binding.create_skin()
		for index in rig.size():
			transforms.append(skeleton.get_bone_global_pose(index) * skin.get_bind_pose(index))
		weights = binding.get_weights()
	for surface in engine.surfaces:
		var vertices: PackedVector3Array = surface.vertices.duplicate()
		if previewing:
			for index in vertices.size():
				var position = Vector3.ZERO
				for bone in weights[surface.start + index]:
					position += (transforms[bone] * vertices[index]) * weights[surface.start + index][bone]
				vertices[index] = position
		positions_by_surface.append(vertices)
	return positions_by_surface

## 射线命中最前面的真实三角面后选择最近顶点，不穿透到背面或其他衣物层。
func pick_weight_vertex(pixel: Vector2) -> String:
	var origin = camera.project_ray_origin(pixel)
	var direction = camera.project_ray_normal(pixel)
	var best = INF
	var result = ""
	var engine = binding.get_weight_engine()
	var deformed = _weight_positions()
	for surface_index in engine.surfaces.size():
		var surface: Dictionary = engine.surfaces[surface_index]
		var vertices: PackedVector3Array = deformed[surface_index]
		var indices: PackedInt32Array = surface.indices if surface.indices != null else PackedInt32Array()
		if indices.is_empty():
			for index in vertices.size():
				indices.append(index)
		for face in range(0, indices.size() - 2, 3):
			var a = indices[face]
			var b = indices[face + 1]
			var c = indices[face + 2]
			var hit = Geometry3D.ray_intersects_triangle(origin, direction, vertices[a], vertices[b], vertices[c])
			if hit != null and origin.distance_squared_to(hit) < best:
				best = origin.distance_squared_to(hit)
				var nearest = a
				for candidate in [b, c]:
					if vertices[candidate].distance_squared_to(hit) < vertices[nearest].distance_squared_to(hit):
						nearest = candidate
				result = engine.ids[surface.start + nearest]
	return result
