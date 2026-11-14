package trash_test

// File operations must report failures as failures: a move deletes its source only
// after the copy succeeded, so a short copy that looks finished loses data.

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import gf "../../src/core"

@(private = "file")
scratch :: proc(t: ^testing.T, name: string) -> string {
	base := os.get_env("GF_TEST_DIR", context.temp_allocator)
	if base == "" do testing.fail_now(t, "set GF_TEST_DIR to an empty scratch directory")
	d := strings.concatenate({base, "/", name}, context.temp_allocator)
	_ = os.remove_all(d)
	_ = os.make_directory_all(d)
	return d
}

@(test)
copy_read_error_is_failure :: proc(t: ^testing.T) {
	when ODIN_OS == .Linux {
		d := scratch(t, "readerr")
		dst := strings.concatenate({d, "/copy"}, context.temp_allocator)
		p: gf.Progress
		// /proc/self/mem is a "regular file" whose first read fails with EIO
		st := gf.copy_tree("/proc/self/mem", dst, &p)
		testing.expect_value(t, st, gf.OperationStatus.ErrorIO)
		testing.expect(t, !os.exists(dst)) // no half-written file left behind
	}
}

@(test)
copy_many_files :: proc(t: ^testing.T) {
	d := scratch(t, "many")
	src := strings.concatenate({d, "/src"}, context.temp_allocator)
	_ = os.make_directory_all(strings.concatenate({src, "/sub"}, context.temp_allocator))
	for i in 0 ..< 300 do _ = os.write_entire_file_from_string(fmt.tprintf("%s/sub/f%d.txt", src, i), fmt.tprintf("file %d", i))
	p: gf.Progress
	testing.expect_value(t, gf.copy_tree(src, strings.concatenate({d, "/dst"}, context.temp_allocator), &p), gf.OperationStatus.Success)
	data, _ := os.read_entire_file_from_path(fmt.tprintf("%s/dst/sub/f299.txt", d), context.temp_allocator)
	testing.expect_value(t, string(data), "file 299")
}

@(test)
errors_keep_their_reason :: proc(t: ^testing.T) {
	d := scratch(t, "reasons")
	testing.expect_value(t, gf.create_directory(d), gf.OperationStatus.ErrorExists)
	testing.expect_value(t, gf.create_directory(strings.concatenate({d, "/no/such/parent"}, context.temp_allocator)), gf.OperationStatus.ErrorNotFound)

	// a move that fails for any reason but "other filesystem" must not copy + delete
	locked := strings.concatenate({d, "/locked"}, context.temp_allocator)
	_ = os.make_directory(locked)
	src := strings.concatenate({d, "/keep.txt"}, context.temp_allocator)
	_ = os.write_entire_file_from_string(src, "precious")
	_ = os.change_mode(locked, {.Read_User, .Execute_User}) // no write permission
	defer _ = os.change_mode(locked, {.Read_User, .Write_User, .Execute_User})
	st := gf.move_file(src, strings.concatenate({locked, "/keep.txt"}, context.temp_allocator))
	if os.get_env("USER", context.temp_allocator) != "root" do testing.expect_value(t, st, gf.OperationStatus.ErrorPermission)
	testing.expect(t, os.exists(src))
}

@(test)
long_paths_are_not_truncated :: proc(t: ^testing.T) {
	d := scratch(t, "long")
	p := d
	for _ in 0 ..< 5 do p = strings.concatenate({p, "/", strings.repeat("x", 240, context.temp_allocator)}, context.temp_allocator)
	_ = os.make_directory_all(p)
	_, st := gf.get_file_info(p)
	testing.expect_value(t, st, gf.OperationStatus.ErrorInvalidPath) // longer than FileInfo.path: refused, not cut
}
