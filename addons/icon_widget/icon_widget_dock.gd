@tool
extends VBoxContainer

signal icon_imported(icon_path: String, icon_id: String)

const API_BASE := "https://api.iconify.design"
const LOCAL_ICONS_DIR := "res://addons/icon_widget/local_icons"
const SETTINGS_PATH := "user://icon_widget_settings.cfg"

const MAX_SEARCH_RESULTS := 240
const PAGE_SIZE := 60
const PREVIEW_SIZE := 256
const MAX_THUMBNAIL_REQUESTS := 6

const SETTINGS_DEFAULTS := {
	"default_import_dir": LOCAL_ICONS_DIR,
	"default_export_dir": "",
	"dark_preview": true,
	"thumbnail_size": 64
}

var _editor_interface: EditorInterface

var _settings: Dictionary = {}
var _collections_by_prefix: Dictionary = {}
var _prefixes_by_category: Dictionary = {}

var _raw_results: Array[String] = []
var _filtered_results: Array[String] = []
var _current_page_icons: Array[String] = []
var _current_page: int = 0
var _selected_icon_id: String = ""
var _pending_export_icon_id: String = ""

var _icon_id_to_item_index: Dictionary = {}
var _thumbnail_textures: Dictionary = {}
var _thumbnail_queue: Array[String] = []
var _thumbnail_queued: Dictionary = {}
var _thumbnail_inflight: Dictionary = {}
var _thumb_done_for_page: int = 0
var _thumb_total_for_page: int = 0

var _search_ticket: int = 0
var _latest_error_was_rate_limit: bool = false
var _picker_mode_active: bool = false
var _picker_apply_in_progress: bool = false

var _search_edit: LineEdit
var _search_button: Button
var _category_filter: OptionButton
var _settings_button: Button

var _prev_page_button: Button
var _next_page_button: Button
var _page_label: Label
var _icon_size_slider: HSlider
var _icon_size_value_label: Label

var _icon_grid: ItemList
var _result_count_label: Label

var _preview_background: ColorRect
var _preview_texture: TextureRect
var _preview_source_texture: Texture2D
var _preview_svg_bytes: PackedByteArray = PackedByteArray()
var _preview_icon_id: String = ""
var _icon_title_label: Label
var _icon_meta_label: Label
var _import_button: Button
var _export_button: Button
var _refresh_button: Button
var _format_option: OptionButton

var _status_label: Label
var _progress_bar: ProgressBar

var _debounce_timer: Timer
var _hover_popup: PopupPanel
var _hover_preview_texture: TextureRect
var _export_dialog: FileDialog
var _settings_popup: PopupPanel
var _setting_import_dir_edit: LineEdit
var _setting_export_dir_edit: LineEdit
var _setting_dark_preview: CheckButton

func set_editor_interface(editor_interface: EditorInterface) -> void:
	_editor_interface = editor_interface

func open_for_icon_pick() -> void:
	visible = true
	_picker_mode_active = true
	_picker_apply_in_progress = false
	_focus_dock_tab()
	if _search_edit != null:
		_search_edit.focus_mode = Control.FOCUS_ALL
		_search_edit.call_deferred("grab_focus")
	_set_status("Picker mode: click icons to apply to the selected IconWidget.")

func cancel_icon_pick() -> void:
	_picker_mode_active = false
	_picker_apply_in_progress = false

func _focus_dock_tab() -> void:
	var cursor: Node = self
	while cursor != null:
		var parent := cursor.get_parent()
		if parent is TabContainer:
			var tabs: TabContainer = parent
			for i in tabs.get_tab_count():
				var tab_control := tabs.get_tab_control(i)
				if tab_control == null:
					continue
				if tab_control == cursor or tab_control.is_ancestor_of(self):
					tabs.current_tab = i
					return
		cursor = parent

func get_selected_icon_id() -> String:
	return _selected_icon_id

func get_local_icons_dir() -> String:
	return LOCAL_ICONS_DIR

func export_selected_icon_to_local_library_sync() -> Dictionary:
	if _selected_icon_id.is_empty():
		return {
			"ok": false,
			"message": "No icon selected in browser"
		}
	var split := _split_icon_id(_selected_icon_id)
	var prefix := str(split.get("prefix", "misc"))
	var icon_name := _safe_file_name(str(split.get("name", "icon")))
	var destination_dir := LOCAL_ICONS_DIR.path_join(prefix)
	if not _ensure_directory(destination_dir):
		return {
			"ok": false,
			"message": "Cannot create local icon directory"
		}
	var destination_path := ""
	if _preview_icon_id == _selected_icon_id and not _preview_svg_bytes.is_empty():
		destination_path = destination_dir.path_join("%s.svg" % icon_name)
		if not _write_binary_file(destination_path, _preview_svg_bytes):
			return {
				"ok": false,
				"message": "Failed to save SVG into local library"
			}
	elif _preview_texture != null and _preview_texture.texture != null:
		var preview_tex: Texture2D = _preview_source_texture
		if preview_tex == null:
			preview_tex = _preview_texture.texture
		var preview_image := preview_tex.get_image()
		if preview_image == null:
			return {
				"ok": false,
				"message": "Selected icon is still loading. Wait for preview and retry."
			}
		var png_bytes := preview_image.save_png_to_buffer()
		if png_bytes.is_empty():
			return {
				"ok": false,
				"message": "Failed to generate preview PNG for local library"
			}
		destination_path = destination_dir.path_join("%s.png" % icon_name)
		if not _write_binary_file(destination_path, png_bytes):
			return {
				"ok": false,
				"message": "Failed to save preview PNG into local library"
			}
	else:
		return {
			"ok": false,
			"message": "Selected icon is not ready yet. Choose icon and wait until preview appears."
		}
	_scan_editor_filesystem()
	_set_status("Saved to local icons: %s" % destination_path)
	return {
		"ok": true,
		"icon_id": _selected_icon_id,
		"icon_path": destination_path
	}

func _ready() -> void:
	if _search_edit != null:
		return
	_ensure_directories()
	_load_settings()
	_build_ui()
	_apply_settings_to_ui()
	_fetch_collections_async()
	_set_status("Type a keyword to search icons from Iconify.")

func _build_ui() -> void:
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	size_flags_vertical = Control.SIZE_EXPAND_FILL

	var top_bar := HBoxContainer.new()
	top_bar.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	add_child(top_bar)

	_search_edit = LineEdit.new()
	_search_edit.placeholder_text = "Search icons (example: home, arrow, folder)"
	_search_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	top_bar.add_child(_search_edit)

	_search_button = Button.new()
	_search_button.text = "Search"
	top_bar.add_child(_search_button)

	_category_filter = OptionButton.new()
	_category_filter.custom_minimum_size = Vector2(170.0, 0.0)
	_category_filter.add_item("All Categories")
	top_bar.add_child(_category_filter)

	_settings_button = Button.new()
	_settings_button.text = "Settings"
	top_bar.add_child(_settings_button)

	var pager_bar := HBoxContainer.new()
	pager_bar.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	add_child(pager_bar)

	_prev_page_button = Button.new()
	_prev_page_button.text = "Prev"
	pager_bar.add_child(_prev_page_button)

	_next_page_button = Button.new()
	_next_page_button.text = "Next"
	pager_bar.add_child(_next_page_button)

	_page_label = Label.new()
	_page_label.text = "Page 0 / 0"
	_page_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	pager_bar.add_child(_page_label)

	var size_label := Label.new()
	size_label.text = "Thumb"
	pager_bar.add_child(size_label)

	_icon_size_slider = HSlider.new()
	_icon_size_slider.min_value = 32.0
	_icon_size_slider.max_value = 128.0
	_icon_size_slider.step = 8.0
	_icon_size_slider.custom_minimum_size = Vector2(120.0, 0.0)
	pager_bar.add_child(_icon_size_slider)

	_icon_size_value_label = Label.new()
	_icon_size_value_label.custom_minimum_size = Vector2(36.0, 0.0)
	pager_bar.add_child(_icon_size_value_label)

	var split := HSplitContainer.new()
	split.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	split.size_flags_vertical = Control.SIZE_EXPAND_FILL
	add_child(split)

	var left_box := VBoxContainer.new()
	left_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	left_box.size_flags_vertical = Control.SIZE_EXPAND_FILL
	split.add_child(left_box)

	_icon_grid = ItemList.new()
	_icon_grid.select_mode = ItemList.SELECT_SINGLE
	_icon_grid.same_column_width = true
	_icon_grid.fixed_column_width = 115
	_icon_grid.icon_mode = ItemList.ICON_MODE_TOP
	_icon_grid.max_columns = 0
	_icon_grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_icon_grid.size_flags_vertical = Control.SIZE_EXPAND_FILL
	left_box.add_child(_icon_grid)

	_result_count_label = Label.new()
	_result_count_label.text = "No results"
	left_box.add_child(_result_count_label)

	var right_panel := PanelContainer.new()
	right_panel.custom_minimum_size = Vector2(260.0, 0.0)
	right_panel.size_flags_vertical = Control.SIZE_EXPAND_FILL
	split.add_child(right_panel)

	var right_box := VBoxContainer.new()
	right_box.size_flags_vertical = Control.SIZE_EXPAND_FILL
	right_panel.add_child(right_box)

	_preview_background = ColorRect.new()
	_preview_background.custom_minimum_size = Vector2(220.0, 220.0)
	_preview_background.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	right_box.add_child(_preview_background)

	var preview_center := CenterContainer.new()
	preview_center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_preview_background.add_child(preview_center)

	_preview_texture = preload("res://addons/icon_widget/drag_icon_preview.gd").new()
	_preview_texture.custom_minimum_size = Vector2(170.0, 170.0)
	_preview_texture.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_preview_texture.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	preview_center.add_child(_preview_texture)

	_icon_title_label = Label.new()
	_icon_title_label.text = "No icon selected"
	_icon_title_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	right_box.add_child(_icon_title_label)

	_icon_meta_label = Label.new()
	_icon_meta_label.text = ""
	_icon_meta_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	right_box.add_child(_icon_meta_label)

	var format_row := HBoxContainer.new()
	right_box.add_child(format_row)

	var format_label := Label.new()
	format_label.text = "Format"
	format_row.add_child(format_label)

	_format_option = OptionButton.new()
	_format_option.add_item("SVG")
	_format_option.add_item("PNG")
	_format_option.add_item("Both")
	_format_option.selected = 0
	format_row.add_child(_format_option)

	var action_row := HBoxContainer.new()
	right_box.add_child(action_row)

	_import_button = Button.new()
	_import_button.text = "Import"
	action_row.add_child(_import_button)

	_export_button = Button.new()
	_export_button.text = "Export"
	action_row.add_child(_export_button)

	_refresh_button = Button.new()
	_refresh_button.text = "Refresh"
	action_row.add_child(_refresh_button)

	var status_row := HBoxContainer.new()
	status_row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	add_child(status_row)

	_status_label = Label.new()
	_status_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	status_row.add_child(_status_label)

	_progress_bar = ProgressBar.new()
	_progress_bar.custom_minimum_size = Vector2(140.0, 0.0)
	_progress_bar.min_value = 0.0
	_progress_bar.max_value = 1.0
	_progress_bar.show_percentage = false
	_progress_bar.visible = false
	status_row.add_child(_progress_bar)

	_debounce_timer = Timer.new()
	_debounce_timer.one_shot = true
	_debounce_timer.wait_time = 0.30
	add_child(_debounce_timer)

	_hover_popup = PopupPanel.new()
	_hover_popup.visible = false
	add_child(_hover_popup)
	var hover_margin := MarginContainer.new()
	hover_margin.add_theme_constant_override("margin_left", 6)
	hover_margin.add_theme_constant_override("margin_top", 6)
	hover_margin.add_theme_constant_override("margin_right", 6)
	hover_margin.add_theme_constant_override("margin_bottom", 6)
	_hover_popup.add_child(hover_margin)
	_hover_preview_texture = TextureRect.new()
	_hover_preview_texture.custom_minimum_size = Vector2(84.0, 84.0)
	_hover_preview_texture.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_hover_preview_texture.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	hover_margin.add_child(_hover_preview_texture)

	_export_dialog = FileDialog.new()
	_export_dialog.file_mode = FileDialog.FILE_MODE_OPEN_DIR
	_export_dialog.access = FileDialog.ACCESS_FILESYSTEM
	_export_dialog.title = "Choose export directory"
	add_child(_export_dialog)

	_build_settings_popup()

	_search_edit.text_changed.connect(_on_search_text_changed)
	_search_edit.text_submitted.connect(_on_search_submitted)
	_search_button.pressed.connect(_on_search_button_pressed)
	_category_filter.item_selected.connect(_on_category_filter_changed)
	_settings_button.pressed.connect(_on_settings_button_pressed)

	_prev_page_button.pressed.connect(_on_prev_page_pressed)
	_next_page_button.pressed.connect(_on_next_page_pressed)
	_icon_size_slider.value_changed.connect(_on_icon_size_changed)

	_icon_grid.item_selected.connect(_on_grid_item_selected)
	_icon_grid.gui_input.connect(_on_grid_gui_input)
	_icon_grid.mouse_exited.connect(_on_grid_mouse_exited)

	_import_button.pressed.connect(_on_import_pressed)
	_export_button.pressed.connect(_on_export_pressed)
	_refresh_button.pressed.connect(_on_refresh_pressed)

	_debounce_timer.timeout.connect(_on_debounce_timeout)
	_export_dialog.dir_selected.connect(_on_export_dir_selected)

func _build_settings_popup() -> void:
	_settings_popup = PopupPanel.new()
	add_child(_settings_popup)
	var wrapper := VBoxContainer.new()
	wrapper.custom_minimum_size = Vector2(420.0, 0.0)
	_settings_popup.add_child(wrapper)

	var title := Label.new()
	title.text = "Icon Widget Settings"
	wrapper.add_child(title)

	var import_row := HBoxContainer.new()
	wrapper.add_child(import_row)
	var import_label := Label.new()
	import_label.text = "Import dir"
	import_row.add_child(import_label)
	_setting_import_dir_edit = LineEdit.new()
	_setting_import_dir_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	import_row.add_child(_setting_import_dir_edit)

	var export_row := HBoxContainer.new()
	wrapper.add_child(export_row)
	var export_label := Label.new()
	export_label.text = "Export dir"
	export_row.add_child(export_label)
	_setting_export_dir_edit = LineEdit.new()
	_setting_export_dir_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	export_row.add_child(_setting_export_dir_edit)

	_setting_dark_preview = CheckButton.new()
	_setting_dark_preview.text = "Dark preview background"
	wrapper.add_child(_setting_dark_preview)

	var actions := HBoxContainer.new()
	wrapper.add_child(actions)
	var save_button := Button.new()
	save_button.text = "Save"
	actions.add_child(save_button)
	var close_button := Button.new()
	close_button.text = "Close"
	actions.add_child(close_button)

	save_button.pressed.connect(_on_settings_save_pressed)
	close_button.pressed.connect(func() -> void:
		_settings_popup.hide()
	)

func _on_settings_button_pressed() -> void:
	_setting_import_dir_edit.text = str(_settings.get("default_import_dir", SETTINGS_DEFAULTS["default_import_dir"]))
	_setting_export_dir_edit.text = str(_settings.get("default_export_dir", SETTINGS_DEFAULTS["default_export_dir"]))
	_setting_dark_preview.button_pressed = bool(_settings.get("dark_preview", SETTINGS_DEFAULTS["dark_preview"]))
	_settings_popup.popup_centered()

func _on_settings_save_pressed() -> void:
	var import_dir := _setting_import_dir_edit.text.strip_edges()
	if import_dir.is_empty() or not import_dir.begins_with("res://"):
		_set_status("Import directory must start with res://", true)
		return
	var export_dir := _setting_export_dir_edit.text.strip_edges()
	if export_dir.is_empty():
		export_dir = ProjectSettings.globalize_path("res://")
	_settings["default_import_dir"] = import_dir
	_settings["default_export_dir"] = export_dir
	_settings["dark_preview"] = _setting_dark_preview.button_pressed
	_save_settings()
	_apply_settings_to_ui()
	_set_status("Settings saved")
	_settings_popup.hide()

func _load_settings() -> void:
	_settings = SETTINGS_DEFAULTS.duplicate(true)
	if str(_settings.get("default_import_dir", "")).is_empty():
		_settings["default_import_dir"] = LOCAL_ICONS_DIR
	if str(_settings.get("default_export_dir", "")).is_empty():
		_settings["default_export_dir"] = ProjectSettings.globalize_path("res://")
	var cfg := ConfigFile.new()
	if cfg.load(SETTINGS_PATH) != OK:
		return
	for key in SETTINGS_DEFAULTS.keys():
		_settings[key] = cfg.get_value("icon_widget", key, SETTINGS_DEFAULTS[key])
	if str(_settings.get("default_import_dir", "")).is_empty() or str(_settings.get("default_import_dir", "")) == "res://assets/icons":
		_settings["default_import_dir"] = LOCAL_ICONS_DIR
	if str(_settings.get("default_export_dir", "")).is_empty():
		_settings["default_export_dir"] = ProjectSettings.globalize_path("res://")

func _save_settings() -> void:
	var cfg := ConfigFile.new()
	for key in SETTINGS_DEFAULTS.keys():
		cfg.set_value("icon_widget", key, _settings.get(key, SETTINGS_DEFAULTS[key]))
	cfg.save(SETTINGS_PATH)

func _apply_settings_to_ui() -> void:
	if _icon_size_slider == null:
		return
	var thumb_size := int(_settings.get("thumbnail_size", SETTINGS_DEFAULTS["thumbnail_size"]))
	thumb_size = clamp(thumb_size, 32, 128)
	_icon_size_slider.value = float(thumb_size)
	_update_thumbnail_size_ui()
	var dark_preview := bool(_settings.get("dark_preview", SETTINGS_DEFAULTS["dark_preview"]))
	if dark_preview:
		_preview_background.color = Color(0.10, 0.10, 0.10, 1.0)
	else:
		_preview_background.color = Color(0.92, 0.92, 0.92, 1.0)

func _ensure_directories() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(LOCAL_ICONS_DIR))

func _fetch_collections_async() -> void:
	var response := await _request_json("%s/collections" % API_BASE, 1)
	if not bool(response.get("ok", false)):
		_set_status("Collection metadata unavailable. Category filter may be limited.", true)
		return
	var data: Dictionary = response.get("json", {})
	_collections_by_prefix = data
	_prefixes_by_category.clear()
	for prefix_variant in data.keys():
		var prefix := str(prefix_variant)
		var info: Dictionary = data.get(prefix, {})
		var category := str(info.get("category", "Other"))
		if not _prefixes_by_category.has(category):
			_prefixes_by_category[category] = PackedStringArray()
		var list: PackedStringArray = _prefixes_by_category[category]
		list.append(prefix)
		_prefixes_by_category[category] = list
	_populate_category_filter()

func _populate_category_filter() -> void:
	var selected_text := _get_selected_category()
	_category_filter.clear()
	_category_filter.add_item("All Categories")
	var categories := PackedStringArray(_prefixes_by_category.keys())
	categories.sort()
	for category in categories:
		_category_filter.add_item(category)
	for i in _category_filter.item_count:
		if _category_filter.get_item_text(i) == selected_text:
			_category_filter.select(i)
			return
	_category_filter.select(0)

func _get_selected_category() -> String:
	if _category_filter == null or _category_filter.item_count == 0:
		return "All Categories"
	return _category_filter.get_item_text(_category_filter.selected)

func _on_search_text_changed(_new_text: String) -> void:
	_debounce_timer.start()

func _on_search_submitted(text: String) -> void:
	_perform_search_async(text)

func _on_search_button_pressed() -> void:
	_perform_search_async(_search_edit.text)

func _on_category_filter_changed(_index: int) -> void:
	_apply_filters_and_render()

func _on_debounce_timeout() -> void:
	var query := _search_edit.text.strip_edges()
	_perform_search_async(query)

func _perform_search_async(raw_query: String) -> void:
	var query := raw_query.strip_edges()
	_search_ticket += 1
	var ticket := _search_ticket
	if query.is_empty():
		_raw_results.clear()
		_apply_filters_and_render()
		_set_status("Type a keyword to search icons from Iconify.")
		return
	_set_busy(true)
	_set_status("Searching '%s'..." % query)
	_latest_error_was_rate_limit = false
	var url := "%s/search?query=%s&limit=%d" % [API_BASE, query.uri_encode(), MAX_SEARCH_RESULTS]
	var response := await _request_json(url, 2)
	if ticket != _search_ticket:
		return
	if bool(response.get("ok", false)):
		var icons: Array[String] = []
		for icon_variant in response.get("json", {}).get("icons", []):
			icons.append(str(icon_variant))
		_raw_results = icons
		_apply_filters_and_render()
		if _filtered_results.is_empty():
			_set_status("No icons found for '%s'." % query)
		else:
			_set_status("Found %d icons for '%s'." % [_filtered_results.size(), query])
	else:
		_set_status(_format_http_error(response, "Search failed"), true)
	_set_busy(false)

func _apply_filters_and_render() -> void:
	_filtered_results = _apply_category_filter(_raw_results)
	_current_page = 0
	_render_current_page()

func _apply_category_filter(input_icons: Array[String]) -> Array[String]:
	var category := _get_selected_category()
	if category == "All Categories":
		return input_icons.duplicate()
	var allowed_prefixes: PackedStringArray = _prefixes_by_category.get(category, PackedStringArray())
	if allowed_prefixes.is_empty():
		return []
	var allowed := {}
	for prefix in allowed_prefixes:
		allowed[prefix] = true
	var filtered: Array[String] = []
	for icon_id in input_icons:
		var prefix := _split_icon_id(icon_id).get("prefix", "")
		if allowed.has(prefix):
			filtered.append(icon_id)
	return filtered

func _render_current_page() -> void:
	_icon_grid.clear()
	_icon_id_to_item_index.clear()
	_current_page_icons.clear()
	_thumbnail_queue.clear()
	_thumbnail_queued.clear()
	_thumbnail_inflight.clear()
	_thumb_done_for_page = 0
	_thumb_total_for_page = 0

	var total := _filtered_results.size()
	if total == 0:
		_result_count_label.text = "No icons to display"
		_page_label.text = "Page 0 / 0"
		_prev_page_button.disabled = true
		_next_page_button.disabled = true
		_progress_bar.visible = false
		return

	var page_count := int(ceil(float(total) / float(PAGE_SIZE)))
	_current_page = clamp(_current_page, 0, max(0, page_count - 1))
	var start := _current_page * PAGE_SIZE
	var end := min(start + PAGE_SIZE, total)

	for i in range(start, end):
		var icon_id := _filtered_results[i]
		_current_page_icons.append(icon_id)
		_icon_grid.add_item(_format_icon_label(icon_id))
		var idx := _icon_grid.get_item_count() - 1
		_icon_grid.set_item_metadata(idx, icon_id)
		_icon_grid.set_item_tooltip(idx, icon_id)
		_icon_id_to_item_index[icon_id] = idx
		var loaded_texture: Texture2D = _thumbnail_textures.get(icon_id)
		if loaded_texture != null:
			_icon_grid.set_item_icon(idx, loaded_texture)
			_thumb_done_for_page += 1
		else:
			_queue_thumbnail(icon_id)

	_thumb_total_for_page = _current_page_icons.size()
	_update_thumbnail_progress()

	_result_count_label.text = "Showing %d-%d of %d" % [start + 1, end, total]
	_page_label.text = "Page %d / %d" % [_current_page + 1, page_count]
	_prev_page_button.disabled = _current_page <= 0
	_next_page_button.disabled = _current_page >= page_count - 1
	_pump_thumbnail_queue()

func _format_icon_label(icon_id: String) -> String:
	var pieces := _split_icon_id(icon_id)
	return "%s\n%s" % [pieces.get("name", icon_id), pieces.get("prefix", "")]

func _queue_thumbnail(icon_id: String) -> void:
	if _thumbnail_textures.has(icon_id):
		return
	if _thumbnail_inflight.has(icon_id):
		return
	if _thumbnail_queued.has(icon_id):
		return
	_thumbnail_queue.append(icon_id)
	_thumbnail_queued[icon_id] = true

func _pump_thumbnail_queue() -> void:
	while _thumbnail_inflight.size() < MAX_THUMBNAIL_REQUESTS and not _thumbnail_queue.is_empty():
		var icon_id := _thumbnail_queue.pop_front()
		_thumbnail_queued.erase(icon_id)
		_thumbnail_inflight[icon_id] = true
		_download_thumbnail_async(icon_id)

func _download_thumbnail_async(icon_id: String) -> void:
	var thumb_size := _thumbnail_size()
	var texture: Texture2D = null
	var response := await _request_bytes(_icon_svg_url(icon_id), 2)
	if bool(response.get("ok", false)):
		var svg_bytes: PackedByteArray = response.get("body", PackedByteArray())
		if not svg_bytes.is_empty():
			var png_bytes := _render_png_bytes_from_svg(svg_bytes, thumb_size)
			texture = _texture_from_png_bytes(png_bytes)
	else:
		if int(response.get("code", 0)) == 429 and not _latest_error_was_rate_limit:
			_latest_error_was_rate_limit = true
			_set_status("Rate limit reached while downloading thumbnails. Retrying in background.", true)
	if texture != null:
		var white_texture := _to_white_mask_texture(texture)
		if white_texture != null:
			texture = white_texture
		_thumbnail_textures[icon_id] = texture
		_set_item_icon_for_icon_id(icon_id, texture)
	_thumb_done_for_page += 1
	_update_thumbnail_progress()
	_thumbnail_inflight.erase(icon_id)
	_pump_thumbnail_queue()

func _set_item_icon_for_icon_id(icon_id: String, texture: Texture2D) -> void:
	if not _icon_id_to_item_index.has(icon_id):
		return
	var idx := int(_icon_id_to_item_index[icon_id])
	if idx < 0 or idx >= _icon_grid.get_item_count():
		return
	_icon_grid.set_item_icon(idx, texture)

func _update_thumbnail_progress() -> void:
	if _thumb_total_for_page <= 0:
		_progress_bar.visible = false
		return
	_progress_bar.visible = true
	_progress_bar.value = float(_thumb_done_for_page) / float(_thumb_total_for_page)
	if _thumb_done_for_page >= _thumb_total_for_page:
		_progress_bar.visible = false

func _on_prev_page_pressed() -> void:
	if _current_page <= 0:
		return
	_current_page -= 1
	_render_current_page()

func _on_next_page_pressed() -> void:
	var max_page := int(ceil(float(_filtered_results.size()) / float(PAGE_SIZE))) - 1
	if _current_page >= max_page:
		return
	_current_page += 1
	_render_current_page()

func _on_icon_size_changed(value: float) -> void:
	_settings["thumbnail_size"] = int(value)
	_save_settings()
	_update_thumbnail_size_ui()
	_thumbnail_textures.clear()
	_render_current_page()

func _update_thumbnail_size_ui() -> void:
	var size := _thumbnail_size()
	if _icon_grid != null:
		_icon_grid.fixed_icon_size = Vector2i(size, size)
	_icon_size_value_label.text = str(size)

func _thumbnail_size() -> int:
	return int(clamp(int(_settings.get("thumbnail_size", SETTINGS_DEFAULTS["thumbnail_size"])), 32, 128))

func _on_grid_item_selected(index: int) -> void:
	if index < 0 or index >= _icon_grid.get_item_count():
		return
	var icon_id := str(_icon_grid.get_item_metadata(index))
	_select_icon(icon_id)
	if _picker_mode_active:
		_import_selected_for_picker_async()

func _import_selected_for_picker_async() -> void:
	if _picker_apply_in_progress:
		return
	if _selected_icon_id.is_empty():
		return
	_picker_apply_in_progress = true
	_set_busy(true)
	var copied := await _copy_icon_to_directory(_selected_icon_id, LOCAL_ICONS_DIR, true)
	_set_busy(false)
	if copied.is_empty():
		_picker_apply_in_progress = false
		_set_status("Failed to apply icon from Iconify", true)
		return
	var chosen_path := _pick_preferred_icon_path(copied)
	if chosen_path.is_empty():
		_picker_apply_in_progress = false
		_set_status("Failed to resolve imported icon path", true)
		return
	icon_imported.emit(chosen_path, _selected_icon_id)
	_picker_apply_in_progress = false
	_scan_editor_filesystem()
	_set_status("Applied icon: %s (picker mode active)" % _selected_icon_id)

func _select_icon(icon_id: String) -> void:
	_selected_icon_id = icon_id
	var pieces := _split_icon_id(icon_id)
	_icon_title_label.text = icon_id
	_icon_meta_label.text = "Collection: %s\nName: %s" % [pieces.get("prefix", "?"), pieces.get("name", "?")]
	_load_preview_async(icon_id, false)

func _load_preview_async(icon_id: String, _force_refresh: bool) -> void:
	_set_busy(true)
	var assets := await _fetch_icon_assets(icon_id)
	if icon_id != _selected_icon_id:
		_set_busy(false)
		return
	if not bool(assets.get("ok", false)):
		_preview_texture.texture = null
		_preview_source_texture = null
		_preview_svg_bytes = PackedByteArray()
		_preview_icon_id = ""
		_set_status(str(assets.get("message", "Failed to load icon")), true)
		_set_busy(false)
		return
	var png_bytes: PackedByteArray = assets.get("png_bytes", PackedByteArray())
	var texture := _texture_from_png_bytes(png_bytes)
	if texture == null:
		_preview_source_texture = null
		_preview_svg_bytes = PackedByteArray()
		_preview_icon_id = ""
		_set_status("Failed to decode icon preview", true)
		_set_busy(false)
		return
	_preview_source_texture = texture
	_preview_svg_bytes = assets.get("svg_bytes", PackedByteArray())
	_preview_icon_id = icon_id
	var white_preview := _to_white_mask_texture(texture)
	if white_preview != null:
		_preview_texture.texture = white_preview
	else:
		_preview_texture.texture = texture
	_prepare_drag_source(icon_id, png_bytes)
	_set_status("Ready: %s" % icon_id)
	_set_busy(false)

func _prepare_drag_source(icon_id: String, png_bytes: PackedByteArray) -> void:
	var drag_paths := PackedStringArray()
	if png_bytes.is_empty():
		return
	var split := _split_icon_id(icon_id)
	var import_dir := "res://.icon_widget_drag".path_join(split.get("prefix", "misc"))
	var file_name := "%s.png" % _safe_file_name(split.get("name", "icon"))
	var target_path := import_dir.path_join(file_name)
	if _write_binary_file(target_path, png_bytes):
		drag_paths.append(target_path)
	if _preview_texture.has_method("set_dragged_files"):
		_preview_texture.call("set_dragged_files", drag_paths)

func _fetch_icon_assets(icon_id: String) -> Dictionary:
	var split := _split_icon_id(icon_id)
	if split.is_empty():
		return {"ok": false, "message": "Invalid icon id"}
	var svg_response := await _request_bytes(_icon_svg_url(icon_id), 2)
	if not bool(svg_response.get("ok", false)):
		return {"ok": false, "message": _format_http_error(svg_response, "Failed to fetch SVG")}
	var svg_bytes: PackedByteArray = svg_response.get("body", PackedByteArray())
	if svg_bytes.is_empty():
		return {"ok": false, "message": "Icon SVG is empty"}
	var png_bytes := _render_png_bytes_from_svg(svg_bytes, PREVIEW_SIZE)
	if png_bytes.is_empty():
		return {"ok": false, "message": "Failed to rasterize SVG preview"}
	return {
		"ok": true,
		"svg_bytes": svg_bytes,
		"png_bytes": png_bytes
	}

func _on_import_pressed() -> void:
	if _selected_icon_id.is_empty():
		_set_status("Select an icon to import", true)
		return
	var target_dir := str(_settings.get("default_import_dir", SETTINGS_DEFAULTS["default_import_dir"]))
	if not target_dir.begins_with("res://"):
		_set_status("Import directory must start with res://", true)
		return
	_set_busy(true)
	var copied := await _copy_icon_to_directory(_selected_icon_id, target_dir, true)
	_set_busy(false)
	if copied.is_empty():
		_set_status("Import failed", true)
		return
	if _preview_texture.has_method("set_dragged_files"):
		_preview_texture.call("set_dragged_files", copied)
	var chosen_path := _pick_preferred_icon_path(copied)
	if _picker_mode_active and not chosen_path.is_empty():
		icon_imported.emit(chosen_path, _selected_icon_id)
	_scan_editor_filesystem()
	_set_status("Imported %d file(s) to %s" % [copied.size(), target_dir])

func _on_export_pressed() -> void:
	if _selected_icon_id.is_empty():
		_set_status("Select an icon to export", true)
		return
	_pending_export_icon_id = _selected_icon_id
	_export_dialog.current_dir = str(_settings.get("default_export_dir", ProjectSettings.globalize_path("res://")))
	_export_dialog.popup_centered_ratio(0.7)

func _on_export_dir_selected(directory: String) -> void:
	if _pending_export_icon_id.is_empty():
		return
	_settings["default_export_dir"] = directory
	_save_settings()
	_set_busy(true)
	var copied := await _copy_icon_to_directory(_pending_export_icon_id, directory, false)
	_set_busy(false)
	if copied.is_empty():
		_set_status("Export failed", true)
		return
	_set_status("Exported %d file(s) to %s" % [copied.size(), directory])

func _copy_icon_to_directory(icon_id: String, target_dir: String, project_path: bool) -> PackedStringArray:
	var svg_bytes := PackedByteArray()
	var png_bytes := PackedByteArray()
	if _preview_icon_id == icon_id:
		svg_bytes = _preview_svg_bytes
		if _preview_source_texture != null:
			var image := _preview_source_texture.get_image()
			if image != null:
				png_bytes = image.save_png_to_buffer()
	if svg_bytes.is_empty() or png_bytes.is_empty():
		var fetched := await _fetch_icon_assets(icon_id)
		if not bool(fetched.get("ok", false)):
			_set_status(str(fetched.get("message", "Could not download icon")), true)
			return PackedStringArray()
		svg_bytes = fetched.get("svg_bytes", PackedByteArray())
		png_bytes = fetched.get("png_bytes", PackedByteArray())
	if svg_bytes.is_empty():
		_set_status("Could not download icon SVG", true)
		return PackedStringArray()
	if png_bytes.is_empty():
		_set_status("Could not render icon PNG", true)
		return PackedStringArray()
	var split := _split_icon_id(icon_id)
	var prefix := str(split.get("prefix", "misc"))
	var icon_name := _safe_file_name(str(split.get("name", "icon")))
	var destination_dir := target_dir.path_join(prefix)
	if not _ensure_directory(destination_dir):
		_set_status("Could not create destination: %s" % destination_dir, true)
		return PackedStringArray()

	var copied := PackedStringArray()
	var mode := _format_option.get_item_text(_format_option.selected)
	if mode == "SVG" or mode == "Both":
		var dest_svg := destination_dir.path_join("%s.svg" % icon_name)
		if _write_binary_file(dest_svg, svg_bytes):
			copied.append(dest_svg)
	if mode == "PNG" or mode == "Both":
		var dest_png := destination_dir.path_join("%s.png" % icon_name)
		if _write_binary_file(dest_png, png_bytes):
			copied.append(dest_png)

	if project_path and not copied.is_empty():
		_scan_editor_filesystem()
	return copied

func _pick_preferred_icon_path(paths: PackedStringArray) -> String:
	if paths.is_empty():
		return ""
	for path in paths:
		if path.get_extension().to_lower() == "svg":
			return path
	for path in paths:
		if path.get_extension().to_lower() == "png":
			return path
	return paths[0]

func _scan_editor_filesystem() -> void:
	if _editor_interface == null:
		return
	var fs := _editor_interface.get_resource_filesystem()
	if fs == null:
		return
	fs.scan()

func _on_refresh_pressed() -> void:
	if _selected_icon_id.is_empty():
		_set_status("Select an icon to refresh", true)
		return
	_load_preview_async(_selected_icon_id, true)

func _on_grid_gui_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion:
		var motion: InputEventMouseMotion = event
		var idx := _icon_grid.get_item_at_position(motion.position, true)
		if idx == -1:
			_hover_popup.hide()
			return
		var icon_id := str(_icon_grid.get_item_metadata(idx))
		_show_hover_preview(icon_id)

func _on_grid_mouse_exited() -> void:
	_hover_popup.hide()

func _show_hover_preview(icon_id: String) -> void:
	var texture: Texture2D = _thumbnail_textures.get(icon_id)
	if texture == null:
		return
	_hover_preview_texture.texture = texture
	var mouse_pos := DisplayServer.mouse_get_position()
	_hover_popup.popup(Rect2i(mouse_pos + Vector2i(20, 20), Vector2i(108, 108)))

func _request_bytes(url: String, retries: int) -> Dictionary:
	var attempt := 0
	while attempt <= retries:
		var request := HTTPRequest.new()
		request.use_threads = true
		request.timeout = 20.0
		add_child(request)
		var err := request.request(url)
		if err != OK:
			request.queue_free()
			attempt += 1
			await get_tree().create_timer(0.15).timeout
			continue
		var result: Array = await request.request_completed
		request.queue_free()
		var req_result := int(result[0])
		var code := int(result[1])
		var headers: PackedStringArray = result[2]
		var body: PackedByteArray = result[3]
		if req_result == HTTPRequest.RESULT_SUCCESS and code >= 200 and code < 300:
			return {
				"ok": true,
				"code": code,
				"headers": headers,
				"body": body
			}
		var retryable := code == 429 or code == 408 or code == 502 or code == 503 or code == 504 or req_result != HTTPRequest.RESULT_SUCCESS
		if attempt < retries and retryable:
			var delay := 0.5 * pow(2.0, float(attempt))
			await get_tree().create_timer(delay).timeout
			attempt += 1
			continue
		return {
			"ok": false,
			"code": code,
			"request_result": req_result,
			"body": body
		}
	return {
		"ok": false,
		"code": 0,
		"request_result": -1,
		"body": PackedByteArray()
	}

func _request_json(url: String, retries: int) -> Dictionary:
	var response := await _request_bytes(url, retries)
	if not bool(response.get("ok", false)):
		return response
	var body: PackedByteArray = response.get("body", PackedByteArray())
	var text := body.get_string_from_utf8()
	var parsed := JSON.parse_string(text)
	if typeof(parsed) != TYPE_DICTIONARY:
		return {
			"ok": false,
			"code": int(response.get("code", 0)),
			"request_result": int(response.get("request_result", HTTPRequest.RESULT_BODY_SIZE_LIMIT_EXCEEDED)),
			"body": body
		}
	response["json"] = parsed
	return response

func _format_http_error(response: Dictionary, prefix: String) -> String:
	var code := int(response.get("code", 0))
	if code == 429:
		return "%s: API rate limit reached. Wait and retry." % prefix
	if code > 0:
		return "%s: HTTP %d" % [prefix, code]
	var request_result := int(response.get("request_result", -1))
	return "%s: network error (%d)" % [prefix, request_result]

func _set_status(message: String, is_error: bool = false) -> void:
	if _status_label == null:
		return
	_status_label.text = message
	if is_error:
		_status_label.modulate = Color(1.0, 0.58, 0.58)
	else:
		_status_label.modulate = Color(1.0, 1.0, 1.0)

func _set_busy(is_busy: bool) -> void:
	if _search_button != null:
		_search_button.disabled = is_busy
	if _import_button != null:
		_import_button.disabled = is_busy
	if _export_button != null:
		_export_button.disabled = is_busy

func _split_icon_id(icon_id: String) -> Dictionary:
	var separator := icon_id.find(":")
	if separator == -1:
		return {}
	return {
		"prefix": icon_id.substr(0, separator),
		"name": icon_id.substr(separator + 1)
	}

func _safe_file_name(input: String) -> String:
	var out := ""
	for i in input.length():
		var code := input.unicode_at(i)
		var ch := input.substr(i, 1)
		var keep := (
			(code >= 48 and code <= 57)
			or (code >= 65 and code <= 90)
			or (code >= 97 and code <= 122)
			or ch == "-"
			or ch == "_"
		)
		out += ch if keep else "_"
	if out.is_empty():
		out = "icon"
	return out

func _icon_svg_url(icon_id: String) -> String:
	var split := _split_icon_id(icon_id)
	if split.is_empty():
		return ""
	return "%s/%s/%s.svg" % [API_BASE, split["prefix"], split["name"]]

func _texture_from_png_bytes(bytes: PackedByteArray) -> Texture2D:
	if bytes.is_empty():
		return null
	var image := Image.new()
	if image.load_png_from_buffer(bytes) != OK:
		return null
	return ImageTexture.create_from_image(image)

func _to_white_mask_texture(texture: Texture2D) -> Texture2D:
	if texture == null:
		return null
	var image := texture.get_image()
	if image == null:
		return null
	image.convert(Image.FORMAT_RGBA8)
	if _image_has_strong_color(image):
		# Keep colorful icons as-is in browser previews.
		return texture
	for y in image.get_height():
		for x in image.get_width():
			var px := image.get_pixel(x, y)
			image.set_pixel(x, y, Color(1.0, 1.0, 1.0, px.a))
	return ImageTexture.create_from_image(image)

func _image_has_strong_color(image: Image) -> bool:
	var width := image.get_width()
	var height := image.get_height()
	if width <= 0 or height <= 0:
		return false
	var step_x := max(1, width / 32)
	var step_y := max(1, height / 32)
	var sampled_pixels := 0
	var colorful_pixels := 0
	for y in range(0, height, step_y):
		for x in range(0, width, step_x):
			var px := image.get_pixel(x, y)
			if px.a < 0.08:
				continue
			sampled_pixels += 1
			var cmax := max(px.r, max(px.g, px.b))
			var cmin := min(px.r, min(px.g, px.b))
			if cmax - cmin > 0.18:
				colorful_pixels += 1
	if sampled_pixels == 0:
		return false
	return float(colorful_pixels) / float(sampled_pixels) > 0.10

func _render_png_bytes_from_svg(svg_bytes: PackedByteArray, target_size: int) -> PackedByteArray:
	if svg_bytes.is_empty():
		return PackedByteArray()
	var probe := Image.new()
	if probe.load_svg_from_buffer(svg_bytes, 1.0) != OK:
		return PackedByteArray()
	var base_max := max(probe.get_width(), probe.get_height())
	if base_max <= 0:
		return PackedByteArray()
	var scale := max(1.0, float(target_size) / float(base_max))
	var image := Image.new()
	if image.load_svg_from_buffer(svg_bytes, scale) != OK:
		return PackedByteArray()
	var rendered_max := max(image.get_width(), image.get_height())
	if rendered_max > target_size and rendered_max > 0:
		var ratio := float(target_size) / float(rendered_max)
		var width := max(1, int(round(float(image.get_width()) * ratio)))
		var height := max(1, int(round(float(image.get_height()) * ratio)))
		image.resize(width, height, Image.INTERPOLATE_LANCZOS)
	return image.save_png_to_buffer()

func _load_png_texture_from_path(path: String) -> Texture2D:
	if not FileAccess.file_exists(path):
		return null
	var bytes := FileAccess.get_file_as_bytes(path)
	return _texture_from_png_bytes(bytes)

func _ensure_directory(path: String) -> bool:
	var abs_path := _to_absolute_path(path)
	return DirAccess.make_dir_recursive_absolute(abs_path) == OK

func _write_binary_file(path: String, bytes: PackedByteArray) -> bool:
	if bytes.is_empty():
		return false
	if not _ensure_directory(path.get_base_dir()):
		return false
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		return false
	file.store_buffer(bytes)
	return true

func _copy_binary_file(source: String, target: String) -> bool:
	if source.is_empty() or target.is_empty():
		return false
	if not FileAccess.file_exists(source):
		return false
	if not _ensure_directory(target.get_base_dir()):
		return false
	var bytes := FileAccess.get_file_as_bytes(source)
	return _write_binary_file(target, bytes)

func _to_absolute_path(path: String) -> String:
	if path.begins_with("res://") or path.begins_with("user://"):
		return ProjectSettings.globalize_path(path)
	return path
