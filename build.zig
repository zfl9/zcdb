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

    if (std.mem.indexOf(u8, fragment, "\"directory\": \"")) |idx| {
        const start = idx + 14;
        if (std.mem.indexOfScalarPos(u8, fragment, start, '"')) |end|
            dir = fragment[start..end];
    }
    if (std.mem.indexOf(u8, fragment, "\"file\": \"")) |idx| {
        const start = idx + 9;
        if (std.mem.indexOfScalarPos(u8, fragment, start, '"')) |end|
            file = fragment[start..end];
    }

    if (dir == null or file == null) return null;

    return b.fmt("{s}{s}{s}", .{ dir.?, std.fs.path.sep_str, file.? });
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

    const buf = try b.allocator.alloc(u8, 1024 * 1024);
    defer b.allocator.free(buf);

    var reader = file.reader(&buf);

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

/// `.zig-cache/cdb/*.json` => compile_commands.json \
/// @return: `dirty` state
fn update(b: *std.Build) !bool {
    try b.cache_root.handle.makePath("cdb");
    var cdb_dir = try b.cache_root.handle.openDir("cdb", .{ .iterate = true });
    defer cdb_dir.close();

    // file_path -> fragment (lazy loaded)
    var cdb_map: std.StringHashMap([]const u8) = .init(b.allocator);
    defer cdb_map.deinit();

    var cdb_map_loaded = false;
    var cdb_map_dirty = false;

    var delete_files: std.ArrayList([]const u8) = .empty;
    defer delete_files.deinit(b.allocator);

    // check for new fragments
    var it = cdb_dir.iterate();
    while (try it.next()) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".json")) continue;

        var fragment = cdb_dir.readFileAlloc(b.allocator, entry.name, 10 * 1024 * 1024) catch continue;
        // the fragment memory cannot be freed

        // trim the trailing newline
        if (fragment.len > 0 and fragment[fragment.len - 1] == '\n')
            fragment = fragment[0..(fragment.len - 1)];

        // trim the trailing comma (,)
        if (fragment.len > 0 and fragment[fragment.len - 1] == ',')
            fragment = fragment[0..(fragment.len - 1)];

        // the clang always emit single-line fragment
        if (std.mem.indexOfScalar(u8, fragment, '\n') != null) continue;

        // if the map is not loaded, load it
        try load_cdb_map(b, &cdb_dir, &cdb_map, &cdb_map_loaded);

        // overwrite the fragment in the map
        const path = extract_path(b, fragment) orelse continue;
        try cdb_map.put(path, fragment);
        cdb_map_dirty = true;

        // delete the fragment file (after the iteration)
        try delete_files.append(b.allocator, b.dupe(entry.name));
    }

    if (cdb_map_dirty)
        try save_cdb_map(b, &cdb_dir, &cdb_map);

    if (cdb_map_dirty or !access_cdb(b)) {
        try load_cdb_map(b, &cdb_dir, &cdb_map, &cdb_map_loaded);
        try save_cdb(b, &cdb_map);
    }

    // delete the fragment files (after saving all files)
    for (delete_files.items) |file| {
        cdb_dir.deleteFile(file) catch {};
    }

    return cdb_map_dirty;
}

/// @return: `changed` state
fn perform_gc(b: *std.Build) !bool {
    var cdb_dir = b.cache_root.handle.openDir("cdb", .{}) catch |err| switch (err) {
        error.FileNotFound => return false, // that is ok
        else => return err,
    };
    defer cdb_dir.close();

    var cdb_map = std.StringHashMap([]const u8).init(b.allocator);
    defer cdb_map.deinit();

    try load_cdb_map(b, &cdb_dir, &cdb_map, null);

    var delete_keys: std.ArrayList(*[]const u8) = .empty;
    defer delete_keys.deinit(b.allocator);

    // check for any deleted source files
    var it = cdb_map.keyIterator();
    while (it.next()) |p_path| {
        std.fs.cwd().access(p_path.*, .{}) catch |err| switch (err) {
            error.FileNotFound => try delete_keys.append(b.allocator, p_path), // delete the entry after the iteration
            else => continue,
        };
    }

    // no need to gc
    if (delete_keys.items.len == 0)
        return false;

    // delete the entries
    for (delete_keys.items) |p_path| {
        _ = cdb_map.removeByPtr(p_path);
    }

    // save cdb_map
    try save_cdb_map(b, &cdb_dir, &cdb_map);
    try save_cdb(b, &cdb_map);

    return true;
}

fn make(step: *std.Build.Step, options: std.Build.Step.MakeOptions) !void {
    _ = options;
    const b = step.owner;
    const dirty = try update(b);
    if (!dirty) step.result_cached = true;
}

fn make_gc(step: *std.Build.Step, options: std.Build.Step.MakeOptions) !void {
    _ = options;
    const b = step.owner;
    const changed = try perform_gc(b);
    if (!changed) step.result_cached = true;
}

/// please @import("zcdb") directly in your build.zig
pub fn build(_: *std.Build) void {}
