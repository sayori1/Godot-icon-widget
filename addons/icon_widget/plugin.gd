@tool
extends EditorPlugin

var _dock: Control
var _inspector_plugin: EditorInspectorPlugin

func _enter_tree() -> void:
	var dock_script := preload("res://addons/icon_widget/icon_widget_dock.gd")
	_dock = dock_script.new()
	_dock.name = "Icon Widget"
	if _dock.has_method("set_editor_interface"):
		_dock.call("set_editor_interface", get_editor_interface())
	add_control_to_dock(DOCK_SLOT_RIGHT_UL, _dock)

	var inspector_script := preload("res://addons/icon_widget/icon_widget_inspector_plugin.gd")
	_inspector_plugin = inspector_script.new()
	if _inspector_plugin.has_method("setup"):
		_inspector_plugin.call("setup", self, _dock)
	add_inspector_plugin(_inspector_plugin)

func _exit_tree() -> void:
	if _inspector_plugin != null:
		remove_inspector_plugin(_inspector_plugin)
		_inspector_plugin = null
	if _dock == null:
		return
	remove_control_from_docks(_dock)
	_dock.queue_free()
	_dock = null
