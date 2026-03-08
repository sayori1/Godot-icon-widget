@tool
class_name IconWidget
extends Control

enum FitMode {
	CONTAIN,
	COVER,
	STRETCH
}

@export_file("*.svg", "*.png") var icon_path: String = "":
	set(value):
		if icon_path == value:
			return
		icon_path = value
		_reload_icon_texture()
@export var icon_id: String = ""
@export var icon_size: Vector2 = Vector2(24.0, 24.0):
	set(value):
		var clamped := Vector2(max(value.x, 1.0), max(value.y, 1.0))
		if icon_size == clamped:
			return
		icon_size = clamped
		_update_control_size()
		if icon_path.get_extension().to_lower() == "svg":
			_reload_icon_texture()
		queue_redraw()
@export var enforce_exact_size: bool = true:
	set(value):
		if enforce_exact_size == value:
			return
		enforce_exact_size = value
		_update_control_size()
@export var tint_from_alpha_mask: bool = true:
	set(value):
		if tint_from_alpha_mask == value:
			return
		tint_from_alpha_mask = value
		queue_redraw()
@export var icon_color: Color = Color(1.0, 1.0, 1.0, 1.0):
	set(value):
		if icon_color == value:
			return
		icon_color = value
		queue_redraw()
@export_range(0.0, 1.0, 0.01) var icon_opacity: float = 1.0:
	set(value):
		var clamped := clamp(value, 0.0, 1.0)
		if is_equal_approx(icon_opacity, clamped):
			return
		icon_opacity = clamped
		queue_redraw()
@export var fit_mode: FitMode = FitMode.CONTAIN:
	set(value):
		if fit_mode == value:
			return
		fit_mode = value
		queue_redraw()
@export var center_icon: bool = true:
	set(value):
		if center_icon == value:
			return
		center_icon = value
		queue_redraw()
@export var background_color: Color = Color(0.0, 0.0, 0.0, 0.0):
	set(value):
		if background_color == value:
			return
		background_color = value
		queue_redraw()
@export var pixel_snap: bool = true:
	set(value):
		if pixel_snap == value:
			return
		pixel_snap = value
		queue_redraw()

var _icon_texture: Texture2D
var _icon_mask_texture: Texture2D

func _ready() -> void:
	_update_control_size()
	_reload_icon_texture()

func _draw() -> void:
	if background_color.a > 0.0:
		draw_rect(Rect2(Vector2.ZERO, size), background_color, true)
	if _icon_texture == null:
		return
	var texture_to_draw := _icon_texture
	if tint_from_alpha_mask and _icon_mask_texture != null:
		texture_to_draw = _icon_mask_texture
	var rect := _compute_draw_rect(texture_to_draw)
	if rect.size.x <= 0.0 or rect.size.y <= 0.0:
		return
	if pixel_snap:
		rect.position = rect.position.round()
	var modulate := icon_color
	modulate.a *= icon_opacity
	draw_texture_rect(texture_to_draw, rect, false, modulate)

func _compute_draw_rect(texture: Texture2D) -> Rect2:
	var available := Rect2(Vector2.ZERO, size)
	var target_size := icon_size
	if fit_mode != FitMode.STRETCH:
		var tex_size := texture.get_size()
		if tex_size.x <= 0.0 or tex_size.y <= 0.0:
			return Rect2(Vector2.ZERO, Vector2.ZERO)
		var scale_x := target_size.x / tex_size.x
		var scale_y := target_size.y / tex_size.y
		var scale := min(scale_x, scale_y)
		if fit_mode == FitMode.COVER:
			scale = max(scale_x, scale_y)
		target_size = tex_size * scale
	var position := available.position
	if center_icon:
		position += (available.size - target_size) * 0.5
	return Rect2(position, target_size)

func _get_minimum_size() -> Vector2:
	return icon_size

func set_icon(path: String, new_icon_id: String = "") -> void:
	icon_id = new_icon_id
	icon_path = path

func clear_icon() -> void:
	icon_id = ""
	icon_path = ""

func _update_control_size() -> void:
	custom_minimum_size = icon_size
	if enforce_exact_size:
		size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
		size_flags_vertical = Control.SIZE_SHRINK_BEGIN
		if not size.is_equal_approx(icon_size):
			size = icon_size
	queue_redraw()

func _reload_icon_texture() -> void:
	_icon_texture = _load_texture_from_path(icon_path)
	_icon_mask_texture = _build_alpha_mask_texture(_icon_texture)
	queue_redraw()

func _load_texture_from_path(path: String) -> Texture2D:
	if path.is_empty():
		return null
	if not FileAccess.file_exists(path):
		var maybe_resource := ResourceLoader.load(path)
		if maybe_resource is Texture2D:
			return maybe_resource
		return null
	var extension := path.get_extension().to_lower()
	if extension == "svg":
		return _load_svg_texture(path)
	var loaded := ResourceLoader.load(path)
	if loaded is Texture2D:
		return loaded
	var image := Image.new()
	if image.load(path) != OK:
		return null
	return ImageTexture.create_from_image(image)

func _load_svg_texture(path: String) -> Texture2D:
	var svg_bytes := FileAccess.get_file_as_bytes(path)
	if svg_bytes.is_empty():
		return null
	var probe := Image.new()
	if probe.load_svg_from_buffer(svg_bytes, 1.0) != OK:
		return null
	var base_max := max(probe.get_width(), probe.get_height())
	if base_max <= 0:
		return null
	var target_max := max(icon_size.x, icon_size.y)
	var scale := max(1.0, target_max / float(base_max))
	var image := Image.new()
	if image.load_svg_from_buffer(svg_bytes, scale) != OK:
		return null
	return ImageTexture.create_from_image(image)

func _build_alpha_mask_texture(texture: Texture2D) -> Texture2D:
	if texture == null:
		return null
	var image := texture.get_image()
	if image == null:
		return null
	image.convert(Image.FORMAT_RGBA8)
	for y in image.get_height():
		for x in image.get_width():
			var px := image.get_pixel(x, y)
			image.set_pixel(x, y, Color(1.0, 1.0, 1.0, px.a))
	return ImageTexture.create_from_image(image)
