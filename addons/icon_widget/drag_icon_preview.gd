@tool
extends TextureRect

var _dragged_files: PackedStringArray = PackedStringArray()

func set_dragged_files(paths: PackedStringArray) -> void:
	_dragged_files = paths.duplicate()

func _get_drag_data(_at_position: Vector2) -> Variant:
	if _dragged_files.is_empty():
		return null
	var preview := PanelContainer.new()
	preview.custom_minimum_size = Vector2(120.0, 28.0)
	var label := Label.new()
	label.text = _dragged_files[0].get_file()
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	preview.add_child(label)
	set_drag_preview(preview)
	return {
		"type": "files",
		"files": Array(_dragged_files)
	}
