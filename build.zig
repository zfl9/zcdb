const std = @import("std");

// ================================= API =================================

pub fn create_step(b: *std.Build, name: []const u8) *std.Build.Step {
    const step = b.step(name, "emit compile_commands.json");
    step.makeFn = make;
    return step;
}

pub fn create_gc_step(b: *std.Build, name: []const u8) *std.Build.Step {
    const step = b.step(name, "gc compile_commands.json");
    step.makeFn = make_gc;
    return step;
}

// ================================= private =================================

const CDB_RAW_FILENAME = "cdb.raw";
const CDB_FILENAME = "compile_commands.json";

/// the returns memory is owned by the caller
fn extract_path(b: *std.Build, fragment: []const u8) ?[]const u8 {
    var dir: ?[]const u8 = null;
    var file: ?[]const u8 = null;

    const dir_keyword = "\"directory\": \"";
    const file_keyword = "\"file\": \"";

    if (std.mem.indexOf(u8, fragment, dir_keyword)) |idx| {
        const start = idx + dir_keyword.len;
        if (std.mem.indexOfScalarPos(u8, fragment, start, '"')) |end|
            dir = fragment[start..end];
    }
    if (std.mem.indexOf(u8, fragment, file_keyword)) |idx| {
        const start = idx + file_keyword.len;
        if (std.mem.indexOfScalarPos(u8, fragment, start, '"')) |end|
            file = fragment[start..end];
    }

    if (dir == null or file == null)
        return null;

    return b.fmt("{s}{s}{s}", .{
        dir.?,
        std.fs.path.sep_str,
        file.?,
    });
}

/// the returns memory is owned by the caller
fn format_fragment(b: *std.Build, fragment: []const u8, path: []const u8) ?[]const u8 {
    // clang always emit single-line fragment with trailing comma
    if (fragment.len == 0) return null;
    if (fragment[fragment.len - 1] != ',') return null;

    const file_ext = std.fs.path.extension(path);
    if (file_ext.len == 0) return null;

    const is_cpp =
        std.ascii.eqlIgnoreCase(file_ext, ".cpp") or
        std.ascii.eqlIgnoreCase(file_ext, ".cc") or
        std.ascii.eqlIgnoreCase(file_ext, ".cxx") or
        std.ascii.eqlIgnoreCase(file_ext, ".c++");

    // replace the argv[0] with clang/clang++
    const arg0_keyword = "\"arguments\": [\"";
    const arg0_idx = std.mem.indexOf(u8, fragment, arg0_keyword) orelse return null;
    const arg0_start = arg0_idx + arg0_keyword.len;
    const arg0_end = std.mem.indexOfScalarPos(u8, fragment, arg0_start, '"') orelse return null;

    return b.fmt("{s}{s}{s}", .{
        fragment[0..arg0_start],
        if (is_cpp) "clang++" else "clang",
        fragment[arg0_end..(fragment.len - 1)],
    });
}

fn load_cdb_map(b: *std.Build, cdb_dir: *std.fs.Dir, cdb_map: *std.StringHashMap([]const u8), p_loaded: ?*bool) !void {
    if (p_loaded) |loaded| {
        if (loaded.*) return;
        loaded.* = true;
    }

    var file = cdb_dir.openFile(CDB_RAW_FILENAME, .{}) catch |err| switch (err) {
        error.FileNotFound => return, // that is ok
        else => return err,
    };
    defer file.close();

    // ensure that the longest line can be buffered
    const buf = try b.allocator.alloc(u8, 1024 * 1024);
    defer b.allocator.free(buf);

    var reader = file.reader(buf);

    while (true) {
        const line = reader.interface.takeDelimiterExclusive('\n') catch |err| switch (err) {
            error.EndOfStream => break,
            else => return err,
        };
        if (line.len == 0) continue;

        const path = extract_path(b, line) orelse continue;
        const fragment = b.dupe(line);
        try cdb_map.put(path, fragment);
    }
}

fn save_cdb_map(b: *std.Build, cdb_dir: *std.fs.Dir, cdb_map: *const std.StringHashMap([]const u8)) !void {
    const filename = CDB_RAW_FILENAME;
    const filename_tmp = filename ++ ".tmp";

    const file = try cdb_dir.createFile(filename_tmp, .{});
    defer file.close();

    const buf = try b.allocator.alloc(u8, 1024 * 1024);
    defer b.allocator.free(buf);

    var writer = file.writer(&buf);

    var it = cdb_map.valueIterator();
    while (it.next()) |p_fragment| {
        try writer.interface.writeAll(p_fragment.*);
        try writer.interface.writeAll("\n");
    }

    // must flush to ensure the file is written
    try writer.interface.flush();

    // atomic rename
    try cdb_dir.rename(filename_tmp, filename);
}

/// test if $project_root/compile_commands.json exists
fn access_cdb(b: *std.Build) bool {
    b.build_root.handle.access(CDB_FILENAME, .{}) catch return false;
    return true;
}

/// save to $project_root/compile_commands.json
fn save_cdb(b: *std.Build, cdb_map: *const std.StringHashMap([]const u8)) !void {
    const filename = CDB_FILENAME;
    const filename_tmp = filename ++ ".tmp";

    const file = try b.build_root.handle.createFile(filename_tmp, .{});
    defer file.close();

    const buf = try b.allocator.alloc(u8, 1024 * 1024);
    defer b.allocator.free(buf);

    var writer = file.writer(&buf);

    if (cdb_map.count() == 0) {
        try writer.interface.writeAll("[]\n");
    } else {
        var is_first_line = true;
        var it = cdb_map.valueIterator();
        while (it.next()) |p_fragment| {
            if (is_first_line) {
                is_first_line = false;
                try writer.interface.writeAll("[\n  ");
            } else {
                try writer.interface.writeAll(",\n  ");
            }
            try writer.interface.writeAll(p_fragment.*);
        }
        try writer.interface.writeAll("\n]\n");
    }

    // must flush to ensure the file is written
    try writer.interface.flush();

    // atomic rename
    try b.build_root.handle.rename(filename_tmp, filename);
}

const CollectCtx = struct {
    /// relative path to the b.cache_root
    cdb_dir_path: []const u8,
    /// reuse the same map to avoid allocating memory
    cdb_map: *std.StringHashMap([]const u8),
    /// must be large enough to store the longest line
    reader_buf: []u8,
    /// each line is a fragment filename to be deleted
    delete_files: *std.ArrayList(u8),
};

/// frag/*.json => cdb.raw \
/// @return: `dirty` state
fn collect(b: *std.Build, ctx: CollectCtx) !bool {
    var dirty = false;

    // - $cdb_dir/
    //   - cdb.raw
    //   - compile_commands.json
    //   - frag/*.json
    var cdb_dir = b.cache_root.handle.openDir(ctx.cdb_dir_path, .{}) catch |err| switch (err) {
        error.FileNotFound => return dirty, // that is ok
        else => return err,
    };
    defer cdb_dir.close();

    // file_path -> fragment (lazy loaded)
    const cdb_map = ctx.cdb_map;
    var cdb_map_loaded = false;

    // ensure that the longest line can be buffered
    const reader_buf = ctx.reader_buf;

    // delete the fragment files (after saving all files)
    const delete_files = ctx.delete_files;

    // check for new fragments
    const frag_dir = cdb_dir.openDir("frag", .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return false, // that is ok
        else => return err,
    };
    defer frag_dir.close();

    var frag_dir_iter = frag_dir.iterate();
    while (try frag_dir_iter.next()) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".json")) continue;

        var file = cdb_dir.openFile(entry.name, .{}) catch continue;
        defer file.close();

        var reader = file.reader(reader_buf);
        var fragment = reader.interface.takeDelimiterExclusive('\n') catch continue;

        // get the key and value (memory is owned)
        const path = extract_path(b, fragment) orelse continue;
        fragment = format_fragment(b, fragment, path) orelse continue;

        // replace the fragment in the map
        try load_cdb_map(b, &cdb_dir, cdb_map, &cdb_map_loaded);
        try cdb_map.put(path, fragment);

        // delete the fragment file (after the iteration)
        try delete_files.appendSlice(b.allocator, entry.name);
        try delete_files.append(b.allocator, '\n');

        dirty = true;
    }

    if (dirty)
        try save_cdb_map(b, &cdb_dir, cdb_map);

    if (dirty or !access_cdb(b)) {
        try load_cdb_map(b, &cdb_dir, cdb_map, &cdb_map_loaded);
        try save_cdb(b, cdb_map);
    }

    // delete the fragment files
    if (delete_files.items.len > 0) {
        var filename_iter = std.mem.splitScalar(u8, delete_files.items, '\n');
        while (filename_iter.next()) |filename| {
            frag_dir.deleteFile(filename) catch {};
        }
    }

    return dirty;
}

fn is_cdb_dir(dirname: []const u8) bool {
    // check if the directory is named like "arch-os-abi" (target triple)
    var iter = std.mem.splitScalar(u8, dirname, '-');
    var token_count = 0;
    while (iter.next()) |_| token_count += 1;
    return token_count == 3;
}

fn collect_all(b: *std.Build) !bool {
    var any_dirty = false;

    // - $cache_root/cdb/
    //   - arch-os-abi/
    //     - cdb.raw
    //     - compile_commands.json
    //     - frag/*.json
    var cdb_dir = b.cache_root.handle.openDir("cdb", .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return any_dirty, // that is ok
        else => return err,
    };
    defer cdb_dir.close();

    var cdb_map: std.StringHashMap([]const u8) = .init(b.allocator);
    defer cdb_map.deinit();

    const reader_buf = try b.allocator.alloc(u8, 1024 * 1024);
    defer b.allocator.free(reader_buf);

    var delete_files: std.ArrayList(u8) = .empty;
    defer delete_files.deinit();

    var dir_iter = cdb_dir.iterate();
    while (try dir_iter.next()) |entry| {
        if (entry.kind != .directory) continue;
        if (!is_cdb_dir(entry.name)) continue;

        // reset the container
        cdb_map.clearRetainingCapacity();
        delete_files.clearRetainingCapacity();

        const dirty = collect(b, .{
            .cdb_dir_path = b.fmt("cdb/{s}", .{entry.name}),
            .cdb_map = &cdb_map,
            .reader_buf = reader_buf,
            .delete_files = &delete_files,
        }) catch true;

        if (dirty) any_dirty = true;
    }

    return any_dirty;
}

const GcCtx = struct {
    /// relative path to the b.cache_root
    cdb_dir_path: []const u8,
    /// reuse the same map to avoid allocating memory
    cdb_map: *std.StringHashMap([]const u8),
};

/// @return: `dirty` state
fn gc(b: *std.Build, ctx: GcCtx) !bool {
    var dirty = false;

    var cdb_dir = b.cache_root.handle.openDir(ctx.cdb_dir_path, .{}) catch |err| switch (err) {
        error.FileNotFound => return dirty, // that is ok
        else => return err,
    };
    defer cdb_dir.close();

    const cdb_map = ctx.cdb_map;
    try load_cdb_map(b, &cdb_dir, cdb_map, null);

    // check for any deleted source files
    var it = cdb_map.keyIterator();
    while (it.next()) |p_path| {
        std.fs.cwd().access(p_path.*, .{}) catch |err| switch (err) {
            error.FileNotFound => {
                cdb_map.removeByPtr(p_path);
                dirty = true;
            },
            else => continue,
        };
    }

    // save cdb_map
    if (dirty) {
        try save_cdb_map(b, &cdb_dir, cdb_map);
        try save_cdb(b, cdb_map);
    }

    return dirty;
}

fn gc_all(b: *std.Build) !bool {
    var any_dirty = false;

    // - $cache_root/cdb/
    //   - arch-os-abi/
    //     - cdb.raw
    //     - compile_commands.json
    //     - frag/*.json
    var cdb_dir = b.cache_root.handle.openDir("cdb", .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return any_dirty, // that is ok
        else => return err,
    };
    defer cdb_dir.close();

    var cdb_map: std.StringHashMap([]const u8) = .init(b.allocator);
    defer cdb_map.deinit();

    var dir_iter = cdb_dir.iterate();
    while (try dir_iter.next()) |entry| {
        if (entry.kind != .directory) continue;
        if (!is_cdb_dir(entry.name)) continue;

        // reset the container
        cdb_map.clearRetainingCapacity();

        const dirty = gc(b, .{
            .cdb_dir_path = b.fmt("cdb/{s}", .{entry.name}),
            .cdb_map = &cdb_map,
        }) catch true;

        if (dirty) any_dirty = true;
    }

    return any_dirty;
}

fn make(step: *std.Build.Step, options: std.Build.Step.MakeOptions) !void {
    _ = options;
    const b = step.owner;
    const dirty = try collect_all(b);
    if (!dirty) step.result_cached = true;
}

fn make_gc(step: *std.Build.Step, options: std.Build.Step.MakeOptions) !void {
    _ = options;
    const b = step.owner;
    const dirty = try gc_all(b);
    if (!dirty) step.result_cached = true;
}

/// please @import("zcdb") directly in your build.zig
pub fn build(_: *std.Build) void {}
