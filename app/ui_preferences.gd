extends RefCounted
## 独立保存界面外观偏好，字体和缩放不会写入任何动画资源。

## 默认正文大小，比最初工作台的十三像素更易阅读。
const DEFAULT_FONT_SIZE: int = 16
## 可选择的全局界面缩放倍率。
const SCALE_OPTIONS: Array[float] = [0.75, 1.0, 1.1, 1.25, 1.5, 1.75, 2.0]
## 当前正文字号，单位为逻辑像素。
var font_size: int = DEFAULT_FONT_SIZE
## 当前按钮、图标、文字和菜单的统一缩放倍率。
var interface_scale: float = 1.0
## 偏好的实际保存路径，测试时可以独立指定。
var settings_path: String = ""
## 最近一次读取或保存失败的中文说明。
var last_error: String = ""
## 是否启用仅限本机的 MCP 命令通道。
var mcp_enabled: bool = true

## 读取便携项目的设置，缺少文件时使用默认值，损坏数据不影响启动。
func load_settings(override_path: String = "") -> void:
	font_size = DEFAULT_FONT_SIZE
	interface_scale = 1.0
	mcp_enabled = true
	last_error = ""
	settings_path = ProjectSettings.globalize_path("res://workspace/settings.cfg") if override_path.is_empty() else ProjectSettings.globalize_path(override_path)
	var config = ConfigFile.new()
	var error = config.load(settings_path)
	if error == ERR_FILE_NOT_FOUND:
		return
	if error != OK:
		last_error = "界面设置读取失败，已使用默认显示设置。"
		return
	var saved_font = config.get_value("appearance", "font_size", DEFAULT_FONT_SIZE)
	var saved_scale = config.get_value("appearance", "interface_scale", 1.0)
	mcp_enabled = bool(config.get_value("mcp", "enabled", true))
	if (saved_font is int or saved_font is float) and is_finite(float(saved_font)):
		font_size = clampi(int(saved_font), 12, 24)
	if (saved_scale is int or saved_scale is float) and is_finite(float(saved_scale)):
		var nearest = 1.0
		for option in SCALE_OPTIONS:
			if absf(option - float(saved_scale)) < absf(nearest - float(saved_scale)):
				nearest = option
		interface_scale = nearest

## 将当前外观自动保存到独立设置文件，并返回真实保存结果。
func save_settings() -> bool:
	last_error = ""
	var error = DirAccess.make_dir_recursive_absolute(settings_path.get_base_dir())
	if error != OK:
		last_error = "无法创建界面设置目录，当前调整仅在本次运行中生效。"
		return false
	var config = ConfigFile.new()
	config.set_value("appearance", "font_size", font_size)
	config.set_value("appearance", "interface_scale", interface_scale)
	config.set_value("mcp", "enabled", mcp_enabled)
	if config.save(settings_path) != OK:
		last_error = "界面设置保存失败，当前调整仅在本次运行中生效。"
		return false
	return true

## 保留标题、正文、辅助文字的相对层级，统一应用用户选择的字号。
func text_size(design_size: int) -> int:
	return maxi(10, design_size + font_size - 13)

## 返回默认外观，实际保存由界面统一处理。
func reset_defaults() -> void:
	font_size = DEFAULT_FONT_SIZE
	interface_scale = 1.0
