const std = @import("std");
const assert = std.debug.assert;

const ENV_EMIT = "ZCDB_EMIT";
const ENV_STAMP = "ZCDB_STAMP";
const CDB_RAW_FILENAME = "cdb.raw";
const CDB_JSON_FILENAME = "compile_commands.json";
const CDB_BASE_DIR = "cdb";
const FRAG_DIR = "frag";

// ================================= API =================================

/// please @import("zcdb") directly in your build.zig
pub fn build(_: *std.Build) void {}

pub const Emit = enum {
    /// yes, emit compile_commands.json
    yes,
    /// force re-emit compile_commands.json
    force,
    /// no, do not emit compile_commands.json
    no,

    pub fn from(name: []const u8) ?Emit {
        if (std.mem.eql(u8, name, "yes"))
            return .yes;
        if (std.mem.eql(u8, name, "force"))
            return .force;
        if (std.mem.eql(u8, name, "no"))
            return .no;
        return null;
    }
};

/// ```zig
/// // usage
/// const zcdb = @import("zcdb");
/// pub fn build(b: *std.Build) void {
///     const zcdb_instance = zcdb.Instance.create(b, .{});
///     defer zcdb_instance.finalize();
///     // the build script logic ...
/// }
/// ```
pub const Instance = struct {
    b: *std.Build,
    emit: Emit,
    force_cflag: ?[]const u8,
    gc_step: *std.Build.Step,
    visited: std.AutoHashMap(*std.Build.Step, void),
    cdb_link: ?*CDBLink = null,

    pub fn get_gc_step(self: *const Instance) *std.Build.Step {
        return self.gc_step;
    }

    pub const CreateOptions = struct {
        /// cli option name (zig build -Dcdb=yes)
        emit_option_name: []const u8 = "cdb",

        /// gc step name (zig build cdb-gc)
        gc_step_name: []const u8 = "cdb-gc",
    };

    pub fn create(b: *std.Build, options: CreateOptions) *Instance {
        const emit = if (is_root_pkg(b))
            b.option(Emit, options.emit_option_name, "emit compile_commands.json") orelse .no
        else
            .no;

        switch (emit) {
            .yes, .force => {
                b.graph.env_map.put(ENV_EMIT, @tagName(emit)) catch unreachable;
            },
            .no => {},
        }

        const force_cflag = switch (emit) {
            .force => cflag: {
                const stamp = b.fmt("{d}", .{std.time.milliTimestamp()});
                b.graph.env_map.put(ENV_STAMP, stamp) catch unreachable;
                break :cflag compute_force_cflag(b, stamp);
            },
            else => null,
        };

        const gc_step = b.step(options.gc_step_name, "gc compile_commands.json");
        if (is_root_pkg(b)) gc_step.makeFn = make_gc;

        const self = b.allocator.create(Instance) catch @panic("OOM");
        self.* = .{
            .b = b,
            .emit = emit,
            .force_cflag = force_cflag,
            .gc_step = gc_step,
            .visited = .init(b.allocator),
        };
        return self;
    }

    pub fn finalize(self: *Instance) void {
        defer self.visited.deinit();

        switch (self.emit) {
            .yes, .force => {
                const b = self.b;
                assert(is_root_pkg(b));

                // collect all cdb fragments
                const cdb_link = CDBLink.create(b);
                assert(self.cdb_link == null);
                self.cdb_link = cdb_link;

                for (b.getInstallStep().dependencies.items) |dep_step| {
                    // inject the cdb flags into all compile steps
                    self.traverse_step(dep_step);

                    // link cdb fragments after all compile steps
                    cdb_link.step.dependOn(dep_step);
                }

                // reference it in the install step
                b.getInstallStep().dependOn(&cdb_link.step);
            },

            .no => {},
        }
    }

    fn traverse_step(self: *Instance, step: *std.Build.Step) void {
        // avoid traversing the same step twice
        if (self.visited.contains(step)) return;
        self.visited.put(step, {}) catch unreachable;

        // inject the cdb flags into the compile step
        if (step.cast(std.Build.Step.Compile)) |compile| {
            self.update_compile(compile);
        }

        // iterate through its dependencies
        for (step.dependencies.items) |dep_step| {
            self.traverse_step(dep_step);
        }
    }

    fn update_compile(self: *Instance, compile: *std.Build.Step.Compile) void {
        const b = self.b;
        const root_module = compile.root_module;

        // the root module's target is always available
        const target = root_module.resolved_target orelse return;
        const triple = compute_triple(b, target);
        const frag_path = compute_frag_path(b, triple);

        // record the dir name for the cdb link step
        self.cdb_link.?.record_triple(triple);

        // traverse all modules in the graph (root + import_table)
        const mod_graph = root_module.getGraph();
        for (mod_graph.modules) |mod| {
            for (mod.link_objects.items) |*link_object| {
                switch (link_object.*) {
                    .c_source_file => |csf| {
                        self.inject_cflags(&csf.flags, frag_path);
                    },
                    .c_source_files => |csf| {
                        self.inject_cflags(&csf.flags, frag_path);
                    },
                    .other_step => |other| {
                        self.traverse_step(&other.step);
                    },
                    else => {},
                }
            }
        }
    }

    fn inject_cflags(self: *Instance, flags: *[]const []const u8, frag_path: []const u8) void {
        switch (self.emit) {
            .yes, .force => {
                const old_flags = flags.*;
                const extra_slots = if (self.emit == .force) 3 else 2;
                const new_flags = self.b.allocator.alloc([]const u8, old_flags.len + extra_slots) catch unreachable;
                @memcpy(new_flags[0..old_flags.len], old_flags);
                new_flags[old_flags.len] = "-gen-cdb-fragment-path";
                new_flags[old_flags.len + 1] = frag_path;
                if (self.emit == .force) new_flags[old_flags.len + 2] = self.force_cflag.?;
                flags.* = new_flags;
            },
            .no => unreachable,
        }
    }
};

/// Returns the C/C++ flags required to emit cdb fragments. \
/// Returns null if zcdb is not enabled in this build. \
pub fn require_cflags(b: *std.Build, target: std.Build.ResolvedTarget) ?[]const []const u8 {
    const emit = Emit.from(b.graph.env_map.get(ENV_EMIT) orelse return null).?;
    switch (emit) {
        .yes, .force => {
            const extra_slots = if (emit == .force) 3 else 2;
            const cflags = b.allocator.alloc([]const u8, extra_slots) catch unreachable;
            cflags[0] = "-gen-cdb-fragment-path";
            cflags[1] = compute_frag_path(b, compute_triple(b, target));
            if (emit == .force) cflags[2] = compute_force_cflag(b, null);
            return cflags;
        },
        .no => return null,
    }
}

// ================================= private =================================

fn is_root_pkg(b: *const std.Build) bool {
    return b.pkg_hash.len == 0;
}

/// `in_stamp` null means read from env_map
fn compute_force_cflag(b: *std.Build, in_stamp: ?[]const u8) []const u8 {
    const stamp = in_stamp orelse b.graph.env_map.get(ENV_STAMP) orelse unreachable;
    return b.fmt("-DZCDB__FORCE__={s}", .{stamp});
}

fn compute_triple(b: *std.Build, target: std.Build.ResolvedTarget) []const u8 {
    const triple = target.result.zigTriple(b.allocator) catch unreachable;
    const cpu = std.zig.serializeCpuAlloc(b.allocator, target.result.cpu) catch unreachable;
    return b.fmt("{s}@{s}", .{ triple, cpu });
}

fn compute_frag_path(b: *std.Build, triple: []const u8) []const u8 {
    var realpath_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cache_root = b.cache_root.handle.realpath(".", &realpath_buf) catch unreachable;
    const path = b.pathJoin(&.{ cache_root, CDB_BASE_DIR, triple, FRAG_DIR });
    b.cache_root.handle.makePath(std.fs.path.dirname(path).?) catch unreachable;
    return path;
}

const CDBLink = struct {
    step: std.Build.Step,
    triple: ?[]const u8,

    pub const base_id: std.Build.Step.Id = .custom;

    pub fn create(b: *std.Build) *CDBLink {
        const self = b.allocator.create(CDBLink) catch @panic("OOM");
        self.* = .{
            .step = .init(.{
                .id = base_id,
                .name = "cdb_link",
                .owner = b,
                .makeFn = make_link,
            }),
            .triple = null,
        };
        return self;
    }

    pub fn record_triple(self: *CDBLink, triple: []const u8) void {
        if (self.triple != null) return;
        self.triple = self.step.owner.dupe(triple);
    }
};

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

    return b.pathJoin(&.{ dir.?, file.? });
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

/// load cdb_map from $cdb_dir/cdb.raw
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

/// save cdb_map to $cdb_dir/cdb.raw
fn save_cdb_map(b: *std.Build, cdb_dir: *std.fs.Dir, cdb_map: *const std.StringHashMap([]const u8)) !void {
    const filename = CDB_RAW_FILENAME;
    const filename_tmp = filename ++ ".tmp";

    const file = try cdb_dir.createFile(filename_tmp, .{});
    defer file.close();

    const buf = try b.allocator.alloc(u8, 1024 * 1024);
    defer b.allocator.free(buf);

    var writer = file.writer(buf);

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

/// test if $cdb_dir/compile_commands.json exists
fn access_cdb_json(cdb_dir: *std.fs.Dir) bool {
    cdb_dir.access(CDB_JSON_FILENAME, .{}) catch return false;
    return true;
}

/// save to $cdb_dir/compile_commands.json
fn save_cdb_json(b: *std.Build, cdb_dir: *std.fs.Dir, cdb_map: *const std.StringHashMap([]const u8)) !void {
    const filename = CDB_JSON_FILENAME;
    const filename_tmp = filename ++ ".tmp";

    const file = try cdb_dir.createFile(filename_tmp, .{});
    defer file.close();

    const buf = try b.allocator.alloc(u8, 1024 * 1024);
    defer b.allocator.free(buf);

    var writer = file.writer(buf);

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
    try cdb_dir.rename(filename_tmp, filename);
}

const LinkCtx = struct {
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
fn link(b: *std.Build, ctx: LinkCtx) !bool {
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
    var frag_dir = cdb_dir.openDir(FRAG_DIR, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return dirty, // that is ok
        else => return err,
    };
    defer frag_dir.close();

    var frag_dir_iter = frag_dir.iterate();
    while (try frag_dir_iter.next()) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".json")) continue;

        var file = frag_dir.openFile(entry.name, .{}) catch continue;
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

    if (dirty or !access_cdb_json(&cdb_dir)) {
        try load_cdb_map(b, &cdb_dir, cdb_map, &cdb_map_loaded);
        try save_cdb_json(b, &cdb_dir, cdb_map);
    }

    // delete the fragment files
    if (delete_files.items.len > 0) {
        var filename_iter = std.mem.splitScalar(u8, delete_files.items, '\n');
        while (filename_iter.next()) |filename| {
            if (filename.len > 0) {
                frag_dir.deleteFile(filename) catch {};
            }
        }
    }

    return dirty;
}

/// "triple@cpu"
fn is_cdb_dir(dirname: []const u8) bool {
    return std.mem.indexOfScalar(u8, dirname, '@') != null;
}

fn link_all(b: *std.Build, step: *std.Build.Step) !bool {
    var any_dirty = false;

    // - $cache_root/cdb/
    //   - triple@cpu/
    //     - cdb.raw
    //     - compile_commands.json
    //     - frag/*.json
    var dir = b.cache_root.handle.openDir(CDB_BASE_DIR, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return any_dirty, // that is ok
        else => return err,
    };
    defer dir.close();

    var cdb_map: std.StringHashMap([]const u8) = .init(b.allocator);
    defer cdb_map.deinit();

    const reader_buf = try b.allocator.alloc(u8, 1024 * 1024);
    defer b.allocator.free(reader_buf);

    var delete_files: std.ArrayList(u8) = .empty;
    defer delete_files.deinit(b.allocator);

    var dir_iter = dir.iterate();
    while (try dir_iter.next()) |entry| {
        if (entry.kind != .directory) continue;
        if (!is_cdb_dir(entry.name)) continue;

        // reset the container
        cdb_map.clearRetainingCapacity();
        delete_files.clearRetainingCapacity();

        const dirty = link(b, .{
            .cdb_dir_path = b.pathJoin(&.{ CDB_BASE_DIR, entry.name }),
            .cdb_map = &cdb_map,
            .reader_buf = reader_buf,
            .delete_files = &delete_files,
        }) catch |err| blk: {
            try step.addError("link failed for target '{s}': {s}", .{ entry.name, @errorName(err) });
            break :blk true;
        };

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
        try save_cdb_json(b, &cdb_dir, cdb_map);
    }

    return dirty;
}

fn gc_all(b: *std.Build, step: *std.Build.Step) !bool {
    var any_dirty = false;

    // - $cache_root/cdb/
    //   - triple@cpu/
    //     - cdb.raw
    //     - compile_commands.json
    //     - frag/*.json
    var dir = b.cache_root.handle.openDir(CDB_BASE_DIR, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return any_dirty, // that is ok
        else => return err,
    };
    defer dir.close();

    var cdb_map: std.StringHashMap([]const u8) = .init(b.allocator);
    defer cdb_map.deinit();

    var dir_iter = dir.iterate();
    while (try dir_iter.next()) |entry| {
        if (entry.kind != .directory) continue;
        if (!is_cdb_dir(entry.name)) continue;

        // reset the container
        cdb_map.clearRetainingCapacity();

        const dirty = gc(b, .{
            .cdb_dir_path = b.pathJoin(&.{ CDB_BASE_DIR, entry.name }),
            .cdb_map = &cdb_map,
        }) catch |err| blk: {
            try step.addError("gc failed for target '{s}': {s}", .{ entry.name, @errorName(err) });
            break :blk true;
        };

        if (dirty) any_dirty = true;
    }

    return any_dirty;
}

/// CDBLink's make function
fn make_link(step: *std.Build.Step, options: std.Build.Step.MakeOptions) !void {
    _ = options;
    const b = step.owner;
    const self: *CDBLink = @fieldParentPtr("step", step);

    const dirty = try link_all(b, step);
    if (!dirty) step.result_cached = true;

    // $build_root/compile_commands.json -> $cache_root/cdb/$triple/compile_commands.json
    if (self.triple) |triple| {
        var realpath_buf: [std.fs.max_path_bytes]u8 = undefined;
        const cache_root = b.cache_root.handle.realpath(".", &realpath_buf) catch unreachable;

        var realpath_buf2: [std.fs.max_path_bytes]u8 = undefined;
        const build_root = b.build_root.handle.realpath(".", &realpath_buf2) catch unreachable;

        const abs_target_path = b.pathJoin(&.{ cache_root, CDB_BASE_DIR, triple, CDB_JSON_FILENAME });
        const target_path = try std.fs.path.relative(b.allocator, build_root, abs_target_path);

        b.build_root.handle.deleteFile(CDB_JSON_FILENAME) catch |err| switch (err) {
            error.FileNotFound => {}, // that's fine
            else => return err,
        };
        try b.build_root.handle.symLink(target_path, CDB_JSON_FILENAME, .{});
    }
}

fn make_gc(step: *std.Build.Step, options: std.Build.Step.MakeOptions) !void {
    _ = options;
    const b = step.owner;

    const dirty = try gc_all(b, step);
    if (!dirty) step.result_cached = true;
}
