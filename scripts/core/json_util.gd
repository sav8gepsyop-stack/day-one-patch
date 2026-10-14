class_name JsonUtil
extends RefCounted
## Small helpers for the data-driven content in res://data.


static func load_file(path: String) -> Variant:
	if not FileAccess.file_exists(path):
		push_error("JSON file missing: %s" % path)
		return null
	var json := JSON.new()
	var err := json.parse(FileAccess.get_file_as_string(path))
	if err != OK:
		push_error("JSON parse error in %s (line %d): %s" % [path, json.get_error_line(), json.get_error_message()])
		return null
	return json.data


static func list_json(dir_path: String) -> PackedStringArray:
	var out := PackedStringArray()
	var dir := DirAccess.open(dir_path)
	if dir == null:
		push_error("Data directory missing: %s" % dir_path)
		return out
	for f in dir.get_files():
		if f.ends_with(".json"):
			out.append(dir_path.path_join(f))
	out.sort()
	return out


static func write_file(path: String, data: Variant) -> bool:
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		push_error("Cannot write %s" % path)
		return false
	f.store_string(JSON.stringify(data, "  ", true))
	return true


static func color(hex: String, fallback := Color.WHITE) -> Color:
	if hex.is_empty():
		return fallback
	return Color.html(hex) if Color.html_is_valid(hex) else fallback


static func vec3(arr: Variant) -> Vector3:
	if arr is Array and arr.size() >= 3:
		return Vector3(float(arr[0]), float(arr[1]), float(arr[2]))
	return Vector3.ZERO
