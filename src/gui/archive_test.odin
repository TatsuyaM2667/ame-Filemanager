package main

import "core:os"
import "core:sys/posix"
import "core:strings"
import "core:testing"
import "core:sync"
import "core:path/filepath"
import "core:log"
import "core:slice"
import "core:math"
import "core:time"
import "core:unicode/utf8"

@(test)
archive_kind_test :: proc(t: ^testing.T) {
	Case :: struct {name, stem, tool: string, ok: bool}
	cases := []Case {
		{"a.tar.gz", "a", "", true}, {"A.TAR.XZ", "A", "", true}, {"x.zip", "x", "", true},
		{"y.7z", "y", "", true}, {"z.tgz", "z", "", true}, {"log.txt.gz", "log.txt", "gzip", true},
		{"d.zst", "d", "zstd", true}, {"e.bz2", "e", "bzip2", true}, {"f.xz", "f", "xz", true},
		{"note.txt", "", "", false}, {".zip", "", "", false},
	}
	for c in cases {
		stem, tool, ok := archive_kind(c.name)
		testing.expectf(t, stem == c.stem && tool == c.tool && ok == c.ok, "%s -> %q %q %v", c.name, stem, tool, ok)
	}
}

@(test)
flatten_test :: proc(t: ^testing.T) {
	base := os.get_env("GF_TEST_DIR", context.temp_allocator)
	if base == "" do return // needs a scratch dir
	j :: proc(a: ..string) -> string {return strings.concatenate(a, context.temp_allocator)}
	// single top-level folder: moved up, wrapper removed
	_ = os.make_directory_all(j(base, "/one/proj"))
	_ = os.write_entire_file_from_string(j(base, "/one/proj/a.txt"), "x")
	flatten(j(base, "/one"))
	testing.expect(t, os.exists(j(base, "/proj/a.txt")))
	testing.expect(t, !os.exists(j(base, "/one")))
	// several entries: left as is
	_ = os.make_directory_all(j(base, "/two/x"))
	_ = os.write_entire_file_from_string(j(base, "/two/y.txt"), "y")
	flatten(j(base, "/two"))
	testing.expect(t, os.exists(j(base, "/two/x")) && os.exists(j(base, "/two/y.txt")))
}

@(test)
tags_follow_renames :: proc(t: ^testing.T) {
	base := os.get_env("GF_TEST_DIR", context.temp_allocator)
	if base == "" do return
	posix_setenv_config(base) // save_tags writes into the scratch dir, never the real config
	file_tags[strings.clone("/a/dir")] = 1 << 2
	file_tags[strings.clone("/a/dir/x.txt")] = 1 << 3
	file_tags[strings.clone("/a/dirx")] = 1 << 4 // shares the prefix but is a different folder
	tags_moved("/a/dir", "/b/new")
	testing.expect_value(t, file_tags["/b/new"], u64(1 << 2))
	testing.expect_value(t, file_tags["/b/new/x.txt"], u64(1 << 3))
	testing.expect_value(t, file_tags["/a/dirx"], u64(1 << 4))
	testing.expect(t, "/a/dir" not_in file_tags)
	append(&tag_list, Tag{2, 0, "無色"}, Tag{3, 0x89b4fa, "青"})
	testing.expect_value(t, tint_of_mask(1 << 2 | 1 << 3), u32(0x89b4fa)) // first *colored* tag wins
}

@(private = "file")
posix_setenv_config :: proc(base: string) {
	posix.setenv("XDG_CONFIG_HOME", strings.clone_to_cstring(base, context.temp_allocator), true)
}

@(test)
lrc_parse :: proc(t: ^testing.T) {
	src := "[ar:Ame Band]\n[ti:Rain]\n[offset:+500]\n[00:01.00]first\n[00:10.50][00:30:00]chorus\n[00:05.25]second\nno stamp\n[00:20.00]\n"
	lines := make([dynamic]Lyric_Line, context.temp_allocator)
	parse_lrc(src, &lines)
	testing.expect_value(t, len(lines), 5)
	// sorted by time, offset (+0.5 s) applied, repeated stamps expanded
	testing.expect_value(t, lines[0].text, "first")
	testing.expect_value(t, lines[0].t, 0.5)
	testing.expect_value(t, lines[1].text, "second")
	testing.expect_value(t, lines[2].text, "chorus")
	testing.expect_value(t, lines[2].t, 10.0)
	testing.expect_value(t, lines[3].text, "") // instrumental gap
	testing.expect_value(t, lines[4].text, "chorus")
	testing.expect_value(t, lines[4].t, 29.5) // [00:30:00] variant
}

@(test)
xml_text_extract :: proc(t: ^testing.T) {
	b := strings.builder_make(context.temp_allocator)
	xml_text(`<w:document><w:body><w:p><w:r><w:t>見出し</w:t></w:r></w:p><w:p><w:t>A &amp; B</w:t><w:tab/><w:t>&lt;x&gt;</w:t></w:p></w:body></w:document>`, &b)
	testing.expect_value(t, strings.to_string(b), "見出し\nA & B\t<x>\n")
	h := strings.builder_make(context.temp_allocator)
	xml_text(`<html><head><title>T</title><style>p{color:red}</style></head><body><p>本文</p><script>var x=1;</script><br/>次</body></html>`, &h)
	testing.expect_value(t, strings.to_string(h), "本文\n\n次")
}

@(test)
test_sort_and_group :: proc(t: ^testing.T) {
	saved_entries, saved_sort, saved_desc, saved_dirs, saved_group := app.entries, app.sort, app.sort_desc, app.dirs_first, app.group
	defer {app.entries, app.sort, app.sort_desc, app.dirs_first, app.group = saved_entries, saved_sort, saved_desc, saved_dirs, saved_group}
	es := [?]Entry {
		{name = "b.txt", size = 50, kind = .Text},
		{name = "dir", is_dir = true},
		{name = "a.png", size = 5_000_000, kind = .Image},
		{name = "c.txt", size = 0, kind = .Text},
	}
	app.entries = make([dynamic]Entry, context.temp_allocator)
	append(&app.entries, ..es[:])
	app.group, app.dirs_first, app.sort, app.sort_desc = .None, true, .Size, true
	testing.expect(t, entry_less(1, 2)) // folders first beats size
	testing.expect(t, entry_less(2, 0)) // bigger first when descending
	app.dirs_first = false
	testing.expect(t, entry_less(1, 3)) // equal sizes: name tiebreak, reversed too when descending
	app.group, app.sort, app.sort_desc = .Size, .Name, false
	r, _ := group_key(&app.entries[3])
	testing.expect_value(t, r, 1) // empty
	testing.expect(t, entry_less(3, 0)) // empty group before small group, despite the name
	testing.expect_value(t, group_label(&app.entries[2]), "中（10 MB 未満）")
	app.group = .Ext
	testing.expect(t, entry_less(2, 0)) // PNG group before TXT group
}

@(test)
test_folder_sort_memory :: proc(t: ^testing.T) {
	tmp := "/tmp/ame-fm-test-prefs"
	_ = os.remove_all(tmp)
	defer _ = os.remove_all(tmp)
	old_xdg := os.get_env("XDG_CONFIG_HOME", context.temp_allocator)
	posix.setenv("XDG_CONFIG_HOME", "/tmp/ame-fm-test-prefs", true) // never touch the user's config
	defer {
		if old_xdg != "" do posix.setenv("XDG_CONFIG_HOME", strings.clone_to_cstring(old_xdg, context.temp_allocator), true)
		else do posix.unsetenv("XDG_CONFIG_HOME")
	}
	saved_cwd := app.cwd
	defer app.cwd = saved_cwd

	load_view_prefs() // nothing saved: defaults
	testing.expect(t, app.dirs_first)
	app.cwd = "/music"
	app.sort, app.sort_desc, app.group = .Size, true, .Ext
	remember_sort()
	app.cwd = "/docs"
	app.sort, app.sort_desc, app.group = .Modified, false, .None
	remember_sort()

	load_view_prefs()
	apply_folder_prefs("/music")
	testing.expect_value(t, app.sort, Sort_Key.Size)
	testing.expect_value(t, app.group, Group_By.Ext)
	testing.expect(t, app.sort_desc)
	apply_folder_prefs("/elsewhere") // unseen folder: the last choice
	testing.expect_value(t, app.sort, Sort_Key.Modified)
	testing.expect(t, !app.sort_desc)
}

@(test)
test_drop_into_self :: proc(t: ^testing.T) {
	defer drag_clear()
	append(&dd.paths, strings.clone("/home/u/写真"))
	testing.expect(t, !dir_ok("/home/u/写真"))
	testing.expect(t, !dir_ok("/home/u/写真/2026"))
	testing.expect(t, dir_ok("/home/u/写真2")) // only a real subfolder counts
	testing.expect(t, dir_ok("/home/u"))
}

@(test)
test_lang_icon :: proc(t: ^testing.T) {
	l, ok := lang_of("/x/Main.PY")
	testing.expect(t, ok && l.icon == "python") // case-insensitive extension
	_, ok = lang_of("Dockerfile")
	testing.expect(t, ok) // known name without extension
	_, ok = lang_of("photo.png")
	testing.expect(t, !ok)
	testing.expect_value(t, kind_of("View.swift", {}), Kind.Code) // languages outside the old list count as code
}

@(test)
test_project_detect :: proc(t: ^testing.T) {
	testing.expect(t, toml_dep("[dependencies]\nyew = \"0.21\"", "yew"))
	testing.expect(t, toml_dep("[dependencies.yew]\nversion = \"0.21\"", "yew"))
	testing.expect(t, !toml_dep("[dependencies]\nyewtil = \"1\"", "yew")) // a longer crate name is not yew
	dir := "/tmp/ame-fm-test-proj"
	_ = os.remove_all(dir)
	defer _ = os.remove_all(dir)
	_ = os.make_directory_all(dir)
	_ = os.write_entire_file_from_string("/tmp/ame-fm-test-proj/package.json", `{"dependencies":{"next":"15","react":"19"}}`)
	l, ok := project_detect(dir)
	testing.expect(t, ok && l.label == "Next.js") // Next wins over the React it depends on
	l, ok = lang_of("vite.config.ts")
	testing.expect(t, ok && l.label == "Vite")
}

@(test)
test_split_label :: proc(t: ^testing.T) {
	r := utf8.string_to_runes("フォルダー優先", context.temp_allocator)
	testing.expect_value(t, label_cut(r), 5) // フォルダー|優先: at the script change, not before ー
	r = utf8.string_to_runes("ここに展開", context.temp_allocator)
	testing.expect_value(t, label_cut(r), 3) // after the particle に
}

@(test)
test_svg_rasterize :: proc(t: ^testing.T) {
	img := svg_rasterize(`<svg viewBox="0 0 10 10"><rect width="10" height="10" fill="#ff0000"/></svg>`, 10, context.temp_allocator)
	testing.expect_value(t, img[0], u32(0xffff0000))
	testing.expect_value(t, img[99], u32(0xffff0000))
	// even-odd: a square with a square hole
	img = svg_rasterize(`<svg viewBox="0 0 10 10"><path fill-rule="evenodd" fill="#fff" d="M0 0h10v10H0zM3 3h4v4H3z"/></svg>`, 10, context.temp_allocator)
	testing.expect_value(t, img[0], u32(0xffffffff))
	testing.expect_value(t, img[5 * 10 + 5] >> 24, u32(0)) // hole
	// circle (arcs): covered area ≈ πr²
	img = svg_rasterize(`<svg viewBox="0 0 40 40"><circle cx="20" cy="20" r="16" fill="#000"/></svg>`, 40, context.temp_allocator)
	area: f32
	for p in img do area += f32(p >> 24) / 255
	testing.expect(t, abs(area - 3.14159 * 16 * 16) < 12)
	// gradients take the average of their stops; relative commands, compact numbers
	img = svg_rasterize(`<svg viewBox="0 0 4 4"><defs><linearGradient id="g"><stop stop-color="#000"/><stop stop-color="#fefefe"/></linearGradient></defs><path fill="url(#g)" d="m0 0h4v4h-4z"/></svg>`, 4, context.temp_allocator)
	testing.expect_value(t, img[5], u32(0xff7f7f7f))
}

@(test)
test_project_main_language :: proc(t: ^testing.T) {
	dir := "/tmp/ame-fm-test-lang"
	_ = os.remove_all(dir)
	defer _ = os.remove_all(dir)
	_ = os.make_directory_all("/tmp/ame-fm-test-lang/src/gui")
	_ = os.make_directory_all("/tmp/ame-fm-test-lang/zig-out")
	_ = os.write_entire_file_from_string("/tmp/ame-fm-test-lang/build.zig", "const std = @import(\"std\");")
	_ = os.write_entire_file_from_string("/tmp/ame-fm-test-lang/src/gui/app.odin", strings.repeat("x := 1\n", 500, context.temp_allocator))
	_ = os.write_entire_file_from_string("/tmp/ame-fm-test-lang/zig-out/huge.zig", strings.repeat("// build output\n", 5000, context.temp_allocator))
	l, ok := project_detect(dir)
	testing.expect(t, ok && l.label == "Odin") // most code is Odin; build.zig and zig-out don't decide it
	_ = os.remove_all("/tmp/ame-fm-test-lang/src")
	l, ok = project_detect(dir)
	testing.expect(t, ok && l.label == "Zig") // no sources: the build file still says Zig
}

@(test)
test_project_live_update :: proc(t: ^testing.T) {
	dir := "/tmp/ame-fm-test-live"
	_ = os.remove_all(dir)
	defer _ = os.remove_all(dir)
	defer projects_clear()
	_ = os.make_directory_all("/tmp/ame-fm-test-live/src")
	_ = os.write_entire_file_from_string("/tmp/ame-fm-test-live/build.zig", "const std = @import(\"std\");")
	_ = os.write_entire_file_from_string("/tmp/ame-fm-test-live/src/main.zig", "pub fn main() void {}")
	frame_no = 0
	l, ok := project_of(dir)
	testing.expect(t, ok && l.label == "Zig")
	// later: lots of Odin arrives in src/ (a download, new files, edits)
	_ = os.write_entire_file_from_string("/tmp/ame-fm-test-live/src/app.odin", strings.repeat("x := 1\n", 300, context.temp_allocator))
	dirs := make([dynamic]string, context.temp_allocator)
	project_watch_dirs(&dirs)
	watched_src := false
	for d in dirs do if d == "/tmp/ame-fm-test-live/src" do watched_src = true
	testing.expect(t, watched_src) // subfolders of a visible project are watched
	project_changed("/tmp/ame-fm-test-live/src") // what the watcher reports
	testing.expect(t, !project_tick()) // debounced: not yet
	time.sleep(450 * time.Millisecond)
	testing.expect(t, project_tick())
	l, ok = project_of(dir)
	testing.expect(t, ok && l.label == "Odin")
}

@(test)
test_new_features :: proc(t: ^testing.T) {
	// select by pattern
	testing.expect(t, pattern_matches("*.jpg *.png", "Photo.JPG"))
	testing.expect(t, pattern_matches("*.jpg,*.png", "dir/a.png"))
	testing.expect(t, !pattern_matches("*.jpg", "a.jpeg"))

	root := "/tmp/ame-fm-test-feat"
	_ = os.remove_all(root)
	defer _ = os.remove_all(root)
	_ = os.make_directory_all("/tmp/ame-fm-test-feat/box/Documents")
	_ = os.make_directory_all("/tmp/ame-fm-test-feat/box/Downloads")
	_ = os.make_directory_all("/tmp/ame-fm-test-feat/box/Music")
	_ = os.write_entire_file_from_string("/tmp/ame-fm-test-feat/box/.hidden", "x")

	// item counts (hidden ones only when shown)
	saved_hidden := app.show_hidden
	defer app.show_hidden = saved_hidden
	app.show_hidden = false
	dir_counts_clear()
	testing.expect_value(t, dir_count("/tmp/ame-fm-test-feat/box"), 3)
	testing.expect_value(t, dir_count("/tmp/ame-fm-test-feat/nope"), -1)
	dir_counts_clear()

	// path bar completion: unique → whole name + "/", shared prefix → up to the fork
	edit_set(&app.path_edit, "/tmp/ame-fm-test-feat/box/Mu")
	path_complete()
	testing.expect_value(t, edit_str(&app.path_edit), "/tmp/ame-fm-test-feat/box/Music/")
	edit_set(&app.path_edit, "/tmp/ame-fm-test-feat/box/D")
	path_complete()
	testing.expect_value(t, edit_str(&app.path_edit), "/tmp/ame-fm-test-feat/box/Do")

	// undo of "new file" never deletes something that was written into
	_ = os.write_entire_file_from_string("/tmp/ame-fm-test-feat/box/note.txt", "important")
	testing.expect(t, !remove_if_empty("/tmp/ame-fm-test-feat/box/note.txt"))
	testing.expect(t, os.exists("/tmp/ame-fm-test-feat/box/note.txt"))
	_ = os.write_entire_file_from_string("/tmp/ame-fm-test-feat/box/empty.txt", "")
	testing.expect(t, remove_if_empty("/tmp/ame-fm-test-feat/box/empty.txt"))
}

@(test)
test_ring_seg_area :: proc(t: ^testing.T) {
	saved := cv
	defer cv = saved
	buf := make([]u32, 400 * 400, context.temp_allocator)
	cv = Canvas{px = raw_data(buf), w = 400, h = 400, stride = 400, clip = {0, 0, 400, 400}}
	area :: proc(buf: []u32) -> f32 {
		a: f32
		for p in buf do a += f32(p >> 24) / 255
		return a
	}
	for spec in ([][3]f32{{0, math.PI / 2, 0.25}, {0.3, 0.3 + 1.5 * math.PI, 0.75}, {0, 2 * math.PI, 1}, {-2.8, -2.2, 0.6 / (2 * math.PI)}}) {
		slice.fill(buf, 0)
		ring_seg(200, 200, 50, 150, spec[0], spec[1], {255, 255, 255, 255})
		want := spec[2] * math.PI * (150 * 150 - 50 * 50)
		testing.expectf(t, abs(area(buf) - want) < want * 0.01, "sector %v: area %v, want %v", spec, area(buf), want)
	}
	// speed: a 12-slice menu ring
	start := time.tick_now()
	for _ in 0 ..< 20 do for k in 0 ..< 12 do ring_seg(200, 200, 54, 172, f32(k) * math.PI / 6, f32(k + 1) * math.PI / 6 - 0.04, {30, 30, 50, 245})
	ms := time.duration_milliseconds(time.tick_since(start)) / 20
	testing.expectf(t, ms < 4, "12 slices took %.2f ms", ms)
	log.infof("12-slice ring: %.2f ms", ms)
}

@(test)
test_any_folder_badge :: proc(t: ^testing.T) {
	dir := "/tmp/ame-fm-test-php"
	_ = os.remove_all(dir)
	defer _ = os.remove_all(dir)
	defer projects_clear()
	_ = os.make_directory_all("/tmp/ame-fm-test-php/lib")
	_ = os.write_entire_file_from_string("/tmp/ame-fm-test-php/index.php", "<?php echo 1;")
	_ = os.write_entire_file_from_string("/tmp/ame-fm-test-php/lib/db.php", "<?php // db")
	_ = os.write_entire_file_from_string("/tmp/ame-fm-test-php/notes.md", strings.repeat("long notes\n", 200, context.temp_allocator))
	l, ok := project_detect(dir)
	testing.expect(t, ok && l.label == "PHP") // no composer.json, no .git: still PHP (docs don't count)

	// on the worker thread: nothing at first, the badge once the result is in
	project_async = true
	defer project_async = false
	frame_no = 7
	l, ok = project_of(dir)
	testing.expect(t, !ok)
	deadline := time.tick_now()
	for !project_tick() && time.duration_seconds(time.tick_since(deadline)) < 3 do time.sleep(5 * time.Millisecond)
	l, ok = project_of(dir)
	testing.expect(t, ok && l.label == "PHP")
}

@(test)
test_open_with :: proc(t: ^testing.T) {
	e, ok := parse_desktop("[Desktop Entry]\nType=Application\nName=Seoritsu\nName[ja]=セオリツ\nExec=/home/u/.local/bin/seoritsu %F\nIcon=seoritsu\nMimeType=text/plain;inode/directory;\n[Desktop Action new]\nName=Other\n")
	testing.expect(t, ok)
	testing.expect_value(t, e.name, "セオリツ")
	_, ok = parse_desktop("[Desktop Entry]\nType=Application\nName=Yazi\nExec=yazi %f\nTerminal=true\n")
	testing.expect(t, !ok) // terminal apps need a terminal to run in

	argv := exec_argv(`"/opt/My Editor/bin/ed" --new-window %F %i`, "/home/u/My Project")
	testing.expect_value(t, len(argv), 3)
	testing.expect_value(t, argv[0], "/opt/My Editor/bin/ed")
	testing.expect_value(t, argv[2], "/home/u/My Project")
	argv = exec_argv("thunar %U", "/tmp/a b")
	testing.expect_value(t, argv[1], "file:///tmp/a%20b")

	// only apps that declare inode/directory, user entries shadowing system ones
	root := "/tmp/ame-fm-test-apps"
	_ = os.remove_all(root)
	defer _ = os.remove_all(root)
	_ = os.make_directory_all("/tmp/ame-fm-test-apps/home/applications")
	_ = os.make_directory_all("/tmp/ame-fm-test-apps/sys/applications")
	_ = os.write_entire_file_from_string("/tmp/ame-fm-test-apps/home/applications/ed.desktop", "[Desktop Entry]\nType=Application\nName=Editor\nExec=ed %F\nMimeType=inode/directory;\n")
	_ = os.write_entire_file_from_string("/tmp/ame-fm-test-apps/sys/applications/ed.desktop", "[Desktop Entry]\nType=Application\nName=Old Editor\nExec=old %F\nMimeType=inode/directory;\n")
	_ = os.write_entire_file_from_string("/tmp/ame-fm-test-apps/sys/applications/viewer.desktop", "[Desktop Entry]\nType=Application\nName=Viewer\nExec=v %f\nMimeType=image/png;\n")
	old_home, old_dirs := os.get_env("XDG_DATA_HOME", context.temp_allocator), os.get_env("XDG_DATA_DIRS", context.temp_allocator)
	posix.setenv("XDG_DATA_HOME", "/tmp/ame-fm-test-apps/home", true)
	posix.setenv("XDG_DATA_DIRS", "/tmp/ame-fm-test-apps/sys", true)
	defer {
		if old_home != "" do posix.setenv("XDG_DATA_HOME", strings.clone_to_cstring(old_home, context.temp_allocator), true)
		else do posix.unsetenv("XDG_DATA_HOME")
		if old_dirs != "" do posix.setenv("XDG_DATA_DIRS", strings.clone_to_cstring(old_dirs, context.temp_allocator), true)
		else do posix.unsetenv("XDG_DATA_DIRS")
	}
	find_apps("inode/directory")
	testing.expect_value(t, len(open_with), 1)
	if len(open_with) == 1 do testing.expect_value(t, open_with[0].name, "Editor")
}

@(test)
test_git_repo_config_safe :: proc(t: ^testing.T) {
	testing.expect(t, repo_lines_safe(""))
	testing.expect(t, repo_lines_safe("global\tfilter.lfs.clean git-lfs clean -- %f\n")) // the user's own config
	testing.expect(t, !repo_lines_safe("local\tcore.fsmonitor touch /tmp/pwned\n"))
	testing.expect(t, !repo_lines_safe("global\tfilter.lfs.clean x\nlocal\tfilter.evil.clean sh -c id\n"))
}

@(test)
test_hardening :: proc(t: ^testing.T) {
	// field codes inside quotes are not expanded (no file names inside sh -c strings)
	argv := exec_argv(`sh -c "echo %f"`, "/tmp/$(touch pwned)")
	testing.expect_value(t, len(argv), 3)
	testing.expect_value(t, argv[2], "echo ")
	argv = exec_argv("ed %F", "/tmp/a")
	testing.expect_value(t, argv[1], "/tmp/a")
	// broken SVGs give a blank icon instead of crashing
	img := svg_rasterize(`<svg viewBox="0 0 0 0"><path d="M0 0h10v10z"/></svg>`, 16, context.temp_allocator)
	testing.expect_value(t, img[0], u32(0))
	img = svg_rasterize(`<svg viewBox="0 0 10 10"><path d="M0 0L1e30 1e30L0 5z M nan"/><rect width="1e39" height="5"/></svg>`, 16, context.temp_allocator)
	_ = img
}

@(test)
test_content_search :: proc(t: ^testing.T) {
	dir := "/tmp/ame-fm-test-content"
	_ = os.remove_all(dir)
	defer _ = os.remove_all(dir)
	_ = os.make_directory_all("/tmp/ame-fm-test-content/notes")
	_ = os.write_entire_file_from_string("/tmp/ame-fm-test-content/notes/todo.txt", "buy MILK tomorrow")
	_ = os.write_entire_file_from_string("/tmp/ame-fm-test-content/other.txt", "nothing here")
	_ = os.write_entire_file("/tmp/ame-fm-test-content/blob.bin", []u8{0, 1, 2, 'm', 'i', 'l', 'k', 0})
	saved_cwd, saved_entries, saved_base, saved_search := app.cwd, app.entries, app.base_count, app.searching
	defer app.cwd, app.entries, app.base_count, app.searching = saved_cwd, saved_entries, saved_base, saved_search
	app.cwd = dir
	app.entries = make([dynamic]Entry, context.temp_allocator)
	app.base_count = 0
	app.searching = true
	content_search_on = true
	defer content_search_on = false
	content_start("milk")
	start := time.tick_now()
	for !content_poll() && time.duration_seconds(time.tick_since(start)) < 10 do time.sleep(10 * time.Millisecond)
	names := make([dynamic]string, context.temp_allocator)
	for e in app.entries do append(&names, e.name)
	testing.expect_value(t, len(names), 1) // text files only: the binary doesn't count
	if len(names) == 1 do testing.expect_value(t, names[0], "notes/todo.txt") // name doesn't match, content does (case-insensitive)
	content_stop()
	clear(&content_names)
}

@(test)
test_folder_sizes :: proc(t: ^testing.T) {
	dir := "/tmp/ame-fm-test-sizes"
	_ = os.remove_all(dir)
	defer _ = os.remove_all(dir)
	_ = os.make_directory_all("/tmp/ame-fm-test-sizes/big/deep")
	_ = os.write_entire_file_from_string("/tmp/ame-fm-test-sizes/big/a.bin", strings.repeat("x", 3000, context.temp_allocator))
	_ = os.write_entire_file_from_string("/tmp/ame-fm-test-sizes/big/deep/b.bin", strings.repeat("y", 500, context.temp_allocator))
	saved_cwd, saved_entries, saved_view := app.cwd, app.entries, app.view
	defer app.cwd, app.entries, app.view = saved_cwd, saved_entries, saved_view
	app.cwd = dir
	app.entries = make([dynamic]Entry, context.temp_allocator)
	app.view = make([dynamic]int, context.temp_allocator)
	append(&app.entries, Entry{name = "big", is_dir = true})
	append(&app.view, 0)
	folder_sizes_start()
	start := time.tick_now()
	for !folder_sizes_poll() && time.duration_seconds(time.tick_since(start)) < 5 do time.sleep(5 * time.Millisecond)
	n, ok := folder_size_of("/tmp/ame-fm-test-sizes/big")
	testing.expect(t, ok)
	testing.expect(t, n >= 3500) // both files (directories add their own sizes on some filesystems)
	folder_sizes_clear()
}

@(test)
test_net_recent_compare :: proc(t: ^testing.T) {
	// SFTP addresses: nothing ssh could read as an option or a shell as syntax
	testing.expect(t, server_ok("tatsuya@nas.local:/srv/share"))
	testing.expect(t, server_ok("nas:"))
	testing.expect(t, !server_ok("-oProxyCommand=sh:/x"))
	testing.expect(t, !server_ok("user@-oProxyCommand=x:/"))
	testing.expect(t, !server_ok("host:/a b"))
	testing.expect(t, !server_ok("host:/$(id)"))
	testing.expect(t, !server_ok("noport"))
	testing.expect(t, !strings.contains(filepath.base(server_mountpoint("u@h:/a/b")), "/"))

	// recently-used.xbel
	items := recent_items(`<xbel><bookmark href="file:///home/u/%E3%83%80%E3%82%A6%E3%83%B3/a%20b.zip" added="x" modified="2026-10-29T19:01:14.854888Z" visited="y"><info/></bookmark><bookmark href="https://example.com/" modified="2026-10-29T19:01:14Z"></bookmark></xbel>`)
	testing.expect_value(t, len(items), 1) // web pages are skipped
	if len(items) == 1 {
		testing.expect_value(t, items[0].path, "/home/u/ダウン/a b.zip")
		testing.expect_value(t, items[0].used, i64(1793300474))
	}

	// byte comparison
	_ = os.write_entire_file_from_string("/tmp/ame-fm-cmp-a", "hello world")
	_ = os.write_entire_file_from_string("/tmp/ame-fm-cmp-b", "hello wOrld")
	_ = os.write_entire_file_from_string("/tmp/ame-fm-cmp-c", "hello world")
	defer {_ = os.remove("/tmp/ame-fm-cmp-a"); _ = os.remove("/tmp/ame-fm-cmp-b"); _ = os.remove("/tmp/ame-fm-cmp-c")}
	same, first, ok := files_equal("/tmp/ame-fm-cmp-a", "/tmp/ame-fm-cmp-b")
	testing.expect(t, ok && !same && first == 7)
	same, _, ok = files_equal("/tmp/ame-fm-cmp-a", "/tmp/ame-fm-cmp-c")
	testing.expect(t, ok && same)
}

@(test)
test_lang_sort_filter :: proc(t: ^testing.T) {
	dir := "/tmp/ame-fm-test-langsort"
	_ = os.remove_all(dir)
	defer _ = os.remove_all(dir)
	defer projects_clear()
	_ = os.make_directory_all("/tmp/ame-fm-test-langsort/proj")
	_ = os.write_entire_file_from_string("/tmp/ame-fm-test-langsort/proj/main.odin", "package main")
	saved := app
	defer app = saved
	app.cwd = dir
	app.entries = make([dynamic]Entry, context.temp_allocator)
	app.view = make([dynamic]int, context.temp_allocator)
	app.groups, app.lay, app.hdrs = {}, {}, {}
	app.searching, app.tree, app.lang_filter = false, false, ""
	append(&app.entries,
		Entry{name = "notes.txt"},
		Entry{name = "app.py"},
		Entry{name = "proj", is_dir = true},
		Entry{name = "build.zig"},
		Entry{name = "readme.md"},
	)
	app.base_count = len(app.entries)
	_, label := entry_lang(&app.entries[2])
	testing.expect_value(t, label, "Odin") // a folder: its badge
	_, label = entry_lang(&app.entries[4])
	testing.expect_value(t, label, "Markdown") // a format counts too

	app.sort, app.sort_desc, app.dirs_first, app.group = .Lang, false, false, .None
	refilter()
	order := make([dynamic]string, context.temp_allocator)
	for vi in app.view do append(&order, app.entries[vi].name)
	testing.expect_value(t, len(order), 5)
	if len(order) == 5 {
		testing.expect_value(t, order[0], "readme.md") // Markdown < Odin < Python < Zig
		testing.expect_value(t, order[1], "proj")
		testing.expect_value(t, order[3], "build.zig")
		testing.expect_value(t, order[4], "notes.txt") // no language: last
	}
	app.group = .Lang
	testing.expect_value(t, group_label(&app.entries[0]), "言語なし")
	app.group = .None
	app.lang_filter = "Python"
	refilter()
	testing.expect_value(t, len(app.view), 1)
}

@(test)
test_pinned_folders :: proc(t: ^testing.T) {
	saved := app
	defer app = saved
	app.cwd = "/home/u"
	app.places = make([dynamic]Place, context.temp_allocator)
	append(&app.places, Place{"ホーム", I_HOME, "/home/u"}, Place{"ドキュメント", I_DOCS, "/home/u/Documents"}, Place{"ダウンロード", I_DOWNLOAD, "/home/u/Downloads"})
	app.entries = make([dynamic]Entry, context.temp_allocator)
	app.view = make([dynamic]int, context.temp_allocator)
	app.groups, app.lay, app.hdrs = {}, {}, {}
	app.searching, app.tree, app.lang_filter, app.group = false, false, "", .None
	append(&app.entries,
		Entry{name = "aaa", is_dir = true, mtime = 50},
		Entry{name = "Downloads", is_dir = true, mtime = 10},
		Entry{name = "zzz.txt", mtime = 99},
		Entry{name = "Documents", is_dir = true, mtime = 1},
	)
	app.base_count = len(app.entries)
	for desc in ([]bool{false, true}) {
		app.sort, app.sort_desc, app.dirs_first = .Modified, desc, false
		refilter()
		testing.expect_value(t, app.entries[app.view[0]].name, "Documents") // sidebar order, either direction
		testing.expect_value(t, app.entries[app.view[1]].name, "Downloads")
	}
	testing.expect_value(t, app.entries[app.view[2]].name, "zzz.txt") // the rest by the sort (newest first)
}

@(test)
test_config_and_tmp_safety :: proc(t: ^testing.T) {
	p := "/tmp/ame-fm-test-cfg/sub/x.conf"
	defer _ = os.remove_all("/tmp/ame-fm-test-cfg")
	testing.expect(t, write_config(p, "a=1\n"))
	testing.expect(t, write_config(p, "a=2\n"))
	data, _ := os.read_entire_file_from_path(p, context.temp_allocator)
	testing.expect_value(t, string(data), "a=2\n")
	testing.expect(t, !os.exists("/tmp/ame-fm-test-cfg/sub/x.conf.new")) // nothing left behind

	// without XDG_RUNTIME_DIR, scratch files go to a private mkdtemp directory
	old := os.get_env("XDG_RUNTIME_DIR", context.temp_allocator)
	posix.unsetenv("XDG_RUNTIME_DIR")
	defer if old != "" do posix.setenv("XDG_RUNTIME_DIR", strings.clone_to_cstring(old, context.temp_allocator), true)
	tp := tmp_path("log")
	dir := filepath.dir(tp)
	testing.expect(t, strings.has_prefix(dir, "/tmp/ame-fm-") && dir != "/tmp")
	fi, err := os.stat(dir, context.temp_allocator)
	testing.expect(t, err == nil && fi.mode == {.Read_User, .Write_User, .Execute_User}) // 0700
	_ = os.remove_all(dir)
}

@(test)
test_packages :: proc(t: ^testing.T) {
	// names that could be read as options or shell are refused
	testing.expect(t, pkg_name_ok("gtk+3.0"))
	testing.expect(t, pkg_name_ok("org.mozilla.firefox"))
	testing.expect(t, !pkg_name_ok("-rf"))
	testing.expect(t, !pkg_name_ok("foo bar"))
	testing.expect(t, !pkg_name_ok("foo;rm"))
	argv, ok := uninstall_argv(Package{name = "-x", manager = .Apk})
	testing.expect(t, !ok)
	argv, ok = uninstall_argv(Package{name = "linux-lts", manager = .Apk, protected = true})
	testing.expect(t, !ok) // the kernel, libc, the package manager… have no remove at all
	argv, ok = uninstall_argv(Package{name = "org.gimp.GIMP", manager = .Flatpak})
	testing.expect(t, ok && strings.join(argv[:], " ", context.temp_allocator) == "flatpak uninstall --user --delete-data org.gimp.GIMP")
	argv, ok = uninstall_argv(Package{name = "htop", manager = .Pacman})
	if ok do testing.expect_value(t, strings.join(argv[1:], " ", context.temp_allocator), "pacman -Rns htop") // argv[0] is doas / sudo / pkexec

	// each terminal gets the command the way it expects it
	testing.expect_value(t, strings.join(terminal_argv("foot", {"a", "b"})[:], " ", context.temp_allocator), "foot a b")
	testing.expect_value(t, strings.join(terminal_argv("gnome-terminal", {"a"})[:], " ", context.temp_allocator), "gnome-terminal -- a")
	testing.expect_value(t, strings.join(terminal_argv("/usr/bin/ghostty", {"a"})[:], " ", context.temp_allocator), "/usr/bin/ghostty -e a")

	testing.expect_value(t, parse_human_size("1.5 GB"), i64(1_500_000_000))
	testing.expect_value(t, parse_human_size("12 kB"), i64(12_000))
	testing.expect_value(t, parse_human_size("??"), i64(-1))

	// the real databases of this machine (whatever package manager it has)
	packages_rescan()
	start := time.tick_now()
	for sync.atomic_load(&pk.scanning) && time.duration_seconds(time.tick_since(start)) < 20 do time.sleep(10 * time.Millisecond)
	if os.exists("/lib/apk/db/installed") {
		explicit, sized := 0, 0
		for p in pk.list {
			if p.explicit do explicit += 1
			if p.size > 0 do sized += 1
		}
		testing.expect(t, len(pk.list) > 0 && explicit > 0 && explicit < len(pk.list) && sized > 0)
		testing.expect(t, len(pk.list) < 2 || pk.list[0].size >= pk.list[1].size) // biggest first
		for p in pk.list do if p.name == "linux-lts" || p.name == "apk-tools" || p.name == "musl" do testing.expect(t, p.protected)
	}
}

@(test)
test_sunburst_scan :: proc(t: ^testing.T) {
	dir := "/tmp/ame-fm-test-sun"
	_ = os.remove_all(dir)
	defer _ = os.remove_all(dir)
	defer sunburst_close()
	_ = os.make_directory_all("/tmp/ame-fm-test-sun/big/deeper/deepest")
	_ = os.make_directory_all("/tmp/ame-fm-test-sun/small")
	_ = os.write_entire_file_from_string("/tmp/ame-fm-test-sun/big/deeper/deepest/a.bin", strings.repeat("x", 90_000, context.temp_allocator))
	_ = os.write_entire_file_from_string("/tmp/ame-fm-test-sun/big/b.bin", strings.repeat("x", 10_000, context.temp_allocator))
	_ = os.write_entire_file_from_string("/tmp/ame-fm-test-sun/small/c.txt", "tiny")
	_ = os.write_entire_file_from_string("/tmp/ame-fm-test-sun/top.txt", strings.repeat("y", 5_000, context.temp_allocator))
	sunburst_set_root(dir)
	start := time.tick_now()
	for sunburst_running() && time.duration_seconds(time.tick_since(start)) < 10 do time.sleep(5 * time.Millisecond)
	top, total, size := sunburst_snapshot()
	testing.expect_value(t, total, 3)
	testing.expect_value(t, size, i64(105_004))
	testing.expect_value(t, top[0].name, "big") // biggest first
	testing.expect_value(t, top[0].size, i64(100_000))
	testing.expect(t, len(top[0].kids) == 2 && top[0].kids[0].name == "deeper") // the hierarchy is kept
	testing.expect_value(t, top[0].kids[0].kids[0].kids[0].name, "a.bin")
	// "small" (4 bytes of 105,004) is below 0.25 % — still counted in the total, just no node of its own children
	testing.expect_value(t, top[2].size, i64(4))
}

@(test)
test_cleanup :: proc(t: ^testing.T) {
	home := "/tmp/ame-fm-test-home"
	outside := "/tmp/ame-fm-test-outside"
	_ = os.remove_all(home)
	_ = os.remove_all(outside)
	defer {_ = os.remove_all(home); _ = os.remove_all(outside)}
	_ = os.make_directory_all("/tmp/ame-fm-test-home/.cache/mozilla/cache2")
	_ = os.make_directory_all("/tmp/ame-fm-test-home/.cache/ame-shell/toolchain")
	_ = os.make_directory_all("/tmp/ame-fm-test-home/.cache/someapp")
	_ = os.make_directory_all("/tmp/ame-fm-test-home/.npm/_cacache")
	_ = os.make_directory_all(outside)
	_ = os.write_entire_file_from_string("/tmp/ame-fm-test-home/.cache/mozilla/cache2/a", strings.repeat("x", 5000, context.temp_allocator))
	_ = os.write_entire_file_from_string("/tmp/ame-fm-test-home/.cache/someapp/b", "yy")
	_ = os.write_entire_file_from_string("/tmp/ame-fm-test-home/.npm/_cacache/c", strings.repeat("z", 9000, context.temp_allocator))
	_ = os.write_entire_file_from_string("/tmp/ame-fm-test-outside/precious", "keep me")
	_ = os.symlink(outside, "/tmp/ame-fm-test-home/.cache/someapp/link") // a cache with a link out of it
	saved_home := app.home
	defer app.home = saved_home
	app.home = home
	cleanup_open()
	cleanup_wait()
	items := make([dynamic]Clean_Item, context.temp_allocator)
	for it in cleanup_items() do if strings.has_prefix(it.path, home) do append(&items, it) // this machine's system caches are listed too
	for it in items do testing.expect(t, !strings.contains(it.path, "ame-shell")) // a toolchain, not a cache
	testing.expect(t, len(items) >= 3)
	if len(items) >= 3 {
		testing.expect_value(t, items[0].label, "Firefox のキャッシュ") // safe tier first
		testing.expect_value(t, items[0].size, i64(5000))
		testing.expect_value(t, items[1].tier, 1) // then re-downloads, biggest first
		testing.expect_value(t, items[1].label, "npm のダウンロード")
	}
	for it in items do if strings.contains(it.path, "someapp") do cleanup_delete_now(it)
	testing.expect(t, os.exists("/tmp/ame-fm-test-home/.cache/someapp")) // the folder stays, emptied
	testing.expect(t, !os.exists("/tmp/ame-fm-test-home/.cache/someapp/b"))
	testing.expect(t, os.exists("/tmp/ame-fm-test-outside/precious")) // the link went, not what it points to
	cleanup_close()
}

@(test)
test_svg_stroke :: proc(t: ^testing.T) {
	// a ring drawn as a stroked circle: area ≈ π((r+w/2)² − (r−w/2)²)
	img := svg_rasterize(`<svg viewBox="0 0 100 100"><circle cx="50" cy="50" r="30" fill="none" stroke="#fff" stroke-width="10"/></svg>`, 100, context.temp_allocator)
	area: f32
	for p in img do area += f32(p >> 24) / 255
	want := f32(math.PI) * (35 * 35 - 25 * 25)
	testing.expectf(t, abs(area - want) < want * 0.05, "ring area %v, want %v", area, want)
	testing.expect_value(t, img[50 * 100 + 50] >> 24, u32(0)) // the middle stays empty
	// an open path is not closed by its stroke
	img = svg_rasterize(`<svg viewBox="0 0 100 100"><path d="M10 10 L90 10 L90 90" fill="none" stroke="#fff" stroke-width="4"/></svg>`, 100, context.temp_allocator)
	testing.expect_value(t, img[50 * 100 + 50] >> 24, u32(0)) // no diagonal back to the start
	testing.expect(t, img[10 * 100 + 50] >> 24 > 200)
}

@(test)
test_tag_colors :: proc(t: ^testing.T) {
	testing.expect_value(t, parse_tag_color("#1e66f5"), u32(0x1e66f5)) // now
	testing.expect_value(t, parse_tag_color("5"), u32(0x89b4fa)) // an older tags.conf (index)
	testing.expect_value(t, parse_tag_color("0"), u32(0))
	testing.expect_value(t, hsv_to_rgb(0, 1, 1), u32(0xff0000))
	testing.expect_value(t, hsv_to_rgb(1.0 / 3, 1, 1), u32(0x00ff00))
	testing.expect_value(t, hsv_to_rgb(0, 0, 0), u32(0x010101)) // never 0: that means "no color"
	h, s, v := rgb_to_hsv(0x1e66f5)
	testing.expect_value(t, hsv_to_rgb(h, s, v), u32(0x1e66f5)) // round trip
}
