@tool
class_name GDLinter
extends EditorPlugin

const DockScene := preload("res://addons/gdLinter/UI/Dock.tscn")

const PLUGIN_SETTINGS: StringName = &"plugin/gdLinter/"
const SETTINGS_GDLINT_PATH: StringName = PLUGIN_SETTINGS + "gdlint_path"

const NO_COLOR: Color = Color(0, 0, 0, 0)

var icon_error := EditorInterface.get_editor_theme().get_icon("Error", "EditorIcons")
var icon_error_ignore := EditorInterface.get_editor_theme().get_icon("ErrorWarning", "EditorIcons")
var icon_ignore := EditorInterface.get_editor_theme().get_icon("Warning", "EditorIcons")
var icon_success := EditorInterface.get_editor_theme().get_icon("StatusSuccess", "EditorIcons")

var warning_color: Color = EditorInterface.get_editor_settings()\
	.get_setting("text_editor/theme/highlighting/comment_markers/warning_color")

var bottom_panel_button: Button
var highlight_lines: PackedInt32Array
var item_lists: Array[ItemList]
var script_editor: ScriptEditor

var proc: Dictionary
var current_path: String

var _dock_ui: GDLinterDock
var _is_gdlint_installed: bool
var _ignore: Resource
var _gdlint_path: String

func _enter_tree() -> void:
	# add default settings values
	if not EditorInterface.get_editor_settings().has_setting(SETTINGS_GDLINT_PATH):
		EditorInterface.get_editor_settings().set_setting(SETTINGS_GDLINT_PATH, "")

	# install the GDLint dock
	_dock_ui = DockScene.instantiate()
	_dock_ui.gd_linter = self
	bottom_panel_button = add_control_to_bottom_panel(_dock_ui, "GDLint")

	# connect signal to lint on save
	resource_saved.connect(on_resource_saved)

	script_editor = EditorInterface.get_script_editor()
	script_editor.editor_script_changed.connect(_on_editor_script_changed)
	_gdlint_path = get_gdlint_path()
	get_gdlint_version()
	prints("Loading GDLint Plugin success")


func _process(_delta: float) -> void:
	# Check if the linter sub-process finished
	if proc:
		var exit_code: int = OS.get_process_exit_code(proc["pid"])
		if exit_code != -1:
			# Read the output and process it
			var std: FileAccess = proc["stdio"] if exit_code == 0 else proc["stderr"]
			var outout: String = std.get_as_text(true)

			process_lint(outout)
			# Mark as complete
			proc = {}

	if not get_current_editor():
		return

	if not highlight_lines.is_empty():
		set_line_color(warning_color)


func exec(path: String, arguments: PackedStringArray, output: Array = [],
	read_stderr: bool = false, open_console: bool = false):
	if OS.get_name() == "Windows":
		var args = PackedStringArray(["/C"]) + PackedStringArray([path]) + arguments
		OS.execute("CMD.exe", args, output, read_stderr, open_console)
	else:
		OS.execute(path, arguments, output, read_stderr, open_console)


func exec_non_block(path: String, arguments: PackedStringArray) -> Dictionary:
	var res: Dictionary

	if OS.get_name() == "Windows":
		var args = PackedStringArray(["/C"]) + PackedStringArray([path]) + arguments
		res = OS.execute_with_pipe("CMD.exe", args, false)
	else:
		res = OS.execute_with_pipe(path, arguments, false)

	return res


func _on_editor_script_changed(script: Script) -> void:
	_dock_ui.clear_items()
	on_resource_saved(script)


func get_gdlint_version() -> void:
	var output := []
	exec(_gdlint_path, ["--version"], output)
	_is_gdlint_installed = true if not output[0].is_empty() else false
	if _is_gdlint_installed:
		_dock_ui.version.text = "Using %s" % output[0]
	else:
		_dock_ui.version.text = "gdlint not found!"


func _exit_tree() -> void:
	if is_instance_valid(_dock_ui):
		remove_control_from_bottom_panel(_dock_ui)
		_dock_ui.free()

	if Engine.get_version_info().hex >= 0x40201:
		prints("Unload GDLint Plugin success")


func on_resource_saved(resource: Resource) -> void:
	if not resource is GDScript:
		return

	_dock_ui.clear_items()
	clear_highlights()

	# Show resource path in the GDLint Dock
	_dock_ui.file.text = resource.resource_path

	run_lint(resource)


func run_lint(resource: GDScript) -> void:
	# Execute linting and get output
	var filepath: String = ProjectSettings.globalize_path(resource.resource_path)

	proc = exec_non_block(_gdlint_path, [filepath])
	current_path = filepath


func process_lint(output: String) -> void:
	var output_array: PackedStringArray = output.replace(current_path + ":", "Line ").split("\n")

	_dock_ui.set_problems_label(_dock_ui.num_problems)
	_dock_ui.set_ignored_problems_label(_dock_ui.num_ignored_problems)

	# Workaround until unique name bug is fixed
	# https://github.com/Scony/godot-gdscript-toolkit/issues/284
	# Hope I won't break other stuff with it
	if not output_array.size() or output_array[0] == "Line ":
		printerr("gdLint Error: ", output_array, "\n File can't be linted!")
		return

	# When there is no error
	if output_array.size() <= 2:
		bottom_panel_button.add_theme_constant_override(&"icon_max_width", 8)
		bottom_panel_button.icon = icon_success
		return

	# When errors are found create buttons in the dock
	for i in output_array.size() - 2:
		var regex := RegEx.new()
		regex.compile("\\d+")
		var result := regex.search(output_array[i])
		if result:
			var current_line := int(result.strings[0]) - 1
			var error := output_array[i].rsplit(":", true, 1)
			if len(error) > 1:
				_dock_ui.create_item(current_line + 1, error[1])
				if _dock_ui.is_error_ignored(error[1]):
					continue
				highlight_lines.append(current_line)

	_dock_ui.set_problems_label(_dock_ui.num_problems)
	_dock_ui.set_ignored_problems_label(_dock_ui.num_ignored_problems)

	# Error, no Ignore
	if _dock_ui.num_problems > 0 and _dock_ui.num_ignored_problems <= 0:
		bottom_panel_button.icon = icon_error
	# no Error, Ignore
	elif _dock_ui.num_problems <= 0 and _dock_ui.num_ignored_problems > 0:
		bottom_panel_button.icon = icon_ignore
	# Error, Ignore
	elif _dock_ui.num_problems > 0 and _dock_ui.num_ignored_problems > 0:
		bottom_panel_button.icon = icon_error_ignore
	else:
		bottom_panel_button.icon = null
	_dock_ui.script_text_editor = EditorInterface.get_script_editor().get_current_editor()


func set_line_color(color: Color) -> void:
	var current_code_editor := get_current_editor()
	if current_code_editor == null:
		return

	for line: int in highlight_lines:
		# Skip line if this one is from the old code editor
		if line > current_code_editor.get_line_count() - 1:
			continue
		# Skip if something else is highlighted
		if current_code_editor.get_line_background_color(line) != NO_COLOR and color != NO_COLOR:
			continue

		current_code_editor.set_line_background_color(line, color.darkened(0.5))


func clear_highlights() -> void:
	set_line_color(NO_COLOR)
	highlight_lines.clear()


func get_current_editor() -> CodeEdit:
	var current_editor := EditorInterface.get_script_editor().get_current_editor()
	if current_editor == null:
		return
	return current_editor.get_base_editor() as CodeEdit


func get_gdlint_path() -> String:
	# get from settings
	var gdlint_path: String = EditorInterface.get_editor_settings()\
		.get_setting(SETTINGS_GDLINT_PATH).strip_edges()
	if not gdlint_path.is_empty():
		return gdlint_path

	if OS.get_name() == "Windows":
		return "gdlint"

	# macOS & Linux
	var output := []
	OS.execute("python3", ["-m", "site", "--user-base"], output)
	var python_bin_folder := (output[0] as String).strip_edges().path_join("bin")
	if FileAccess.file_exists(python_bin_folder.path_join("gdlint")):
		return python_bin_folder.path_join("gdlint")

	# Linux dirty hardcoded fallback
	if OS.get_name() == "Linux":
		if FileAccess.file_exists("/usr/bin/gdlint"):
			return "/usr/bin/gdlint"

	# Global fallback
	return "gdlint"
