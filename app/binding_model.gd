extends RefCounted
## 角色静态几何导入与自动蒙皮，原始顶点始终保留在独立资源中。

## 支持运行时导入的文件扩展名。
const FORMATS = ["glb", "gltf", "fbx"]

## 读取模型并烘焙节点变换；不播放模型自带动画、不加载脚本。
func import_file(path: String) -> Dictionary:
	if not FileAccess.file_exists(path) or path.get_extension().to_lower() not in FORMATS:
		return {"ok": false, "error": "请选择存在的 GLB、glTF 或 FBX 文件。"}
	var document = FBXDocument.new() if path.get_extension().to_lower() == "fbx" else GLTFDocument.new()
	var state = FBXState.new() if path.get_extension().to_lower() == "fbx" else GLTFState.new()
	# FBX 外部贴图先注册运行时纹理，避免依赖编辑器生成的 .import 缓存。
	var textures: Array = _cache_textures(path.get_base_dir())
	textures.append_array(_cache_textures(path.get_basename() + ".fbm"))
	var error = document.append_from_file(path, state)
	if error != OK:
		return {"ok": false, "error": "模型读取失败（%d），请检查文件和贴图依赖。" % error}
	var scene = document.generate_scene(state)
	if scene == null:
		return {"ok": false, "error": "模型无法生成三维场景。"}
	var parts: Array = []
	_collect(scene, Transform3D.IDENTITY, parts)
	scene.free()
	if parts.is_empty():
		return {"ok": false, "error": "文件中没有可绑定的三角网格。"}
	var bounds = AABB()
	var vertices = 0
	for mesh in parts:
		bounds = mesh.get_aabb() if vertices == 0 else bounds.merge(mesh.get_aabb())
		for surface in mesh.get_surface_count():
			vertices += mesh.surface_get_array_len(surface)
	if not bounds.position.is_finite() or not bounds.size.is_finite() or bounds.size.y < 0.01:
		return {"ok": false, "error": "模型尺寸无效或高度小于 0.01 米，请检查导出单位。"}
	return {"ok": true, "parts": parts, "bounds": bounds, "vertices": vertices}

## 仅预读同级图片和 FBX 配套纹理目录，不扫描无关资源。
func _cache_textures(folder: String) -> Array:
	var textures: Array = []
	if not DirAccess.dir_exists_absolute(folder):
		return textures
	for filename in DirAccess.get_files_at(folder):
		if filename.get_extension().to_lower() not in ["png", "jpg", "jpeg", "webp", "tga", "bmp"]:
			continue
		var path = folder.path_join(filename)
		var image = Image.load_from_file(path)
		if image != null and not image.is_empty():
			image.generate_mipmaps()
			var texture = ImageTexture.create_from_image(image)
			texture.take_over_path(ProjectSettings.localize_path(path))
			textures.append(texture)
	return textures

## 递归保留各网格材质和 UV，将原始模型冻结为统一米制坐标。
func _collect(node: Node, parent_transform: Transform3D, parts: Array) -> void:
	var transform = parent_transform * node.transform if node is Node3D else parent_transform
	if node is MeshInstance3D and node.mesh != null:
		var mesh = ArrayMesh.new()
		mesh.resource_name = node.name
		for surface in node.mesh.get_surface_count():
			if node.mesh.surface_get_primitive_type(surface) != Mesh.PRIMITIVE_TRIANGLES:
				continue
			var arrays: Array = node.mesh.surface_get_arrays(surface).duplicate(true)
			var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
			for index in vertices.size():
				vertices[index] = transform * vertices[index]
			arrays[Mesh.ARRAY_VERTEX] = vertices
			if arrays[Mesh.ARRAY_NORMAL] != null:
				var normals: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
				var normal_basis = transform.basis.inverse().transposed()
				for index in normals.size():
					normals[index] = (normal_basis * normals[index]).normalized()
				arrays[Mesh.ARRAY_NORMAL] = normals
			if arrays[Mesh.ARRAY_TANGENT] != null:
				var tangents: PackedFloat32Array = arrays[Mesh.ARRAY_TANGENT]
				for index in range(0, tangents.size(), 4):
					var direction = (transform.basis * Vector3(tangents[index], tangents[index + 1], tangents[index + 2])).normalized()
					tangents[index] = direction.x
					tangents[index + 1] = direction.y
					tangents[index + 2] = direction.z
					tangents[index + 3] *= signf(transform.basis.determinant())
				arrays[Mesh.ARRAY_TANGENT] = tangents
			if transform.basis.determinant() < 0:
				var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX] if arrays[Mesh.ARRAY_INDEX] != null else PackedInt32Array()
				if indices.is_empty():
					for index in vertices.size():
						indices.append(index)
				for index in range(0, indices.size() - 2, 3):
					var swap = indices[index + 1]
					indices[index + 1] = indices[index + 2]
					indices[index + 2] = swap
				arrays[Mesh.ARRAY_INDEX] = indices
			arrays[Mesh.ARRAY_BONES] = null
			arrays[Mesh.ARRAY_WEIGHTS] = null
			mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
			mesh.surface_set_material(mesh.get_surface_count() - 1, _portable_material(node.get_active_material(surface)))
		if mesh.get_surface_count() > 0:
			parts.append(mesh)
	for child in node.get_children():
		_collect(child, transform, parts)

## 把纹理复制为无外部路径的图像资源，项目重开不依赖原贴图和导入缓存。
func _portable_material(source: Material) -> Material:
	if source == null:
		return null
	var material = source.duplicate(true)
	material.resource_path = ""
	if source is BaseMaterial3D:
		for index in BaseMaterial3D.TEXTURE_MAX:
			var texture: Texture2D = source.get_texture(index)
			if texture == null:
				continue
			var image = texture.get_image()
			if image != null and not image.is_empty():
				material.set_texture(index, ImageTexture.create_from_image(image))
	return material

## 按已计算的拓扑权重生成临时蒙皮，原始位置、法线和贴图不变。
func build_skin_mesh(source: ArrayMesh, bones: Array, rest: Array, rigid: bool, surface_weights: Array = []) -> ArrayMesh:
	if surface_weights.is_empty():
		var engine = load("res://app/binding_weights.gd").new()
		engine.initialize([source])
		engine.calculate(bones, rest, source.get_aabb().size.y, rigid)
		var resolved: Array = engine.resolved({})
		for surface in engine.surfaces:
			surface_weights.append(resolved.slice(surface.start, surface.start + surface.vertices.size()))
	var mesh = ArrayMesh.new()
	for surface in source.get_surface_count():
		var arrays: Array = source.surface_get_arrays(surface).duplicate(true)
		var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var indices = PackedInt32Array()
		var weights = PackedFloat32Array()
		indices.resize(vertices.size() * 4)
		weights.resize(vertices.size() * 4)
		for vertex in vertices.size():
			var value: Dictionary = surface_weights[surface][vertex]
			var choices: Array = value.keys()
			var remaining = 65535
			for slot in choices.size():
				indices[vertex * 4 + slot] = choices[slot]
			for slot in range(1, choices.size()):
				var quantized = floori(value[choices[slot]] * 65535.0)
				remaining -= quantized
				weights[vertex * 4 + slot] = float(quantized) / 65535.0 + (0.0000001 if quantized > 0 else 0.0)
			weights[vertex * 4] = minf(1.0, float(remaining) / 65535.0 + 0.0000001)
		arrays[Mesh.ARRAY_BONES] = indices
		arrays[Mesh.ARRAY_WEIGHTS] = weights
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
		mesh.surface_set_material(surface, source.surface_get_material(surface))
	return mesh
