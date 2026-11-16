package main

// Installed applications from the system's package managers, with their sizes, and full
// removal (the package, its now-unneeded dependencies and its settings).
//   apk (Alpine, Chimera) · pacman (Arch) · dpkg/apt (Debian, Ubuntu) · rpm with dnf/zypper
//   (Fedora, openSUSE) · xbps (Void) · pkg (FreeBSD) · Flatpak
// Databases are read directly where they are plain text (fast, no root); others via their
// query tool. Removal runs in a terminal through doas / sudo / pkexec, so the user sees the
// exact command and types the password there — never a shell string, never silently.

import "core:fmt"
import "core:mem"
import "core:mem/virtual"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:sync"
import "core:thread"

Pkg_Manager :: enum u8 {
	Apk, Pacman, Dpkg, Rpm, Xbps, Pkg, Flatpak,
}

PKG_MANAGER_NAMES := [Pkg_Manager]string {
	.Apk = "apk", .Pacman = "pacman", .Dpkg = "apt", .Rpm = "rpm", .Xbps = "xbps", .Pkg = "pkg", .Flatpak = "Flatpak",
}

Package :: struct {
	name, version, desc: string,
	size:                i64, // installed bytes (-1 unknown)
	manager:             Pkg_Manager,
	explicit:            bool, // installed on purpose (not only as a dependency)
	system:              bool, // Flatpak: system-wide installation
	protected:           bool, // the system needs it (kernel, libc, init, package manager…): no remove button
}

// Packages whose removal can leave the machine unbootable or without a way to install
// anything again. Debian's own "Essential" / "required" marks are honoured too (scan_dpkg).
@(private = "file")
PROTECTED :: []string {
	"linux", "linux-lts", "linux-stable", "linux-zen", "linux-hardened", "kernel", "kernel-core",
	"base", "base-files", "base-full", "base-minimal", "base-system", "base-devel",
	"musl", "glibc", "libc", "libc6", "gcc-libs", "llvm-runtime",
	"apk-tools", "pacman", "dpkg", "apt", "rpm", "dnf", "zypper", "xbps", "pkg", "flatpak",
	"systemd", "dinit", "dinit-chimera", "openrc", "runit", "runit-void", "sysvinit",
	"doas", "opendoas", "sudo", "polkit", "util-linux", "coreutils", "chimerautils", "busybox",
	"bash", "dash", "zsh", "shadow", "pam", "linux-pam", "e2fsprogs", "btrfs-progs", "grub", "systemd-boot",
	"wayland", "mesa", "dbus", "elogind", "seatd", "eudev", "udev", "networkmanager", "iwd",
}

@(private = "file")
is_protected :: proc(name: string) -> bool {
	for n in PROTECTED do if name == n do return true
	return strings.has_prefix(name, "linux-firmware") || strings.has_prefix(name, "base-") || strings.has_prefix(name, "kernel-")
}

pk: struct {
	lock:     sync.Mutex,
	arena:    virtual.Arena, // the list's strings (one arena per scan)
	list:     [dynamic]Package, // valid while !scanning
	scanning: bool, // atomic
	scanned:  bool,
	th:       ^thread.Thread,
	removing: string, // package being removed (shown while its terminal is open)
}

// A package name we are willing to put on a command line: nothing an option parser or a
// terminal could misread.
pkg_name_ok :: proc(s: string) -> bool {
	if s == "" || s[0] == '-' || len(s) > 200 do return false
	for c in s {
		switch c {
		case 'a' ..= 'z', 'A' ..= 'Z', '0' ..= '9', '.', '_', '+', '-', '@', ':':
		case: return false
		}
	}
	return true
}

// ---------------------------------------------------------------------------
// Readers (all run on the scan thread, allocating from the arena)

@(private = "file")
read_text :: proc(path: string) -> string {
	data, err := os.read_entire_file_from_path(path, context.temp_allocator)
	return string(data) if err == nil else ""
}

// /lib/apk/db/installed: blank-line separated records of "K:value" lines; explicit = in /etc/apk/world.
@(private = "file")
scan_apk :: proc(out: ^[dynamic]Package, a: mem.Allocator) {
	db := read_text("/lib/apk/db/installed")
	if db == "" do return
	world := make(map[string]bool, 256, context.temp_allocator)
	w := read_text("/etc/apk/world")
	for line in strings.split_lines_iterator(&w) {
		name := line
		if i := strings.index_any(line, "<>=~@"); i >= 0 do name = line[:i]
		if name != "" do world[strings.trim_space(name)] = true
	}
	p: Package
	p.manager, p.size = .Apk, -1
	flush :: proc(out: ^[dynamic]Package, p: ^Package, world: map[string]bool) {
		if p.name != "" {
			p.explicit = p.name in world
			append(out, p^)
		}
		p^ = Package{manager = .Apk, size = -1}
	}
	text := db
	for line in strings.split_lines_iterator(&text) {
		if line == "" {flush(out, &p, world); continue}
		if len(line) < 2 || line[1] != ':' do continue
		v := line[2:]
		switch line[0] {
		case 'P': p.name = strings.clone(v, a)
		case 'V': p.version = strings.clone(v, a)
		case 'T': p.desc = strings.clone(v, a)
		case 'I': p.size, _ = strconv.parse_i64(v)
		}
	}
	flush(out, &p, world)
}

// /var/lib/pacman/local/<pkg>/desc: "%KEY%" then value lines; %REASON% 1 = dependency.
@(private = "file")
scan_pacman :: proc(out: ^[dynamic]Package, a: mem.Allocator) {
	infos, err := os.read_all_directory_by_path("/var/lib/pacman/local", context.temp_allocator)
	if err != nil do return
	for fi in infos {
		if fi.type != .Directory do continue
		desc := read_text(strings.concatenate({fi.fullpath, "/desc"}, context.temp_allocator))
		if desc == "" do continue
		p := Package{manager = .Pacman, size = -1, explicit = true}
		key := ""
		text := desc
		for line in strings.split_lines_iterator(&text) {
			if strings.has_prefix(line, "%") && strings.has_suffix(line, "%") {key = line; continue}
			if line == "" {key = ""; continue}
			switch key {
			case "%NAME%":    p.name = strings.clone(line, a)
			case "%VERSION%": p.version = strings.clone(line, a)
			case "%DESC%":    p.desc = strings.clone(line, a)
			case "%SIZE%":    p.size, _ = strconv.parse_i64(line)
			case "%REASON%":  p.explicit = line != "1"
			}
			key = ""
		}
		if p.name != "" do append(out, p)
	}
}

// /var/lib/dpkg/status (Installed-Size in KiB); automatic = Auto-Installed in apt's extended_states.
@(private = "file")
scan_dpkg :: proc(out: ^[dynamic]Package, a: mem.Allocator) {
	status := read_text("/var/lib/dpkg/status")
	if status == "" do return
	auto := make(map[string]bool, 1024, context.temp_allocator)
	ext := read_text("/var/lib/apt/extended_states")
	name := ""
	for line in strings.split_lines_iterator(&ext) {
		if strings.has_prefix(line, "Package: ") do name = line[9:]
		else if line == "Auto-Installed: 1" && name != "" do auto[name] = true
	}
	p := Package{manager = .Dpkg, size = -1}
	installed := false
	essential := false
	text := status
	for line in strings.split_lines_iterator(&text) {
		switch {
		case line == "":
			if p.name != "" && installed {
				p.explicit = p.name not_in auto
				p.protected = essential
				append(out, p)
			}
			p, installed, essential = Package{manager = .Dpkg, size = -1}, false, false
		case line == "Essential: yes" || line == "Priority: required": essential = true
		case strings.has_prefix(line, "Package: "):        p.name = strings.clone(line[9:], a)
		case strings.has_prefix(line, "Version: "):        p.version = strings.clone(line[9:], a)
		case strings.has_prefix(line, "Description: "):    p.desc = strings.clone(line[13:], a)
		case strings.has_prefix(line, "Status: "):         installed = strings.has_suffix(line, " installed")
		case strings.has_prefix(line, "Installed-Size: "):
			kb, _ := strconv.parse_i64(line[16:])
			p.size = kb * 1024
		}
	}
	if p.name != "" && installed do append(out, p)
}

// Lines of tab-separated fields from a query tool.
@(private = "file")
tool_lines :: proc(cmd: []string) -> [dynamic][]string {
	rows := make([dynamic][]string, context.temp_allocator)
	if !have_tool(cmd[0]) do return rows
	_, stdout, _, err := os.process_exec({command = cmd}, context.temp_allocator)
	if err != nil do return rows
	text := string(stdout)
	for line in strings.split_lines_iterator(&text) do if line != "" do append(&rows, strings.split(line, "\t", context.temp_allocator))
	return rows
}

@(private = "file")
scan_tools :: proc(out: ^[dynamic]Package, a: mem.Allocator) {
	// rpm: no "installed on purpose" flag that is cheap to get, so everything counts
	for f in tool_lines({"rpm", "-qa", "--qf", "%{NAME}\t%{VERSION}-%{RELEASE}\t%{SIZE}\t%{SUMMARY}\n"}) do if len(f) == 4 {
		n, _ := strconv.parse_i64(f[2])
		append(out, Package{strings.clone(f[0], a), strings.clone(f[1], a), strings.clone(f[3], a), n, .Rpm, true, false, false})
	}
	// FreeBSD pkg: %a = automatic, %sb = flat size in bytes
	for f in tool_lines({"pkg", "query", "%n\t%v\t%sb\t%a\t%c"}) do if len(f) == 5 {
		n, _ := strconv.parse_i64(f[2])
		append(out, Package{strings.clone(f[0], a), strings.clone(f[1], a), strings.clone(f[4], a), n, .Pkg, f[3] == "0", false, false})
	}
	// xbps: manually installed ones are listed by -m (sizes aren't in its plain output)
	if have_tool("xbps-query") {
		manual := make(map[string]bool, 256, context.temp_allocator)
		for f in tool_lines({"xbps-query", "-m"}) {
			n := f[0]
			if i := strings.last_index_byte(n, '-'); i > 0 do n = n[:i] // name-version_revision
			manual[n] = true
		}
		for f in tool_lines({"xbps-query", "-l"}) { // "ii name-version description"
			fields := strings.fields(f[0], context.temp_allocator)
			if len(fields) < 2 do continue
			nv := fields[1]
			n, v := nv, ""
			if i := strings.last_index_byte(nv, '-'); i > 0 do n, v = nv[:i], nv[i + 1:]
			desc := strings.join(fields[2:], " ", context.temp_allocator)
			append(out, Package{strings.clone(n, a), strings.clone(v, a), strings.clone(desc, a), -1, .Xbps, n in manual, false, false})
		}
	}
	// Flatpak apps (sizes come human-readable: "1.2 GB")
	for f in tool_lines({"flatpak", "list", "--app", "--columns=application,version,size,installation,name"}) do if len(f) >= 5 {
		append(out, Package{strings.clone(f[0], a), strings.clone(f[1], a), strings.clone(f[4], a), parse_human_size(f[2]), .Flatpak, true, f[3] == "system", false})
	}
}

// "1.2 GB", "540.3 MB", "12 kB" → bytes (-1 if it can't be read).
parse_human_size :: proc(s: string) -> i64 {
	f := strings.fields(strings.trim_space(s), context.temp_allocator)
	if len(f) == 0 do return -1
	n, ok := strconv.parse_f64(strings.trim_right(f[0], " "))
	if !ok do return -1
	unit := strings.to_lower(f[1], context.temp_allocator) if len(f) > 1 else "b"
	mult: f64 = 1
	switch unit {
	case "kb", "kib", "k": mult = 1e3
	case "mb", "mib", "m": mult = 1e6
	case "gb", "gib", "g": mult = 1e9
	case "tb", "tib", "t": mult = 1e12
	}
	return i64(n * mult)
}

@(private = "file")
scan_worker :: proc() {
	list := make([dynamic]Package)
	arena: virtual.Arena
	a := virtual.arena_allocator(&arena)
	scan_apk(&list, a)
	scan_pacman(&list, a)
	scan_dpkg(&list, a)
	scan_tools(&list, a)
	free_all(context.temp_allocator)
	for &p in list do if p.manager != .Flatpak && is_protected(p.name) do p.protected = true
	slice.sort_by(list[:], proc(x, y: Package) -> bool {return x.size > y.size if x.size != y.size else x.name < y.name})
	sync.mutex_lock(&pk.lock)
	delete(pk.list)
	virtual.arena_destroy(&pk.arena)
	pk.list, pk.arena = list, arena
	pk.scanned = true
	sync.mutex_unlock(&pk.lock)
	sync.atomic_store(&pk.scanning, false)
	wake()
}

// Reads the package databases again in the background (on opening the view, after a removal).
packages_rescan :: proc() {
	if sync.atomic_load(&pk.scanning) do return
	if pk.th != nil {
		thread.join(pk.th)
		thread.destroy(pk.th)
	}
	sync.atomic_store(&pk.scanning, true)
	pk.th = thread.create_and_start(scan_worker)
}

// ---------------------------------------------------------------------------
// Removal

// The command that removes the package completely, with the privilege tool in front.
uninstall_argv :: proc(p: Package) -> (argv: [dynamic]string, ok: bool) {
	argv = make([dynamic]string, context.temp_allocator)
	if !pkg_name_ok(p.name) || p.protected do return argv, false
	if p.manager == .Flatpak { // flatpak asks polkit itself for system installs
		append(&argv, "flatpak", "uninstall", "--system" if p.system else "--user", "--delete-data", p.name)
		return argv, true
	}
	switch {
	case have_tool("doas"):   append(&argv, "doas")
	case have_tool("sudo"):   append(&argv, "sudo")
	case have_tool("pkexec"): append(&argv, "pkexec")
	case: return argv, false
	}
	switch p.manager {
	case .Apk:    append(&argv, "apk", "del", p.name) // dependencies nobody else needs go too
	case .Pacman: append(&argv, "pacman", "-Rns", p.name) // + unneeded deps, + config backups
	case .Dpkg:   append(&argv, "apt-get", "purge", "--autoremove", p.name) // purge = settings too
	case .Rpm:
		switch {
		case have_tool("dnf"):    append(&argv, "dnf", "remove", p.name)
		case have_tool("zypper"): append(&argv, "zypper", "remove", "--clean-deps", p.name)
		case:                     append(&argv, "rpm", "-e", p.name)
		}
	case .Xbps:   append(&argv, "xbps-remove", "-R", p.name)
	case .Pkg:    append(&argv, "pkg", "delete", p.name) // pkg autoremove is a separate, explicit step
	case .Flatpak:
	}
	return argv, true
}

@(private = "file") pending: Package // what the confirmation dialog is about (strings copied below)
@(private = "file") pending_cmd: string

begin_uninstall :: proc(p: Package) {
	argv, ok := uninstall_argv(p)
	if !ok {
		toastf("「%s」は削除できません（doas / sudo / pkexec が見つからないか、名前が不正です）", p.name)
		return
	}
	delete(pending_cmd)
	pending_cmd = strings.join(argv[:], " ")
	delete(pending.name)
	pending = p
	pending.name = strings.clone(p.name)
	pending.version, pending.desc = "", "" // the list may be rescanned meanwhile
	app.dialog = .Uninstall
}

uninstall_text :: proc() -> (title, body: string) {
	return fmt.tprintf("「%s」を完全に削除しますか？", pending.name), fmt.tprintf("端末で実行します: %s", pending_cmd)
}

// Confirmed: run the removal in a terminal that stays open on the result.
uninstall_ok :: proc() {
	app.dialog = .None
	argv, ok := uninstall_argv(pending)
	if !ok do return
	exe, err := os.get_executable_path(context.temp_allocator)
	if err != nil do return
	inner := make([dynamic]string, context.temp_allocator)
	append(&inner, exe, "--hold") // prints the command, runs it, waits for Enter
	append(&inner, ..argv[:])
	term := find_terminal()
	if term == "" {
		toastf("端末が見つかりません")
		return
	}
	if pid := spawn(terminal_argv(term, inner[:])[:]); pid != 0 {
		append(&jobs, Job{pid = pid, kind = .Uninstall, label = strings.clone(pending.name)})
		delete(pk.removing)
		pk.removing = strings.clone(pending.name)
	}
}

// The first terminal emulator that is installed ($TERMINAL first).
find_terminal :: proc() -> string {
	terms := [?]string {
		os.get_env("TERMINAL", context.temp_allocator), "ame-terminal", "ghostty", "foot", "kgx", "gnome-terminal",
		"konsole", "alacritty", "kitty", "wezterm", "xfce4-terminal", "xterm", // the usual ones on Arch and FreeBSD
	}
	for t in terms do if t != "" && have_tool(t) do return t
	return ""
}

// How each terminal takes a command to run (no shell in between).
terminal_argv :: proc(term: string, cmd: []string) -> [dynamic]string {
	out := make([dynamic]string, context.temp_allocator)
	append(&out, term)
	switch filepath.base(term) {
	case "foot", "kitty":                  // the command follows directly
	case "kgx", "gnome-terminal":          append(&out, "--")
	case "wezterm":                        append(&out, "start", "--")
	case "xfce4-terminal":                 append(&out, "-x")
	case:                                  append(&out, "-e") // ghostty, konsole, alacritty, xterm, most others
	}
	append(&out, ..cmd)
	return out
}

// `ame-filemanager --hold CMD…` (inside the terminal): runs CMD with the terminal's input
// and output, reports how it went and waits for Enter, so the result can be read.
hold_main :: proc(args: []string) -> int {
	if len(args) == 0 do return 2
	fmt.printfln("$ %s\n", strings.join(args, " ", context.temp_allocator))
	code := 127
	if p, err := os.process_start({command = args, stdin = os.stdin, stdout = os.stdout, stderr = os.stderr}); err == nil {
		st, _ := os.process_wait(p)
		code = st.exit_code if st.exited else 1
	}
	fmt.println()
	fmt.println("完了しました。" if code == 0 else fmt.tprintf("失敗しました（終了コード %d）。", code))
	fmt.print("Enter キーで閉じます…")
	buf: [16]u8
	_, _ = os.read(os.stdin, buf[:])
	return code
}
