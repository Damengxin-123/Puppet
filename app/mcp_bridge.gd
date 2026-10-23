extends Node
## 仅监听本机的命令通道，标准 MCP 协议由 Python 适配器处理。

## 服务状态变化时更新设置页。
signal status_changed(message: String)
## 最大单次网络请求或响应字节数。
const MAX_BYTES: int = 16777216
## 本机 TCP 监听器。
var server: TCPServer = TCPServer.new()
## 共享文档命令服务。
var commands
## 当前进程专用鉴权令牌，不放入工具返回值。
var token: String = ""
## 当前实例描述文件，关闭服务时只删除自身文件。
var descriptor_path: String = ""
## 已接入连接的缓冲和发送进度。
var clients: Array = []
## 等待主线程串行执行的命令。
var pending: Array = []
## 异步截图执行期间避免第二个命令并发修改文档。
var executing: bool = false
## 设置页显示的服务状态。
var status_text: String = "MCP 服务未启动"
## 实例发现目录。
var instance_directory: String = ""

## 初始化服务但不自动监听，由用户设置决定是否启动。
func initialize(service, directory: String) -> void:
	commands = service
	instance_directory = directory
	set_process(false)

## 由操作系统分配空闲端口，多个软件实例不会抢占同一个固定端口。
func start() -> bool:
	if server.is_listening():
		return true
	if server.listen(0, "127.0.0.1") != OK:
		_set_status("MCP 本机端口启动失败")
		return false
	token = Crypto.new().generate_random_bytes(32).hex_encode()
	if DirAccess.make_dir_recursive_absolute(instance_directory) != OK:
		server.stop()
		_set_status("MCP 实例目录无法写入")
		return false
	descriptor_path = instance_directory.path_join(commands.instance_id + ".json")
	var file = FileAccess.open(descriptor_path, FileAccess.WRITE)
	if file == null:
		server.stop()
		_set_status("MCP 实例信息保存失败")
		return false
	file.store_string(JSON.stringify({"api_version": commands.API_VERSION, "instance_id": commands.instance_id, "document_id": commands.document_id, "pid": OS.get_process_id(), "host": "127.0.0.1", "port": server.get_local_port(), "token": token, "project_path": ProjectSettings.globalize_path("res://")}, "\t") + "\n")
	file.close()
	set_process(true)
	_set_status("MCP 已启用 · 本机端口 %d" % server.get_local_port())
	return true

## 停止接收新连接并撤销当前实例发现信息。
func stop() -> void:
	server.stop()
	for client in clients:
		client.peer.disconnect_from_host()
	clients.clear()
	pending.clear()
	if not descriptor_path.is_empty() and FileAccess.file_exists(descriptor_path):
		DirAccess.remove_absolute(descriptor_path)
	descriptor_path = ""
	set_process(false)
	_set_status("MCP 服务已关闭")

## 主线程非阻塞读取网络，每条连接最多执行一条 JSON 命令。
func _process(_delta: float) -> void:
	while server.is_connection_available():
		var peer = server.take_connection()
		if clients.size() >= 16:
			peer.disconnect_from_host()
		else:
			clients.append({"peer": peer, "input": PackedByteArray(), "output": PackedByteArray(), "offset": 0, "queued": false, "created": Time.get_ticks_msec()})
	for client in clients.duplicate():
		var peer: StreamPeerTCP = client.peer
		peer.poll()
		if peer.get_status() != StreamPeerTCP.STATUS_CONNECTED or Time.get_ticks_msec() - int(client.created) > 120000:
			peer.disconnect_from_host()
			clients.erase(client)
			continue
		if not client.output.is_empty():
			var chunk: PackedByteArray = client.output.slice(int(client.offset), mini(client.output.size(), int(client.offset) + 65536))
			var sent = peer.put_partial_data(chunk)
			if sent[0] != OK:
				peer.disconnect_from_host()
				clients.erase(client)
				continue
			client.offset += int(sent[1])
			if client.offset >= client.output.size():
				peer.disconnect_from_host()
				clients.erase(client)
		elif not client.queued:
			var available = peer.get_available_bytes()
			if available > 0:
				var read = peer.get_data(mini(available, 65536))
				if read[0] == OK:
					client.input.append_array(read[1])
			if client.input.size() > MAX_BYTES:
				_respond(client, commands._error("REQUEST_TOO_LARGE", "请求超过 16 MiB。"))
			elif client.input.has(10):
				client.queued = true
				var request = JSON.parse_string(client.input.slice(0, client.input.find(10)).get_string_from_utf8())
				client.input.clear()
				if not request is Dictionary or str(request.get("token", "")) != token:
					_respond(client, {"ok": false, "error": {"code": "UNAUTHORIZED", "message": "实例令牌无效。"}})
				elif not request.get("method") is String or not request.get("params", {}) is Dictionary:
					_respond(client, commands._error("INVALID_REQUEST", "需要工具名称和参数对象。"))
				else:
					pending.append({"client": client, "method": request.method, "params": request.get("params", {})})
	if not executing and not pending.is_empty():
		_run_next()

## 异步执行截图时继续刷新 UI，但所有接口命令保持串行顺序。
func _run_next() -> void:
	executing = true
	var job: Dictionary = pending.pop_front()
	if clients.has(job.client):
		var result: Dictionary = await commands.execute(job.method, job.params)
		if clients.has(job.client):
			_respond(job.client, result)
		_set_status("MCP 已连接 · 最近操作：" + str(job.method))
	executing = false

## 分块发送响应，避免大图片阻塞 Godot 主线程。
func _respond(client: Dictionary, result: Dictionary) -> void:
	client.queued = true
	var encoded = (JSON.stringify(result) + "\n").to_utf8_buffer()
	if encoded.size() > MAX_BYTES:
		encoded = (JSON.stringify(commands._error("RESPONSE_TOO_LARGE", "响应超过 16 MiB，请减少图片数量、尺寸或分页读取。")) + "\n").to_utf8_buffer()
	client.output = encoded
	client.offset = 0

## 保存可见状态并通知设置页。
func _set_status(message: String) -> void:
	status_text = message
	status_changed.emit(message)

## 正常关闭软件时清理当前实例，不影响其他已打开的木偶人。
func _exit_tree() -> void:
	stop()
