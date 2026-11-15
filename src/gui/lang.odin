#+feature dynamic-literals
package main

// Programming-language and framework logos, drawn from real logo SVGs bundled into the
// binary (assets/icons, see SOURCES.md) by our own rasterizer (svg.odin): source files by
// extension or well-known name (Dockerfile, next.config.js…), and project folders by
// their manifest (package.json → React / Next.js / Vue…, Cargo.toml → Yew / Leptos…).

import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:sync"
import "core:thread"

Lang :: struct {
	icon:  string, // assets/icons/<icon>.svg
	label: string,
}

// Frameworks
FW_REACT    :: Lang{"react", "React"}
FW_NEXT     :: Lang{"nextdotjs", "Next.js"}
FW_VUE      :: Lang{"vuedotjs", "Vue"}
FW_NUXT     :: Lang{"nuxt", "Nuxt"}
FW_ANGULAR  :: Lang{"angular", "Angular"}
FW_SVELTE   :: Lang{"svelte", "Svelte"}
FW_VITE     :: Lang{"vite", "Vite"}
FW_TAILWIND :: Lang{"tailwindcss", "Tailwind"}
FW_NODE     :: Lang{"nodedotjs", "Node.js"}
FW_DJANGO   :: Lang{"django", "Django"}
FW_RAILS    :: Lang{"rubyonrails", "Rails"}
FW_LARAVEL  :: Lang{"laravel", "Laravel"}
FW_FLUTTER  :: Lang{"flutter", "Flutter"}
FW_DOTNET   :: Lang{"dotnet", ".NET"}
FW_TAURI    :: Lang{"tauri", "Tauri"}
FW_SPRING   :: Lang{"spring", "Spring"}
FW_QT       :: Lang{"qt", "Qt"}
FW_SUPABASE :: Lang{"supabase", "Supabase"}
FW_YEW      :: Lang{"yew", "Yew"}
FW_LEPTOS   :: Lang{"leptos", "Leptos"}
FW_DIOXUS   :: Lang{"dioxus", "Dioxus"}
FW_BEVY     :: Lang{"bevy", "Bevy"}
FW_ASTRO    :: Lang{"astro", "Astro"}
FW_REMIX    :: Lang{"remix", "Remix"}
FW_SOLID    :: Lang{"solid", "Solid"}
FW_ELECTRON :: Lang{"electron", "Electron"}
FW_EXPRESS  :: Lang{"express", "Express"}
FW_FLASK    :: Lang{"flask", "Flask"}
FW_FASTAPI  :: Lang{"fastapi", "FastAPI"}
FW_DENO     :: Lang{"deno", "Deno"}
// Languages (also the project fallback)
LG_RUST   :: Lang{"rust", "Rust"}
LG_PYTHON :: Lang{"python", "Python"}
LG_GO     :: Lang{"go", "Go"}
LG_DART   :: Lang{"dart", "Dart"}
LG_RUBY   :: Lang{"ruby", "Ruby"}
LG_PHP    :: Lang{"php", "PHP"}
LG_JAVA   :: Lang{"openjdk", "Java"}
LG_ZIG    :: Lang{"zig", "Zig"}

@(private = "file")
LANG_BY_EXT := map[string]string {
	".pdf" = "acrobat",
	".py" = "python", ".pyw" = "python", ".pyi" = "python", ".ipynb" = "jupyter",
	".js" = "javascript", ".mjs" = "javascript", ".cjs" = "javascript",
	".ts" = "typescript", ".mts" = "typescript", ".cts" = "typescript",
	".jsx" = "react", ".tsx" = "react",
	".rs" = "rust", ".go" = "go",
	".c" = "c", ".h" = "c",
	".cpp" = "cplusplus", ".cc" = "cplusplus", ".cxx" = "cplusplus", ".hpp" = "cplusplus", ".hh" = "cplusplus", ".hxx" = "cplusplus",
	".java" = "openjdk", ".kt" = "kotlin", ".kts" = "kotlin",
	".lua" = "lua", ".rb" = "ruby",
	".html" = "html5", ".htm" = "html5", ".css" = "css", ".scss" = "sass", ".sass" = "sass",
	".r" = "r", ".swift" = "swift", ".php" = "php", ".cs" = "csharp", ".hs" = "haskell",
	".md" = "markdown", ".markdown" = "markdown",
	".sh" = "gnubash", ".bash" = "gnubash", ".zsh" = "gnubash", ".fish" = "gnubash",
	".json" = "json", ".jsonc" = "json",
	".vue" = "vuedotjs", ".dart" = "dart", ".zig" = "zig", ".nix" = "nixos",
	".ex" = "elixir", ".exs" = "elixir", ".scala" = "scala", ".jl" = "julia",
	".clj" = "clojure", ".cljs" = "clojure", ".edn" = "clojure",
	".ml" = "ocaml", ".mli" = "ocaml",
	".tex" = "latex", ".sty" = "latex", ".bib" = "latex",
	".sql" = "sql",
	".yaml" = "yaml", ".yml" = "yaml", ".toml" = "toml",
	".xml" = "xml", ".xsd" = "xml", ".xsl" = "xml",
	".vim" = "vim", ".pl" = "perl", ".pm" = "perl", ".nim" = "nim", ".elm" = "elm",
	".fs" = "fsharp", ".fsx" = "fsharp", ".ps1" = "powershell", ".psm1" = "powershell",
	".cmake" = "cmake", ".mk" = "gnu", ".odin" = "odin", ".gradle" = "gradle",
	".tf" = "terraform", ".tfvars" = "terraform",
	".svelte" = "svelte", ".astro" = "astro",
	".csproj" = "dotnet", ".sln" = "dotnet", ".razor" = "dotnet",
	".gitignore" = "git", ".gitattributes" = "git", ".gitmodules" = "git",
}

@(private = "file")
LANG_BY_NAME := map[string]Lang {
	"dockerfile"         = {"docker", "Docker"},
	"containerfile"      = {"docker", "Docker"},
	"docker-compose.yml" = {"docker", "Docker"},
	"compose.yaml"       = {"docker", "Docker"},
	"makefile"           = {"gnu", "Make"},
	"gnumakefile"        = {"gnu", "Make"},
	"cmakelists.txt"     = {"cmake", "CMake"},
	"package.json"       = FW_NODE,
	"angular.json"       = FW_ANGULAR,
	"manage.py"          = FW_DJANGO,
	"artisan"            = FW_LARAVEL,
	"pubspec.yaml"       = FW_FLUTTER,
	"tauri.conf.json"    = FW_TAURI,
	"trunk.toml"         = FW_YEW, // Trunk bundles Yew / Leptos apps
	"dioxus.toml"        = FW_DIOXUS,
	"cargo.toml"         = LG_RUST,
	"cargo.lock"         = LG_RUST,
	"gemfile"            = LG_RUBY,
	"go.mod"             = LG_GO,
	"build.zig.zon"      = LG_ZIG,
	"deno.json"          = FW_DENO,
}

// Config files named <stem>.config.<js|ts|mjs|cjs>
@(private = "file")
LANG_BY_CONFIG := map[string]Lang {
	"next"     = FW_NEXT,
	"nuxt"     = FW_NUXT,
	"vite"     = FW_VITE,
	"vitest"   = FW_VITE,
	"tailwind" = FW_TAILWIND,
	"svelte"   = FW_SVELTE,
	"astro"    = FW_ASTRO,
	"remix"    = FW_REMIX,
}

lang_of :: proc(name: string) -> (l: Lang, ok: bool) {
	base := strings.to_lower(filepath.base(name), context.temp_allocator)
	if l, ok = LANG_BY_NAME[base]; ok do return
	if i := strings.index(base, ".config."); i > 0 {
		if l, ok = LANG_BY_CONFIG[base[:i]]; ok do return
	}
	icon: string
	icon, ok = LANG_BY_EXT[filepath.ext(base)]
	return {icon, ""}, ok
}

// ---------------------------------------------------------------------------
// Bundled icons, rasterized on first use per size

@(private = "file") ICON_FILES := #load_directory("../../assets/icons")
@(private = "file") icon_svgs: map[string]string
@(private = "file") icon_cache: map[[2]int][]u32 // (icon index, size) → pixels

@(private = "file")
icon_svg :: proc(name: string) -> (svg: string, idx: int, ok: bool) {
	if len(icon_svgs) == 0 {
		for f in ICON_FILES do if strings.has_suffix(f.name, ".svg") do icon_svgs[strings.trim_suffix(f.name, ".svg")] = string(f.data)
	}
	svg, ok = icon_svgs[name]
	if !ok do return
	for f, i in ICON_FILES do if raw_data(f.data) == raw_data(svg) do idx = i
	return
}

// Brand color of an icon: its first solid fill.
icon_color :: proc(name: string) -> u32 {
	svg, _, ok := icon_svg(name)
	if !ok do return 0x444444
	rest := svg
	for {
		i := strings.index(rest, "fill=\"#")
		if i < 0 do return 0x444444
		h := rest[i + 7:]
		end := strings.index_byte(h, '"')
		if end == 6 {
			if v, vok := strconv.parse_uint(h[:6], 16); vok do return u32(v)
		}
		rest = h
	}
}

// Draws the logo into a square of side size centered in r. Renders at a fixed step
// size (16, 24, 32, 48, 64, 96, 128) and scales, so animated sizes don't fill the cache.
draw_icon :: proc(r: Rect, name: string, size: f32) -> bool {
	_, idx, ok := icon_svg(name)
	if !ok do return false
	step := 128
	for st in ([]int{16, 24, 32, 48, 64, 96}) do if f32(st) >= size {step = st; break}
	key := [2]int{idx, step}
	img, cached := icon_cache[key]
	if !cached {
		svg, _, _ := icon_svg(name)
		img = svg_rasterize(svg, step)
		icon_cache[key] = img
	}
	blit_scaled({r.x + (r.w - size) / 2, r.y + (r.h - size) / 2, size, size}, img, step, step)
	return true
}

// Logo centered in r (size: its side), or the name if the icon is missing.
draw_lang :: proc(r: Rect, l: Lang, size: f32) {
	if draw_icon(r, l.icon, size) do return
	ts := i32(size * 0.55)
	for ts > 6 && f32(text_width(l.label, ts, true)) > r.w - 2 do ts -= 1
	tw := f32(text_width(l.label, ts, true))
	text(r.x + (r.w - tw) / 2, baseline(r, ts), l.label, ts, hex(0x444444), true)
}

// ---------------------------------------------------------------------------
// Project folders: what framework / language a folder is, from its manifest files

// Detected projects, kept live: the folders each detection looked at are watched while
// the project is on screen, and a change anywhere in them re-detects it shortly after.
@(private = "file")
Project :: struct {
	lang:    Lang,
	ok:      bool,
	pending: bool, // being (re)detected by the worker; the old badge stays meanwhile
	dirs:    [dynamic]string, // root + the subfolders main_language walked
	seen:    u64, // frame it was last drawn in
}

// Detection walks up to 4000 entries per folder, so it runs on a worker thread:
// the badge appears when ready and scrolling never waits for the disk.
project_async := false // set at startup; tests detect synchronously

@(private = "file")
Done :: struct {
	dir:  string,
	gen:  int,
	lang: Lang,
	ok:   bool,
	dirs: [dynamic]string,
}
@(private = "file") q: struct {
	lock: sync.Mutex,
	sema: sync.Sema,
	jobs: [dynamic]string, // newest last; the worker takes newest first (what just scrolled into view)
	done: [dynamic]Done,
	gen:  int, // bumped on navigation: results for the old folder are dropped
	th:   ^thread.Thread,
}

@(private = "file")
project_worker :: proc() {
	for {
		sync.sema_wait(&q.sema)
		sync.mutex_lock(&q.lock)
		if len(q.jobs) == 0 {
			sync.mutex_unlock(&q.lock)
			continue
		}
		dir := pop(&q.jobs)
		gen := q.gen
		sync.mutex_unlock(&q.lock)
		dirs := make([dynamic]string)
		append(&dirs, strings.clone(dir))
		lang, ok := project_detect(dir, &dirs)
		free_all(context.temp_allocator)
		sync.mutex_lock(&q.lock)
		append(&q.done, Done{dir, gen, lang, ok, dirs})
		sync.mutex_unlock(&q.lock)
		wake()
	}
}

@(private = "file")
project_queue :: proc(dir: string) {
	sync.mutex_lock(&q.lock)
	append(&q.jobs, strings.clone(dir))
	sync.mutex_unlock(&q.lock)
	sync.sema_post(&q.sema)
	if q.th == nil do q.th = thread.create_and_start(project_worker)
}

@(private = "file")
free_dirs :: proc(dirs: ^[dynamic]string) {
	for d in dirs do delete(d)
	delete(dirs^)
}
@(private = "file") projects: map[string]Project // cleared when leaving the folder
@(private = "file") stale: map[string]i64 // project root → when to re-detect (debounce)

PROJECT_WATCH_MAX :: 400 // inotify watches / kqueue fds spent on visible projects

@(private = "file")
project_free :: proc(root: string) {
	if p, ok := projects[root]; ok {
		for d in p.dirs do delete(d)
		delete(p.dirs)
		k, _ := delete_key(&projects, root)
		delete(k)
	}
	if root in stale {
		k, _ := delete_key(&stale, root)
		delete(k)
	}
}

projects_clear :: proc() {
	sync.mutex_lock(&q.lock)
	q.gen += 1
	for d in q.jobs do delete(d)
	clear(&q.jobs)
	sync.mutex_unlock(&q.lock)
	roots := make([dynamic]string, context.temp_allocator)
	for k in projects do append(&roots, strings.clone(k, context.temp_allocator))
	for k in roots do project_free(k)
	for k in stale do delete(k)
	clear(&stale)
}

// Folders to watch: those of the projects drawn in the last frame.
project_watch_dirs :: proc(out: ^[dynamic]string) {
	n := 0
	for _, p in projects {
		if p.seen != frame_no do continue
		for d in p.dirs {
			if n >= PROJECT_WATCH_MAX do return
			append(out, d)
			n += 1
		}
	}
}

// A watched folder changed: re-detect the project(s) containing it in 0.4 s.
project_changed :: proc(dir: string) {
	for root, p in projects {
		for d in p.dirs do if d == dir {
			if root not_in stale do stale[strings.clone(root)] = ticks_ms() + 400
			break
		}
	}
}

// Takes in the worker's results and re-detects projects whose debounce ran out;
// true if a redraw is needed.
project_tick :: proc() -> bool {
	changed := false
	sync.mutex_lock(&q.lock)
	done := q.done
	q.done = {}
	gen := q.gen
	sync.mutex_unlock(&q.lock)
	for &d in done {
		p, ok := &projects[d.dir]
		if d.gen == gen && ok {
			free_dirs(&p.dirs)
			p.lang, p.ok, p.dirs, p.pending = d.lang, d.ok, d.dirs, false
			changed = true
		} else do free_dirs(&d.dirs)
		delete(d.dir)
	}
	delete(done)

	now := ticks_ms()
	due := make([dynamic]string, context.temp_allocator)
	for root, t in stale do if now >= t do append(&due, strings.clone(root, context.temp_allocator))
	for root in due {
		if !project_async {
			project_free(root) // the next draw detects it again
		} else if p, ok := &projects[root]; ok {
			k, _ := delete_key(&stale, root)
			delete(k)
			if !p.pending {
				p.pending = true
				project_queue(root)
			}
		}
		changed = true
	}
	return changed
}

project_deadline :: proc() -> i64 {
	d: i64
	for _, t in stale do if d == 0 || t < d do d = t
	return d
}

@(private = "file")
read_small :: proc(dir, name: string) -> (s: string, ok: bool) {
	p, _ := filepath.join({dir, name}, context.temp_allocator)
	fi, err := os.stat(p, context.temp_allocator)
	if err != nil || fi.size > 256 * 1024 do return
	data, rerr := os.read_entire_file_from_path(p, context.temp_allocator)
	return string(data), rerr == nil
}

@(private = "file")
exists_in :: proc(dir, name: string) -> bool {
	p, _ := filepath.join({dir, name}, context.temp_allocator)
	return os.exists(p)
}

// A dependency named dep in a Cargo.toml: `dep = ...`, `dep.workspace = ...` or [dependencies.dep]
toml_dep :: proc(toml, dep: string) -> bool {
	text := toml
	for line in strings.split_lines_iterator(&text) {
		l := strings.trim_space(line)
		if strings.has_prefix(l, "[") && strings.has_suffix(l, strings.concatenate({".", dep, "]"}, context.temp_allocator)) do return true
		if !strings.has_prefix(l, dep) || len(l) == len(dep) do continue
		if c := l[len(dep)]; c == ' ' || c == '=' || c == '.' do return true
	}
	return false
}

// A framework found in the manifest wins (React, Yew, Django…); otherwise the language
// with the most source code (by bytes) — so a mostly-Odin repo with a small build.zig
// is Odin, not Zig. Folders without any code get no badge.
project_detect :: proc(dir: string, dirs: ^[dynamic]string = nil) -> (Lang, bool) {
	marker: Lang // language a manifest implies, used when no source files are found
	if pkg, ok := read_small(dir, "package.json"); ok {
		has :: proc(pkg, dep: string) -> bool {return strings.contains(pkg, strings.concatenate({"\"", dep}, context.temp_allocator))}
		switch {
		case exists_in(dir, "src-tauri"):   return FW_TAURI, true
		case has(pkg, "next\""):            return FW_NEXT, true
		case has(pkg, "nuxt\""):            return FW_NUXT, true
		case has(pkg, "astro\""):           return FW_ASTRO, true
		case has(pkg, "@remix-run/"):       return FW_REMIX, true
		case has(pkg, "@angular/core\""):   return FW_ANGULAR, true
		case has(pkg, "svelte\"") || has(pkg, "@sveltejs/kit\""): return FW_SVELTE, true
		case has(pkg, "solid-js\""):        return FW_SOLID, true
		case has(pkg, "vue\""):             return FW_VUE, true
		case has(pkg, "electron\""):        return FW_ELECTRON, true
		case has(pkg, "react\""):           return FW_REACT, true
		case has(pkg, "express\""):         return FW_EXPRESS, true
		case has(pkg, "vite\""):            return FW_VITE, true
		}
		marker = FW_NODE
	}
	if cargo, ok := read_small(dir, "Cargo.toml"); ok {
		switch {
		case toml_dep(cargo, "yew"):    return FW_YEW, true
		case toml_dep(cargo, "leptos"): return FW_LEPTOS, true
		case toml_dep(cargo, "dioxus"): return FW_DIOXUS, true
		case toml_dep(cargo, "bevy"):   return FW_BEVY, true
		case toml_dep(cargo, "tauri"):  return FW_TAURI, true
		}
		marker = LG_RUST
	}
	if pub, ok := read_small(dir, "pubspec.yaml"); ok {
		if strings.contains(pub, "flutter") do return FW_FLUTTER, true
		marker = LG_DART
	}
	if exists_in(dir, "manage.py") do return FW_DJANGO, true
	if exists_in(dir, "artisan") do return FW_LARAVEL, true
	for f in ([]string{"pyproject.toml", "requirements.txt", "setup.py"}) {
		if py, ok := read_small(dir, f); ok {
			low := strings.to_lower(py, context.temp_allocator)
			switch {
			case strings.contains(low, "django"):  return FW_DJANGO, true
			case strings.contains(low, "fastapi"): return FW_FASTAPI, true
			case strings.contains(low, "flask"):   return FW_FLASK, true
			}
			marker = LG_PYTHON
		}
	}
	if gem, ok := read_small(dir, "Gemfile"); ok {
		if strings.contains(gem, "rails") do return FW_RAILS, true
		marker = LG_RUBY
	}
	if comp, ok := read_small(dir, "composer.json"); ok {
		if strings.contains(comp, "laravel/") do return FW_LARAVEL, true
		marker = LG_PHP
	}
	for f in ([]string{"pom.xml", "build.gradle", "build.gradle.kts"}) {
		if j, ok := read_small(dir, f); ok {
			if strings.contains(j, "springframework") do return FW_SPRING, true
			marker = LG_JAVA
		}
	}
	if exists_in(dir, "deno.json") || exists_in(dir, "deno.jsonc") do return FW_DENO, true
	if cm, ok := read_small(dir, "CMakeLists.txt"); ok && (strings.contains(cm, "Qt6") || strings.contains(cm, "Qt5")) do return FW_QT, true
	if exists_in(dir, "supabase/config.toml") do return FW_SUPABASE, true
	if exists_in(dir, "go.mod") do marker = LG_GO
	if exists_in(dir, "build.zig") do marker = LG_ZIG

	// any folder: whatever language it holds the most of right now
	if l, ok := main_language(dir, dirs); ok do return l, true
	return marker, marker.icon != ""
}

// Languages that count as "the project's language" (not data / docs / config).
@(private = "file")
LANGUAGE_NAMES := map[string]string {
	"python" = "Python", "javascript" = "JavaScript", "typescript" = "TypeScript", "react" = "React",
	"rust" = "Rust", "go" = "Go", "c" = "C", "cplusplus" = "C++", "openjdk" = "Java", "kotlin" = "Kotlin",
	"lua" = "Lua", "ruby" = "Ruby", "html5" = "HTML", "css" = "CSS", "sass" = "Sass", "r" = "R",
	"swift" = "Swift", "php" = "PHP", "csharp" = "C#", "haskell" = "Haskell", "gnubash" = "Shell",
	"vuedotjs" = "Vue", "dart" = "Dart", "zig" = "Zig", "nixos" = "Nix", "elixir" = "Elixir",
	"scala" = "Scala", "julia" = "Julia", "clojure" = "Clojure", "ocaml" = "OCaml", "perl" = "Perl",
	"nim" = "Nim", "elm" = "Elm", "fsharp" = "F#", "powershell" = "PowerShell", "odin" = "Odin",
	"svelte" = "Svelte", "astro" = "Astro", "jupyter" = "Jupyter", "latex" = "LaTeX",
}

// Build output, dependencies and caches are not the project's own code.
@(private = "file")
SKIP_DIRS :: []string {"node_modules", "target", "zig-cache", "zig-out", "build", "dist", "out", "vendor", "third_party", "venv", "__pycache__", "Pods", "bin", "obj"}

// The language with the most bytes of source, looking up to 3 levels deep (at most ~4000 entries).
main_language :: proc(dir: string, dirs: ^[dynamic]string = nil) -> (Lang, bool) {
	bytes := make(map[string]i64, 16, context.temp_allocator)
	budget := 4000
	walk :: proc(dir: string, depth: int, bytes: ^map[string]i64, budget: ^int, dirs: ^[dynamic]string) {
		infos, err := os.read_all_directory_by_path(dir, context.temp_allocator)
		if err != nil do return
		for fi in infos {
			if budget^ <= 0 do return
			budget^ -= 1
			if strings.has_prefix(fi.name, ".") do continue
			if fi.type == .Directory {
				if depth < 3 && !slice.contains(SKIP_DIRS, fi.name) {
					if dirs != nil && len(dirs) < 64 do append(dirs, strings.clone(fi.fullpath))
					walk(fi.fullpath, depth + 1, bytes, budget, dirs)
				}
				continue
			}
			ext := strings.to_lower(filepath.ext(fi.name), context.temp_allocator)
			if icon, ok := LANG_BY_EXT[ext]; ok && icon in LANGUAGE_NAMES do bytes[icon] += max(fi.size, 1)
		}
	}
	walk(dir, 0, &bytes, &budget, dirs)
	best, most := "", i64(0)
	for icon, n in bytes do if n > most || n == most && icon < best {best, most = icon, n}
	if best == "" do return {}, false
	return {best, LANGUAGE_NAMES[best]}, true
}

// Cached per folder; only folders actually drawn are looked at.
project_of :: proc(dir: string) -> (Lang, bool) {
	if p, ok := &projects[dir]; ok {
		p.seen = frame_no
		return p.lang, p.ok
	}
	p := Project{seen = frame_no}
	append(&p.dirs, strings.clone(dir))
	if project_async {
		p.pending = true
		project_queue(dir)
	} else do p.lang, p.ok = project_detect(dir, &p.dirs)
	projects[strings.clone(dir)] = p
	return p.lang, p.ok
}

// White badge with the project's logo in the folder's lower right corner.
project_badge :: proc(x, y, s: f32, dir: string) {
	l, ok := project_of(dir)
	if !ok do return
	b := s * 0.46
	r := Rect{x + s - b * 0.92, y + s - b * 0.98, b, b}
	rrect({r.x, r.y + s * 0.02, r.w, r.h}, b * 0.28, hex(0x000000, 60))
	rrect(r, b * 0.28, hex(0xffffff, 245))
	draw_lang(r, l, b * 0.72)
}

// List rows: a "logo + name" chip after the folder name (a badge would be too small there).
project_chip :: proc(x, cy: f32, dir: string) {
	l, ok := project_of(dir)
	if !ok do return
	size := fs(11)
	h := px(18)
	tw := f32(text_width(l.label, size, true))
	gw := px(16)
	r := Rect{x, cy - h / 2, tw + gw + px(12), h}
	rrect(r, h / 2, hex(0xffffff, 235))
	draw_icon({r.x + px(4), r.y, px(14), h}, l.icon, px(12))
	text(r.x + px(6) + gw, baseline(r, size), l.label, size, hex(icon_color(l.icon)), true)
}

// ---------------------------------------------------------------------------
// "Language" as a property of any entry, for sorting, grouping and filtering:
// a folder's badge (framework / main language), a file's logo (language, or formats
// like Markdown, JSON, Docker, PDF).

@(private = "file")
FORMAT_NAMES := map[string]string {
	"markdown" = "Markdown", "json" = "JSON", "yaml" = "YAML", "toml" = "TOML", "xml" = "XML",
	"docker" = "Docker", "git" = "Git", "gnu" = "Make", "cmake" = "CMake", "acrobat" = "PDF",
	"sql" = "SQL", "gradle" = "Gradle", "terraform" = "Terraform", "dotnet" = ".NET",
	"nextdotjs" = "Next.js", "nuxt" = "Nuxt", "vite" = "Vite", "tailwindcss" = "Tailwind",
	"nodedotjs" = "Node.js", "angular" = "Angular", "django" = "Django", "laravel" = "Laravel",
	"flutter" = "Flutter", "tauri" = "Tauri", "yew" = "Yew", "dioxus" = "Dioxus", "deno" = "Deno",
	"remix" = "Remix",
}

// Display name of a Lang (file entries only carry the icon).
lang_label :: proc(l: Lang) -> string {
	if l.label != "" do return l.label
	if n, ok := LANGUAGE_NAMES[l.icon]; ok do return n
	if n, ok := FORMAT_NAMES[l.icon]; ok do return n
	return l.icon
}

// The language / framework of an entry ("" when it has none, or a folder still being looked at).
entry_lang :: proc(e: ^Entry) -> (l: Lang, label: string) {
	ok: bool
	if e.is_dir do l, ok = project_of(full_path(e.name))
	else do l, ok = lang_of(e.name)
	if !ok do return {}, ""
	return l, lang_label(l)
}
