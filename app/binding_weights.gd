extends RefCounted
## 沿焊接后的网格拓扑传播自动权重；手工权重以原始顶点稳定标识保存。

## 原始表面记录，包含未修改的几何和全局顶点起点。
var surfaces: Array = []
## 各原始顶点对应的焊接顶点，缝边共享传播距离。
var welds: PackedInt32Array = PackedInt32Array()
## 焊接顶点坐标，单位米。
var points: PackedVector3Array = PackedVector3Array()
## 沿三角形边的邻接表，不跨越空间中互不连接的表面。
var neighbors: Array = []
## 稳定顶点标识到全局索引的映射。
var lookup: Dictionary = {}
## 全局顶点的稳定标识。
var ids: Array[String] = []
## 每个焊接顶点关联的原始顶点索引。
var originals: Array = []
## 自动计算的焊接顶点权重。
var automatic: Array = []
## 当前骨架快照，用于稳定骨骼标识转换。
var bones: Array = []
## 当前参考骨段，所有距离都取自绑定姿态。
var segments: Array = []
## 模型高度用于自适应采样和保护半径。
var height: float = 1.0
## 各连通分量的顶点索引。
var components: Array = []

## 从原网格建立稳定索引和跨 UV 缝的拓扑，不改变原始网格。
func initialize(parts: Array) -> void:
	var welded: Dictionary = {}
	for part in parts.size():
		for surface in parts[part].get_surface_count():
			var arrays: Array = parts[part].surface_get_arrays(surface)
			var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
			var start = ids.size()
			surfaces.append({"mesh_index": part, "surface_index": surface, "start": start, "vertices": vertices, "indices": arrays[Mesh.ARRAY_INDEX]})
			for index in vertices.size():
				var key = vertices[index].snapped(Vector3.ONE * 0.00001)
				if not welded.has(key):
					welded[key] = points.size()
					points.append(vertices[index])
					neighbors.append({})
					originals.append([])
				var node: int = welded[key]
				var id = "%d:%d:%d" % [part, surface, index]
				lookup[id] = ids.size()
				originals[node].append(ids.size())
				ids.append(id)
				welds.append(node)
			var triangles: PackedInt32Array = arrays[Mesh.ARRAY_INDEX] if arrays[Mesh.ARRAY_INDEX] != null else PackedInt32Array()
			if triangles.is_empty():
				for index in vertices.size():
					triangles.append(index)
			for triangle in range(0, triangles.size() - 2, 3):
				for edge in 3:
					var a = welds[start + triangles[triangle + edge]]
					var b = welds[start + triangles[triangle + (edge + 1) % 3]]
					if a != b:
						neighbors[a][b] = true
						neighbors[b][a] = true
	var seen: Dictionary = {}
	for index in points.size():
		neighbors[index] = neighbors[index].keys()
	for index in points.size():
		if seen.has(index):
			continue
		var group: Array = [index]
		seen[index] = true
		var cursor = 0
		while cursor < group.size():
			for adjacent in neighbors[group[cursor]]:
				if not seen.has(adjacent):
					seen[adjacent] = true
					group.append(adjacent)
			cursor += 1
		components.append(group)

## 骨长编辑只让自动解失效，稳定顶点标识和手工覆盖仍然保留。
func invalidate() -> void:
	automatic.clear()

## 从骨段内部采样寻找最近的表面种子，再沿真实三角边传播距离。
func calculate(definition: Array, rest: Array, model_height: float, rigid: bool) -> void:
	if not automatic.is_empty():
		return
	bones = definition
	height = maxf(model_height, 0.01)
	segments.clear()
	for index in bones.size():
		var children: Array = []
		for child in bones.size():
			if int(bones[child].parent) == index:
				children.append(child)
		if int(bones[index].parent) < 0:
			continue
		if children.is_empty():
			var direction: Vector3 = (rest[index].position - rest[int(bones[index].parent)].position).normalized()
			segments.append({"bone": index, "a": rest[index].position, "b": rest[index].position + direction * height * (0.045 if _role(index) == "hand" else 0.02)})
		for child in children:
			segments.append({"bone": index, "a": rest[index].position, "b": rest[child].position})
	if segments.is_empty():
		segments.append({"bone": 0, "a": rest[0].position, "b": rest[0].position})
	var fields: Dictionary = {}
	for segment in segments:
		var bone: int = segment.bone
		if not fields.has(bone):
			var distances = PackedFloat32Array()
			distances.resize(points.size())
			distances.fill(INF)
			fields[bone] = distances
		for fraction in [0.15, 0.40, 0.65, 0.90]:
			var sample: Vector3 = segment.a.lerp(segment.b, fraction)
			var nearest = INF
			for point in points:
				nearest = minf(nearest, point.distance_to(sample))
			# 只在真正最靠近骨段的表面播种，外套背面不会因靠近手腕而同时播种。
			var threshold = nearest + height * 0.004
			for index in points.size():
				var distance = points[index].distance_to(sample)
				if distance <= threshold:
					fields[bone][index] = minf(fields[bone][index], distance)
			# 躯干允许穿过多层衣物播种，避免外套因内层衬衣遮挡而只跟随胸部。
			if _role(bone) in ["pelvis", "joint", "chest"] and bones[bone].get("semantic", {}).get("side", "") == "center":
				for group in components:
					var closest = INF
					var seed = -1
					for index in group:
						var distance = points[index].distance_to(sample)
						if distance < closest:
							closest = distance
							seed = index
					if seed >= 0 and closest < height * 0.14:
						fields[bone][seed] = minf(fields[bone][seed], closest)
	for bone in fields:
		var heap: Array = []
		var distances: PackedFloat32Array = fields[bone]
		for index in points.size():
			if is_finite(distances[index]):
				_push(heap, Vector2(distances[index], index))
		while not heap.is_empty():
			var current = _pop(heap)
			var index = int(current.y)
			if current.x > distances[index] + 0.000001:
				continue
			for adjacent in neighbors[index]:
				var distance = current.x + points[index].distance_to(points[adjacent])
				if distance + 0.000001 < distances[adjacent]:
					distances[adjacent] = distance
					_push(heap, Vector2(distance, adjacent))
		fields[bone] = distances
	# 完全独立的小配件采用整体归属，避免一个腰扣被切分到多个远处骨骼。
	for group in components:
		var candidates: Array = []
		for bone in fields:
			if is_finite(fields[bone][group[0]]):
				candidates.append(bone)
		if not candidates.is_empty():
			continue
		var center = Vector3.ZERO
		for index in group:
			center += points[index]
		center /= group.size()
		var best = INF
		var owner = 1 if bones.size() > 1 else 0
		for segment in segments:
			var distance = center.distance_to(Geometry3D.get_closest_point_to_segment(center, segment.a, segment.b))
			if _arm(segment.bone) and distance > height * 0.045:
				continue
			if distance < best:
				best = distance
				owner = segment.bone
		if not fields.has(owner):
			var distances = PackedFloat32Array()
			distances.resize(points.size())
			distances.fill(INF)
			fields[owner] = distances
		for index in group:
			fields[owner][index] = maxf(best, height * 0.001)
	for index in points.size():
		var distances: Dictionary = {}
		for bone in fields:
			if is_finite(fields[bone][index]):
				distances[bone] = float(fields[bone][index])
		var order: Array = distances.keys()
		order.sort_custom(func(a, b): return distances[a] < distances[b])
		var nearest: int = order[0]
		var value: Dictionary = {}
		for bone in order:
			if bone != nearest and (rigid or not _related(bone, nearest)):
				continue
			value[bone] = 1.0 / pow(maxf(distances[bone], height * 0.01), 4.0)
			if value.size() >= 4:
				break
		automatic.append(normalize(value))
	# 沿邻接面平滑，权重不会隔空从衣服跳到手上。
	if not rigid:
		for iteration in 3:
			var next: Array = []
			for index in points.size():
				var value: Dictionary = automatic[index].duplicate()
				var count: float = neighbors[index].size()
				if count > 0:
					for bone in value:
						value[bone] *= 0.5
					for adjacent in neighbors[index]:
						for bone in automatic[adjacent]:
							value[bone] = float(value.get(bone, 0)) + automatic[adjacent][bone] * 0.5 / count
				next.append(normalize(value))
			automatic = next

## 识别语义角色，不依赖左右关节排列顺序。
func _role(index: int) -> String:
	return str(bones[index].get("semantic", {}).get("role", ""))

## 判断是否属于手臂或手指链，供衣物保护和快捷清除使用。
func _arm(index: int) -> bool:
	while index >= 0:
		if _role(index) in ["upper_arm", "forearm", "hand"]:
			return true
		index = int(bones[index].parent)
	return false

## 自动混合限制在相邻骨骼，避免左右肢体或手臂与髋部直接混合。
func _related(a: int, b: int) -> bool:
	return int(bones[a].parent) == b or int(bones[b].parent) == a

## 保留最多四项非负有限权重并归一化，排序保证结果可重现。
func normalize(value: Dictionary) -> Dictionary:
	var keys: Array = []
	for bone in value:
		if is_finite(float(value[bone])) and float(value[bone]) > 0.000001:
			keys.append(bone)
	keys.sort_custom(func(a, b): return int(a) < int(b) if is_equal_approx(value[a], value[b]) else value[a] > value[b])
	keys = keys.slice(0, 4)
	var total = 0.0
	for bone in keys:
		total += float(value[bone])
	var result: Dictionary = {}
	for bone in keys:
		result[int(bone)] = float(value[bone]) / total
	return result

## 把当前自动解与按稳定骨骼标识保存的手工覆盖合并。
func resolved(overrides: Dictionary) -> Array:
	var by_id: Dictionary = {}
	for index in bones.size():
		by_id[str(bones[index].id)] = index
	var result: Array = []
	for index in ids.size():
		var value: Dictionary = automatic[welds[index]]
		if overrides.has(ids[index]):
			value = {}
			for bone_id in overrides[ids[index]]:
				if by_id.has(bone_id):
					value[by_id[bone_id]] = overrides[ids[index]][bone_id]
			value = normalize(value)
			if value.is_empty():
				value = automatic[welds[index]]
		result.append(value)
	return result

## 从一个原始顶点沿网格表面选区，半径不会穿过空隙选到其他衣物层。
func region(seed_id: String, radius_m: float, whole_component: bool = false) -> Array:
	if not lookup.has(seed_id):
		return []
	var start: int = welds[lookup[seed_id]]
	var distances: Dictionary = {start: 0.0}
	var heap: Array = []
	_push(heap, Vector2(0, start))
	while not heap.is_empty():
		var current = _pop(heap)
		var index = int(current.y)
		if current.x > distances[index] + 0.000001:
			continue
		for adjacent in neighbors[index]:
			var distance = current.x + points[index].distance_to(points[adjacent])
			if (whole_component or distance <= radius_m) and distance + 0.000001 < float(distances.get(adjacent, INF)):
				distances[adjacent] = distance
				_push(heap, Vector2(distance, adjacent))
	var selected: Array = []
	for index in distances:
		for original in originals[index]:
			selected.append(ids[original])
	return selected

## 任意手工选区自动包含相同位置的缝边顶点，防止 UV 接缝裂开。
func expand_seams(selected: Array) -> Array:
	var result: Dictionary = {}
	for id in selected:
		for index in originals[welds[lookup[id]]]:
			result[ids[index]] = true
	return result.keys()

## 最小堆插入，距离传播保持 O(E log V) 而非逐顶点扫描。
func _push(heap: Array, value: Vector2) -> void:
	heap.append(value)
	var index = heap.size() - 1
	while index > 0:
		var parent = (index - 1) / 2
		if heap[parent].x <= value.x:
			break
		heap[index] = heap[parent]
		index = parent
	heap[index] = value

## 取出当前距离最小的顶点。
func _pop(heap: Array) -> Vector2:
	var result: Vector2 = heap[0]
	var value: Vector2 = heap.pop_back()
	if heap.is_empty():
		return result
	var index = 0
	while index * 2 + 1 < heap.size():
		var child = index * 2 + 1
		if child + 1 < heap.size() and heap[child + 1].x < heap[child].x:
			child += 1
		if value.x <= heap[child].x:
			break
		heap[index] = heap[child]
		index = child
	heap[index] = value
	return result
