package main

// Filelight-style sunburst for the storage page: the folder in the middle, each ring one
// level deeper, every segment's angle its share of the size. Hover = name / size in the
// center, click a folder = dive in, click the center = up. Measured on a worker thread
// (readdir + lstat, no symlinks followed); top-level items appear as they finish.

import "core:fmt"
import "core:math"
import "core:mem"
import "core:mem/virtual"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import "core:sync"
import "core:sys/posix"
import "core:thread"

SB_DEPTH :: 6 // levels kept as nodes; deeper folders only add to their parent's size
SB_RINGS :: 5 // levels drawn

SNode :: struct {
	name:   string,
	size:   i64,
	is_dir: bool,
	kids:   []^SNode, // biggest first; tiny ones (< 0.25 % of this one) left out
}

@(private = "file")
Scan :: struct {
	path:     string, // owned
	arena:    virtual.Arena, // every node and name of this scan
	top:      [dynamic]^SNode, // the root's children so far (guarded by sb.lock)
	size:     i64, // their total (guarded)
	total:    int, // how many top-level entries there are
	running:  bool, // atomic
	cancel:   bool, // atomic
	th:       ^thread.Thread,
	at:       i64, // when it finished
}

@(private = "file") sb: struct {
	lock:    sync.Mutex,
	cur:     ^Scan,
	cache:   [dynamic]^Scan, // finished scans of other roots (going back up is instant)
	anim_t0: f32,
	seen:    int, // for sunburst_poll
}

// ---------------------------------------------------------------------------
// Scanning

@(private = "file")
cstr :: proc(s: string) -> cstring {return strings.clone_to_cstring(s, context.temp_allocator)}

// Size of everything under path, without keeping nodes (below SB_DEPTH).
@(private = "file")
sum_dir :: proc(path: string, s: ^Scan) -> i64 {
	d := posix.opendir(cstr(path))
	if d == nil do return 0
	defer posix.closedir(d)
	n: i64
	for !sync.atomic_load(&s.cancel) {
		ent := posix.readdir(d)
		if ent == nil do break
		name := string(cstring(&ent.d_name[0]))
		if name == "." || name == ".." do continue
		full := strings.concatenate({path, "/", name}, context.temp_allocator)
		st: posix.stat_t
		if posix.lstat(cstr(full), &st) != .OK do continue
		if posix.S_ISDIR(st.st_mode) do n += sum_dir(full, s)
		else do n += i64(st.st_size)
	}
	return n
}

@(private = "file")
scan_node :: proc(path, name: string, depth: int, s: ^Scan, a: mem.Allocator) -> ^SNode {
	node := new(SNode, a)
	node.name = strings.clone(name, a)
	st: posix.stat_t
	if posix.lstat(cstr(path), &st) != .OK do return node
	if !posix.S_ISDIR(st.st_mode) {
		node.size = i64(st.st_size)
		return node
	}
	node.is_dir = true
	if depth >= SB_DEPTH {
		node.size = sum_dir(path, s)
		return node
	}
	d := posix.opendir(cstr(path))
	if d == nil do return node
	kids := make([dynamic]^SNode, context.temp_allocator)
	for !sync.atomic_load(&s.cancel) {
		ent := posix.readdir(d)
		if ent == nil do break
		kname := string(cstring(&ent.d_name[0]))
		if kname == "." || kname == ".." do continue
		k := scan_node(strings.concatenate({path, "/", kname}, context.temp_allocator), kname, depth + 1, s, a)
		node.size += k.size
		append(&kids, k)
	}
	posix.closedir(d)
	slice.sort_by(kids[:], proc(x, y: ^SNode) -> bool {return x.size > y.size})
	keep := 0
	for k in kids do if keep < 64 && k.size * 400 >= node.size && k.size > 0 do keep += 1
	node.kids = slice.clone(kids[:keep], a)
	return node
}

@(private = "file")
scan_worker :: proc(s: ^Scan) {
	// only this thread allocates from the arena; the main thread reads nodes only after
	// they were appended to s.top (under the lock), and arena memory never moves
	a := virtual.arena_allocator(&s.arena)
	d := posix.opendir(cstr(s.path))
	if d != nil {
		names := make([dynamic]string, context.temp_allocator)
		for {
			ent := posix.readdir(d)
			if ent == nil do break
			n := string(cstring(&ent.d_name[0]))
			if n != "." && n != ".." do append(&names, strings.clone(n, context.temp_allocator))
		}
		posix.closedir(d)
		sync.mutex_lock(&sb.lock)
		s.total = len(names)
		sync.mutex_unlock(&sb.lock)
		for n in names {
			if sync.atomic_load(&s.cancel) do break
			k := scan_node(strings.concatenate({s.path, "/", n}, context.temp_allocator), n, 1, s, a)
			sync.mutex_lock(&sb.lock)
			append(&s.top, k)
			s.size += k.size
			sync.mutex_unlock(&sb.lock)
			wake()
		}
	}
	free_all(context.temp_allocator)
	s.at = ticks_ms()
	sync.atomic_store(&s.running, false)
	wake()
}

@(private = "file")
scan_free :: proc(s: ^Scan) {
	if s == nil do return
	sync.atomic_store(&s.cancel, true)
	if s.th != nil {
		thread.join(s.th)
		thread.destroy(s.th)
	}
	delete(s.top)
	virtual.arena_destroy(&s.arena)
	delete(s.path)
	free(s)
}

// Shows path in the middle: a cached scan if there is a recent one, else a new scan.
sunburst_set_root :: proc(path: string) {
	if sb.cur != nil && sb.cur.path == path do return
	if sb.cur != nil {
		if sync.atomic_load(&sb.cur.running) do scan_free(sb.cur) // unfinished: not worth keeping
		else {
			append(&sb.cache, sb.cur)
			if len(sb.cache) > 4 {scan_free(sb.cache[0]); ordered_remove(&sb.cache, 0)}
		}
		sb.cur = nil
	}
	for s, i in sb.cache do if s.path == path && ticks_ms() - s.at < 120_000 {
		sb.cur = s
		ordered_remove(&sb.cache, i)
		break
	}
	if sb.cur == nil {
		s := new(Scan)
		s.path = strings.clone(path)
		s.top = make([dynamic]^SNode)
		sync.atomic_store(&s.running, true)
		s.th = thread.create_and_start_with_poly_data(s, scan_worker)
		sb.cur = s
	}
	sb.anim_t0 = app.now
}

// Leaving the page: stop and give all the memory back.
sunburst_close :: proc() {
	scan_free(sb.cur)
	sb.cur = nil
	for s in sb.cache do scan_free(s)
	clear(&sb.cache)
}

sunburst_poll :: proc() -> bool {
	if sb.cur == nil do return false
	sync.mutex_lock(&sb.lock)
	n := len(sb.cur.top) + (0 if sync.atomic_load(&sb.cur.running) else 1 << 20)
	sync.mutex_unlock(&sb.lock)
	changed := n != sb.seen
	sb.seen = n
	return changed
}

// ---------------------------------------------------------------------------
// Drawing

@(private = "file") PALETTE := [?]u32{0x89b4fa, 0xa6e3a1, 0xf9e2af, 0xfab387, 0xf38ba8, 0xcba6f7, 0x94e2d5, 0x74c7ec, 0xf5c2e7, 0xb4befe, 0xeba0ac, 0xf2cdcd}

@(private = "file")
Hit :: struct {
	node:  ^SNode,
	path:  [SB_RINGS]string, // names from the root down to it
	depth: int,
}

@(private = "file")
seg_color :: proc(top_index, level: int, is_dir: bool) -> Color {
	c := hex(PALETTE[top_index % len(PALETTE)])
	c = mix(c, hex(0xffffff), clamp(f32(level) * 0.13, 0, 0.6)) // deeper = lighter
	if !is_dir do c = mix(c, hex(0x9399b2), 0.45) // files: quieter than folders
	return c
}

// Draws one level (and, recursively, the ones below); finds the segment under the pointer.
@(private = "file")
ring :: proc(kids: []^SNode, parent: i64, level, top_index: int, a0, a1: f32, g: ^Geo, hit: ^Hit, trail: ^[SB_RINGS]string) {
	if level >= SB_RINGS || parent <= 0 do return
	r_in := g.r0 + f32(level) * g.rw
	r_out := r_in + g.rw - px(1.5)
	a := a0
	for k, i in kids {
		span := (a1 - a0) * f32(f64(k.size) / f64(parent))
		if span * r_out < px(1.5) do break // biggest first: the rest are even smaller
		ti := i if level == 0 else top_index
		gap := min(px(1) / r_out, span * 0.2)
		col := seg_color(ti, level, k.is_dir)
		trail[level] = k.name
		if g.pd >= r_in && g.pd < r_out && angle_in(g.pa, a, a + span) {
			hit.node, hit.depth, hit.path = k, level, trail^
			col = mix(col, hex(0xffffff), 0.35)
		}
		ring_seg(g.cx, g.cy, r_in, r_out, a + gap, a + span - gap, col)
		// the name on wide top-level segments
		if level == 0 && span > 0.32 {
			mid := a + span / 2
			lr := (r_in + r_out) / 2
			label := ellipsize(k.name, fs(11), span * lr * 0.8, true)
			tw := f32(text_width(label, fs(11), true))
			text(g.cx + math.cos(mid) * lr - tw / 2, g.cy + math.sin(mid) * lr + px(4), label, fs(11), hex(0x11131c), true)
		}
		if k.is_dir && len(k.kids) > 0 do ring(k.kids, k.size, level + 1, ti, a, a + span, g, hit, trail)
		a += span
	}
}

@(private = "file")
Geo :: struct {
	cx, cy, r0, rw: f32,
	pd, pa:         f32, // pointer: distance from the center, angle (same range as the segments)
}

// Is angle x within [a, b] (all in the chart's range: −π/2 … 3π/2)?
@(private = "file")
angle_in :: proc(x, a, b: f32) -> bool {return x >= a && x < b}

// Draws the chart in r; returns the height used.
draw_sunburst :: proc(r: Rect) -> f32 {
	s := sb.cur
	if s == nil do return 0
	top, total, size_sum := sunburst_snapshot()
	running := sync.atomic_load(&s.running)

	wide := r.w > px(700)
	d := min(r.w * (0.55 if wide else 1), px(460))
	cx, cy := r.x + d / 2, r.y + d / 2 + px(8)
	p := progress(sb.anim_t0, 0.6) // rings sweep open
	R := d / 2 - px(6)
	g := Geo{cx = cx, cy = cy, r0 = R * 0.24, rw = (R - R * 0.24) / SB_RINGS}
	dx, dy := app.mx - cx, app.my - cy
	g.pd = math.sqrt(dx * dx + dy * dy)
	g.pa = math.atan2(dy, dx)
	if g.pa < -math.PI / 2 do g.pa += 2 * math.PI
	if p < 1 do g.pd = -1 // no hover while it opens

	hit: Hit
	trail: [SB_RINGS]string
	ring_seg(cx, cy, g.r0 + g.rw * SB_RINGS, R + px(3), -math.PI / 2, 3 * math.PI / 2, hex(0xffffff, 10))
	if size_sum > 0 do ring(top[:], size_sum, 0, 0, -math.PI / 2, -math.PI / 2 + 2 * math.PI * p, &g, &hit, &trail)

	// center: the root, or what the pointer is on
	in_center := g.pd >= 0 && g.pd < g.r0
	ring_seg(cx, cy, 0, g.r0 - px(3), -math.PI / 2, 3 * math.PI / 2, hex(0x10141f, 250) if !in_center else hex(0x1b2133, 250))
	name, size := filepath.base(s.path), size_sum
	if s.path == app.home do name = "ホーム"
	if hit.node != nil do name, size = hit.node.name, hit.node.size
	l1 := ellipsize(name, fs(13), g.r0 * 1.7, true)
	text(cx - f32(text_width(l1, fs(13), true)) / 2, cy - px(4), l1, fs(13), FG, true)
	l2 := format_size(size)
	if hit.node != nil && size_sum > 0 do l2 = fmt.tprintf("%s・%.1f%%", l2, f64(hit.node.size) * 100 / f64(size_sum))
	text(cx - f32(text_width(l2, fs(11))) / 2, cy + px(14), l2, fs(11), DIM)
	if running {
		l3 := fmt.tprintf("計算中 %d / %d", len(top), total)
		text(cx - f32(text_width(l3, fs(10))) / 2, cy + px(30), l3, fs(10), ACCENT)
	} else if s.path != app.home {
		l3 := "↑ クリックで上へ"
		text(cx - f32(text_width(l3, fs(10))) / 2, cy + px(30), l3, fs(10), DIM)
	}
	if hit.node != nil || in_center do app.animating = true // keep hover highlight in step with the pointer

	// clicks: a folder → dive in; the center → up (not above home). Applied after drawing:
	// switching roots can free this scan's nodes, which the legend below still reads.
	next_root := ""
	defer if next_root != "" do sunburst_set_root(next_root)
	if app.pressed && app.button == 1 && p >= 1 {
		if hit.node != nil && hit.node.is_dir {
			parts := make([dynamic]string, context.temp_allocator)
			append(&parts, s.path)
			for i in 0 ..= hit.depth do append(&parts, hit.path[i])
			next_root, _ = filepath.join(parts[:], context.temp_allocator)
		} else if in_center && s.path != app.home && strings.has_prefix(s.path, app.home) {
			next_root = filepath.dir(s.path)
		}
	}

	// legend: the biggest items, with "open" for folders
	lx, ly, lw := r.x + d + px(24), r.y + px(8), r.w - d - px(24)
	if !wide do lx, ly, lw = r.x, r.y + d + px(24), r.w
	for k, i in top {
		if i >= 12 do break
		row := Rect{lx, ly + f32(i) * px(30), lw, px(28)}
		if hovering(row) do rrect(row, px(6), HOVER)
		rrect({row.x + px(6), row.y + px(9), px(10), px(10)}, px(3), seg_color(i, 0, k.is_dir))
		text(row.x + px(24), baseline(row, fs(13)), ellipsize(k.name, fs(13), lw - px(150)), fs(13), FG)
		sz := fmt.tprintf("%s  %d%%", format_size(k.size), int(f64(k.size) * 100 / f64(max(size_sum, 1)) + 0.5))
		text(row.x + row.w - f32(text_width(sz, fs(12))) - px(8), baseline(row, fs(12)), sz, fs(12), DIM)
		if k.is_dir && clicked(row) {
			p, _ := filepath.join({s.path, k.name}, context.temp_allocator)
			push(.Navigate, 0, p) // the legend opens the folder in the file list
		}
	}
	legend_h := f32(min(len(top), 12)) * px(30)
	return d + px(16) if wide else d + px(32) + legend_h
}

sunburst_running :: proc() -> bool {return sb.cur != nil && sync.atomic_load(&sb.cur.running)}

// The root's children measured so far (biggest first), how many there are, their total.
sunburst_snapshot :: proc() -> (top: []^SNode, total: int, size: i64) {
	s := sb.cur
	if s == nil do return
	sync.mutex_lock(&sb.lock)
	top = slice.clone(s.top[:], context.temp_allocator)
	total, size = s.total, s.size
	sync.mutex_unlock(&sb.lock)
	slice.sort_by(top, proc(x, y: ^SNode) -> bool {return x.size > y.size})
	return
}
