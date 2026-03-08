@tool
extends EditorInspectorPlugin

const WIDGET_SCRIPT_PATH := "res://addons/icon_widget/icon_widget.gd"
const LOCAL_ICONS_DIR := "res://addons/icon_widget/local_icons"

var _host_plugin: EditorPlugin
var _dock: Control
var _pending_iconify_target: Object

func setup(host_plugin: EditorPlugin, dock: Control) -> void:
	_host_plugin = host_plugin
	_dock = dock
	_bind_dock_signal()

func update_dock(dock: Control) -> void:
	_dock = dock
	_bind_dock_signal()

func _bind_dock_signal() -> void:
	if _dock == null:
		return
	if not _dock.has_signal("icon_imported"):
		return
	var cb := Callable(self, "_on_dock_icon_imported")
	if _dock.is_connected("icon_imported", cb):
		return
	_dock.connect("icon_imported", cb)

func _can_handle(object: Object) -> bool:
	if object == null:
		return false
	var script := object.get_script()
	if script == null:
		return false
	return str(script.resource_path) == WIDGET_SCRIPT_PATH

func _parse_begin(object: Object) -> void:
	var row := HBoxContainer.new()

	var iconify_button := Button.new()
	iconify_button.text = "From Iconify"
	iconify_button.tooltip_text = "Open Icon Widget and pick an icon."
	iconify_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	iconify_button.pressed.connect(_on_pick_from_iconify_pressed.bind(object))
	row.add_child(iconify_button)

	var file_button := Button.new()
	file_button.text = "From Local Files"
	file_button.tooltip_text = "Choose SVG/PNG from disk."
	file_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	file_button.pressed.connect(_on_pick_from_local_file_pressed.bind(object))
	row.add_child(file_button)

	add_custom_control(row)

func _on_pick_from_iconify_pressed(target: Object) -> void:
	if not is_instance_valid(target):
		return
	_pending_iconify_target = target
	_open_icon_browser()

func _open_icon_browser() -> void:
	if _dock == null:
		return
	if _dock.has_method("open_for_icon_pick"):
		_dock.call("open_for_icon_pick")

func _on_dock_icon_imported(icon_path: String, icon_id: String) -> void:
	if not is_instance_valid(_pending_iconify_target):
		return
	_apply_icon_change(_pending_iconify_target, icon_path, icon_id)

func _on_pick_from_local_file_pressed(target: Object) -> void:
	_pending_iconify_target = null
	_cancel_icon_browser_pick()
	_open_local_file_dialog(target)

func _cancel_icon_browser_pick() -> void:
	if _dock == null:
		return
	if _dock.has_method("cancel_icon_pick"):
		_dock.call("cancel_icon_pick")

func _open_local_file_dialog(target: Object) -> void:
	if _host_plugin == null:
		return
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(LOCAL_ICONS_DIR))
	var dialog := FileDialog.new()
	dialog.file_mode = FileDialog.FILE_MODE_OPEN_FILE
	dialog.access = FileDialog.ACCESS_FILESYSTEM
	dialog.title = "Select local icon file"
	dialog.current_dir = ProjectSettings.globalize_path(LOCAL_ICONS_DIR)
	dialog.filters = PackedStringArray([
		"*.svg ; SVG Icon",
		"*.png ; PNG Icon"
	])
	var root := _host_plugin.get_editor_interface().get_base_control()
	root.add_child(dialog)
	dialog.file_selected.connect(_on_local_file_selected.bind(target, dialog), CONNECT_ONE_SHOT)
	dialog.canceled.connect(func() -> void:
		dialog.queue_free()
	, CONNECT_ONE_SHOT)
	dialog.popup_centered_ratio(0.7)

func _on_local_file_selected(path: String, target: Object, dialog: FileDialog) -> void:
	if is_instance_valid(dialog):
		dialog.queue_free()
	if not is_instance_valid(target):
		return
	var normalized := _normalize_icon_path(path)
	_apply_icon_change(target, normalized, "")

func _normalize_icon_path(path: String) -> String:
	if path.begins_with("res://"):
		return path
	var project_root := ProjectSettings.globalize_path("res://")
	if path.begins_with(project_root):
		var relative := path.substr(project_root.length())
		if relative.begins_with("/"):
			relative = relative.substr(1)
		return "res://" + relative
	return path

func _apply_icon_change(target: Object, path: String, icon_id: String) -> void:
	var old_path := str(target.get("icon_path"))
	var old_icon_id := str(target.get("icon_id"))
	if _host_plugin == null:
		target.set("icon_path", path)
		target.set("icon_id", icon_id)
		_cleanup_replaced_icon_file(target, old_path, old_icon_id, path, icon_id)
		return
	var undo_redo := _host_plugin.get_undo_redo()
	if undo_redo == null:
		target.set("icon_path", path)
		target.set("icon_id", icon_id)
		_cleanup_replaced_icon_file(target, old_path, old_icon_id, path, icon_id)
		return
	undo_redo.create_action("Change IconWidget Icon")
	undo_redo.add_do_property(target, "icon_path", path)
	undo_redo.add_do_property(target, "icon_id", icon_id)
	undo_redo.add_undo_property(target, "icon_path", old_path)
	undo_redo.add_undo_property(target, "icon_id", old_icon_id)
	undo_redo.commit_action()
	_cleanup_replaced_icon_file(target, old_path, old_icon_id, path, icon_id)

func _cleanup_replaced_icon_file(target: Object, old_path: String, old_icon_id: String, new_path: String, new_icon_id: String) -> void:
	if old_path.is_empty():
		return
	if old_path == new_path:
		return
	if old_icon_id == new_icon_id:
		return
	if old_icon_id.is_empty():
		return
	if not old_path.begins_with(LOCAL_ICONS_DIR):
		return
	var old_ext := old_path.get_extension().to_lower()
	var candidates := PackedStringArray()
	candidates.append(old_path)
	if old_ext == "svg":
		candidates.append("%s.png" % old_path.get_basename())
	elif old_ext == "png":
		candidates.append("%s.svg" % old_path.get_basename())
	var removed_any := false
	for candidate in candidates:
		if _is_icon_path_used_anywhere(target, candidate):
			continue
		_delete_file_if_exists(candidate)
		_delete_file_if_exists("%s.import" % candidate)
		removed_any = true
	_try_remove_empty_dir(old_path.get_base_dir())
	if removed_any:
		_scan_editor_filesystem()

func _is_icon_path_used_anywhere(ignored_target: Object, icon_path: String) -> bool:
	if icon_path.is_empty():
		return false
	if _is_icon_path_used_by_other_widgets(ignored_target, icon_path):
		return true
	if _is_icon_path_referenced_in_saved_project(icon_path):
		return true
	return false

func _is_icon_path_used_by_other_widgets(ignored_target: Object, icon_path: String) -> bool:
	if _host_plugin == null or icon_path.is_empty():
		return false
	var root := _host_plugin.get_editor_interface().get_edited_scene_root()
	if root == null:
		return false
	return _is_icon_path_used_recursive(root, ignored_target, icon_path)

func _is_icon_path_used_recursive(node: Node, ignored_target: Object, icon_path: String) -> bool:
	if node != ignored_target:
		var script := node.get_script()
		if script != null and str(script.resource_path) == WIDGET_SCRIPT_PATH:
			if str(node.get("icon_path")) == icon_path:
				return true
	for child in node.get_children():
		if child is Node and _is_icon_path_used_recursive(child, ignored_target, icon_path):
			return true
	return false

func _is_icon_path_referenced_in_saved_project(icon_path: String) -> bool:
	if _host_plugin == null or icon_path.is_empty():
		return false
	return _scan_project_for_icon_path("res://", icon_path)

func _scan_project_for_icon_path(directory: String, icon_path: String) -> bool:
	var abs_dir := ProjectSettings.globalize_path(directory)
	var dir := DirAccess.open(abs_dir)
	if dir == null:
		# Be conservative on scan failure to avoid deleting a still-used icon.
		return true
	dir.list_dir_begin()
	while true:
		var name := dir.get_next()
		if name.is_empty():
			break
		if name == "." or name == "..":
			continue
		var child_path := directory.path_join(name)
		if dir.current_is_dir():
			if child_path.begins_with("res://.godot"):
				continue
			if child_path.begins_with(LOCAL_ICONS_DIR):
				continue
			if _scan_project_for_icon_path(child_path, icon_path):
				dir.list_dir_end()
				return true
			continue
		if not _is_scannable_project_file(child_path):
			continue
		if _resource_file_references_icon_path(child_path, icon_path):
			dir.list_dir_end()
			return true
	dir.list_dir_end()
	return false

func _is_scannable_project_file(path: String) -> bool:
	var ext := path.get_extension().to_lower()
	return ext == "tscn" or ext == "scn" or ext == "tres" or ext == "res"

func _resource_file_references_icon_path(path: String, icon_path: String) -> bool:
	var ext := path.get_extension().to_lower()
	if ext == "tscn" or ext == "scn":
		var loaded := ResourceLoader.load(path)
		if loaded is PackedScene:
			return _packed_scene_references_icon_path(loaded, icon_path)
	return _file_contains_path_bytes(path, icon_path, true)

func _packed_scene_references_icon_path(scene: PackedScene, icon_path: String) -> bool:
	var state := scene.get_state()
	if state == null:
		return true
	for node_idx in range(state.get_node_count()):
		var node_script_path := ""
		var node_has_icon_path := false
		var node_icon_path := ""
		for prop_idx in range(state.get_node_property_count(node_idx)):
			var prop_name := str(state.get_node_property_name(node_idx, prop_idx))
			var prop_value: Variant = state.get_node_property_value(node_idx, prop_idx)
			if prop_name == "script":
				node_script_path = _extract_script_path(prop_value)
			elif prop_name == "icon_path":
				node_has_icon_path = true
				node_icon_path = str(prop_value)
		if not node_has_icon_path:
			continue
		if node_icon_path != icon_path:
			continue
		if node_script_path.is_empty() or node_script_path == WIDGET_SCRIPT_PATH:
			return true
	return false

func _extract_script_path(value: Variant) -> String:
	if value is Script:
		return str(value.resource_path)
	if value is Resource:
		return str(value.resource_path)
	var as_text := str(value)
	if as_text.begins_with("res://"):
		return as_text
	return ""

func _file_contains_path_bytes(path: String, needle: String, conservative_on_read_error: bool) -> bool:
	if needle.is_empty():
		return false
	if not FileAccess.file_exists(path):
		return false
	var content := FileAccess.get_file_as_bytes(path)
	if content.is_empty():
		return conservative_on_read_error
	var needle_bytes := needle.to_utf8_buffer()
	if needle_bytes.is_empty():
		return false
	return _bytes_contains(content, needle_bytes)

func _bytes_contains(haystack: PackedByteArray, needle: PackedByteArray) -> bool:
	if needle.is_empty():
		return true
	var hay_size := haystack.size()
	var needle_size := needle.size()
	if needle_size > hay_size:
		return false
	var max_start := hay_size - needle_size
	for start in range(max_start + 1):
		var matched := true
		for offset in range(needle_size):
			if haystack[start + offset] != needle[offset]:
				matched = false
				break
		if matched:
			return true
	return false

func _delete_file_if_exists(path: String) -> void:
	if path.is_empty():
		return
	if not FileAccess.file_exists(path):
		return
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))

func _try_remove_empty_dir(path: String) -> void:
	if path.is_empty():
		return
	if not path.begins_with(LOCAL_ICONS_DIR):
		return
	var abs_path := ProjectSettings.globalize_path(path)
	var dir := DirAccess.open(abs_path)
	if dir == null:
		return
	dir.list_dir_begin()
	while true:
		var name := dir.get_next()
		if name.is_empty():
			break
		if name == "." or name == "..":
			continue
		dir.list_dir_end()
		return
	dir.list_dir_end()
	DirAccess.remove_absolute(abs_path)

func _scan_editor_filesystem() -> void:
	if _host_plugin == null:
		return
	var fs := _host_plugin.get_editor_interface().get_resource_filesystem()
	if fs == null:
		return
	fs.scan()
