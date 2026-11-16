package main

// "ストレージ": a page (sidebar → ストレージ) that shows where the space went —
//   disks: each mounted filesystem's used / free space
//   home:  what the home folder's top-level items take (sizes worked out in the background;
//          a click opens the folder)
//   apps:  installed packages by size, with full removal (pkgs.odin)

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import "core:sync"
import "core:sys/posix"
import "core:thread"
import gf "../core"

STORAGE :: "storage:"
I_STORAGE :: 0xf200 // pie chart

is_storage_view :: proc() -> bool {return app.cwd == STORAGE}

@(private = "file")
Disk :: struct {
	mount:       string,
	free, total: u64,
}

@(private = "file")
Item :: struct {
	name:   string,
	size:   i64,
	is_dir: bool,
}

@(private = "file") st: struct {
	disks:      [dynamic]Disk,
	disks_at:   i64,
	// home breakdown (worker)
	lock:       sync.Mutex,
	items:      [dynamic]Item, // done so far, owned
	total:      int, // how many there are to measure
	prog:       gf.Progress,
	th:         ^thread.Thread,
	running:    bool, // atomic
	// page
	scroll:     f32,
	all_pkgs:   bool, // also packages installed only as dependencies
}

// Called when the page is opened: start (or restart) the measurements.
storage_open :: proc() {
	st.scroll = 0
	st.disks_at = 0
	home_breakdown_start()
	packages_rescan()
}

storage_close :: proc() {
	home_breakdown_stop()
}

// ---------------------------------------------------------------------------
// Disks

@(private = "file")
refresh_disks :: proc() {
	if ticks_ms() - st.disks_at < 5000 do return
	st.disks_at = ticks_ms()
	for d in st.disks do delete(d.mount)
	clear(&st.disks)
	mounts := make([dynamic]string, context.temp_allocator)
	append(&mounts, "/", app.home)
	if data, err := os.read_entire_file_from_path("/proc/self/mounts", context.temp_allocator); err == nil {
		text := string(data)
		for line in strings.split_lines_iterator(&text) {
			f := strings.fields(line, context.temp_allocator)
			if len(f) >= 2 && strings.has_prefix(f[0], "/dev/") && !strings.has_prefix(f[1], "/boot") {
				mp, _ := strings.replace_all(f[1], "\\040", " ", context.temp_allocator)
				append(&mounts, mp)
			}
		}
	} else if infos, err2 := os.read_all_directory_by_path("/media", context.temp_allocator); err2 == nil { // FreeBSD
		for fi in infos do if fi.type == .Directory do append(&mounts, fi.fullpath)
	}
	seen := make(map[u64]bool, 8, context.temp_allocator)
	for mp in mounts {
		s: posix.stat_t
		v: posix.statvfs_t
		c := strings.clone_to_cstring(mp, context.temp_allocator)
		if posix.stat(c, &s) != .OK || posix.statvfs(c, &v) != .OK do continue
		if u64(s.st_dev) in seen || v.f_blocks == 0 do continue
		seen[u64(s.st_dev)] = true
		append(&st.disks, Disk{strings.clone(mp), u64(v.f_bavail) * u64(v.f_frsize), u64(v.f_blocks) * u64(v.f_frsize)})
		if len(st.disks) >= 8 do break
	}
}

// ---------------------------------------------------------------------------
// Home breakdown (worker thread)

@(private = "file")
home_worker :: proc() {
	infos, err := os.read_all_directory_by_path(app.home, context.temp_allocator)
	if err == nil {
		sync.mutex_lock(&st.lock)
		st.total = len(infos)
		sync.mutex_unlock(&st.lock)
		for fi in infos {
			if sync.atomic_load(&st.prog.cancel) do break
			n := gf.tree_size(fi.fullpath, &st.prog) if fi.type == .Directory else fi.size
			sync.mutex_lock(&st.lock)
			append(&st.items, Item{strings.clone(fi.name), n, fi.type == .Directory})
			sync.mutex_unlock(&st.lock)
			wake()
		}
	}
	free_all(context.temp_allocator)
	sync.atomic_store(&st.running, false)
	wake()
}

@(private = "file")
home_breakdown_start :: proc() {
	home_breakdown_stop()
	sync.atomic_store(&st.prog.cancel, false)
	sync.atomic_store(&st.running, true)
	st.th = thread.create_and_start(home_worker)
}

@(private = "file")
home_breakdown_stop :: proc() {
	if st.th != nil {
		sync.atomic_store(&st.prog.cancel, true)
		thread.join(st.th)
		thread.destroy(st.th)
		st.th = nil
	}
	for it in st.items do delete(it.name)
	clear(&st.items)
	st.total = 0
}

// ---------------------------------------------------------------------------
// Drawing

@(private = "file") CHART_COLORS := [?]u32{0x89b4fa, 0xa6e3a1, 0xf9e2af, 0xfab387, 0xf38ba8, 0xcba6f7, 0x94e2d5, 0x74c7ec, 0xf5c2e7, 0xb4befe}

@(private = "file")
section :: proc(x, y: f32, title, note: string) -> f32 {
	w := text(x, y + px(18), title, fs(16), FG, true)
	if note != "" do text(x + w + px(10), y + px(18), note, fs(12), DIM)
	return y + px(32)
}

draw_storage :: proc(b: Rect) {
	refresh_disks()
	if app.wheel != 0 && hovering(b) do st.scroll = max(0, st.scroll - app.wheel * px(72))
	set_clip(b)
	defer reset_clip()
	x := b.x + px(24)
	w := b.w - px(48)
	y := b.y + px(16) - st.scroll

	// --- disks
	y = section(x, y, "ディスク", "")
	cols := 2 if w > px(560) else 1
	cw := (w - px(12) * f32(cols - 1)) / f32(cols)
	for d, i in st.disks {
		cx := x + f32(i % cols) * (cw + px(12))
		cy := y + f32(i / cols) * px(86)
		card := Rect{cx, cy, cw, px(76)}
		rrect(card, px(12), hex(0xffffff, 14))
		used := d.total - d.free
		frac := f32(f64(used) / f64(d.total))
		label := "ホーム" if d.mount == app.home else (d.mount if d.mount != "/" else "システム（/）")
		text(card.x + px(16), card.y + px(26), ellipsize(label, fs(14), card.w * 0.5, true), fs(14), FG, true)
		info := fmt.tprintf("%s 使用中 / %s（空き %s）", format_size(i64(used)), format_size(i64(d.total)), format_size(i64(d.free)))
		iw := f32(text_width(info, fs(12)))
		text(card.x + card.w - px(16) - iw, card.y + px(26), info, fs(12), DIM)
		bar := Rect{card.x + px(16), card.y + px(44), card.w - px(32), px(12)}
		rrect(bar, px(6), hex(0xffffff, 22))
		rrect({bar.x, bar.y, max(bar.h, bar.w * frac), bar.h}, px(6), DANGER if frac > 0.9 else ACCENT)
		pct := fmt.tprintf("%d%%", int(frac * 100 + 0.5))
		text(bar.x, bar.y + px(28), pct, fs(11), DIM)
	}
	y += f32((len(st.disks) + cols - 1) / cols) * px(86) + px(12)

	// --- home breakdown
	sync.mutex_lock(&st.lock)
	items := slice.clone(st.items[:], context.temp_allocator)
	total_n := st.total
	sync.mutex_unlock(&st.lock)
	slice.sort_by(items, proc(a, b: Item) -> bool {return a.size > b.size})
	sum: i64
	for it in items do sum += it.size
	note := fmt.tprintf("合計 %s", format_size(sum))
	if sync.atomic_load(&st.running) do note = fmt.tprintf("計算中… %d / %d（%s）", len(items), total_n, format_size(sum))
	y = section(x, y, "ホームの内訳", note)
	if sum > 0 {
		// one stacked bar, then the biggest items as rows
		bar := Rect{x, y, w, px(18)}
		rrect(bar, px(9), hex(0xffffff, 18))
		bx := bar.x
		for it, i in items {
			if i >= len(CHART_COLORS) do break
			sw := bar.w * f32(f64(it.size) / f64(sum))
			if sw >= 1 do fill({bx, bar.y, sw, bar.h}, hex(CHART_COLORS[i]))
			bx += sw
		}
		rrect(bar, px(9), hex(0xffffff, 30), px(1))
		y += px(30)
		top := items[0].size
		for it, i in items {
			if i >= 12 do break
			row := Rect{x, y, w, px(30)}
			if hovering(row) && it.is_dir do rrect(row, px(6), HOVER)
			glyph_center({row.x, row.y, px(24), row.h}, 0xf07b if it.is_dir else 0xf15b, fs(12), hex(CHART_COLORS[i % len(CHART_COLORS)]))
			text(row.x + px(30), baseline(row, fs(13)), ellipsize(it.name, fs(13), px(200)), fs(13), FG)
			track := Rect{row.x + px(240), row.y + px(11), row.w - px(240) - px(150), px(8)}
			rrect(track, px(4), hex(0xffffff, 14))
			rrect({track.x, track.y, max(track.h, track.w * f32(f64(it.size) / f64(max(top, 1)))), track.h}, px(4), hex(CHART_COLORS[i % len(CHART_COLORS)]))
			sz := fmt.tprintf("%s  %d%%", format_size(it.size), int(f64(it.size) * 100 / f64(sum) + 0.5))
			text(row.x + row.w - f32(text_width(sz, fs(12))), baseline(row, fs(12)), sz, fs(12), DIM)
			if it.is_dir && clicked(row) {
				p, _ := filepath.join({app.home, it.name}, context.temp_allocator)
				push(.Navigate, 0, p)
			}
			y += px(32)
		}
	}
	y += px(16)

	// --- apps
	sync.mutex_lock(&pk.lock)
	defer sync.mutex_unlock(&pk.lock)
	q := strings.to_lower(edit_str(&app.search), context.temp_allocator) if app.searching else ""
	shown := make([dynamic]int, context.temp_allocator)
	pkg_sum: i64
	for p, i in pk.list {
		if !st.all_pkgs && !p.explicit do continue
		if q != "" && !strings.contains(strings.to_lower(p.name, context.temp_allocator), q) && !strings.contains(strings.to_lower(p.desc, context.temp_allocator), q) do continue
		append(&shown, i)
		if p.size > 0 do pkg_sum += p.size
	}
	scanning := sync.atomic_load(&pk.scanning)
	apps_note := "読み込み中…" if scanning && !pk.scanned else fmt.tprintf("%d 個・%s", len(shown), format_size(pkg_sum))
	y = section(x, y, "アプリ", apps_note)
	// filter toggle: only what was installed on purpose / everything
	tlabel := "すべて表示中" if st.all_pkgs else "自分で入れたもの"
	tw := f32(text_width(tlabel, fs(12), true)) + px(24)
	tog := Rect{x + w - tw, y - px(30), tw, px(26)}
	rrect(tog, tog.h / 2, ACCENT if !st.all_pkgs else hex(0xffffff, 26))
	text(tog.x + px(12), baseline(tog, fs(12)), tlabel, fs(12), hex(0x060913) if !st.all_pkgs else FG, true)
	if clicked(tog) do st.all_pkgs = !st.all_pkgs
	if pk.scanned && len(pk.list) == 0 {
		text(x, y + px(20), "対応しているパッケージマネージャーが見つかりません", fs(13), DIM)
		y += px(40)
	}
	rh := px(46)
	for i, k in shown {
		ry := y + f32(k) * rh
		if ry > b.y + b.h do break // rows below the window: skip (the list can be thousands long)
		if ry + rh < b.y do continue
		p := pk.list[i]
		row := Rect{x, ry, w, rh - px(4)}
		if hovering(row) do rrect(row, px(8), HOVER)
		badge := Rect{row.x + px(8), row.y + px(8), px(48), px(18)}
		rrect(badge, px(9), hex(0xffffff, 26))
		mname := PKG_MANAGER_NAMES[p.manager]
		text(badge.x + (badge.w - f32(text_width(mname, fs(10), true))) / 2, baseline(badge, fs(10)), mname, fs(10), DIM, true)
		name_w := text(row.x + px(66), row.y + px(19), ellipsize(p.name, fs(14), w * 0.35, true), fs(14), FG, true)
		text(row.x + px(74) + name_w, row.y + px(19), ellipsize(p.version, fs(11), px(120)), fs(11), DIM)
		text(row.x + px(66), row.y + px(36), ellipsize(p.desc, fs(12), w - px(260)), fs(12), DIM)
		sz := "—" if p.size < 0 else format_size(p.size)
		text(row.x + w - px(150) - f32(text_width(sz, fs(13))), baseline(row, fs(13)), sz, fs(13), FG)
		del := Rect{row.x + w - px(130), row.y + (row.h - px(28)) / 2, px(120), px(28)}
		if p.protected {
			text(del.x + px(12), baseline(del, fs(12)), "システム（削除不可）", fs(12), DIM)
		} else if pk.removing == p.name {
			text(del.x + px(12), baseline(del, fs(12)), "削除しています…", fs(12), DIM)
		} else if text_button(del, "アンインストール", 2) {
			begin_uninstall(p)
		}
	}
	y += f32(len(shown)) * rh + px(40)

	// scroll limit from the content height
	content := y + st.scroll - b.y
	st.scroll = clamp(st.scroll, 0, max(0, content - b.h))
}

// True when the workers have something new to show (redraw only then, no busy frames).
storage_poll :: proc() -> bool {
	if !is_storage_view() do return false
	@(static) seen_items: int
	@(static) seen_scan: bool
	sync.mutex_lock(&st.lock)
	n := len(st.items)
	sync.mutex_unlock(&st.lock)
	scanning := sync.atomic_load(&pk.scanning)
	changed := n != seen_items || scanning != seen_scan
	seen_items, seen_scan = n, scanning
	return changed
}

// A removal's terminal closed: read the package lists again.
uninstall_done :: proc(name: string, ok: bool) {
	delete(pk.removing)
	pk.removing = ""
	packages_rescan()
	toastf("「%s」の削除を終えました。一覧を更新しています…", name)
}
