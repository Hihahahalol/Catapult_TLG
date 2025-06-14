extends Node


signal copy_dir_done
signal rm_dir_done
signal move_dir_done
signal extract_done
signal zip_done


var _platform: String = ""

var last_extract_result: int = 0 setget , _get_last_extract_result
# Stores the exit code of the last extract operation (0 if successful).
var last_zip_result: int = 0 setget , _get_last_zip_result
# Stores the exit code of the last zip operation (0 if successful).


func _enter_tree() -> void:
	
	_platform = OS.get_name()


func _get_last_extract_result() -> int:
	
	return last_extract_result


func _get_last_zip_result() -> int:
	return last_zip_result
	

func list_dir(path: String, recursive := false) -> Array:
	# Lists the files and subdirectories within a directory.
	
	var d = Directory.new()
	d.open(path)
	
	var error = d.list_dir_begin(true)
	if error:
		Status.post(tr("msg_list_dir_failed") % [path, error], Enums.MSG_ERROR)
		return []
	
	var result = []
	
	while true:
		var name = d.get_next()
		if name:
			result.append(name)
			if recursive and d.current_is_dir():
				var subdir = list_dir(path.plus_file(name), true)
				for child in subdir:
					result.append(name.plus_file(child))
		else:
			break
	
	return result


func _copy_dir_internal(data: Array) -> void:
	
	var abs_path: String = data[0]
	var dest_dir: String = data[1]
	
	var dir = abs_path.get_file()
	var d = Directory.new()
	
	var error = d.make_dir_recursive(dest_dir.plus_file(dir))
	if error:
		Status.post(tr("msg_cannot_create_target_dir") % [dest_dir.plus_file(dir), error], Enums.MSG_ERROR)
		return
	
	for item in list_dir(abs_path):
		var path = abs_path.plus_file(item)
		if d.file_exists(path):
			error = d.copy(path, dest_dir.plus_file(dir).plus_file(item))
			if error:
				Status.post(tr("msg_copy_file_failed") % [item, error], Enums.MSG_ERROR)
				Status.post(tr("msg_copy_file_failed_details") % [path, dest_dir.plus_file(dir).plus_file(item)])
		elif d.dir_exists(path):
			_copy_dir_internal([path, dest_dir.plus_file(dir)])


func copy_dir(abs_path: String, dest_dir: String) -> void:
	# Recursively copies a directory *into* a new location.
	
	var tfe = ThreadedFuncExecutor.new()
	tfe.execute(self, "_copy_dir_internal", [abs_path, dest_dir])
	yield(tfe, "func_returned")
	tfe.collect()
	emit_signal("copy_dir_done")


func _rm_dir_internal(data: Array) -> void:
	
	var abs_path = data[0]
	var d = Directory.new()
	var error
	
	for item in list_dir(abs_path):
		var path = abs_path.plus_file(item)
		if d.file_exists(path):
			error = d.remove(path)
			if error:
				Status.post(tr("msg_remove_file_failed") % [item, error], Enums.MSG_ERROR)
				Status.post(tr("msg_remove_file_failed_details") % path, Enums.MSG_DEBUG)
		elif d.dir_exists(path):
			_rm_dir_internal([path])
	
	error = d.remove(abs_path)
	if error:
		Status.post(tr("msg_rm_dir_failed") % [abs_path, error], Enums.MSG_ERROR)


func rm_dir(abs_path: String) -> void:
	# Recursively removes a directory.
	
	var tfe = ThreadedFuncExecutor.new()
	tfe.execute(self, "_rm_dir_internal", [abs_path])
	yield(tfe, "func_returned")
	tfe.collect()
	emit_signal("rm_dir_done")


func _move_dir_internal(data: Array) -> void:
	
	var abs_path: String = data[0]
	var abs_dest: String = data[1]
	
	var d = Directory.new()
	var error = d.make_dir_recursive(abs_dest)
	if error:
		Status.post(tr("msg_create_dir_failed") % [abs_dest, error], Enums.MSG_ERROR)
		return
	
	for item in list_dir(abs_path):
		var path = abs_path.plus_file(item)
		var dest = abs_dest.plus_file(item)
		if d.file_exists(path):
			error = d.rename(path, abs_dest.plus_file(item))
			if error:
				Status.post(tr("msg_move_file_failed") % [item, error], Enums.MSG_ERROR)
				Status.post(tr("msg_move_file_failed_details") % [path, dest])
		elif d.dir_exists(path):
			_move_dir_internal([path, abs_dest.plus_file(item)])
	
	error = d.remove(abs_path)
	if error:
		Status.post(tr("msg_move_rmdir_failed") % [abs_path, error], Enums.MSG_ERROR)


func move_dir(abs_path: String, abs_dest: String) -> void:
	# Moves the specified directory (this is move with rename, so the last
	# part of dest is the new name for the directory).
	
	var tfe = ThreadedFuncExecutor.new()
	tfe.execute(self, "_move_dir_internal", [abs_path, abs_dest])
	yield(tfe, "func_returned")
	tfe.collect()
	emit_signal("move_dir_done")


func extract(path: String, dest_dir: String) -> void:
	# Extracts a .zip or .tar.gz archive using 7-Zip on Windows and Linux
	# Falls back to system utilities on Linux if 7-Zip is not available.
	
	var sevenzip_exe
	if OS.get_name() == "Windows":
		sevenzip_exe = Paths.utils_dir.plus_file("7za.exe")
	else:  # Linux (X11)
		sevenzip_exe = Paths.utils_dir.plus_file("7za")
	
	var command_linux_zip = {
		"name": "unzip",
		"args": ["-o", "%s" % path, "-d", "%s" % dest_dir]
	}
	var command_linux_gz = {
		"name": "tar",
		"args": ["-xzf", path, "-C", dest_dir,
				"--exclude=*doc/CONTRIBUTING.md", "--exclude=*doc/JSON_LOADING_ORDER.md"]
				# Godot can't operate on symlinks just yet, so we have to avoid them.
	}
	var command_sevenzip_windows = {
		"name": "cmd",
		"args": ["/C", "\"%s\" x \"%s\" -o\"%s\" -y" % [sevenzip_exe.replace("/", "\\"), path.replace("/", "\\"), dest_dir.replace("/", "\\")]]
	}
	var command_sevenzip_linux = {
		"name": "/bin/bash",
		"args": ["-c", "'%s' x '%s' -o'%s' -y" % [sevenzip_exe, path, dest_dir]]
	}
	var command
	
	var d = Directory.new()
	
	# On Linux, prefer system utilities for better compatibility
	if (_platform == "X11") and (path.to_lower().ends_with(".tar.gz")):
		Status.post("[debug] Using system tar for .tar.gz extraction")
		command = command_linux_gz
	elif (_platform == "X11") and (path.to_lower().ends_with(".zip")):
		Status.post("[debug] Using system unzip for .zip extraction")
		command = command_linux_zip
	# Try to use 7-Zip on both platforms as fallback
	elif d.file_exists(sevenzip_exe) and (path.to_lower().ends_with(".zip") or path.to_lower().ends_with(".tar.gz")):
		Status.post("[debug] Extracting: " + path + " to: " + dest_dir)
		if OS.get_name() == "Windows":
			command = command_sevenzip_windows
		else:  # Linux (X11)
			command = command_sevenzip_linux
	elif (_platform == "Windows") and (path.to_lower().ends_with(".zip")):
		# On Windows, 7-Zip should always be available
		if not d.file_exists(sevenzip_exe):
			Status.post("[error] 7za.exe not found at: " + sevenzip_exe, Enums.MSG_ERROR)
			emit_signal("extract_done")
			return
		Status.post("[debug] Extracting: " + path + " to: " + dest_dir)
		command = command_sevenzip_windows
	else:
		Status.post(tr("msg_extract_unsupported") % path.get_file(), Enums.MSG_ERROR)
		emit_signal("extract_done")
		return
		
	if not d.dir_exists(dest_dir):
		d.make_dir_recursive(dest_dir)
		
	Status.post(tr("msg_extracting_file") % path.get_file())
	Status.post("[debug] Extract command: " + str(command), Enums.MSG_DEBUG)
		
	var oew = OSExecWrapper.new()
	oew.execute(command["name"], command["args"], false)
	yield(oew, "process_exited")
	last_extract_result = oew.exit_code
	if oew.exit_code:
		Status.post(tr("msg_extract_error") % oew.exit_code, Enums.MSG_ERROR)
		Status.post(tr("msg_extract_failed_cmd") % str(command), Enums.MSG_DEBUG)
		if oew.output.size() > 0:
			for i in range(oew.output.size()):
				Status.post("[7-Zip output] " + str(oew.output[i]), Enums.MSG_ERROR)
		else:
			Status.post("[7-Zip] No output captured", Enums.MSG_ERROR)
	emit_signal("extract_done")


func zip(parent: String, dir_to_zip: String, dest_zip: String) -> void:
	# Creates a .zip using 7-Zip on Windows and Linux for better performance.
	# Falls back to system zip on Linux if 7-Zip is not available.
	# parent: directory that zip command is run from  (Path.savegames)
	# dir_to_zip: relative folder to zip up  (world_name)
	# dest_zip: zip name   (world_name.zip)
	# 
	# runs a command like:
	# cd <userdata/save> && 7za a MyWorld.zip MyWorld
	
	var sevenzip_exe
	if OS.get_name() == "Windows":
		sevenzip_exe = Paths.utils_dir.plus_file("7za.exe")
	else:  # Linux (X11)
		sevenzip_exe = Paths.utils_dir.plus_file("7za")
	
	var command_linux_zip = {
		"name": "/bin/bash",
		"args": ["-c", "cd '%s' && zip -r '%s' '%s'" % [parent, dest_zip, dir_to_zip]]
	}
	var command_sevenzip_windows = {
		"name": "cmd",
		"args": ["/C", "cd /d \"%s\" && \"%s\" a \"%s\" \"%s\" -mx5" % [parent, sevenzip_exe, dest_zip, dir_to_zip]]
	}
	var command_sevenzip_linux = {
		"name": "/bin/bash",
		"args": ["-c", "cd '%s' && '%s' a '%s' '%s' -mx5" % [parent, sevenzip_exe, dest_zip, dir_to_zip]]
	}
	var command
	
	var d = Directory.new()
	
	if not dest_zip.to_lower().ends_with(".zip"):
		Status.post(tr("msg_extract_unsupported") % dest_zip.get_file(), Enums.MSG_ERROR)
		emit_signal("zip_done")
		return
	
	# Try to use 7-Zip first for better performance
	if d.file_exists(sevenzip_exe):
		if OS.get_name() == "Windows":
			command = command_sevenzip_windows
		else:  # Linux (X11)
			command = command_sevenzip_linux
	# Fall back to system zip on Linux
	elif _platform == "X11":
		Status.post("[debug] Using system zip for compression")
		command = command_linux_zip
	else:
		Status.post(tr("msg_extract_unsupported") % dest_zip.get_file(), Enums.MSG_ERROR)
		emit_signal("zip_done")
		return
	
	Status.post(tr("msg_zipping_file") % dest_zip.get_file())
		
	var oew = OSExecWrapper.new()
	oew.execute(command["name"], command["args"], false)
	yield(oew, "process_exited")
	last_zip_result = oew.exit_code
	if oew.exit_code:
		Status.post(tr("msg_zip_error") % oew.exit_code, Enums.MSG_ERROR)
		Status.post(tr("msg_extract_failed_cmd") % str(command), Enums.MSG_DEBUG)
		if oew.output.size() > 0:
			Status.post(tr("msg_extract_fail_output") % oew.output[0], Enums.MSG_DEBUG)
	emit_signal("zip_done")
	