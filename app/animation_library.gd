class_name PuppetLibrary
extends RefCounted
## 按不可变骨架索引保存本地动作与完整关键姿势。

## 成功持久化后通知共享文档修订号，手动与 MCP 编辑使用同一信号。
signal clip_saved(clip_id: String, clip_revision: int)

## 本动作库对应的稳定骨架标识。
var rig_id: String = "standard_humanoid_v1"
## 本动作库对应的结构版本，不与可编辑关节约束的修订号混用。
var rig_version: int = 1
## 各动作已保存的最新修订号，撤销内容也产生新的修订。
var revisions: Dictionary = {}
## 一秒对应的整数时间刻度。
const TICKS_PER_SECOND = 60000
## 当前骨架的关节定义。
var rig: Array = []
## 原生动画求解器。
var core
## 当前载入的动作资源。
var clips: Array = []
## 项目内动作保存目录。
var storage_path: String
## 最近一次文件操作的错误说明。
var last_error: String = ""

## 准备本地目录并读取已有动作，首次启动生成示例。
func initialize(animator, definition: Array, override_path: String = "", skeleton_id: String = "standard_humanoid_v1", skeleton_version: int = 1, create_defaults: bool = true) -> void:
	core = animator
	rig = definition
	rig_id = skeleton_id
	rig_version = skeleton_version
	storage_path = override_path if not override_path.is_empty() else ProjectSettings.globalize_path("res://workspace/animations/" + rig_id)
	DirAccess.make_dir_recursive_absolute(storage_path)
	var directory = DirAccess.open(storage_path)
	if directory:
		for filename in directory.get_files():
			if filename.ends_with(".json.previous") and not FileAccess.file_exists(storage_path.path_join(filename.trim_suffix(".previous"))):
				DirAccess.rename_absolute(storage_path.path_join(filename), storage_path.path_join(filename.trim_suffix(".previous")))
		for filename in directory.get_files():
			if filename.ends_with(".json"):
				var parsed = JSON.parse_string(FileAccess.get_file_as_string(storage_path.path_join(filename)))
				if parsed is Dictionary and _is_valid_clip(parsed):
					revisions[str(parsed.id)] = int(parsed.get("revision", 0))
					clips.append(parsed)
	clips.sort_custom(func(a, b): return str(a.name).naturalnocasecmp_to(str(b.name)) < 0)
	if clips.is_empty() and create_defaults:
		_create_examples()

## 生成全身零旋转姿势。
func rest_pose() -> PackedVector3Array:
	var result = PackedVector3Array()
	result.resize(rig.size())
	return core.clamp_pose(result)

## 将旋转与根位置编码为可读的关键姿势。
func make_key(tick: int, pose: PackedVector3Array, root: Vector3) -> Dictionary:
	var rotations: Array = []
	for value in pose:
		rotations.append([snappedf(value.x, 0.01), snappedf(value.y, 0.01), snappedf(value.z, 0.01)])
	return {"tick": tick, "rotations_deg": rotations, "root_m": [snappedf(root.x, 0.01), snappedf(root.y, 0.01), snappedf(root.z, 0.01)]}

## 从持久化关键姿势读取旋转数组。
func key_pose(key: Dictionary) -> PackedVector3Array:
	var result = PackedVector3Array()
	for value in key.rotations_deg:
		result.append(Vector3(float(value[0]), float(value[1]), float(value[2])))
	return result

## 读取关键姿势中的根位移。
func key_root(key: Dictionary) -> Vector3:
	var value = key.root_m
	return Vector3(float(value[0]), float(value[1]), float(value[2]))

## 创建独立动作，默认录入起止两个站立姿势。
func create_clip(display_name: String, duration: float = 2.0, options: Dictionary = {}) -> Dictionary:
	var id = "clip_%s_%06d" % [str(Time.get_unix_time_from_system()).replace(".", "_"), randi() % 1000000]
	var ids: Array = []
	for bone in rig:
		ids.append(bone.id)
	var end_tick = roundi(duration * TICKS_PER_SECOND)
	var clip = {"format_version": 1, "id": id, "name": display_name, "skeleton_id": rig_id, "skeleton_version": rig_version, "joint_ids": ids, "duration_tick": end_tick, "ticks_per_second": TICKS_PER_SECOND, "fps": int(options.get("fps", 30)), "interpolation": int(options.get("interpolation", 2)), "loop": bool(options.get("loop", true)), "keyframes": [make_key(0, rest_pose(), Vector3.ZERO), make_key(end_tick, rest_pose(), Vector3.ZERO)]}
	clips.append(clip)
	if not save_clip(clip):
		clips.pop_back()
		return {}
	return clip

## 插入或替换当前时刻的关键帧并保持时间排序。
func upsert_key(clip: Dictionary, tick: int, pose: PackedVector3Array, root: Vector3) -> void:
	var key = make_key(tick, core.clamp_pose(pose), root)
	var index = find_key(clip, tick)
	if index >= 0:
		clip.keyframes[index] = key
	else:
		clip.keyframes.append(key)
	clip.keyframes.sort_custom(func(a, b): return int(a.tick) < int(b.tick))

## 查找精确时间码对应的关键帧。
func find_key(clip: Dictionary, tick: int) -> int:
	for index in clip.keyframes.size():
		if int(clip.keyframes[index].tick) == tick:
			return index
	return -1

## 计算任意时刻的最终姿势，使用原生四元数插值。
func sample(clip: Dictionary, tick: int) -> Dictionary:
	var keys: Array = clip.keyframes
	if keys.is_empty():
		return {"pose": rest_pose(), "root": Vector3.ZERO}
	var left: Dictionary = keys[0]
	var right: Dictionary = keys[-1]
	if tick <= int(left.tick):
		return {"pose": core.clamp_pose(key_pose(left)), "root": key_root(left)}
	if tick >= int(right.tick):
		return {"pose": core.clamp_pose(key_pose(right)), "root": key_root(right)}
	for index in range(keys.size() - 1):
		if tick >= int(keys[index].tick) and tick <= int(keys[index + 1].tick):
			left = keys[index]
			right = keys[index + 1]
			break
	var weight = float(tick - int(left.tick)) / float(int(right.tick) - int(left.tick))
	var mode = int(clip.interpolation)
	var factor = weight
	if mode == 0:
		factor = 0.0
	elif mode == 2:
		factor = weight * weight * (3.0 - 2.0 * weight)
	return {"pose": core.interpolate_pose(key_pose(left), key_pose(right), weight, mode), "root": key_root(left).lerp(key_root(right), factor)}

## 通过临时文件和上一版备份保存动作，返回真实写入结果。
func save_clip(clip: Dictionary) -> bool:
	var next_revision = maxi(int(clip.get("revision", 0)), int(revisions.get(str(clip.id), 0))) + 1
	var persisted = clip.duplicate(true)
	persisted.revision = next_revision
	last_error = ""
	var destination = storage_path.path_join(str(clip.id) + ".json")
	var temporary = destination + ".tmp"
	var backup = destination + ".previous"
	var file = FileAccess.open(temporary, FileAccess.WRITE)
	if file == null:
		last_error = "无法写入动作目录：" + storage_path
		return false
	file.store_string(JSON.stringify(persisted, "\t", false) + "\n")
	file.flush()
	file.close()
	if FileAccess.file_exists(backup):
		DirAccess.remove_absolute(backup)
	if FileAccess.file_exists(destination):
		if DirAccess.rename_absolute(destination, backup) != OK:
			last_error = "旧版动作正在被占用，未覆盖原文件。"
			return false
	if DirAccess.rename_absolute(temporary, destination) != OK:
		if FileAccess.file_exists(backup):
			DirAccess.rename_absolute(backup, destination)
		last_error = "保存动作失败，已保留上一版。"
		return false
	clip.revision = next_revision
	revisions[str(clip.id)] = next_revision
	clip_saved.emit(str(clip.id), next_revision)
	return true

## 校验骨架索引、时间码与关键帧数据，跳过不兼容的外部文件。
func _is_valid_clip(clip: Dictionary) -> bool:
	if clip.get("format_version", 0) != 1 or clip.get("skeleton_id", "") != rig_id or int(clip.get("skeleton_version", 1)) != rig_version or not clip.has("id") or not clip.has("name"):
		return false
	if not clip.id is String or clip.id.is_empty() or not clip.id.is_valid_filename() or clip.id.contains(".."):
		return false
	if int(clip.get("ticks_per_second", 0)) != TICKS_PER_SECOND or int(clip.get("duration_tick", 0)) <= 0:
		return false
	if not clip.get("keyframes", null) is Array or clip.keyframes.is_empty() or not clip.get("joint_ids", null) is Array:
		return false
	if clip.joint_ids.size() != rig.size():
		return false
	for index in rig.size():
		if clip.joint_ids[index] != rig[index].id:
			return false
	var previous = -1
	for key in clip.keyframes:
		if not key is Dictionary or not key.get("rotations_deg", null) is Array or key.rotations_deg.size() != rig.size():
			return false
		var tick = int(key.get("tick", -1))
		if tick <= previous or tick > int(clip.duration_tick) or not key.get("root_m", null) is Array or key.root_m.size() != 3:
			return false
		previous = tick
		for value in key.rotations_deg + [key.root_m]:
			if not value is Array or value.size() != 3:
				return false
			for number in value:
				if not (number is float or number is int) or not is_finite(float(number)):
					return false
	clip["interpolation"] = clampi(int(clip.get("interpolation", 2)), 0, 2)
	clip["loop"] = bool(clip.get("loop", true))
	clip["fps"] = clampi(int(clip.get("fps", 30)), 1, 240)
	return true

## 首次使用提供可立即播放和修改的动作示例。
func _create_examples() -> void:
	create_clip("基础站姿", 2.0)
	if rig_id != "standard_humanoid_v1":
		return
	var wave = create_clip("挥手示例", 2.0)
	var pose = rest_pose()
	pose[12] = Vector3(0, 0, -110)
	pose[13] = Vector3(0, 90, 0)
	upsert_key(wave, 24000, pose, Vector3.ZERO)
	pose[14] = Vector3(0, 0, 35)
	upsert_key(wave, 48000, pose, Vector3.ZERO)
	pose[14] = Vector3(0, 0, -35)
	upsert_key(wave, 72000, pose, Vector3.ZERO)
	pose[14] = Vector3(0, 0, 35)
	upsert_key(wave, 96000, pose, Vector3.ZERO)
	save_clip(wave)
	var squat = create_clip("下蹲示例", 2.0)
	pose = rest_pose()
	pose[15].x = -50
	pose[19].x = -50
	pose[16].x = 95
	pose[20].x = 95
	pose[17].x = -45
	pose[21].x = -45
	upsert_key(squat, 60000, pose, Vector3(0, -0.27, 0))
	save_clip(squat)

