# ZCDB — 为 Zig 构建系统生成 `compile_commands.json`

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
    const zcdb_instance = zcdb.Instance.create(b, .{});
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

生成的 `compile_commands.json` 以 symlink 形式出现在项目根目录，clangd 等工具自动识别。

## CLI 选项

| 选项 | 默认 | 说明 |
|---|---|---|
| `-Dcdb=no` | 是 | 不生成 |
| `-Dcdb=yes` | | 增量生成 |
| `-Dcdb=force` | | 强制重新生成（穿透 Zig 编译缓存） |

- 不同 target 的编译数据库按 `<triple>@<cpu>` 隔离存放，互不干扰。
- 首个发现的 target 被作为 symlink 目标，自动软链接到项目根目录下。

## API

### `Instance.create(b, options) → *Instance`

在 configure 阶段早期创建 zcdb 实例。

```zig
pub const CreateOptions = struct {
    emit_option_name: []const u8 = "cdb",
    gc_step_name: []const u8 = "cdb-gc",
};
```

### `instance.finalize()`

为所有 C/C++ 编译步骤注入 `-gen-cdb-fragment-path`。通过 `defer` 调用。

### `instance.get_gc_step() → *std.Build.Step`

获取 GC step，可挂载到自定义 step 链中。

### `require_cflags(b, target) → ?[]const []const u8`

获取 zcdb 所需的编译 flags，若未启用则返回 `null`。供 zmake 等外部构建系统集成使用：

```zig
if (zcdb.require_cflags(b, target)) |cflags| {
    // 追加到 CFLAGS/CXXFLAGS
}
```

## zmake 集成

> zmake 已自动集成 zcdb，无需额外配置与干预。

zcdb 通过 `b.graph.env_map` 写入 `ZCDB_EMIT`、`ZCDB_STAMP`，同一构建图内的所有包均可读取。
