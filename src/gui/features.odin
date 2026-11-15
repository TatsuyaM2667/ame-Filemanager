package main

// Things other file managers have that make daily use nicer:
// - New empty file (Nautilus / Dolphin "New Document")
// - Select by pattern, e.g. "*.jpg *.png" (Nautilus Ctrl+S)
// - Paste an image or text from the clipboard as a new file (Windows / macOS)
// - Tab completion in the path bar (Dolphin, shells)
// - Item counts for folders in list view (Nautilus, Finder)
// - Free space of the current drive at the bottom of the sidebar (Dolphin, Finder)

import "core:c/libc"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:sys/posix"
import "core:mem/virtual"
import "core:time"
import "core:sync"
import "core:thread"
import gf "../core"

// ---------------------------------------------------------------------------
// New empty file

begin_new_file :: proc() {
	if in_trash() || is_tag_view() do return
	app.dialog = .New_File
	edit_set(&app.dlg_edit, "新しいテキスト.txt")
	app.dlg_edit.anchor = 0
	app.dlg_edit.cur = len("新しいテキスト") // name selected, extension kept
	app.edit_focus = .Dialog
}

new_file_ok :: proc() {
	name := strings.trim_space(edit_str(&app.dlg_edit))
	if name_problem(name) != "" do return
	path := full_path(name)
	fd := posix.open(strings.clone_to_cstring(path, context.temp_allocator), {.WRONLY, .CREAT, .EXCL, .CLOEXEC}, {.IRUSR, .IWUSR, .IRGRP, .IROTH})
	if fd < 0 {
		toastf("ファイルを作成できません")
		return
	}
	posix.close(fd)
	push_undo(.Mkdir, {{"", path}}) // undo removes it only while still empty
	app.dialog = .None
	select_after_reload(name)
}

// Reloads and selects (and scrolls to) the item with this name.
select_after_reload :: proc(name: string) {
	n := strings.clone(name, context.temp_allocator)
	reload()
	clear_sel()
	for k in 0 ..< len(app.view) do if app.entries[app.view[k]].name == n {
		app.entries[app.view[k]].sel = true
		app.focus, app.anchor = k, k
		ensure_visible(k)
	}
}

// ---------------------------------------------------------------------------
// Select by pattern

begin_select_pattern :: proc() {
	app.dialog = .Select_Pattern
	edit_set(&app.dlg_edit, "*.", false)
	app.edit_focus = .Dialog
}

// Space or comma separated globs, case-insensitive ("*.JPG" matches "a.jpg").
pattern_matches :: proc(patterns, name: string) -> bool {
	low := strings.to_lower(filepath.base(name), context.temp_allocator)
	spaced, _ := strings.replace_all(patterns, ",", " ", context.temp_allocator)
	for p in strings.fields(strings.to_lower(spaced, context.temp_allocator), context.temp_allocator) {
		if ok, _ := filepath.match(p, low); ok do return true
	}
	return false
}

select_pattern_ok :: proc() {
	pat := strings.trim_space(edit_str(&app.dlg_edit))
	if pat == "" do return
	n := 0
	first := -1
	for vi, k in app.view {
		e := &app.entries[vi]
		e.sel = pattern_matches(pat, e.name)
		if e.sel {
			n += 1
			if first < 0 do first = k
		}
	}
	app.dialog = .None
	if first >= 0 {
		app.focus, app.anchor = first, first
		ensure_visible(first)
	}
	toastf("%d 個を選択しました", n)
}

// ---------------------------------------------------------------------------
// Paste an image / text from the clipboard as a file

@(private = "file")
stamp :: proc() -> string {
	now := libc.time(nil)
	tm := libc.localtime(&now)^
	return fmt.tprintf("%d-%02d-%02d %02d.%02d.%02d", tm.tm_year + 1900, tm.tm_mon + 1, tm.tm_mday, tm.tm_hour, tm.tm_min, tm.tm_sec)
}

// Called by paste when the clipboard holds no files. True if something was saved.
paste_as_file :: proc() -> bool {
	if in_trash() || is_tag_view() do return false
	data := plat_get_clipboard_image()
	label, ext := "貼り付けた画像", ".png"
	if len(data) == 0 {
		text := plat_get_clipboard_text()
		if strings.trim_space(text) == "" do return false
		data = transmute([]u8)text
		label, ext = "貼り付けたテキスト", ".txt"
	}
	path := unique_dest(app.cwd, strings.concatenate({label, " ", stamp(), ext}, context.temp_allocator))
	if err := os.write_entire_file(path, data); err != nil {
		toastf("保存できません")
		return true
	}
	push_undo(.Copy, {{"", path}}) // undo moves it to the trash
	select_after_reload(filepath.base(path))
	toastf("「%s」として保存しました", filepath.base(path))
	return true
}

// ---------------------------------------------------------------------------
// Tab completion in the path bar

path_complete :: proc() {
	text := edit_str(&app.path_edit)
	tilde := strings.has_prefix(text, "~")
	full := strings.concatenate({app.home, text[1:]}, context.temp_allocator) if tilde else text
	slash := strings.last_index_byte(full, '/')
	if slash < 0 do return
	dir, prefix := full[:slash + 1], full[slash + 1:]
	infos, err := os.read_all_directory_by_path(dir if dir != "" else "/", context.temp_allocator)
	if err != nil do return
	matches := make([dynamic]string, context.temp_allocator)
	for fi in infos {
		if fi.type != .Directory do continue
		if strings.has_prefix(fi.name, ".") && !strings.has_prefix(prefix, ".") do continue
		if strings.has_prefix(fi.name, prefix) do append(&matches, fi.name)
	}
	if len(matches) == 0 { // then case-insensitively
		lp := strings.to_lower(prefix, context.temp_allocator)
		for fi in infos {
			if fi.type == .Directory && strings.has_prefix(strings.to_lower(fi.name, context.temp_allocator), lp) do append(&matches, fi.name)
		}
	}
	if len(matches) == 0 do return
	common := matches[0]
	for m in matches[1:] {
		n := 0
		for n < len(common) && n < len(m) && common[n] == m[n] do n += 1
		common = common[:n]
	}
	done := len(matches) == 1
	if !done && len(common) <= len(prefix) {
		shown := matches[:min(len(matches), 6)]
		toastf("%s%s", strings.join(shown, "  ", context.temp_allocator), " …" if len(matches) > 6 else "")
		return
	}
	out := strings.concatenate({dir, matches[0] if done else common, "/" if done else ""}, context.temp_allocator)
	if tilde do out = strings.concatenate({"~", out[len(app.home):]}, context.temp_allocator)
	edit_set(&app.path_edit, out)
}

// ---------------------------------------------------------------------------
// Item counts for folders (list view)

@(private = "file") counts: map[string]int // cleared on every reload

dir_counts_clear :: proc() {
	for k in counts do delete(k)
	clear(&counts)
}

// Entries in a folder (hidden ones only when shown), -1 if unreadable. Names only: no stat.
dir_count :: proc(path: string) -> int {
	if n, ok := counts[path]; ok do return n
	n := -1
	if d := posix.opendir(strings.clone_to_cstring(path, context.temp_allocator)); d != nil {
		n = 0
		for n < 100_000 {
			ent := posix.readdir(d)
			if ent == nil do break
			name := cstring(&ent.d_name[0])
			if name == "." || name == ".." do continue
			if !app.show_hidden && ent.d_name[0] == '.' do continue
			n += 1
		}
		posix.closedir(d)
	}
	counts[strings.clone(path)] = n
	return n
}

// ---------------------------------------------------------------------------
// Free space of the drive the current folder is on (bottom of the sidebar)

@(private = "file") space: struct {
	path:        string,
	at:          i64,
	free, total: u64,
	ok:          bool,
}

draw_free_space :: proc(w, H: f32) {
	if app.cwd != space.path || ticks_ms() - space.at > 10_000 {
		delete(space.path)
		space.path = strings.clone(app.cwd)
		space.at = ticks_ms()
		st: posix.statvfs_t
		space.ok = !is_tag_view() && posix.statvfs(strings.clone_to_cstring(app.cwd, context.temp_allocator), &st) == .OK
		if space.ok {
			space.free = u64(st.f_bavail) * u64(st.f_frsize)
			space.total = u64(st.f_blocks) * u64(st.f_frsize)
		}
	}
	if !space.ok || space.total == 0 do return
	r := Rect{0, H - px(52), w, px(52)}
	fill(r, hex(0x0b0f1a, 200))
	fill({px(12), r.y, w - px(24), 1}, LINE)
	label := fmt.tprintf("空き %s / %s", format_size(i64(space.free)), format_size(i64(space.total)))
	text(px(18), r.y + px(22), label, fs(12), DIM)
	used := 1 - f32(f64(space.free) / f64(space.total))
	bar := Rect{px(18), r.y + px(32), w - px(36), px(6)}
	rrect(bar, px(3), hex(0xffffff, 25))
	rrect({bar.x, bar.y, max(bar.h, bar.w * used), bar.h}, px(3), DANGER if used > 0.9 else ACCENT)
}

// ---------------------------------------------------------------------------
// Recent files: the freedesktop recently-used.xbel that GTK / GNOME apps (browsers'
// downloads, editors, the file chooser) keep, shown as a virtual folder like a tag.

RECENT :: "recent:"
I_RECENT :: 0xf017 // clock

is_recent_view :: proc() -> bool {return app.cwd == RECENT}

load_recent_view :: proc() -> bool {
	clear(&app.entries)
	app.base_count = 0
	data_home := os.get_env("XDG_DATA_HOME", context.temp_allocator)
	if data_home == "" do data_home, _ = filepath.join({app.home, ".local/share"}, context.temp_allocator)
	path, _ := filepath.join({data_home, "recently-used.xbel"}, context.temp_allocator)
	data, err := os.read_entire_file_from_path(path, context.temp_allocator)
	if err != nil do return true // nothing used yet: an empty view
	for item in recent_items(string(data)) {
		info, serr := os.lstat(item.path, context.temp_allocator)
		if serr != nil do continue // deleted or moved since
		e := Entry {
			name  = strings.clone(item.path[1:], virtual.arena_allocator(&app.listing)),
			size  = info.size,
			mtime = time.time_to_unix(info.modification_time),
			btime = time.time_to_unix(info.creation_time),
			atime = item.used, // "accessed" = when it was last used, so that sort shows newest first
		}
		e.is_link = info.type == .Symlink
		e.is_dir = info.type == .Directory || (e.is_link && os.is_dir(item.path))
		e.kind = kind_of(info.name, info.mode)
		append(&app.entries, e)
	}
	app.base_count = len(app.entries)
	return true
}

Recent_Item :: struct {
	path: string,
	used: i64, // unix seconds of the bookmark's "modified" (last use)
}

// <bookmark href="file:///…" … modified="2026-10-29T19:01:14.854888Z"> entries, local files only.
recent_items :: proc(xbel: string) -> [dynamic]Recent_Item {
	items := make([dynamic]Recent_Item, context.temp_allocator)
	rest := xbel
	for {
		i := strings.index(rest, "<bookmark ")
		if i < 0 do break
		rest = rest[i + 10:]
		end := strings.index_byte(rest, '>')
		if end < 0 do break
		tag := rest[:end]
		href := xml_attr(tag, "href")
		if !strings.has_prefix(href, "file://") do continue
		p := url_decode_tmp(href[7:])
		if !filepath.is_abs(p) do continue
		t, _ := time.rfc3339_to_time_utc(xml_attr(tag, "modified"))
		append(&items, Recent_Item{p, time.time_to_unix(t)})
	}
	return items
}

@(private = "file")
xml_attr :: proc(tag, name: string) -> string {
	key := strings.concatenate({" ", name, "=\""}, context.temp_allocator)
	i := strings.index(strings.concatenate({" ", tag}, context.temp_allocator), key)
	if i < 0 do return ""
	v := tag[i + len(key) - 1:]
	end := strings.index_byte(v, '"')
	return v[:end] if end >= 0 else ""
}

// ---------------------------------------------------------------------------
// Folder sizes on request (Dolphin / Finder "calculate size"): computed on a worker
// thread, shown in the list's size column instead of the item count.

@(private = "file") fs_job: struct {
	lock:    sync.Mutex,
	paths:   [dynamic]string, // to do (owned)
	results: map[string]i64, // done (keys owned)
	prog:    gf.Progress, // .cancel stops the walk
	th:      ^thread.Thread,
	running: bool, // atomic
	gen:     int,
}

@(private = "file")
fs_worker :: proc() {
	for {
		sync.mutex_lock(&fs_job.lock)
		if len(fs_job.paths) == 0 || sync.atomic_load(&fs_job.prog.cancel) {
			sync.atomic_store(&fs_job.running, false)
			sync.mutex_unlock(&fs_job.lock)
			wake()
			return
		}
		p := pop(&fs_job.paths)
		sync.mutex_unlock(&fs_job.lock)
		n := gf.tree_size(p, &fs_job.prog)
		free_all(context.temp_allocator)
		if sync.atomic_load(&fs_job.prog.cancel) {
			delete(p)
			continue
		}
		sync.mutex_lock(&fs_job.lock)
		fs_job.results[p] = n
		sync.mutex_unlock(&fs_job.lock)
		wake()
	}
}

// Stops any calculation and forgets the results (navigation, reload).
folder_sizes_clear :: proc() {
	if fs_job.th != nil {
		sync.atomic_store(&fs_job.prog.cancel, true)
		thread.join(fs_job.th)
		thread.destroy(fs_job.th)
		fs_job.th = nil
	}
	for p in fs_job.paths do delete(p)
	clear(&fs_job.paths)
	for k in fs_job.results do delete(k)
	clear(&fs_job.results)
	sync.atomic_store(&fs_job.prog.cancel, false)
}

// The selected folders, or every folder on screen when nothing is selected.
folder_sizes_start :: proc() {
	folder_sizes_clear()
	sel := selection()
	for vi in app.view {
		e := app.entries[vi]
		if !e.is_dir || e.is_link do continue
		if len(sel) > 0 && !e.sel do continue
		append(&fs_job.paths, strings.clone(full_path(e.name)))
	}
	if len(fs_job.paths) == 0 do return
	sync.atomic_store(&fs_job.running, true)
	fs_job.th = thread.create_and_start(fs_worker)
	toastf("%d 個のフォルダーのサイズを計算しています…", len(fs_job.paths))
}

folder_sizes_running :: proc() -> bool {return sync.atomic_load(&fs_job.running)}

folder_size_of :: proc(path: string) -> (n: i64, ok: bool) {
	if len(fs_job.results) == 0 && fs_job.th == nil do return
	sync.mutex_lock(&fs_job.lock)
	n, ok = fs_job.results[path]
	sync.mutex_unlock(&fs_job.lock)
	return
}

// Once the worker has finished: one toast with the total.
folder_sizes_poll :: proc() -> bool {
	if fs_job.th == nil || folder_sizes_running() do return false
	thread.join(fs_job.th)
	thread.destroy(fs_job.th)
	fs_job.th = nil
	total: i64
	for _, n in fs_job.results do total += n
	toastf("%d 個のフォルダー、合計 %s", len(fs_job.results), format_size(total))
	return true
}

// ---------------------------------------------------------------------------
// Compare two files: identical? a unified diff for text, the first differing byte otherwise.

// Byte-for-byte comparison, streamed (any size). first = offset of the first difference.
files_equal :: proc(a, b: string) -> (same: bool, first: i64, ok: bool) {
	fa, ea := os.open(a)
	if ea != nil do return
	defer os.close(fa)
	fb, eb := os.open(b)
	if eb != nil do return
	defer os.close(fb)
	ba, bb: [65536]u8
	off: i64
	for {
		na, _ := os.read_full(fa, ba[:])
		nb, _ := os.read_full(fb, bb[:])
		n := min(na, nb)
		for i in 0 ..< n do if ba[i] != bb[i] do return false, off + i64(i), true
		if na != nb do return false, off + i64(n), true
		if na == 0 do return true, 0, true
		off += i64(na)
	}
}

@(private = "file")
looks_text :: proc(path: string) -> bool {
	f, err := os.open(path)
	if err != nil do return false
	defer os.close(f)
	buf: [8192]u8
	n, _ := os.read(f, buf[:])
	for c in buf[:n] do if c == 0 do return false
	return true
}

compare_selected :: proc() {
	sel := selection()
	if len(sel) != 2 || app.entries[sel[0]].is_dir || app.entries[sel[1]].is_dir {
		toastf("比較するファイルを 2 つ選んでください")
		return
	}
	ea, eb := app.entries[sel[0]], app.entries[sel[1]]
	a, b := full_path(ea.name), full_path(eb.name)
	same, first, ok := files_equal(a, b)
	if !ok {
		toastf("ファイルを読めません")
		return
	}
	report: string
	is_diff := false
	switch {
	case same:
		report = "2 つのファイルは同じ内容です。"
	case ea.size < 4 << 20 && eb.size < 4 << 20 && looks_text(a) && looks_text(b) && have_tool("diff"):
		_, out, _, _ := os.process_exec({command = {"diff", "-u", "-L", filepath.base(ea.name), "-L", filepath.base(eb.name), "--", a, b}}, context.temp_allocator)
		report, is_diff = string(out), true // diff exits 1 when the files differ: that's the normal case here
	case:
		report = fmt.tprintf("内容が異なります（%d バイト目から）。\n\n%s: %s\n%s: %s", first + 1, filepath.base(ea.name), format_size(ea.size), filepath.base(eb.name), format_size(eb.size))
	}
	for vi, k in app.view do if vi == sel[0] {preview_open(k); break}
	if !pv.open do return
	preview_show_text(report, strings.concatenate({filepath.base(ea.name), "  ↔  ", filepath.base(eb.name)}, context.temp_allocator), is_diff)
}
