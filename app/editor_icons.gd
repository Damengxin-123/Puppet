extends RefCounted
## 为紧凑工作台生成统一线宽的本地矢量图标，无需外部图标服务。

## 已生成的图标纹理，避免界面刷新时重复栅格化。
static var textures: Dictionary = {}

## 各个操作的简约图形，坐标统一使用二十四像素画布。
const SHAPES: Dictionary = {
	"skeleton": '<circle cx="12" cy="4" r="2"/><path d="M12 8v7M5 10l7-2 7 2M12 15l-5 6m5-6 5 6"/><circle cx="12" cy="8" r="1"/>',
	"bone": '<path d="M15 5a3 3 0 1 1 4 4l-10 10a3 3 0 1 1-4-4L15 5Z"/><path d="m8 13 3 3M13 8l3 3"/>',
	"film": '<rect x="3" y="3" width="18" height="18" rx="2"/><path d="M7 3v18M17 3v18M3 8h4m-4 8h4M17 8h4m-4 8h4"/>',
	"animation": '<path d="m3 7 16-4 2 5-17 4-1-5ZM4 12v8a1 1 0 0 0 1 1h15V9M7 6l3 4m3-6 3 4"/><path d="m10 14 5 3-5 3Z"/>',
	"model": '<path d="m12 2 9 5v10l-9 5-9-5V7l9-5ZM3 7l9 5 9-5M12 12v10M8 4l9 5"/>',
	"settings": '<path d="M3 6h6m4 0h8M3 12h12m4 0h2M3 18h3m4 0h11"/><circle cx="11" cy="6" r="2"/><circle cx="17" cy="12" r="2"/><circle cx="8" cy="18" r="2"/>',
	"select": '<path d="m5 3 15 9-7 2-3 7-5-18Z"/>',
	"rotate": '<ellipse cx="12" cy="12" rx="9" ry="4"/><ellipse cx="12" cy="12" rx="4" ry="9"/><path d="M5 5a10 10 0 0 1 14 14M18 15l1 4-4-1"/>',
	"orbit": '<circle cx="12" cy="12" r="2"/><ellipse cx="12" cy="12" rx="10" ry="4" transform="rotate(-40 12 12)"/><ellipse cx="12" cy="12" rx="4" ry="10" transform="rotate(-20 12 12)"/>',
	"frame": '<path d="M8 3H3v5m13-5h5v5M3 16v5h5m13-5v5h-5"/>',
	"grid": '<rect x="3" y="3" width="18" height="18" rx="2"/><path d="M3 12h18M12 3v18"/>',
	"panel_left": '<rect x="3" y="3" width="18" height="18" rx="2"/><path d="M9 3v18"/>',
	"panel_right": '<rect x="3" y="3" width="18" height="18" rx="2"/><path d="M15 3v18"/>',
	"tree": '<path d="M5 3v15h5M5 8h5M5 13h5M14 8h7M14 13h7M14 18h7"/>',
	"library": '<path d="M4 4v16M8 4v16M12 4v16m4-16 5 15"/>',
	"plus": '<path d="M12 5v14M5 12h14"/>',
	"rename": '<path d="m15 4 5 5M4 20l5-1L21 7a2 2 0 0 0-4-4L5 15l-1 5Z"/>',
	"undo": '<path d="m8 4-5 5 5 5M3 9h11a6 6 0 0 1 0 12"/>',
	"redo": '<path d="m16 4 5 5-5 5m5-5H10a6 6 0 0 0 0 12"/>',
	"save": '<path d="M4 3h13l4 4v14H3V3h1ZM7 3v6h10V3M7 21v-8h10v8"/>',
	"key": '<path d="m12 2 10 10-10 10L2 12 12 2ZM8 12h8M12 8v8"/>',
	"diamond": '<path d="m12 5 7 7-7 7-7-7 7-7Z"/>',
	"delete": '<path d="M4 7h16M9 7V3h6v4M6 7l1 14h10l1-14M10 11v6m4-6v6"/>',
	"play": '<path d="m7 4 13 8-13 8V4Z"/>',
	"pause": '<path d="M8 4v16M16 4v16"/>',
	"previous": '<path d="M5 5v14m14-14L7 12l12 7V5Z"/>',
	"next": '<path d="M19 5v14M5 5l12 7-12 7V5Z"/>',
	"more": '<circle cx="5" cy="12" r="1"/><circle cx="12" cy="12" r="1"/><circle cx="19" cy="12" r="1"/>',
	"chevron_right": '<path d="m9 5 7 7-7 7"/>',
	"chevron_down": '<path d="m5 9 7 7 7-7"/>',
	"reset": '<path d="M3 10a9 9 0 1 1 1 7M3 3v7h7"/>',
	"lock": '<rect x="5" y="10" width="14" height="11" rx="2"/><path d="M8 10V6a4 4 0 0 1 8 0v4M12 14v3"/>',
	"close": '<path d="m6 6 12 12M6 18 18 6"/>'
}

## 生成可由按钮主题着色的图标纹理，并复用已经生成的结果。
static func get_icon(icon_name: String) -> Texture2D:
	if textures.has(icon_name):
		return textures[icon_name]
	var image = Image.new()
	var source = '<svg xmlns="http://www.w3.org/2000/svg" width="32" height="32" viewBox="0 0 24 24"><g fill="none" stroke="white" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round">%s</g></svg>' % SHAPES.get(icon_name, SHAPES.more)
	if image.load_svg_from_string(source) != OK:
		return null
	var texture = ImageTexture.create_from_image(image)
	textures[icon_name] = texture
	return texture
