# ZCDB

为 Zig 构建系统生成 `compile_commands.json`，开箱即用，无需额外配置。

## 快速开始

### 1. 添加依赖

> 具体版本见 [Tags](https://github.com/zfl9/zcdb/tags) 页面。

```bash
zig fetch --save=zcdb https://github.com/zfl9/zcdb/archive/refs/tags/v1.0.0.tar.gz
```

### 2. 集成到 `build.zig`

```zig
const zcdb = @import("zcdb");

pub fn build(b: *std.Build) void {
    // 标准构建选项
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // 创建 zcdb 实例
    const zcdb_instance = zcdb.Instance.create(b, .{ .target = target });
    defer zcdb_instance.finalize();

    // 正常构建逻辑（addExecutable、installArtifact 等）
}
```

### 3. 使用

```bash
zig build -Dcdb=yes    # 生成 compile_commands.json
zig build -Dcdb=force  # 强制重新生成 compile_commands.json
zig build cdb-gc       # 清理 compile_commands.json 中源文件已不存在的条目
```

- 生成的 `compile_commands.json` 以 symlink 形式出现在项目根目录。
- 不同 target 的编译数据库按 `<triple>@<cpu>` 隔离存放，互不干扰。
- `zcdb.Instance.create()` 参数中的 target 将被作为 symlink 目标。

## CLI 选项

| 选项 | 默认 | 说明 |
|---|---|---|
| `-Dcdb=no` | 是 | 不生成 |
| `-Dcdb=yes` | | 增量生成 |
| `-Dcdb=force` | | 强制重新生成（穿透 Zig 编译缓存） |

## API

### `Instance.create(b, options) → *Instance`

在 configure 阶段早期创建 zcdb 实例。

```zig
pub const CreateOptions = struct {
    target: std.Build.ResolvedTarget,
    emit_option_name: []const u8 = "cdb",
    gc_step_name: []const u8 = "cdb-gc",
};
```

### `instance.finalize()`

为所有 C/C++ 编译步骤注入 `-gen-cdb-fragment-path`。通过 `defer` 调用。

### `instance.get_gc_step() → *std.Build.Step`

获取 GC step，可挂载到自定义 step 链中。

### `require_cflags(b, target) → ?[]const []const u8`

获取 zcdb 所需的编译 flags，若未启用则返回 `null`。用于外部构建系统的集成。

```zig
if (zcdb.require_cflags(b, target)) |cflags| {
    // 追加到 CFLAGS/CXXFLAGS
}
```

## 已知限制

zcdb 的 `compile_commands.json` 反映的是**最近一次实际触发的 C/C++ 编译记录**，而非当前 `zig build` 的构建上下文。这是因为 Zig 编译缓存可能命中了某个历史构建，此时 `zig cc`/`zig c++` 并未执行，cdb 数据未得到更新，仍然是上一次触发编译时的记录。

解决方法：

- 日常增量开发不受影响（源码不断修改，自然触发增量编译）
- 若怀疑 cdb 滞后，执行 `zig build -Dcdb=force` 强制触发重新构建
- 或者删除 `.zig-cache/` 本地缓存目录，再重新构建，获得完全干净的 cdb
