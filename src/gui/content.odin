package main

// Search inside files: with "中身" on in the search bar, files under the current folder
// whose text contains the query are listed too (ripgrep if installed — it skips
// .gitignore'd and binary files — otherwise grep -r). Runs in a worker thread with a
// child process that is killed when the query changes; at most 2000 hits, 30 s.

import "core:c"
import "core:mem"
import "core:mem/virtual"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:sync"
import "core:sys/posix"
import "core:thread"

CONTENT_MAX :: 2000

@(private = "file")
Content_Job :: struct {
	dir, q:   string,
	hidden:   bool,
	cancel:   bool, // atomic
	done:     bool, // atomic
	hits:     [dynamic]string, // paths relative to dir
	th:       ^thread.Thread,
}
@(private = "file") job: ^Content_Job

content_search_on := false
content_names: map[string]bool // hits already listed (keys live in the search arena), so the name walk skips them

search_allocator :: proc() -> mem.Allocator {return virtual.arena_allocator(&app.search_arena)}

@(private = "file")
content_worker :: proc(j: ^Content_Job) {
	defer {
		sync.atomic_store(&j.done, true)
		wake()
	}
	cmd: []string
	if have_tool("rg") {
		cmd = {"rg", "--files-with-matches", "--fixed-strings", "--ignore-case", "--max-filesize", "20M", "--no-messages", "--hidden" if j.hidden else "--no-hidden", "--", j.q, "."}
	} else {
		cmd = {"grep", "-rlIiF", "--", j.q, "."}
	}
	r, w, perr := os.pipe()
	if perr != nil do return
	p, serr := os.process_start({command = cmd, working_dir = j.dir, stdout = w})
	os.close(w)
	defer os.close(r)
	if serr != nil do return
	fd := posix.FD(os.fd(r))
	pending := make([dynamic]u8)
	defer delete(pending)
	chunk: [16384]u8
	start := ticks_ms()
	stop := false
	for !stop {
		if sync.atomic_load(&j.cancel) || ticks_ms() - start > 30_000 do break
		pfd := posix.pollfd{fd = fd, events = {.IN}}
		if posix.poll(&pfd, 1, c.int(30)) == 0 do continue // short: a new keystroke waits for this
		n := posix.read(fd, &chunk[0], len(chunk))
		if n <= 0 do break
		append(&pending, ..chunk[:n])
		for {
			nl := -1
			for b, i in pending do if b == '\n' {nl = i; break}
			if nl < 0 do break
			line := strings.trim_prefix(string(pending[:nl]), "./")
			if line != "" && (j.hidden || !strings.has_prefix(filepath.base(line), ".")) do append(&j.hits, strings.clone(line))
			remove_range(&pending, 0, nl + 1)
			if len(j.hits) >= CONTENT_MAX {stop = true; break}
		}
	}
	_ = os.process_kill(p) // finished, cancelled or capped: never leave it running
	_, _ = os.process_wait(p)
}

@(private = "file")
job_free :: proc(j: ^Content_Job) {
	thread.destroy(j.th)
	for h in j.hits do delete(h)
	delete(j.hits)
	delete(j.dir)
	delete(j.q)
	free(j)
}

// Stops the running search (if any) and starts one for q in the current folder.
content_start :: proc(q: string) {
	content_stop()
	clear(&content_names)
	if !content_search_on || len(q) < 2 || is_tag_view() || in_trash() do return
	j := new(Content_Job)
	j.dir, j.q, j.hidden = strings.clone(app.cwd), strings.clone(q), app.show_hidden
	j.th = thread.create_and_start_with_poly_data(j, content_worker)
	job = j
}

content_stop :: proc() {
	if job == nil do return
	sync.atomic_store(&job.cancel, true)
	thread.join(job.th)
	job_free(job)
	job = nil
}

content_running :: proc() -> bool {return job != nil}

// Adds the finished search's hits as entries; true if the view must be rebuilt.
content_poll :: proc() -> bool {
	if job == nil || !sync.atomic_load(&job.done) do return false
	j := job
	job = nil
	thread.join(j.th)
	defer job_free(j)
	if j.dir != app.cwd || !app.searching do return false
	a := search_allocator()
	have := make(map[string]bool, len(app.entries), context.temp_allocator)
	for e in app.entries[app.base_count:] do have[e.name] = true
	for rel in j.hits {
		if rel in have do continue
		name := strings.clone(rel, a)
		content_names[name] = true
		full, _ := filepath.join({app.cwd, rel}, context.temp_allocator)
		fi, err := os.stat(full, context.temp_allocator)
		if err != nil do continue
		append(&app.entries, Entry {
			name = name, size = fi.size, mtime = fi.modification_time._nsec / 1_000_000_000,
			btime = fi.creation_time._nsec / 1_000_000_000, atime = fi.access_time._nsec / 1_000_000_000,
			kind = kind_of(fi.name, fi.mode), hidden = strings.has_prefix(filepath.base(rel), "."), content_hit = true,
		})
	}
	toastf("中身に「%s」を含むファイル: %d 個%s", j.q, len(j.hits), "（上限）" if len(j.hits) >= CONTENT_MAX else "")
	return true
}
