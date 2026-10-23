extends RefCounted
## 独立绑定项目的存储和关节编辑，绝不写回源模型、骨架库或动画库。

## 已提交项目变化；界面与 MCP 共同订阅。
signal changed
## 导入和蒙皮计算模块。
const ModelScript = preload("res://app/binding_model.gd")
## 自动与手工蒙皮共用的拓扑计算模块。
const WeightsScript = preload("res://app/binding_weights.gd")
## 当前模型的稳定顶点和自动权重缓存。
var weight_engine
## 项目目录，不与动画资产目录混用。
var directory: String = ""
## 源骨架注册表，仅用于复制定义和校验。
var registry
## 当前持久项目数据。
var project: Dictionary = {}
## 当前模型的原始几何，导入后不修改。
var parts: Array = []
## 当前绑定专用求解器。
var core
## 当前项目骨架的原生参数。
var bones: Array = []
## 模型处理工具。
var model = ModelScript.new()
## 最近项目操作错误。
var last_error: String = ""
## 当前项目的撤销记录。
var undo_stack: Array = []
## 当前项目的重做记录。
var redo_stack: Array = []
## 拖动期间的持久快照，结束后只提交一次。
var drag_snapshot: Dictionary = {}
## 已按当前参考骨架生成的预览网格缓存。
var skinned_parts: Array = []
## 上次打开项目的稳定标识。
var last_project_id: String = ""
## 源骨架求解器，仅用于读取动画的原始空间方向。
var source_core
## 项目关节到源骨架关节的稳定标识映射。
var source_joint_indices: PackedInt32Array = PackedInt32Array()
## 将源骨架朝向转换到当前项目朝向的旋转。
var retarget_alignment: Quaternion = Quaternion.IDENTITY
## 源动画全局旋转到项目绑定坐标的参考姿态补偿。
var retarget_corrections: Array[Quaternion] = []

## 准备独立项目目录并恢复异常退出时保留的上一版。
func initialize(rig_registry, override_path: String = "") -> void:
	registry = rig_registry
	directory = ProjectSettings.globalize_path("res://workspace/bindings") if override_path.is_empty() else override_path
	DirAccess.make_dir_recursive_absolute(directory)
	var selection = ConfigFile.new()
	if selection.load(directory.path_join("选择.cfg")) == OK:
		last_project_id = str(selection.get_value("binding", "project_id", ""))
	for item in DirAccess.get_directories_at(directory):
		var path = directory.path_join(item).path_join("项目.json")
		if not FileAccess.file_exists(path) and FileAccess.file_exists(path + ".previous"):
			DirAccess.rename_absolute(path + ".previous", path)

## 列出所有已保存项目，原始模型被移动也不影响再次打开。
func list_projects() -> Array:
	var result: Array = []
	for item in DirAccess.get_directories_at(directory):
		var path = directory.path_join(item).path_join("项目.json")
		if not FileAccess.file_exists(path):
			continue
		var data = JSON.parse_string(FileAccess.get_file_as_string(path))
		if data is Dictionary and data.get("format_version") == 1 and data.get("id") == item:
			result.append({"project_id": data.id, "name": data.name, "rig_id": data.rig_id, "revision": data.revision, "model_name": data.model_name})
	result.sort_custom(func(a, b): return str(a.name).naturalnocasecmp_to(str(b.name)) < 0)
	return result

## 创建任务时复制骨架和模型几何；项目以稳定标识独立保存。
func create_project(path: String, display_name: String, rig_id: String) -> Dictionary:
	if display_name.strip_edges().is_empty() or display_name.length() > 96:
		return _failure("项目名称需要 1 至 96 个字符。")
	var definition: Dictionary = registry.get_definition(rig_id)
	if definition.is_empty():
		return _failure("源骨架不存在。")
	var imported: Dictionary = model.import_file(path)
	if not imported.ok:
		return _failure(imported.error)
	var id = "binding_" + Crypto.new().generate_random_bytes(12).hex_encode()
	var folder = directory.path_join(id)
	if DirAccess.make_dir_recursive_absolute(folder) != OK:
		return _failure("不能创建绑定项目目录。")
	var resources: Array = []
	for index in imported.parts.size():
		var filename = "模型_%02d.res" % index
		if ResourceSaver.save(imported.parts[index], folder.path_join(filename), ResourceSaver.FLAG_BUNDLE_RESOURCES | ResourceSaver.FLAG_COMPRESS) != OK:
			return _failure("模型资源保存失败，当前项目保持不变。")
		resources.append(filename)
	var bounds: AABB = imported.bounds
	var candidate = {"format_version": 1, "id": id, "name": display_name.strip_edges(), "rig_id": rig_id, "revision": 1, "model_name": path.get_file(), "source_path": path, "model_resources": resources, "vertices": imported.vertices, "bounds_position_m": _array(bounds.position), "bounds_size_m": _array(bounds.size), "rig": definition, "skin_mode": "smooth"}
	# 初次只按模型高度与地面位置摆放骨架，保留模型原有坐标、形状及比例。
	var source_core = registry.create_core(rig_id)
	var reference: Array = source_core.evaluate_transforms(PackedVector3Array(), Vector3.ZERO)
	var rest_bounds = AABB(reference[0].position, Vector3.ZERO)
	for transform in reference:
		rest_bounds = rest_bounds.expand(transform.position)
	var scale_factor = bounds.size.y / maxf(rest_bounds.size.y + 0.15, 0.01)
	for bone in candidate.rig.bones:
		var offset: Vector3 = registry.to_vector(bone.rest_translation_m) * scale_factor
		if str(bone.parent_id).is_empty():
			offset += Vector3(bounds.get_center().x, bounds.position.y, bounds.get_center().z)
		bone.rest_translation_m = _array(offset.snapped(Vector3.ONE * 0.01))
	if not _persist(candidate):
		return _failure(last_error)
	project = candidate
	parts = imported.parts
	weight_engine = null
	undo_stack.clear()
	redo_stack.clear()
	_rebuild_core()
	_remember_project()
	changed.emit()
	return {"ok": true, "project": get_state()}

## 从项目自带资源重新加载，先完整验证再替换当前任务。
func open_project(id: String) -> Dictionary:
	if not registry.valid_id(id):
		return _failure("项目标识无效。")
	var folder = directory.path_join(id)
	if not FileAccess.file_exists(folder.path_join("项目.json")):
		return _failure("绑定项目不存在。")
	var data = JSON.parse_string(FileAccess.get_file_as_string(folder.path_join("项目.json")))
	if not data is Dictionary or data.get("format_version") != 1 or data.get("id") != id:
		return _failure("绑定项目不存在或格式不正确。")
	var checked: Dictionary = registry.validate_definition(data.get("rig", {}))
	if not checked.ok or not data.get("model_resources") is Array or data.model_resources.is_empty():
		return _failure("绑定项目的骨架或模型记录损坏。")
	var loaded: Array = []
	for filename in data.model_resources:
		if not filename is String or filename != filename.get_file() or not filename.ends_with(".res"):
			return _failure("项目资源路径不合法。")
		var mesh = ResourceLoader.load(folder.path_join(filename), "ArrayMesh", ResourceLoader.CACHE_MODE_IGNORE)
		if not mesh is ArrayMesh:
			return _failure("项目缺少模型资源：" + filename)
		loaded.append(mesh)
	data.rig = checked.definition
	project = data
	parts = loaded
	weight_engine = null
	undo_stack.clear()
	redo_stack.clear()
	drag_snapshot.clear()
	_rebuild_core()
	_remember_project()
	changed.emit()
	return {"ok": true, "project": get_state()}

## 返回项目独立参考姿势、稳定关节标识与实际骨长。
func get_state() -> Dictionary:
	if project.is_empty():
		return {}
	var result = project.duplicate(true)
	result.erase("weight_overrides")
	result.weight_override_count = project.get("weight_overrides", {}).size()
	result.weight_algorithm = "surface_geodesic_v2"
	result.project_id = project.id
	result.storage_path = directory.path_join(project.id)
	result.editing = not drag_snapshot.is_empty()
	result.joints = []
	var transforms: Array = core.evaluate_transforms(PackedVector3Array(), Vector3.ZERO)
	for index in bones.size():
		var parent = int(bones[index].parent)
		result.joints.append({"bone_id": bones[index].id, "name": bones[index].name, "parent_id": "" if parent < 0 else bones[parent].id, "position_m": _array(transforms[index].position), "length_m": 0.0 if parent < 0 else snappedf(transforms[index].position.distance_to(transforms[parent].position), 0.01)})
	return result

## 拖动只修改目标关节；可显式选择是否一起平移整条子链。
func move_joint(bone_id: String, position: Array, move_children: bool = false, preview: bool = false) -> Dictionary:
	if project.is_empty() or not registry.numeric_vector(position, 3):
		return _failure("需要已打开项目及有效的三轴米制坐标。")
	var target: Vector3 = registry.to_vector(position)
	if maxf(absf(target.x), maxf(absf(target.y), absf(target.z))) > 1000:
		return _failure("关节坐标不能超出 1000 米。")
	if not target.is_equal_approx(target.snapped(Vector3.ONE * 0.01)):
		return _failure("关节坐标最多保留两位小数。")
	var index = -1
	for item in bones.size():
		if bones[item].id == bone_id:
			index = item
	if index < 0:
		return _failure("项目中不存在该关节。")
	var before = project.duplicate(true)
	var transforms: Array = core.evaluate_transforms(PackedVector3Array(), Vector3.ZERO)
	var delta: Vector3 = target - transforms[index].position
	for item in bones.size():
		var affected = item == index
		var parent = int(bones[item].parent)
		while move_children and parent >= 0:
			if parent == index:
				affected = true
			parent = int(bones[parent].parent)
		if affected:
			transforms[item].position += delta
	for item in bones.size():
		var parent = int(bones[item].parent)
		var offset: Vector3 = transforms[item].position
		if parent >= 0:
			offset = transforms[parent].rotation.inverse() * (offset - transforms[parent].position)
		project.rig.bones[item].rest_translation_m = _array(offset)
	_rebuild_core()
	if not preview:
		return _commit(before)
	return {"ok": true}

## 显式改变骨长时沿当前方向移动关节和后代，其他分支保持原位。
func set_length(bone_id: String, length_m: float) -> Dictionary:
	if project.is_empty():
		return _failure("请先打开绑定项目。")
	if not is_finite(length_m) or length_m < 0.01 or length_m > 100 or absf(length_m - snappedf(length_m, 0.01)) > 0.000001:
		return _failure("骨长必须为 0.01 至 100.00 米，保留两位小数。")
	var transforms: Array = core.evaluate_transforms(PackedVector3Array(), Vector3.ZERO)
	for index in bones.size():
		if bones[index].id != bone_id:
			continue
		var parent = int(bones[index].parent)
		if parent < 0:
			return _failure("根关节没有父骨段。")
		var direction: Vector3 = transforms[index].position - transforms[parent].position
		if direction.length() < 0.00001:
			return _failure("重合关节没有方向，请先拖开关节。")
		var before = project.duplicate(true)
		var offset: Vector3 = registry.to_vector(project.rig.bones[index].rest_translation_m)
		project.rig.bones[index].rest_translation_m = _array(offset.normalized() * length_m)
		_rebuild_core()
		return _commit(before)
	return _failure("项目中不存在该关节。")

## 按 Y 轴旋转整个参考骨架以匹配不同模型朝向，几何与源动画不变。
func rotate_rig(degrees: float) -> Dictionary:
	if project.is_empty():
		return _failure("请先打开绑定项目。")
	return update_options(project.name, project.skin_mode, degrees)

## 记录拖动起点，避免每一帧都写入硬盘。
func begin_drag() -> void:
	drag_snapshot = project.duplicate(true)

## 松开鼠标后原子保存一次，并建立一条撤销记录。
func finish_drag() -> Dictionary:
	if drag_snapshot.is_empty():
		return {"ok": true}
	var before = drag_snapshot
	drag_snapshot = {}
	return _commit(before)

## 修改项目名称或蒙皮方式，不改变动画资源。
func update_options(display_name: String, skin_mode: String, yaw_delta_deg: float = 0.0) -> Dictionary:
	if project.is_empty() or display_name.strip_edges().is_empty() or display_name.length() > 96 or skin_mode not in ["smooth", "rigid"] or not is_finite(yaw_delta_deg) or absf(yaw_delta_deg) > 360.0:
		return _failure("项目名称或蒙皮方式不合法。")
	var before = project.duplicate(true)
	project.name = display_name.strip_edges()
	project.skin_mode = skin_mode
	var root: Dictionary = project.rig.bones[0]
	var values: Array = root.rest_rotation_xyzw
	var current = Quaternion(values[0], values[1], values[2], values[3])
	var rotated = Quaternion(Vector3.UP, deg_to_rad(yaw_delta_deg)) * current
	root.rest_rotation_xyzw = [rotated.x, rotated.y, rotated.z, rotated.w]
	_rebuild_core()
	return _commit(before)

## 将用户可见的每次修改立即持久化，保存失败则恢复上一版本。
func _commit(before: Dictionary, history: bool = true) -> Dictionary:
	project.revision = int(before.revision) + 1
	if not _persist(project):
		project = before
		_rebuild_core()
		changed.emit()
		return _failure(last_error)
	if history:
		undo_stack.append(before)
		if undo_stack.size() > 64:
			undo_stack.pop_front()
		redo_stack.clear()
	changed.emit()
	return {"ok": true, "project": get_state()}

## 撤销或重做只作用于当前绑定项目，重新保存后可继续编辑。
func undo(redo: bool = false) -> Dictionary:
	var source: Array = redo_stack if redo else undo_stack
	var destination: Array = undo_stack if redo else redo_stack
	if source.is_empty():
		return _failure("没有可以重做的绑定修改。" if redo else "没有可以撤销的绑定修改。")
	var before = project.duplicate(true)
	project = source[-1].duplicate(true)
	_rebuild_core()
	var result = _commit(before, false)
	if result.ok:
		source.pop_back()
		destination.append(before)
	return result

## 手动保存用于确认项目已写入成功。
func save() -> Dictionary:
	if project.is_empty():
		return _failure("请先创建或打开绑定项目。")
	return {"ok": true, "project": get_state()} if _persist(project) else _failure(last_error)

## 延迟构建蒙皮，拖动期间只移动骨架，原模型不参与运算。
func get_skinned_parts() -> Array:
	if skinned_parts.is_empty():
		var rest: Array = core.evaluate_transforms(PackedVector3Array(), Vector3.ZERO)
		var engine = get_weight_engine()
		var weights: Array = get_weights()
		for index in parts.size():
			var surface_weights: Array = []
			for surface in engine.surfaces:
				if surface.mesh_index == index:
					surface_weights.append(weights.slice(surface.start, surface.start + surface.vertices.size()))
			skinned_parts.append(model.build_skin_mesh(parts[index], bones, rest, project.skin_mode == "rigid", surface_weights))
	return skinned_parts

## 延迟建立原始顶点索引，关节编辑后仅重算自动权重。
func get_weight_engine():
	if weight_engine == null:
		weight_engine = WeightsScript.new()
		weight_engine.initialize(parts)
	weight_engine.calculate(bones, core.evaluate_transforms(PackedVector3Array(), Vector3.ZERO), float(project.bounds_size_m[1]), project.skin_mode == "rigid")
	return weight_engine

## 获取预览、数值查询与权重编辑共用的最终归一化权重。
func get_weights() -> Array:
	return get_weight_engine().resolved(project.get("weight_overrides", {}))

## 骨骼稳定标识转为当前索引，无效标识不默认落到根节点。
func bone_index(bone_id: String) -> int:
	for index in bones.size():
		if str(bones[index].id) == bone_id:
			return index
	return -1

## 解析显式顶点或基于网格表面的米制选区，写入前一次性校验全部目标。
func weight_selection(params: Dictionary) -> Dictionary:
	if project.is_empty():
		return _failure("请先打开绑定项目。")
	var engine = get_weight_engine()
	var selected: Array = []
	if params.has("vertex_ids"):
		if not params.vertex_ids is Array or params.vertex_ids.is_empty() or params.vertex_ids.size() > 100000:
			return _failure("顶点列表需要包含 1 至 100000 个稳定标识。")
		for id in params.vertex_ids:
			if not id is String or not engine.lookup.has(id):
				return _failure("顶点标识不存在：" + str(id))
		selected = engine.expand_seams(params.vertex_ids)
	elif params.has("seed_vertex_id"):
		var radius = float(params.get("radius_m", 0.03))
		if not engine.lookup.has(str(params.seed_vertex_id)) or not is_finite(radius) or radius < 0.01 or radius > 100 or absf(radius - snappedf(radius, 0.01)) > 0.000001:
			return _failure("选区需要有效种子顶点和 0.01 至 100.00 米、两位小数的半径。")
		selected = engine.region(str(params.seed_vertex_id), radius, bool(params.get("whole_component", false)))
	else:
		return _failure("请指定顶点列表或种子顶点与表面半径。")
	return {"ok": true, "vertex_ids": selected}

## 分页查看真实权重和原始坐标，按骨骼过滤时分页作用于过滤后的结果。
func query_weights(params: Dictionary) -> Dictionary:
	var engine = get_weight_engine()
	var weights: Array = get_weights()
	var offset = int(params.get("offset", 0))
	var limit = int(params.get("limit", 64))
	var filter_bone = bone_index(str(params.get("bone_id", "")))
	var minimum = float(params.get("minimum_weight", 0.001))
	if offset < 0 or limit < 1 or limit > 512 or not is_finite(minimum) or minimum < 0 or minimum > 1 or (params.has("bone_id") and filter_bone < 0):
		return _failure("权重查询的骨骼、分页或阈值无效。")
	var candidates: Array = engine.ids
	if params.has("vertex_ids") or params.has("seed_vertex_id"):
		var selection = weight_selection(params)
		if not selection.ok:
			return selection
		candidates = selection.vertex_ids
	var matches: Array = []
	for id in candidates:
		if filter_bone < 0 or float(weights[engine.lookup[id]].get(filter_bone, 0)) >= minimum:
			matches.append(id)
	var result: Array = []
	for id in matches.slice(offset, offset + limit):
		var index: int = engine.lookup[id]
		var influences: Dictionary = {}
		for bone in weights[index]:
			influences[str(bones[bone].id)] = weights[index][bone]
		result.append({"vertex_id": id, "position_m": _array(engine.points[engine.welds[index]]), "weights": influences, "manual": project.get("weight_overrides", {}).has(id)})
	var meshes: Array = []
	for surface in engine.surfaces:
		meshes.append({"mesh_index": surface.mesh_index, "surface_index": surface.surface_index, "vertex_count": surface.vertices.size()})
	return {"ok": true, "project_id": project.id, "project_revision": project.revision, "algorithm": "surface_geodesic_v2", "surfaces": meshes, "total": matches.size(), "offset": offset, "vertices": result, "manual_vertex_count": project.get("weight_overrides", {}).size()}

## 原子编辑整组选区，自动归一化并保留最多四权重；历史、保存与关节共用。
func edit_weights(params: Dictionary) -> Dictionary:
	var selection = weight_selection(params)
	if not selection.ok:
		return selection
	var operation = str(params.get("operation", "set"))
	var target = bone_index(str(params.get("bone_id", "")))
	var amount = float(params.get("value", 1.0))
	var fallback = bone_index(str(params.get("fallback_bone_id", "pelvis")))
	var excluded: Array = []
	if operation not in ["set", "add", "subtract", "smooth", "exclude", "exclude_arms"] or not is_finite(amount) or amount < 0 or amount > 1:
		return _failure("操作类型或权重无效，权重范围为 0 至 1。")
	if operation in ["set", "add", "subtract"] and target < 0:
		return _failure("请选择要修改权重的骨骼。")
	var engine = get_weight_engine()
	if operation in ["exclude", "exclude_arms"]:
		if fallback < 0:
			return _failure("清除影响时需要有效的接收骨骼。")
		if operation == "exclude_arms":
			for index in bones.size():
				if engine._arm(index):
					excluded.append(index)
		else:
			if not params.get("excluded_bone_ids") is Array or params.excluded_bone_ids.is_empty():
				return _failure("请列出要清除的骨骼影响。")
			for id in params.excluded_bone_ids:
				var index = bone_index(str(id))
				if index < 0:
					return _failure("要清除的骨骼不存在。")
				excluded.append(index)
		if fallback in excluded:
			return _failure("接收骨骼不能同时被清除。")
	var before = project.duplicate(true)
	var weights: Array = get_weights()
	var overrides: Dictionary = project.get("weight_overrides", {}).duplicate(true)
	for id in selection.vertex_ids:
		var index: int = engine.lookup[id]
		var value: Dictionary = weights[index].duplicate()
		if operation == "smooth":
			var node: int = engine.welds[index]
			var count: float = engine.neighbors[node].size()
			if count > 0:
				for bone in value:
					value[bone] *= 1.0 - amount
				for adjacent in engine.neighbors[node]:
					var neighbor: Dictionary = weights[engine.originals[adjacent][0]]
					for bone in neighbor:
						value[bone] = float(value.get(bone, 0)) + neighbor[bone] * amount / count
		elif operation in ["exclude", "exclude_arms"]:
			var removed = 0.0
			for bone in excluded:
				removed += float(value.get(bone, 0))
				value.erase(bone)
			value[fallback] = float(value.get(fallback, 0)) + removed
		else:
			var old = float(value.get(target, 0))
			var desired = amount if operation == "set" else clampf(old + amount * (-1.0 if operation == "subtract" else 1.0), 0, 1)
			value.erase(target)
			if value.is_empty() and desired < 1.0:
				if fallback < 0 or fallback == target:
					return _failure("唯一影响降到 1 以下时，请指定不同的接收骨骼。")
				value[fallback] = 1.0
			value = engine.normalize(value)
			# 提前保留目标骨骼名额，避免设定的小权重被四项截断挤掉。
			if desired > 0 and value.size() > 3:
				value.erase(value.keys()[-1])
				value = engine.normalize(value)
			for bone in value:
				value[bone] *= 1.0 - desired
			value[target] = desired
		value = engine.normalize(value)
		if value.is_empty():
			return _failure("修改后至少需要一根骨骼影响顶点。")
		var stored: Dictionary = {}
		for bone in value:
			stored[str(bones[bone].id)] = value[bone]
		overrides[id] = stored
	project.weight_overrides = overrides
	project.weight_algorithm = "surface_geodesic_v2"
	skinned_parts.clear()
	var result = _commit(before)
	result.affected_vertices = selection.vertex_ids.size()
	return result

## 清除指定手工覆盖恢复自动结果；整项目恢复必须显式使用 scope=all。
func reset_weights(params: Dictionary) -> Dictionary:
	var selected: Array = []
	if str(params.get("scope", "selection")) == "all":
		selected = project.get("weight_overrides", {}).keys()
	else:
		var selection = weight_selection(params)
		if not selection.ok:
			return selection
		selected = selection.vertex_ids
	var before = project.duplicate(true)
	var overrides: Dictionary = project.get("weight_overrides", {}).duplicate(true)
	for id in selected:
		overrides.erase(id)
	project.weight_overrides = overrides
	skinned_parts.clear()
	return _commit(before)

## 重算拓扑自动蒙皮，保留当前关节、骨长及全部手工权重。
func recalculate_weights() -> Dictionary:
	var before = project.duplicate(true)
	project.weight_algorithm = "surface_geodesic_v2"
	if weight_engine != null:
		weight_engine.invalidate()
	skinned_parts.clear()
	get_weight_engine()
	return _commit(before)

## 为当前参考姿态计算逆绑定矩阵，零姿态精确还原导入模型。
func create_skin() -> Skin:
	var skin = Skin.new()
	var rest: Array = core.evaluate_transforms(PackedVector3Array(), Vector3.ZERO)
	for index in rest.size():
		skin.add_bind(index, Transform3D(Basis(rest[index].rotation), rest[index].position).affine_inverse())
	return skin

## 骨架改变朝向时同步旋转动画根位移，原动作中的移动方向语义保持一致。
func adapt_root_motion(value: Vector3) -> Vector3:
	return retarget_alignment * value

## 将源动画方向映射到绑定参考姿态；不把下垂手臂再次当作 T 姿态旋转。
func evaluate_animation(pose: PackedVector3Array, root_motion: Vector3) -> Array:
	if source_core == null or retarget_corrections.size() != bones.size():
		return core.evaluate_transforms(pose, root_motion)
	var source: Array = source_core.evaluate_transforms(pose, Vector3.ZERO)
	var result: Array = []
	for index in bones.size():
		var source_index = source_joint_indices[index]
		var rotation = (retarget_alignment * source[source_index].rotation * retarget_corrections[index]).normalized()
		var parent = int(bones[index].parent)
		var position: Vector3 = bones[index].offset + root_motion if parent < 0 else result[parent].position + result[parent].rotation * bones[index].offset
		result.append({"position": position, "rotation": rotation})
	return result

## 通过主要子骨段推导参考方向；中心骨链优先，末端继承上一骨段的摆向。
func _rebuild_retargeting() -> void:
	retarget_corrections.clear()
	source_joint_indices.clear()
	retarget_alignment = Quaternion.IDENTITY
	var source_definition: Dictionary = registry.get_definition(project.rig_id)
	if source_definition.is_empty():
		source_core = null
		return
	var source_bones: Array = registry.native_from_definition(source_definition)
	if source_core == null:
		source_core = ClassDB.instantiate("PuppetAnimator")
	source_core.configure_rig(source_bones)
	var source_by_id: Dictionary = {}
	for index in source_bones.size():
		source_by_id[str(source_bones[index].id)] = index
	for bone in bones:
		if not source_by_id.has(str(bone.id)):
			source_core = null
			return
		source_joint_indices.append(source_by_id[str(bone.id)])
	var source_rest: Array = source_core.evaluate_transforms(PackedVector3Array(), Vector3.ZERO)
	var target_rest: Array = core.evaluate_transforms(PackedVector3Array(), Vector3.ZERO)
	retarget_alignment = (target_rest[0].rotation * source_rest[source_joint_indices[0]].rotation.inverse()).normalized()
	var swings: Array[Quaternion] = []
	for index in bones.size():
		var parent = int(bones[index].parent)
		var primary = -1
		var priority = -INF
		for child in bones.size():
			if int(bones[child].parent) != index:
				continue
			var direction: Vector3 = target_rest[child].position - target_rest[index].position
			var source_direction: Vector3 = source_rest[source_joint_indices[child]].position - source_rest[source_joint_indices[index]].position
			if direction.length_squared() < 0.00000001 or source_direction.length_squared() < 0.00000001:
				continue
			var score = source_direction.length()
			if bones[index].get("semantic", {}).get("side", "center") == "center" and bones[child].get("semantic", {}).get("side", "center") == "center":
				score += 1000.0
			if score > priority:
				priority = score
				primary = child
		var swing = swings[parent] if parent >= 0 else Quaternion.IDENTITY
		if primary >= 0 and parent >= 0:
			var source_direction: Vector3 = retarget_alignment * (source_rest[source_joint_indices[primary]].position - source_rest[source_joint_indices[index]].position)
			var target_direction: Vector3 = target_rest[primary].position - target_rest[index].position
			swing = Quaternion(source_direction.normalized(), target_direction.normalized())
		swings.append(swing)
		var source_frame: Quaternion = (swing * retarget_alignment * source_rest[source_joint_indices[index]].rotation).normalized()
		retarget_corrections.append((source_frame.inverse() * target_rest[index].rotation).normalized())

## 使用项目内骨长重建求解器，源骨架注册表保持不变。
func _rebuild_core() -> void:
	bones = registry.native_from_definition(project.rig)
	if core == null:
		core = ClassDB.instantiate("PuppetAnimator")
	core.configure_rig(bones)
	skinned_parts.clear()
	if weight_engine != null:
		weight_engine.invalidate()
	_rebuild_retargeting()

## 记住最近项目，重新启动后继续该绑定任务。
func _remember_project() -> void:
	last_project_id = str(project.id)
	var selection = ConfigFile.new()
	selection.set_value("binding", "project_id", last_project_id)
	selection.save(directory.path_join("选择.cfg"))

## 用临时文件和上一版本替换，失败不破坏已有项目。
func _persist(data: Dictionary) -> bool:
	var path = directory.path_join(data.id).path_join("项目.json")
	var file = FileAccess.open(path + ".tmp", FileAccess.WRITE)
	if file == null:
		last_error = "不能写入绑定项目，请检查目录权限和磁盘空间。"
		return false
	file.store_string(JSON.stringify(data, "\t", false) + "\n")
	file.flush()
	file.close()
	if FileAccess.file_exists(path + ".previous"):
		DirAccess.remove_absolute(path + ".previous")
	if FileAccess.file_exists(path) and DirAccess.rename_absolute(path, path + ".previous") != OK:
		last_error = "项目文件被占用，旧项目已保留。"
		return false
	if DirAccess.rename_absolute(path + ".tmp", path) != OK:
		if FileAccess.file_exists(path + ".previous"):
			DirAccess.rename_absolute(path + ".previous", path)
		last_error = "项目保存失败，已恢复旧版本。"
		return false
	last_error = ""
	return true

## 向量按实际精度保存，界面与外部坐标输入限制为两位小数。
func _array(value: Vector3) -> Array:
	return [value.x, value.y, value.z]

## 生成可直接显示的错误结果。
func _failure(message: String) -> Dictionary:
	last_error = message
	return {"ok": false, "error": message}
