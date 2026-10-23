extends RefCounted
## 数据驱动骨架注册表：稳定标识、语义、参考轴和约束独立于关节数量。

## 当前结构格式，未来新增约束模型时通过能力清单声明。
const SCHEMA_VERSION: int = 1
## 当前已加载的骨架，按稳定骨架标识索引。
var definitions: Dictionary = {}
## 骨架定义与约束的持久化目录。
var storage_directory: String = ""
## 启动时跳过的不兼容骨架及其具体原因。
var load_errors: Array = []

## 注册内置骨架并加载项目中后续增加的骨架定义。
func initialize(default_core, override_directory: String = "") -> void:
	storage_directory = ProjectSettings.globalize_path("res://workspace/rigs") if override_directory.is_empty() else override_directory
	definitions.clear()
	load_errors.clear()
	var builtin = _builtin_definition(default_core.describe_rig())
	definitions[builtin.id] = builtin
	DirAccess.make_dir_recursive_absolute(storage_directory)
	var directory = DirAccess.open(storage_directory)
	if directory == null:
		return
	for filename in directory.get_files():
		if filename.ends_with(".json.previous") and not FileAccess.file_exists(storage_directory.path_join(filename.trim_suffix(".previous"))):
			DirAccess.rename_absolute(storage_directory.path_join(filename), storage_directory.path_join(filename.trim_suffix(".previous")))
	for filename in directory.get_files():
		if not filename.ends_with(".json"):
			continue
		var source = JSON.parse_string(FileAccess.get_file_as_string(storage_directory.path_join(filename)))
		var checked = validate_definition(source)
		if not checked.ok:
			load_errors.append({"file": filename, "error": checked.error})
			continue
		var definition: Dictionary = checked.definition
		if definitions.has(definition.id) and _topology_signature(definitions[definition.id]) != _topology_signature(definition):
			load_errors.append({"file": filename, "error": "同一骨架标识不能悄悄替换骨架层级，请使用新的骨架标识。"})
			continue
		definitions[definition.id] = definition

## 将现有标准骨架转换成公开的可扩展定义，语义使用稳定名称而非数组编号。
func _builtin_definition(native_bones: Array) -> Dictionary:
	var bones: Array = []
	for item in native_bones:
		var role = "joint"
		var id = str(item.id)
		for candidate in ["root", "pelvis", "head", "neck", "chest", "clavicle", "upper_arm", "forearm", "hand", "thigh", "shin", "foot", "toe"]:
			if id == candidate or id.begins_with(candidate + "_"):
				role = candidate
		var rest: Quaternion = item.get("rest_rotation", Quaternion.IDENTITY)
		bones.append({
			"id": id, "name": str(item.name), "parent_id": "" if int(item.parent) < 0 else str(native_bones[item.parent].id),
			"rest_translation_m": _vector_array(item.offset), "rest_rotation_xyzw": [rest.x, rest.y, rest.z, rest.w],
			"limits": {"type": "euler_xyz", "minimum_deg": _vector_array(item.minimum), "maximum_deg": _vector_array(item.maximum)},
			"semantic": {"role": role, "side": "left" if id.ends_with("_l") else ("right" if id.ends_with("_r") else "center")},
			"display": {"kind": "head" if role == "head" else "joint", "radius_m": float(item.radius), "draw_parent_bone": role not in ["root", "pelvis"]},
			"ik_chain_length": 2
		})
	return {"schema_version": SCHEMA_VERSION, "id": "standard_humanoid_v1", "name": "标准人形", "skeleton_version": 1, "revision": 1, "bones": bones}

## 返回骨架摘要，不向调用方泄露可直接修改的内部引用。
func list_rigs() -> Array:
	var result: Array = []
	for id in definitions:
		var definition: Dictionary = definitions[id]
		result.append({"rig_id": id, "name": definition.name, "skeleton_version": definition.skeleton_version, "revision": definition.revision, "joint_count": definition.bones.size()})
	return result

## 返回完整且可序列化的骨架定义。
func get_definition(rig_id: String) -> Dictionary:
	return definitions[rig_id].duplicate(true) if definitions.has(rig_id) else {}

## 将稳定父节点标识映射成原生求解器内部的拓扑顺序索引。
func native_definition(rig_id: String) -> Array:
	return native_from_definition(definitions[rig_id])

## 将已验证的候选定义转换为原生数据，便于提交前检查新限制。
func native_from_definition(definition: Dictionary) -> Array:
	var result: Array = []
	var indices: Dictionary = {}
	for bone in definition.bones:
		var rotation: Array = bone.rest_rotation_xyzw
		result.append({
			"id": bone.id, "name": bone.name, "parent": int(indices.get(bone.parent_id, -1)),
			"offset": to_vector(bone.rest_translation_m), "rest_rotation": Quaternion(rotation[0], rotation[1], rotation[2], rotation[3]),
			"minimum": to_vector(bone.limits.minimum_deg), "maximum": to_vector(bone.limits.maximum_deg),
			"radius": bone.display.radius_m, "semantic": bone.semantic.duplicate(true), "display": bone.display.duplicate(true), "ik_chain_length": bone.ik_chain_length
		})
		indices[bone.id] = result.size() - 1
	return result

## 创建独立求解实例，多个骨架体系之间不共享可变限制。
func create_core(rig_id: String):
	if not definitions.has(rig_id):
		return null
	var animator = ClassDB.instantiate("PuppetAnimator")
	return animator if animator.configure_rig(native_definition(rig_id)) else null

## 完整验证后注册新的骨架标识，支持任意合法的手脚细分层级。
func register_definition(source: Dictionary) -> Dictionary:
	var checked = validate_definition(source)
	if not checked.ok:
		return checked
	var definition: Dictionary = checked.definition
	if definitions.has(definition.id):
		return {"ok": false, "error": "骨架标识已存在。"}
	definition.revision = 1
	var saved = persist_definition(definition)
	if saved.ok:
		definitions[definition.id] = definition
	return saved

## 持久化骨架快照，保存失败时保持内存和旧文件不变。
func persist_definition(definition: Dictionary) -> Dictionary:
	var destination = storage_directory.path_join(str(definition.id) + ".json")
	var temporary = destination + ".tmp"
	var backup = destination + ".previous"
	var file = FileAccess.open(temporary, FileAccess.WRITE)
	if file == null:
		return {"ok": false, "error": "无法写入骨架定义。"}
	file.store_string(JSON.stringify(definition, "\t", false) + "\n")
	file.flush()
	file.close()
	if FileAccess.file_exists(backup):
		DirAccess.remove_absolute(backup)
	if FileAccess.file_exists(destination) and DirAccess.rename_absolute(destination, backup) != OK:
		return {"ok": false, "error": "骨架文件被占用，未替换旧定义。"}
	if DirAccess.rename_absolute(temporary, destination) != OK:
		if FileAccess.file_exists(backup):
			DirAccess.rename_absolute(backup, destination)
		return {"ok": false, "error": "保存骨架失败，已保留旧定义。"}
	return {"ok": true, "rig_id": definition.id, "revision": definition.revision}

## 通过稳定关节标识修改欧拉角限制，结构版本保持不变。
func preview_limits(rig_id: String, changes: Array) -> Dictionary:
	if not definitions.has(rig_id):
		return {"ok": false, "error": "骨架不存在。"}
	var candidate = get_definition(rig_id)
	for change in changes:
		if not change is Dictionary or not change.get("bone_id", null) is String:
			return {"ok": false, "error": "限制修改需要有效的 bone_id。"}
		var found = false
		for bone in candidate.bones:
			if bone.id == change.bone_id:
				bone.limits = change.get("limits", {}).duplicate(true)
				found = true
		if not found:
			return {"ok": false, "error": "关节不存在：" + str(change.bone_id)}
	candidate.revision = int(candidate.revision) + 1
	return validate_definition(candidate)

## 校验唯一标识、无环层级、有限数值、参考坐标和当前支持的约束模型。
func validate_definition(source) -> Dictionary:
	if not source is Dictionary or not valid_id(source.get("id", "")) or not source.get("name", null) is String:
		return {"ok": false, "error": "需要有效的骨架 id 和中文名称。"}
	if source.name.strip_edges().is_empty() or source.name.length() > 96:
		return {"ok": false, "error": "骨架名称需要 1 至 96 个字符。"}
	if int(source.get("schema_version", 0)) != SCHEMA_VERSION or int(source.get("skeleton_version", 0)) < 1:
		return {"ok": false, "error": "不支持的骨架结构格式或版本。"}
	if not source.get("bones", null) is Array or source.bones.is_empty() or source.bones.size() > 512:
		return {"ok": false, "error": "骨架需要包含 1 至 512 个关节。"}
	var normalized = source.duplicate(true)
	var nodes: Dictionary = {}
	var roots = 0
	for bone in normalized.bones:
		if not bone is Dictionary or not valid_id(bone.get("id", "")) or nodes.has(bone.id) or not bone.get("name", null) is String:
			return {"ok": false, "error": "关节标识需唯一，且关节需要名称。"}
		if bone.name.strip_edges().is_empty() or bone.name.length() > 96:
			return {"ok": false, "error": "关节名称需要 1 至 96 个字符。"}
		bone.parent_id = "" if bone.get("parent_id") == null else bone.parent_id
		if not bone.parent_id is String:
			return {"ok": false, "error": "parent_id 必须是稳定关节标识。"}
		if bone.parent_id.is_empty():
			roots += 1
		bone.rest_rotation_xyzw = bone.get("rest_rotation_xyzw", [0.0, 0.0, 0.0, 1.0])
		if not numeric_vector(bone.get("rest_translation_m"), 3) or not numeric_vector(bone.rest_rotation_xyzw, 4):
			return {"ok": false, "error": "参考姿势的位置和四元数必须是有限数值数组。"}
		var rotation: Array = bone.rest_rotation_xyzw
		var quaternion = Quaternion(rotation[0], rotation[1], rotation[2], rotation[3])
		if quaternion.length_squared() < 0.000001:
			return {"ok": false, "error": "参考四元数不能为零。"}
		quaternion = quaternion.normalized()
		bone.rest_rotation_xyzw = [quaternion.x, quaternion.y, quaternion.z, quaternion.w]
		var limits = bone.get("limits", {})
		if not limits is Dictionary or limits.get("type", "") != "euler_xyz" or not numeric_vector(limits.get("minimum_deg"), 3) or not numeric_vector(limits.get("maximum_deg"), 3):
			return {"ok": false, "error": "当前约束模型需为 euler_xyz，并提供三轴上下限。"}
		for axis in 3:
			if limits.minimum_deg[axis] > limits.maximum_deg[axis] or limits.minimum_deg[axis] < -180 or limits.maximum_deg[axis] > 180:
				return {"ok": false, "error": "旋转上下限必须有序，并位于负一百八十至正一百八十度。"}
			if absf(float(limits.minimum_deg[axis]) - snappedf(float(limits.minimum_deg[axis]), 0.01)) > 0.000001 or absf(float(limits.maximum_deg[axis]) - snappedf(float(limits.maximum_deg[axis]), 0.01)) > 0.000001:
				return {"ok": false, "error": "旋转限制与关键帧角度一样保留两位小数。"}
		bone.semantic = bone.get("semantic", {})
		bone.display = bone.get("display", {})
		if not bone.semantic is Dictionary or not bone.display is Dictionary:
			return {"ok": false, "error": "语义和显示属性必须是对象。"}
		bone.display.radius_m = bone.display.get("radius_m", 0.04)
		if not (bone.display.radius_m is int or bone.display.radius_m is float) or not is_finite(float(bone.display.radius_m)) or bone.display.radius_m <= 0 or bone.display.radius_m > 2:
			return {"ok": false, "error": "显示半径必须是有效的米制长度。"}
		bone.display.kind = bone.display.get("kind", "joint")
		bone.display.draw_parent_bone = bool(bone.display.get("draw_parent_bone", not bone.parent_id.is_empty()))
		bone.ik_chain_length = clampi(int(bone.get("ik_chain_length", 2)), 1, 32)
		nodes[bone.id] = bone
	if roots != 1:
		return {"ok": false, "error": "每个骨架必须包含一个根节点。"}
	var ordered: Array = []
	var indices: Dictionary = {}
	while ordered.size() < nodes.size():
		var progressed = false
		for bone in normalized.bones:
			if not indices.has(bone.id) and (bone.parent_id.is_empty() or indices.has(bone.parent_id)):
				indices[bone.id] = ordered.size()
				ordered.append(bone)
				progressed = true
		if not progressed:
			return {"ok": false, "error": "关节层级包含环，或父关节不存在。"}
	normalized.bones = ordered
	normalized.revision = maxi(1, int(normalized.get("revision", 1)))
	return {"ok": true, "definition": normalized}

## 限制文件标识，防止标识被误用成目录路径。
func valid_id(value) -> bool:
	if not value is String or value.is_empty() or value.length() > 96 or value.contains(".."):
		return false
	var pattern = RegEx.new()
	pattern.compile("^[A-Za-z][A-Za-z0-9_.-]*$")
	return pattern.search(value) != null

## 检查工具输入的向量是否包含指定数量的有限数值。
func numeric_vector(value, count: int) -> bool:
	if not value is Array or value.size() != count:
		return false
	for number in value:
		if not (number is int or number is float) or not is_finite(float(number)):
			return false
	return true

## 将公开的数值数组转换为原生数学向量。
func to_vector(values: Array) -> Vector3:
	return Vector3(float(values[0]), float(values[1]), float(values[2]))

## 将引擎向量转换为可以跨进程传输的数组。
func _vector_array(value: Vector3) -> Array:
	return [value.x, value.y, value.z]

## 识别层级和参考姿势，约束编辑不能偷偷替换骨长或轴。
func _topology_signature(definition: Dictionary) -> String:
	var topology: Array = []
	for bone in definition.bones:
		topology.append([bone.id, bone.parent_id, bone.rest_translation_m, bone.rest_rotation_xyzw])
	return JSON.stringify([definition.skeleton_version, topology])
