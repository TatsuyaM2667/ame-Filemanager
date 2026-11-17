package main

// "ストレージ": a page (sidebar → ストレージ) that shows where the space went —
//   disks: each mounted filesystem's used / free space
//   home:  what the home folder's top-level items take (sizes worked out in the background;
//          a click opens the folder)
//   apps:  installed packages by size, with full removal (pkgs.odin)

import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import "core:sys/posix"

STORAGE :: "storage:"
I_STORAGE :: 0xf200 // pie chart

is_storage_view :: proc() -> bool {return app.cwd == STORAGE}

@(private = "file")
Disk :: struct {
	mount:       string,
	free, total: u64,
}

@(private = "file") st: struct {
	disks:      [dynamic]Disk,
	disks_at:   i64,
	// page
	scroll:     f32,
	all_pkgs:   bool, // also packages installed only as dependencies
}

// Called when the page is opened: start (or restart) the measurements.
storage_open :: proc() {
	st.scroll = 0
	st.disks_at = 0
	sunburst_set_root(app.home)
	cleanup_open()
	packages_rescan()
}

storage_close :: proc() {
	sunburst_close()
	cleanup_close()
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
// Drawing

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

	// --- sunburst of the home folder (sunburst.odin)
	y = section(x, y, "容量マップ", "クリックで中へ・中心で上へ・右の一覧で開く")
	y += draw_sunburst({x, y, w, 0}) + px(16)

	// --- what can go, recommended first (cleanup.odin)
	y = section(x, y, "消しても大丈夫なもの", "おすすめ順（自動で作り直されるもの → 再ダウンロードになるもの、大きい順）")
	busy := cleanup_busy()
	shown_n, hidden_n := 0, 0
	for it in cleanup_items() {
		// worth a row: 1 MB or more (or still being measured / a command with no size)
		if it.size >= 0 && it.size < 1 << 20 && it.kind != .Trash do continue
		if it.kind == .Trash && it.size <= 4096 do continue // empty trash: nothing to gain
		if shown_n >= 15 {hidden_n += 1; continue}
		shown_n += 1
		row := Rect{x, y, w, px(46)}
		if hovering(row) do rrect(row, px(8), HOVER)
		rank := fmt.tprintf("%d", shown_n)
		text(row.x + px(10) + (px(16) - f32(text_width(rank, fs(12), true))) / 2, baseline(row, fs(12)), rank, fs(12), DIM, true)
		tl := "安全" if it.tier == 0 else "再ダウンロード"
		tc := hex(0xa6e3a1) if it.tier == 0 else hex(0xf9e2af)
		tag := Rect{row.x + px(36), row.y + px(7), f32(text_width(tl, fs(10), true)) + px(14), px(17)}
		rrect(tag, px(8), with_alpha(tc, 50))
		text(tag.x + px(7), baseline(tag, fs(10)), tl, fs(10), tc, true)
		text(tag.x + tag.w + px(8), row.y + px(20), it.label, fs(14), FG, true)
		text(row.x + px(36), row.y + px(38), ellipsize(it.detail, fs(11), w - px(300)), fs(11), DIM)
		sz := "計算中…" if it.size < 0 && it.path != "" else ("—" if it.size < 0 else format_size(it.size))
		text(row.x + w - px(150) - f32(text_width(sz, fs(13))), baseline(row, fs(13)), sz, fs(13), FG)
		btn := Rect{row.x + w - px(130), row.y + (row.h - px(28)) / 2, px(120), px(28)}
		switch {
		case busy == it.label:
			text(btn.x + px(12), baseline(btn, fs(12)), "削除しています…", fs(12), DIM)
		case busy == "" && text_button(btn, "空にする" if it.kind == .Trash else ("片付ける" if it.kind == .Command else "削除"), 2):
			begin_cleanup(it)
		}
		y += px(48)
	}
	if hidden_n > 0 {
		text(x + px(36), y + px(16), fmt.tprintf("ほか %d 件（小さいもの）", hidden_n), fs(12), DIM)
		y += px(28)
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
		// the app's own icon (launcher icon), or a package glyph for libraries and tools
		ic := Rect{row.x + px(10), row.y + (row.h - px(36)) / 2, px(36), px(36)}
		if !draw_app_icon(p.icon, ic.x + ic.w / 2, ic.y + ic.h / 2, px(32)) {
			rrect(ic, px(9), hex(0xffffff, 16))
			glyph_center(ic, 0xf1b2, fs(15), DIM) // cube
		}
		name_w := text(row.x + px(56), row.y + px(19), ellipsize(p.name, fs(14), w * 0.35, true), fs(14), FG, true)
		ver_w := text(row.x + px(64) + name_w, row.y + px(19), ellipsize(p.version, fs(11), px(120)), fs(11), DIM)
		mname := PKG_MANAGER_NAMES[p.manager]
		badge := Rect{row.x + px(72) + name_w + ver_w, row.y + px(7), f32(text_width(mname, fs(9), true)) + px(12), px(16)}
		rrect(badge, px(8), hex(0xffffff, 22))
		text(badge.x + px(6), baseline(badge, fs(9)), mname, fs(9), DIM, true)
		text(row.x + px(56), row.y + px(36), ellipsize(p.desc, fs(12), w - px(250)), fs(12), DIM)
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
	@(static) seen_scan: bool
	@(static) seen_clean: int
	@(static) seen_busy: string
	scanning := sync.atomic_load(&pk.scanning)
	gen, busy := cleanup_gen(), cleanup_busy()
	changed := sunburst_poll() || scanning != seen_scan || gen != seen_clean || busy != seen_busy
	seen_scan, seen_clean, seen_busy = scanning, gen, busy
	return changed
}

// A removal's terminal closed: read the package lists again.
uninstall_done :: proc(name: string, ok: bool) {
	delete(pk.removing)
	pk.removing = ""
	packages_rescan()
	toastf("「%s」の削除を終えました。一覧を更新しています…", name)
}
