class_name PuppetTimeline
extends Control
## 可点击定位并拖动关键帧的紧凑秒制时间轨道。

## 请求将播放指针移动到指定时间码。
signal seek_requested(tick: int)
## 请求将关键帧移动到新的时间码。
signal key_move_requested(previous_tick: int, next_tick: int)
## 轨道总时长，使用整数刻度避免帧间隔舍入。
var duration_tick: int = 120000
## 当前播放位置。
var playhead_tick: int = 0
## 轨道上已经记录的关键姿势。
var keys: Array = []
## 当前正在拖动的关键帧时间，负数表示普通拖动指针。
var dragged_key: int = -1
## 鼠标是否正在拖动轨道。
var dragging: bool = false
## 使用与辅助文字一致的字号，避免时间刻度绕过用户的字体设置。
var label_font_size: int = 11

## 设置可用鼠标交互并在尺寸变化时刷新标尺。
func _ready() -> void:
	custom_minimum_size = Vector2(180, 56)
	mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	resized.connect(queue_redraw)

## 从界面偏好同步刻度字号及行高，维持清晰且不重叠的时间标尺。
func set_label_font_size(value: int) -> void:
	label_font_size = maxi(10, value)
	custom_minimum_size.y = maxi(56, label_font_size + 44)
	queue_redraw()

## 更新轨道数据而不重建界面节点。
func configure(duration: int, frames: Array, tick: int) -> void:
	duration_tick = maxi(duration, 1)
	keys = frames
	playhead_tick = tick
	queue_redraw()

## 将时间码映射到轨道横坐标。
func tick_to_x(tick: int) -> float:
	return 16.0 + float(tick) / duration_tick * maxf(size.x - 32.0, 1.0)

## 将鼠标位置转换为两位秒数对应的时间码。
func x_to_tick(x: float) -> int:
	return clampi(roundi(clampf((x - 16.0) / maxf(size.x - 32.0, 1.0), 0, 1) * duration_tick / 600.0) * 600, 0, duration_tick)

## 关键帧位于轨道下半区，随面板高度调整绘制及命中位置。
func key_y() -> float:
	return size.y - 16.0

## 绘制刻度、关键帧标记和播放指针。
func _draw() -> void:
	var font = get_theme_default_font()
	var spacing = maxf(70, font.get_string_size("600.00", HORIZONTAL_ALIGNMENT_LEFT, -1, label_font_size).x + 28)
	var marks = clampi(int((size.x - 32.0) / spacing), 2, 10)
	var track_top = label_font_size + 15
	draw_rect(Rect2(Vector2(16, track_top), Vector2(maxf(size.x - 32, 0), maxf(size.y - track_top - 7, 0))), Color("eef3f5"))
	for index in range(marks + 1):
		var x = 16.0 + (size.x - 32.0) * index / marks
		draw_line(Vector2(x, track_top - 2), Vector2(x, size.y - 7), Color("dce5e9"), 1, true)
		var text = "%.2f" % (float(duration_tick) / 60000.0 * index / marks)
		var width = font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, label_font_size).x
		var label_x = clampf(x - width * 0.5, 16, size.x - 16 - width)
		draw_string(font, Vector2(label_x, label_font_size + 6), text, HORIZONTAL_ALIGNMENT_LEFT, -1, label_font_size, Color("6d808a"))
	for key in keys:
		var x = tick_to_x(int(key.tick))
		var y = key_y()
		var color = Color("128f82") if int(key.tick) == playhead_tick else Color("8aa1aa")
		draw_colored_polygon(PackedVector2Array([Vector2(x, y - 4), Vector2(x + 4, y), Vector2(x, y + 4), Vector2(x - 4, y)]), color)
	var play_x = tick_to_x(playhead_tick)
	var needle_top = track_top - 4
	draw_line(Vector2(play_x, needle_top), Vector2(play_x, size.y - 5), Color("128f82"), 1.5, true)
	draw_colored_polygon(PackedVector2Array([Vector2(play_x - 4, needle_top), Vector2(play_x + 4, needle_top), Vector2(play_x + 4, needle_top + 4), Vector2(play_x, needle_top + 8), Vector2(play_x - 4, needle_top + 4)]), Color("128f82"))

## 处理定位和关键帧拖动，移动到空白处可以插入新关键帧。
func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed:
			dragging = true
			dragged_key = -1
			for key in keys:
				if absf(event.position.x - tick_to_x(int(key.tick))) < 9 and absf(event.position.y - key_y()) < 12:
					dragged_key = int(key.tick)
					break
			seek_requested.emit(dragged_key if dragged_key >= 0 else x_to_tick(event.position.x))
		else:
			if dragging and dragged_key >= 0:
				var target = x_to_tick(event.position.x)
				if target != dragged_key:
					key_move_requested.emit(dragged_key, target)
			dragging = false
			dragged_key = -1
		accept_event()
	elif event is InputEventMouseMotion and dragging and dragged_key < 0:
		seek_requested.emit(x_to_tick(event.position.x))
		accept_event()
