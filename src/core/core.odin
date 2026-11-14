package gfcore

import "base:runtime"
import "core:c/libc"
import "core:fmt"
import "core:io"
import "core:mem"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:sync"
import "core:time"

// ============================================================================
// Core Types
// ============================================================================

FileType :: enum u8 {
	Unknown   = 0,
	Regular   = 1,
	Directory = 2,
	Symlink   = 3,
}

FileInfo :: struct {
	name:      [256]u8,
	name_len:  u32,
	path:      [1024]u8,
	path_len:  u32,
	size:      i64,
	modified:  i64,
	file_type: FileType,
	is_hidden: bool,
}

OperationStatus :: enum i32 {
	Success          = 0,
	ErrorNotFound    = -1,
	ErrorPermission  = -2,
	ErrorExists      = -3,
	ErrorIO          = -4,
	ErrorInvalidPath = -5,
	Cancelled        = -6,
	ErrorUnknown     = -100,
}

// ============================================================================
// Internal Helpers
// ============================================================================

// errno values shared by Linux and FreeBSD
@(private) EPERM :: 1
@(private) ENOENT :: 2
@(private) EACCES :: 13
@(private) EEXIST :: 17
@(private) EXDEV :: 18

// Maps an os error to a status, keeping the reason (not "everything is ErrorIO / ErrorExists").
status_of :: proc(err: os.Error) -> OperationStatus {
	if err == nil do return .Success
	#partial switch e in err {
	case os.General_Error:
		#partial switch e {
		case .Exist:        return .ErrorExists
		case .Not_Exist:    return .ErrorNotFound
		case .Invalid_Path: return .ErrorInvalidPath
		}
	case io.Error:
		if e == .Permission_Denied do return .ErrorPermission
	case os.Platform_Error:
		switch i32(e) {
		case EPERM, EACCES: return .ErrorPermission
		case EEXIST:        return .ErrorExists
		case ENOENT:        return .ErrorNotFound
		}
	}
	return .ErrorIO
}

// rename(2) failed only because src and dst are on different filesystems.
is_cross_device :: proc(err: os.Error) -> bool {
	e, ok := err.(os.Platform_Error)
	return ok && i32(e) == EXDEV
}

// ok=false when the path does not fit the fixed C-ABI buffer (names always fit: NAME_MAX is 255).
file_info_from_os :: proc(path: string, info: os.File_Info) -> (fi: FileInfo, ok: bool) {
	name := filepath.base(path)
	if len(name) > len(fi.name) || len(path) > len(fi.path) do return
	mem.copy(&fi.name[0], raw_data(name), len(name))
	fi.name_len = u32(len(name))
	mem.copy(&fi.path[0], raw_data(path), len(path))
	fi.path_len = u32(len(path))

	fi.size = info.size
	fi.modified = time.time_to_unix_nano(info.modification_time)

	// Check if directory using type field
	#partial switch info.type {
	case .Directory:
		fi.file_type = .Directory
	case .Symlink:
		fi.file_type = .Symlink
	case .Regular:
		fi.file_type = .Regular
	case:
		fi.file_type = .Unknown
	}

	fi.is_hidden = len(name) > 0 && name[0] == '.'
	return fi, true
}

// ============================================================================
// Core File Operations
// ============================================================================

// The returned slice is temp-allocated: valid until the caller frees the temp allocator
// (once per frame in the GUI, at exit in the CLI). Entries whose path is longer than
// FileInfo.path (1024 bytes) are left out rather than truncated into a wrong path.
// (`context.allocator = ...` only changes this procedure's copy of the context: callers are unaffected.)
list_directory :: proc(path: string) -> ([]FileInfo, OperationStatus) {
	context.allocator = context.temp_allocator

	handle, err := os.open(path, os.O_RDONLY)
	if err != nil {
		return nil, status_of(err)
	}
	defer os.close(handle)

	file_infos, read_err := os.read_dir(handle, -1, context.allocator)
	if read_err != nil {
		return nil, status_of(read_err)
	}

	results := make([dynamic]FileInfo, 0, len(file_infos))
	for info in file_infos {
		full_path, join_err := filepath.join({path, info.name}, context.temp_allocator)
		if join_err != nil do continue
		if fi, ok := file_info_from_os(full_path, info); ok do append(&results, fi)
	}
	return results[:], .Success
}

copy_file :: proc(src: string, dst: string) -> OperationStatus {
	if path_exists(dst) {
		return .ErrorExists
	}
	context.allocator = context.temp_allocator
	info, stat_err := os.stat(src, context.allocator)
	if stat_err != nil {
		return .ErrorNotFound
	}
	// note: the os package takes (dst, src); this package's procedures are all (src, dst)
	err := os.copy_directory_all(dst, src) if info.type == .Directory else os.copy_file(dst, src)
	return status_of(err)
}

move_file :: proc(src: string, dst: string) -> OperationStatus {
	err := os.rename(src, dst)
	if err != nil {
		// only a move across filesystems becomes copy + delete; other failures
		// (permissions, bad path, full disk) are reported as they are
		if !is_cross_device(err) do return status_of(err)
		copy_status := copy_file(src, dst)
		if copy_status != .Success {
			return copy_status
		}

		del_err := os.remove_all(src)
		if del_err != nil {
			return .ErrorIO
		}
	}

	return .Success
}

// Recursive: callers (CLI prompt, GUI dialog) confirm first.
delete_path :: proc(path: string) -> OperationStatus {
	context.allocator = context.temp_allocator
	info, stat_err := os.lstat(path, context.allocator)
	if stat_err != nil {
		return .ErrorNotFound
	}
	// remove_all would follow a symlink to a dir and empty its target
	err := os.remove(path) if info.type == .Symlink else os.remove_all(path)
	return status_of(err)
}

rename_path :: proc(old_path: string, new_path: string) -> OperationStatus {
	return status_of(os.rename(old_path, new_path))
}

create_directory :: proc(path: string) -> OperationStatus {
	return status_of(os.make_directory(path))
}

path_exists :: proc(path: string) -> bool {
	_, err := os.stat(path, context.temp_allocator)
	return err == nil
}

get_file_info :: proc(path: string) -> (FileInfo, OperationStatus) {
	info, err := os.stat(path, context.temp_allocator)
	if err != nil {
		return {}, status_of(err)
	}
	fi, ok := file_info_from_os(path, info)
	if !ok do return {}, .ErrorInvalidPath // too long for the C ABI buffer
	return fi, .Success
}

// ============================================================================
// Trash (freedesktop.org Trash spec, same layout GNOME Files uses)
// ============================================================================

// Returns $XDG_DATA_HOME/Trash (usually ~/.local/share/Trash).
trash_dir :: proc(allocator := context.allocator) -> string {
	data, err := os.user_data_dir(context.temp_allocator)
	if err != nil {
		return ""
	}
	dir, _ := filepath.join({data, "Trash"}, allocator)
	return dir
}

@(private)
url_escape :: proc(s: string) -> string {
	b := strings.builder_make(context.temp_allocator)
	for i in 0 ..< len(s) {
		ch := s[i]
		switch ch {
		case 'A' ..= 'Z', 'a' ..= 'z', '0' ..= '9', '-', '.', '_', '~', '/':
			strings.write_byte(&b, ch)
		case:
			fmt.sbprintf(&b, "%%%02X", ch)
		}
	}
	return strings.to_string(b)
}

@(private)
url_unescape :: proc(s: string) -> string {
	b := strings.builder_make(context.temp_allocator)
	hex :: proc(c: u8) -> int {
		switch c {
		case '0' ..= '9': return int(c - '0')
		case 'a' ..= 'f': return int(c - 'a' + 10)
		case 'A' ..= 'F': return int(c - 'A' + 10)
		}
		return -1
	}
	for i := 0; i < len(s); i += 1 {
		if s[i] == '%' && i + 2 < len(s) && hex(s[i + 1]) >= 0 && hex(s[i + 2]) >= 0 {
			strings.write_byte(&b, u8(hex(s[i + 1]) * 16 + hex(s[i + 2])))
			i += 2
		} else {
			strings.write_byte(&b, s[i])
		}
	}
	return strings.to_string(b)
}

// Moves path into the trash, writing the matching .trashinfo.
trash_path :: proc(path: string) -> OperationStatus {
	st, _ := trash_path_named(path)
	return st
}

// Like trash_path, also returning the name inside Trash/files (temp-allocated) for undo.
trash_path_named :: proc(path: string) -> (OperationStatus, string) {
	context.allocator = context.temp_allocator
	td := trash_dir()
	if td == "" {
		return .ErrorIO, ""
	}
	files, _ := filepath.join({td, "files"})
	info, _ := filepath.join({td, "info"})
	os.make_directory_all(files)
	os.make_directory_all(info)

	abs, abs_err := os.get_absolute_path(path, context.allocator)
	if abs_err != nil || !path_exists(abs) {
		return .ErrorNotFound, ""
	}
	base := filepath.base(abs)
	name := base
	for i := 2; ; i += 1 {
		f, _ := filepath.join({files, name})
		n, _ := filepath.join({info, strings.concatenate({name, ".trashinfo"})})
		if !path_exists(f) && !path_exists(n) {
			break
		}
		name = fmt.tprintf("%s.%d", base, i)
	}

	now := libc.time(nil)
	t := libc.localtime(&now)
	content := fmt.tprintf(
		"[Trash Info]\nPath=%s\nDeletionDate=%04d-%02d-%02dT%02d:%02d:%02d\n",
		url_escape(abs), t.tm_year + 1900, t.tm_mon + 1, t.tm_mday, t.tm_hour, t.tm_min, t.tm_sec,
	)
	info_path, _ := filepath.join({info, strings.concatenate({name, ".trashinfo"})})
	if os.write_entire_file_from_string(info_path, content) != nil {
		return .ErrorPermission, ""
	}
	dst, _ := filepath.join({files, name})
	if os.rename(abs, dst) != nil {
		// shortcut: no per-volume trash, so files on other filesystems can't be trashed.
		// The file is left untouched and ErrorIO returned; deleting it instead is the
		// caller's (the user's) decision — the GUI suggests Shift+Delete.
		os.remove(info_path)
		return .ErrorIO, ""
	}
	return .Success, name
}

// Puts a trashed item (name inside Trash/files) back where it came from.
restore_from_trash :: proc(name: string) -> OperationStatus {
	context.allocator = context.temp_allocator
	td := trash_dir()
	info_path, _ := filepath.join({td, "info", strings.concatenate({name, ".trashinfo"})})
	data, err := os.read_entire_file_from_path(info_path, context.allocator)
	if err != nil {
		return .ErrorNotFound
	}
	orig := ""
	text := string(data)
	for line in strings.split_lines_iterator(&text) {
		if strings.has_prefix(line, "Path=") {
			orig = url_unescape(line[5:])
		}
	}
	if orig == "" {
		return .ErrorInvalidPath
	}
	if path_exists(orig) {
		return .ErrorExists
	}
	os.make_directory_all(filepath.dir(orig))
	src, _ := filepath.join({td, "files", name})
	if os.rename(src, orig) != nil {
		return .ErrorIO
	}
	os.remove(info_path)
	return .Success
}

// Permanently deletes one trashed item and its .trashinfo.
delete_from_trash :: proc(name: string) -> OperationStatus {
	return delete_trashed(trash_dir(context.temp_allocator), name)
}

@(private)
delete_trashed :: proc(td, name: string) -> OperationStatus {
	context.allocator = context.temp_allocator
	src, _ := filepath.join({td, "files", name})
	status := delete_path(src)
	info_path, _ := filepath.join({td, "info", strings.concatenate({name, ".trashinfo"})})
	os.remove(info_path)
	return status
}

empty_trash :: proc() -> OperationStatus {
	context.allocator = context.temp_allocator
	td := trash_dir()
	files, _ := filepath.join({td, "files"})
	infos, err := os.read_all_directory_by_path(files, context.allocator)
	if err != nil {
		return .Success
	}
	result := OperationStatus.Success
	for fi in infos {
		if delete_trashed(td, fi.name) != .Success {
			result = .ErrorPermission
		}
	}
	return result
}

// ============================================================================
// Copy with progress and cancellation (used by the GUI's background operations)
// ============================================================================

// Shared with a worker thread: read/write the fields with sync atomics.
// total is set by the caller (from tree_size) before copying; copy_tree only adds to done.
Progress :: struct {
	total, done: i64,
	cancel:      bool,
}

// Total bytes under path (symlinks are not followed).
tree_size :: proc(path: string, p: ^Progress = nil) -> i64 {
	context.allocator = context.temp_allocator
	info, err := os.lstat(path, context.allocator)
	if err != nil do return 0
	if info.type != .Directory do return info.size
	infos, rerr := os.read_all_directory_by_path(path, context.allocator)
	if rerr != nil do return 0
	n: i64
	for fi in infos {
		if p != nil && sync.atomic_load(&p.cancel) do return n
		n += tree_size(fi.fullpath, p)
	}
	return n
}

// Recursively copies src to dst (dst must not exist), streaming file data so
// progress can be reported and the copy cancelled between chunks. A read or write
// error fails the copy and removes the partial file: a move deletes the source only
// after this returns .Success, so a short copy must never look like a finished one.
copy_tree :: proc(src, dst: string, p: ^Progress) -> OperationStatus {
	buf := make([]byte, 1 << 20) // one buffer for the whole tree, not one per file
	defer delete(buf)
	return copy_tree_buf(src, dst, p, buf)
}

@(private)
copy_tree_buf :: proc(src, dst: string, p: ^Progress, buf: []byte) -> OperationStatus {
	if sync.atomic_load(&p.cancel) do return .Cancelled
	info, err := os.lstat(src, context.temp_allocator)
	if err != nil do return status_of(err)
	if path_exists(dst) do return .ErrorExists
	#partial switch info.type {
	case .Directory:
		if e := os.make_directory(dst); e != nil do return status_of(e)
		os.change_mode(dst, info.mode)
		infos, rerr := os.read_all_directory_by_path(src, context.temp_allocator)
		if rerr != nil do return status_of(rerr)
		for fi in infos {
			// each child's temp memory (paths, listings) is released before the next one
			runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
			d, _ := filepath.join({dst, fi.name}, context.temp_allocator)
			if st := copy_tree_buf(fi.fullpath, d, p, buf); st != .Success do return st
		}
		return .Success
	case .Symlink:
		target, lerr := os.read_link(src, context.temp_allocator)
		if lerr != nil do return status_of(lerr)
		return status_of(os.symlink(target, dst))
	}
	in_f, oerr := os.open(src)
	if oerr != nil do return status_of(oerr)
	defer os.close(in_f)
	out_f, cerr := os.open(dst, {.Write, .Create, .Excl, .Trunc}, info.mode)
	if cerr != nil do return status_of(cerr)
	fail :: proc(out_f: ^os.File, dst: string, st: OperationStatus) -> OperationStatus {
		os.close(out_f)
		os.remove(dst) // drop the half-written file only
		return st
	}
	for {
		if sync.atomic_load(&p.cancel) do return fail(out_f, dst, .Cancelled)
		n, rerr := os.read(in_f, buf)
		if n > 0 {
			if w, werr := os.write(out_f, buf[:n]); werr != nil || w != n do return fail(out_f, dst, .ErrorIO)
			sync.atomic_add(&p.done, i64(n))
		}
		if rerr == io.Error.EOF || (rerr == nil && n == 0) do break
		if rerr != nil do return fail(out_f, dst, .ErrorIO) // a failed read is not the end of the file
	}
	// close reports delayed write errors (full disk, network filesystems)
	if os.close(out_f) != nil {
		os.remove(dst)
		return .ErrorIO
	}
	return .Success
}
