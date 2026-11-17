package main

// "消しても大丈夫なもの": space that can be given back, safest and biggest first.
//   tier 0 安全        — rebuilt on its own (trash, thumbnails, browser / GPU / font caches,
//                        package-manager download caches, unused Flatpak runtimes)
//   tier 1 再ダウンロード — fetched again when needed (npm, Cargo, Gradle, pip…, unknown caches)
// Only the contents of fixed places are deleted: paths are built from a list, checked to be
// inside the home folder and not symlinks. System caches run their own cleaning command in a
// terminal (doas / sudo), like uninstalling. ~/.cache/ame-shell holds a compiler, not a cache.

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import "core:sync"
import "core:sys/posix"
import "core:thread"
import gf "../core"

Clean_Kind :: enum u8 {
	Contents, // delete everything inside path (path itself stays)
	Trash, // empty the trash (freedesktop: files + info)
	Command, // a system cleaning command (needs root, runs in a terminal)
}

Clean_Item :: struct {
	label:         string, // static
	detail:        string, // owned
	path:          string, // owned; what is measured (and, for Contents, emptied)
	cmd:           []string, // Command: static
	kind:          Clean_Kind,
	tier:          int,
	size:          i64, // -1 while measuring / unknown
}

@(private = "file") cl: struct {
	lock:     sync.Mutex,
	items:    [dynamic]Clean_Item,
	th:       ^thread.Thread, // measuring or deleting
	busy:     string, // label being deleted ("" = none), static; set and cleared on the main thread
	deleting: bool, // atomic: the delete worker is running
	cancel:   bool, // atomic
	pending:  int, // the item the confirmation dialog is about
	gen:      int, // bumped when sizes change (for storage_poll)
}

// ~/.cache/<name> we know: what it is and how safe it is.
@(private = "file")
Known :: struct {name, label: string, tier: int}
@(private = "file")
KNOWN_CACHES :: []Known {
	{"thumbnails", "サムネイル", 0},
	{"mozilla", "Firefox のキャッシュ", 0},
	{"chromium", "Chromium のキャッシュ", 0},
	{"google-chrome", "Chrome のキャッシュ", 0},
	{"BraveSoftware", "Brave のキャッシュ", 0},
	{"mesa_shader_cache", "GPU シェーダーのキャッシュ", 0},
	{"mesa_shader_cache_db", "GPU シェーダーのキャッシュ", 0},
	{"radv_builtin_shaders", "GPU シェーダーのキャッシュ", 0},
	{"nvidia", "GPU シェーダーのキャッシュ", 0},
	{"fontconfig", "フォントのキャッシュ", 0},
	{"gstreamer-1.0", "GStreamer のキャッシュ", 0},
	{"go-build", "Go のビルドキャッシュ", 0},
	{"flatpak", "Flatpak のキャッシュ", 0},
	{"pip", "pip のダウンロード", 1},
	{"yarn", "Yarn のダウンロード", 1},
	{"pnpm", "pnpm のダウンロード", 1},
	{"bazel", "Bazel のキャッシュ", 1},
	{"next-swc", "Next.js (SWC) のキャッシュ", 1},
	{"JetBrains", "JetBrains IDE のキャッシュ", 1},
	{"electron", "Electron のダウンロード", 1},
	{"ms-playwright", "Playwright のブラウザー", 1},
	{"uv", "uv（Python）のダウンロード", 1},
	{"node-gyp", "node-gyp のヘッダー", 1},
	{"typescript", "TypeScript のキャッシュ", 0},
	{"deno", "Deno のキャッシュ", 1},
	{"zig", "Zig のビルドキャッシュ", 0},
	{"ccache", "ccache（C/C++ のビルドキャッシュ）", 0},
	{"sccache", "sccache（ビルドキャッシュ）", 0},
	{"pkg", "パッケージのダウンロード", 1},
}

// Not caches even though they live in ~/.cache (a compiler toolchain, etc.).
@(private = "file") NEVER :: []string{"ame-shell"}

// Developer tools' download caches outside ~/.cache.
@(private = "file")
Extra :: struct {rel, label: string}
@(private = "file")
EXTRA_CACHES :: []Extra {
	{".npm/_cacache", "npm のダウンロード"},
	{".cargo/registry/cache", "Cargo のダウンロード（.crate）"},
	{".cargo/registry/src", "Cargo の展開済みソース"},
	{".gradle/caches", "Gradle のキャッシュ"},
	{".bun/install/cache", "Bun のダウンロード"},
	{".cache-pip", "pip のダウンロード"},
}

@(private = "file")
System :: struct {tool, path, label: string, cmd: []string}
@(private = "file")
SYSTEM_CACHES :: []System {
	{"apk", "/var/cache/apk", "apk のパッケージキャッシュ", {"apk", "cache", "clean"}},
	{"pacman", "/var/cache/pacman/pkg", "pacman のパッケージキャッシュ", {"pacman", "-Sc"}},
	{"apt-get", "/var/cache/apt/archives", "apt のパッケージキャッシュ", {"apt-get", "clean"}},
	{"dnf", "/var/cache/dnf", "dnf のパッケージキャッシュ", {"dnf", "clean", "all"}},
	{"xbps-remove", "/var/cache/xbps", "xbps のパッケージキャッシュ", {"xbps-remove", "-O"}},
	{"pkg", "/var/cache/pkg", "pkg のパッケージキャッシュ", {"pkg", "clean", "-y"}},
	{"journalctl", "/var/log/journal", "システムのログ（2 週間より前）", {"journalctl", "--vacuum-time=2weeks"}},
}

@(private = "file")
is_real_dir :: proc(path: string) -> bool {
	st: posix.stat_t
	return posix.lstat(strings.clone_to_cstring(path, context.temp_allocator), &st) == .OK && posix.S_ISDIR(st.st_mode)
}

// What could be cleaned on this machine (sizes are measured afterwards).
@(private = "file")
collect :: proc() {
	for it in cl.items {delete(it.path); delete(it.detail)}
	clear(&cl.items)
	home := app.home
	add :: proc(label, detail, path: string, kind: Clean_Kind, tier: int, cmd: []string = nil) {
		append(&cl.items, Clean_Item{label = label, detail = strings.clone(detail), path = strings.clone(path), kind = kind, tier = tier, cmd = cmd, size = -1})
	}
	trash, _ := filepath.join({home, ".local/share/Trash"}, context.temp_allocator)
	if is_real_dir(trash) do add("ゴミ箱", "ゴミ箱を空にします", trash, .Trash, 0)
	cache, _ := filepath.join({home, ".cache"}, context.temp_allocator)
	if infos, err := os.read_all_directory_by_path(cache, context.temp_allocator); err == nil {
		outer: for fi in infos {
			if fi.type != .Directory do continue // files and symlinks: left alone
			for n in NEVER do if fi.name == n do continue outer
			label, tier := "", 1
			for k in KNOWN_CACHES do if k.name == fi.name {label, tier = k.label, k.tier; break}
			detail := fmt.tprintf("~/.cache/%s", fi.name)
			if label == "" {
				label = "アプリのキャッシュ"
				detail = fmt.tprintf("~/.cache/%s（作り直されます。使用中のアプリは閉じてから）", fi.name)
			}
			add(label, detail, fi.fullpath, .Contents, tier)
		}
	}
	for e in EXTRA_CACHES {
		p, _ := filepath.join({home, e.rel}, context.temp_allocator)
		if is_real_dir(p) do add(e.label, strings.concatenate({"~/", e.rel}), p, .Contents, 1)
	}
	for s in SYSTEM_CACHES {
		if have_tool(s.tool) && os.exists(s.path) do add(s.label, strings.join(s.cmd, " "), s.path, .Command, 0, s.cmd)
	}
	if have_tool("flatpak") do add("使われていない Flatpak ランタイム", "flatpak uninstall --unused", "", .Command, 0, {"flatpak", "uninstall", "--unused"})
}

@(private = "file")
measure_worker :: proc() {
	sync.mutex_lock(&cl.lock)
	paths := make([dynamic]string, context.temp_allocator)
	for it in cl.items do append(&paths, strings.clone(it.path, context.temp_allocator))
	sync.mutex_unlock(&cl.lock)
	prog: gf.Progress
	for p, i in paths {
		if sync.atomic_load(&cl.cancel) do break
		n := i64(-1) if p == "" else gf.tree_size(p, &prog)
		sync.mutex_lock(&cl.lock)
		if i < len(cl.items) do cl.items[i].size = n
		cl.gen += 1
		sync.mutex_unlock(&cl.lock)
		wake()
	}
	free_all(context.temp_allocator)
}

@(private = "file")
stop_worker :: proc() {
	if cl.th == nil do return
	sync.atomic_store(&cl.cancel, true)
	thread.join(cl.th)
	thread.destroy(cl.th)
	cl.th = nil
	sync.atomic_store(&cl.cancel, false)
}

cleanup_open :: proc() {
	stop_worker()
	collect()
	cl.th = thread.create_and_start(measure_worker)
}

cleanup_close :: proc() {stop_worker()}

cleanup_gen :: proc() -> int {
	sync.mutex_lock(&cl.lock)
	defer sync.mutex_unlock(&cl.lock)
	return cl.gen
}

// The rows, recommended first: safe before re-download, then biggest first.
cleanup_items :: proc() -> []Clean_Item {
	sync.mutex_lock(&cl.lock)
	items := slice.clone(cl.items[:], context.temp_allocator)
	sync.mutex_unlock(&cl.lock)
	slice.sort_by(items, proc(a, b: Clean_Item) -> bool {
		if a.tier != b.tier do return a.tier < b.tier
		return a.size > b.size
	})
	return items
}

cleanup_busy :: proc() -> string {
	if cl.busy != "" && !sync.atomic_load(&cl.deleting) do cl.busy = "" // finished
	return cl.busy
}

// ---------------------------------------------------------------------------
// Doing it

@(private = "file") confirm: Clean_Item // what the dialog is about (path owned)

begin_cleanup :: proc(it: Clean_Item) {
	delete(confirm.path)
	delete(confirm.detail)
	confirm = it
	confirm.path = strings.clone(it.path) // own copies: the list may be rebuilt while the dialog is open
	confirm.detail = strings.clone(it.detail)
	app.dialog = .Cleanup
}

cleanup_text :: proc() -> (title, body: string) {
	switch confirm.kind {
	case .Trash:    return "ゴミ箱を空にしますか？", "ゴミ箱の中身は元に戻せなくなります。"
	case .Command:  return fmt.tprintf("「%s」を片付けますか？", confirm.label), fmt.tprintf("端末で実行します: %s", strings.join(confirm.cmd, " ", context.temp_allocator))
	case .Contents: return fmt.tprintf("「%s」を削除しますか？", confirm.label), fmt.tprintf("%s の中身を完全に削除します（%s）", confirm.detail, format_size(max(confirm.size, 0)))
	}
	return "", ""
}

@(private = "file")
delete_worker :: proc() {
	switch confirm.kind {
	case .Trash:
		_ = gf.empty_trash()
	case .Contents:
		// only inside the home folder, only a real directory, never through a symlink
		home := strings.concatenate({app.home, "/"}, context.temp_allocator)
		if strings.has_prefix(confirm.path, home) && is_real_dir(confirm.path) {
			if infos, err := os.read_all_directory_by_path(confirm.path, context.temp_allocator); err == nil {
				for fi in infos do _ = gf.delete_path(fi.fullpath) // lstat-based: a symlink goes, its target stays
			}
		}
	case .Command:
	}
	free_all(context.temp_allocator)
	sync.atomic_store(&cl.deleting, false)
	wake()
}

cleanup_ok :: proc() {
	app.dialog = .None
	if confirm.kind == .Command {
		argv := make([dynamic]string, context.temp_allocator)
		if confirm.cmd[0] != "flatpak" { // flatpak asks polkit itself
			switch {
			case have_tool("doas"):   append(&argv, "doas")
			case have_tool("sudo"):   append(&argv, "sudo")
			case have_tool("pkexec"): append(&argv, "pkexec")
			case:
				toastf("doas / sudo / pkexec が見つかりません")
				return
			}
		}
		append(&argv, ..confirm.cmd)
		run_in_terminal(argv[:], confirm.label, .Cleanup)
		return
	}
	stop_worker()
	cl.busy = confirm.label
	sync.atomic_store(&cl.deleting, true)
	cl.th = thread.create_and_start(proc() {
		delete_worker()
		measure_worker() // sizes again, so the list shows what is left
	})
}

// For tests: delete the contents the way the "削除" button does (synchronously).
cleanup_delete_now :: proc(it: Clean_Item) {
	delete(confirm.path)
	delete(confirm.detail)
	confirm = it
	confirm.path, confirm.detail = strings.clone(it.path), strings.clone(it.detail)
	sync.atomic_store(&cl.deleting, true)
	delete_worker()
}

cleanup_wait :: proc() {
	if cl.th != nil {
		thread.join(cl.th)
		thread.destroy(cl.th)
		cl.th = nil
	}
}
