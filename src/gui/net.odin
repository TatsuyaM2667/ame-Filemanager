package main

// Network locations over SFTP (sshfs): "サーバーへ接続…" takes user@host:/path, mounts it
// under ~/.cache/ame-filemanager/net/ and opens it. Servers are remembered in net.conf and
// listed in the sidebar (open / disconnect / forget). Key-based login (ssh-agent) only:
// there is no terminal to type a password into, so ssh runs with BatchMode.

import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:sys/posix"

servers: [dynamic]string // "user@host:/path", in the order they were added

@(private = "file")
net_conf :: proc() -> string {
	p, _ := filepath.join({app_config_dir(), "net.conf"}, context.temp_allocator)
	return p
}

load_servers :: proc() {
	data, err := os.read_entire_file_from_path(net_conf(), context.temp_allocator)
	if err != nil do return
	text := string(data)
	for line in strings.split_lines_iterator(&text) do if server_ok(line) do append(&servers, strings.clone(line))
}

@(private = "file")
save_servers :: proc() {
	write_config(net_conf(), strings.concatenate({strings.join(servers[:], "\n", context.temp_allocator), "\n"}, context.temp_allocator))
}

// [user@]host:[path] that can't be mistaken for an ssh option ("-oProxyCommand=…")
// and has nothing a shell or ssh_config would treat specially.
server_ok :: proc(s: string) -> bool {
	host, sep, _ := strings.partition(s, ":")
	if sep == "" || host == "" || strings.has_prefix(host, "-") do return false
	if at := strings.index_byte(host, '@'); at >= 0 && (at == 0 || strings.has_prefix(host[at + 1:], "-")) do return false
	for c in s do if c < ' ' || c == ' ' || c == '\'' || c == '"' || c == '`' || c == '$' || c == '\\' do return false
	return true
}

// Where a server is mounted.
server_mountpoint :: proc(s: string) -> string {
	b := strings.builder_make(context.temp_allocator)
	for c in s do strings.write_rune(&b, '_' if c == '/' || c == ':' else c)
	cache, _ := os.user_cache_dir(context.temp_allocator)
	p, _ := filepath.join({cache, "ame-filemanager", "net", strings.trim_right(strings.to_string(b), "_")}, context.temp_allocator)
	return p
}

// From the mount table when there is one (Linux): stat() on a dead network mount can hang
// the UI. Elsewhere (FreeBSD) a mount point sits on another device than its parent.
is_mounted :: proc(dir: string) -> bool {
	@(static) table: string
	@(static) read_at: i64
	if ticks_ms() - read_at > 1000 {
		delete(table)
		data, err := os.read_entire_file_from_path("/proc/self/mounts", context.allocator)
		table = string(data) if err == nil else ""
		read_at = ticks_ms()
	}
	if table != "" {
		esc, _ := strings.replace_all(dir, " ", "\\040", context.temp_allocator)
		return strings.contains(table, strings.concatenate({" ", esc, " "}, context.temp_allocator))
	}
	a, b: posix.stat_t
	if posix.stat(strings.clone_to_cstring(dir, context.temp_allocator), &a) != .OK do return false
	if posix.stat(strings.clone_to_cstring(filepath.dir(dir), context.temp_allocator), &b) != .OK do return false
	return a.st_dev != b.st_dev
}

begin_connect :: proc() {
	app.dialog = .Connect
	edit_set(&app.dlg_edit, "ユーザー@ホスト:/home/ユーザー", true)
	app.edit_focus = .Dialog
}

connect_ok :: proc() {
	s := strings.trim_space(edit_str(&app.dlg_edit))
	if !server_ok(s) do return
	app.dialog = .None
	known := false
	for v in servers do if v == s do known = true
	if !known {
		append(&servers, strings.clone(s))
		save_servers()
	}
	server_open(s)
}

// Opens a server: straight in if mounted, otherwise mounts it first (in the background).
server_open :: proc(s: string) {
	mp := server_mountpoint(s)
	if is_mounted(mp) {
		push(.Navigate, 0, strings.clone(mp, context.temp_allocator))
		return
	}
	if !have_tool("sshfs") {
		toastf("SFTP の接続には sshfs が必要です（apk add sshfs / pacman -S sshfs / pkg install fusefs-sshfs）")
		return
	}
	_ = os.make_directory_all(mp)
	host, _, path := strings.partition(s, ":")
	remote := strings.concatenate({host, ":", path if path != "" else "."}, context.temp_allocator)
	cmd := []string{"sshfs", "-o", "BatchMode=yes,ConnectTimeout=10,reconnect,ServerAliveInterval=15", remote, mp}
	if pid := spawn(cmd); pid != 0 {
		append(&jobs, Job{pid = pid, kind = .Net_Mount, label = strings.clone(s), dest = strings.clone(mp)})
		toastf("「%s」に接続しています…", s)
	}
}

server_disconnect :: proc(s: string) {
	mp := server_mountpoint(s)
	if strings.has_prefix(app.cwd, mp) do go_to(app.home) // don't keep it busy
	cmd: []string
	switch {
	case have_tool("fusermount3"): cmd = {"fusermount3", "-u", mp}
	case have_tool("fusermount"):  cmd = {"fusermount", "-u", mp}
	case:                          cmd = {"umount", mp} // FreeBSD
	}
	if pid := spawn(cmd); pid != 0 {
		append(&jobs, Job{pid = pid, kind = .Mount, label = strings.clone(s), dest = strings.clone("eject")})
	}
}

server_forget :: proc(i: int) {
	if i < 0 || i >= len(servers) do return
	delete(servers[i])
	ordered_remove(&servers, i)
	save_servers()
}

// Job finished (sshfs daemonizes once connected, so exit 0 = mounted).
net_mount_done :: proc(j: Job, ok: bool) {
	if ok {
		toastf("「%s」に接続しました", j.label)
		go_to(j.dest)
	} else {
		_ = os.remove(j.dest) // the empty mount point
		toastf("「%s」に接続できませんでした（ssh の鍵認証が必要です）", j.label)
	}
}

// Sidebar section: each server, with disconnect (when mounted) or forget (when not).
draw_sidebar_servers :: proc(y: ^f32, w: f32) {
	if len(servers) == 0 do return
	side_section(y, w, "ネットワーク")
	for s, i in servers {
		mp := server_mountpoint(s)
		mounted := is_mounted(mp)
		r := side_row(y, w, 0xf0c2, s, strings.has_prefix(app.cwd, mp), !mounted) // cloud
		br := Rect{r.x + r.w - px(32), r.y + px(4), px(28), r.h - px(8)}
		if hovering(br) do rrect(br, px(6), HOVER)
		glyph_center(br, I_EJECT if mounted else I_CLOSE, fs(12), DIM)
		switch {
		case clicked(br) && mounted: server_disconnect(s)
		case clicked(br):            server_forget(i); return
		case clicked(r):             server_open(s)
		}
	}
}
