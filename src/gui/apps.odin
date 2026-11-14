package main

// "Open with": installed applications (freedesktop .desktop files) that declare the
// item's MIME type — inode/directory for folders — shown in the radial menu with their
// own icons (scalable SVG from the icon theme, drawn by svg.odin).

import "core:os"
import "core:path/filepath"
import "core:strings"

App_Entry :: struct {
	name, exec, icon_svg: string, // icon_svg: path to a scalable icon, or ""
	id:                   string, // desktop file name, e.g. "seoritsu.desktop"
}

open_with: [dynamic]App_Entry // the apps in the open menu (labels must outlive frames)
open_with_target: string // the path they open

@(private = "file")
app_dirs :: proc() -> [dynamic]string {
	dirs := make([dynamic]string, context.temp_allocator)
	data_home := os.get_env("XDG_DATA_HOME", context.temp_allocator)
	if data_home == "" do data_home, _ = filepath.join({app.home, ".local/share"}, context.temp_allocator)
	append(&dirs, data_home)
	data_dirs := os.get_env("XDG_DATA_DIRS", context.temp_allocator)
	if data_dirs == "" do data_dirs = "/usr/local/share:/usr/share" // FreeBSD ports live in /usr/local
	for d in strings.split(data_dirs, ":", context.temp_allocator) do if d != "" do append(&dirs, d)
	return dirs
}

// The scalable SVG for an Icon= value (an absolute path, or a name in the hicolor theme).
@(private = "file")
find_icon :: proc(icon: string, data_dirs: []string) -> string {
	if icon == "" do return ""
	if filepath.is_abs(icon) do return strings.clone(icon) if strings.has_suffix(icon, ".svg") && os.exists(icon) else ""
	for d in data_dirs {
		for sub in ([]string{"icons/hicolor/scalable/apps", "pixmaps"}) {
			p, _ := filepath.join({d, sub, strings.concatenate({icon, ".svg"}, context.temp_allocator)}, context.temp_allocator)
			if os.exists(p) do return strings.clone(p)
		}
	}
	return ""
}

@(private = "file")
free_apps :: proc() {
	for a in open_with {
		delete(a.name)
		delete(a.exec)
		delete(a.icon_svg)
		delete(a.id)
	}
	clear(&open_with)
}

// Fills open_with with the apps that open this MIME type (first definition of an id wins,
// as in the XDG spec: the user's own files shadow the system's).
find_apps :: proc(mime: string) {
	free_apps()
	dirs := app_dirs()
	seen := make(map[string]bool, 64, context.temp_allocator)
	for d in dirs {
		apps_dir, _ := filepath.join({d, "applications"}, context.temp_allocator)
		infos, err := os.read_all_directory_by_path(apps_dir, context.temp_allocator)
		if err != nil do continue
		for fi in infos {
			if !strings.has_suffix(fi.name, ".desktop") || fi.name in seen do continue
			seen[fi.name] = true
			if fi.name == "ame-filemanager.desktop" do continue // ourselves
			data, rerr := os.read_entire_file_from_path(fi.fullpath, context.temp_allocator)
			if rerr != nil do continue
			e, ok := parse_desktop(string(data))
			if !ok || !mime_listed(e.mimes, mime) do continue
			append(&open_with, App_Entry{
				name = strings.clone(e.name), exec = strings.clone(e.exec),
				icon_svg = find_icon(e.icon, dirs[:]), id = strings.clone(fi.name),
			})
		}
	}
}

@(private = "file")
mime_listed :: proc(list, mime: string) -> bool {
	for m in strings.split(list, ";", context.temp_allocator) do if m == mime do return true
	return false
}

Desktop :: struct {
	name, exec, icon, mimes: string,
}

// [Desktop Entry] of a .desktop file; ok=false for hidden, terminal or non-app entries.
parse_desktop :: proc(text: string) -> (e: Desktop, ok: bool) {
	t := text
	in_entry := false
	name_ja := ""
	kind := ""
	for line in strings.split_lines_iterator(&t) {
		l := strings.trim_space(line)
		if strings.has_prefix(l, "[") {
			in_entry = l == "[Desktop Entry]"
			continue
		}
		if !in_entry do continue
		k, _, v := strings.partition(l, "=")
		switch strings.trim_space(k) {
		case "Name":     e.name = v
		case "Name[ja]": name_ja = v
		case "Exec":     e.exec = v
		case "Icon":     e.icon = v
		case "MimeType": e.mimes = v
		case "Type":     kind = v
		case "Terminal": if v == "true" do return e, false
		case "NoDisplay", "Hidden": if v == "true" do return e, false
		}
	}
	if name_ja != "" do e.name = name_ja
	return e, kind == "Application" && e.exec != "" && e.name != ""
}

// Exec= line → argv for one path (%f %F %u %U → the path or its URI; %i %c %k dropped).
exec_argv :: proc(exec, path: string) -> [dynamic]string {
	argv := make([dynamic]string, context.temp_allocator)
	b := strings.builder_make(context.temp_allocator)
	quoted, have := false, false
	flush :: proc(argv: ^[dynamic]string, b: ^strings.Builder, have: ^bool) {
		if have^ do append(argv, strings.clone(strings.to_string(b^), context.temp_allocator))
		strings.builder_reset(b)
		have^ = false
	}
	for i := 0; i < len(exec); i += 1 {
		c := exec[i]
		switch {
		case c == '"':
			quoted = !quoted
			have = true
		case c == '\\' && quoted && i + 1 < len(exec):
			i += 1
			strings.write_byte(&b, exec[i])
		case (c == ' ' || c == '\t') && !quoted:
			flush(&argv, &b, &have)
		case c == '%' && quoted && i + 1 < len(exec):
			// the spec forbids field codes inside quotes; expanding them there would let a file
			// name with quotes or $(…) inject commands into e.g. sh -c "… %f"
			i += 1
			if exec[i] == '%' do strings.write_byte(&b, '%')
		case c == '%' && i + 1 < len(exec):
			i += 1
			switch exec[i] {
			case 'f', 'F':      strings.write_string(&b, path); have = true
			case 'u', 'U':      strings.write_string(&b, file_uri(path)); have = true
			case '%':           strings.write_byte(&b, '%'); have = true
			}
		case:
			strings.write_byte(&b, c)
			have = true
		}
	}
	flush(&argv, &b, &have)
	return argv
}

launch_app :: proc(i: int) {
	if i < 0 || i >= len(open_with) || open_with_target == "" do return
	a := open_with[i]
	argv := exec_argv(a.exec, open_with_target)
	if len(argv) == 0 || spawn(argv[:], filepath.dir(open_with_target)) == 0 {
		toastf("「%s」を起動できません", a.name)
		return
	}
	toastf("「%s」で開きました", a.name)
}

// ---------------------------------------------------------------------------
// Icons for the menu

@(private = "file") app_icons: map[string][]u32 // "path@size" → pixels

draw_app_icon :: proc(path: string, cx, cy, size: f32) -> bool {
	if path == "" do return false
	s := max(int(size), 8)
	key := strings.concatenate({path, "@", itoa_tmp(s)}, context.temp_allocator)
	img, ok := app_icons[key]
	if !ok {
		data, err := os.read_entire_file_from_path(path, context.temp_allocator)
		if err != nil do return false
		img = svg_rasterize(string(data), s)
		app_icons[strings.clone(key)] = img
	}
	blit_scaled({cx - f32(s) / 2, cy - f32(s) / 2, f32(s), f32(s)}, img, s, s)
	return true
}

// ---------------------------------------------------------------------------
// Radial menus: 開く… → アプリから開く… → the app

open_open_menu :: proc() {
	sel := selection()
	if len(sel) == 0 do return
	e := app.entries[sel[0]]
	clear(&app.menu_items)
	append(&app.menu_items, Menu_Item{label = "開く", act = .Open, key = "Enter", ok = true})
	if e.is_dir do append(&app.menu_items, Menu_Item{label = "新しいタブで開く", act = .New_Tab, key = "中クリック", ok = true})
	append(&app.menu_items, Menu_Item{label = "アプリから開く…", act = .Open_With_Menu, ok = true})
	app.menu_open, app.menu_main = true, false
	app.prev_menu = false
}

open_with_menu :: proc() {
	sel := selection()
	if len(sel) == 0 do return
	e := app.entries[sel[0]]
	delete(open_with_target)
	open_with_target = strings.clone(full_path(e.name))
	find_apps("inode/directory" if e.is_dir else file_mime(e.name))
	if len(open_with) == 0 {
		toastf("この%sを開けるアプリが見つかりません", "フォルダー" if e.is_dir else "ファイル")
		return
	}
	clear(&app.menu_items)
	for a, i in open_with {
		append(&app.menu_items, Menu_Item{label = a.name, act = .Open_With, arg = i, has_arg = true, ok = true, image = a.icon_svg})
	}
	app.menu_open, app.menu_main = true, false
	app.prev_menu = false
}

// MIME type of a file by name, from the shared-mime-info glob list (*.ext patterns).
file_mime :: proc(name: string) -> string {
	ext := strings.to_lower(filepath.ext(name), context.temp_allocator)
	if ext == "" do return "application/octet-stream"
	want := strings.concatenate({"*", ext}, context.temp_allocator)
	for d in app_dirs() {
		p, _ := filepath.join({d, "mime/globs2"}, context.temp_allocator)
		data, err := os.read_entire_file_from_path(p, context.temp_allocator)
		if err != nil do continue
		t := string(data)
		for line in strings.split_lines_iterator(&t) { // weight:mime:glob
			parts := strings.split_n(line, ":", 3, context.temp_allocator)
			if len(parts) == 3 && strings.to_lower(parts[2], context.temp_allocator) == want do return strings.clone(parts[1], context.temp_allocator)
		}
	}
	return "text/plain" if lang_icon_known(name) else "application/octet-stream"
}

// Source files without a registered type still open in text editors.
@(private = "file")
lang_icon_known :: proc(name: string) -> bool {
	_, ok := lang_of(name)
	return ok
}
