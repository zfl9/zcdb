# ZCDB — 为 Zig 构建系统生成 `compile_commands.json`

收集 zig build 过程中，由 `zig cc / zig c++` 编译 C/C++ 源文件时产生的**编译数据库** JSON 片段（`-gen-cdb-fragment-path`），自动合并输出标准的 `compile_commands.json` 至项目根目录，clangd 等工具可自动识别。

## 特性

- **零外部依赖**：仅使用 Zig 标准库，无需任何第三方工具或运行时。
- **自动注入**：无需手动修改 C/C++ 编译 flags，zcdb 自动注入 `-gen-cdb-fragment-path`。
- **缓存集成**：与 Zig 缓存系统紧密集成，仅在触发新的编译时重新生成数据库。
- **自动去重**：同一源文件被多次编译后（源码改动、编译选项改动），仅保留最新的编译命令。
- **垃圾回收**：提供 GC step，自动清理"源文件已不存在"的条目，确保编译数据库与实际源码一致。
- **多目标隔离**：使用 `<triple>@<cpu>` 命名编译数据库目录，不同 `-Dtarget` / `-Dcpu` 配置的编译记录互不干扰。
- **透明集成**：非 root package 自动静默；支持与 zmake 等外部构建系统通信。

## 快速开始

### 1. 声明依赖

使用 `zig fetch --save` 引入 zcdb：

> 具体版本请见 [tags 页面](https://github.com/zfl9/zcdb/tags)

```bash
zig fetch --save=zcdb https://github.com/zfl9/zcdb/archive/refs/tags/v0.1.0.tar.gz
```

### 2. 集成到 `build.zig`

```zig
const zcdb = @import("zcdb");

pub fn build(b: *std.Build) void {
    // 创建 zcdb 实例（必须在 build 函数开头）
    var zcdb_instance = zcdb.Instance.create(b, .{});
    defer zcdb_instance.finalize();

    // ... 你的正常构建逻辑（b.installArtifact, b.addExecutable 等）...
}
```

### 3. 使用

```bash
# 生成 compile_commands.json（默认不生成）
zig build -Dcdb=yes

# 强制重新生成所有 fragment
zig build -Dcdb=force

# 清理"源文件已不存在"的条目
zig build cdb-gc
```

生成的 `compile_commands.json` 出现在项目根目录（symlink），clangd 等工具会自动识别。

## 选项说明

### `-Dcdb` 三态选项

| 值 | 行为 |
|---|---|
| `no`（默认） | 不生成 compile_commands.json |
| `yes` | 生成 compile_commands.json，增量模式 |
| `force` | 强制重新生成所有 fragment |

### `-Dtarget` / `-Dcpu` 与目录命名

编译数据库片段按 `<triple>@<cpu>` 隔离存放，不同构建配置互不干扰：

```
.zig-cache/cdb/
  ├── x86_64-linux-gnu@generic/
  ├── x86_64-linux-gnu@x86_64_v2/
  ├── x86_64-linux-gnu@x86_64_v3/
  ├── aarch64-linux-musl@generic+v8a/
  ├── arm-linux-musleabi@generic+v7a/
  └── ...
```

最先生成的目标配置对应的 `compile_commands.json` 会被 symlink 到项目根目录。

### 垃圾回收

```bash
zig build cdb-gc
```

检查 `compile_commands.json` 中记录的源文件是否仍存在，自动移除已不存在的文件条目。

## API 说明

### `zcdb.Instance.create(b, options) → *Instance`

创建 zcdb 实例，在 configure 阶段早期调用。

**参数：**
- `b: *std.Build` — build 句柄
- `options: CreateOptions` — 配置选项
  - `gc_step_name: []const u8 = "cdb-gc"` — GC step 的名称

### `zcdb_instance.finalize()`

在 configure 阶段末尾（通过 `defer`）调用：
- 为所有 C/C++ 编译步骤注入 `-gen-cdb-fragment-path` flag
- 创建 CDBLink step，自动挂载到 install step 链

### `zcdb_instance.get_gc_step() → *std.Build.Step`

获取 GC step，可挂载到自定义 step 中。仅 root package 可用。

### 完整示例

```zig
const zcdb = @import("zcdb");

pub fn build(b: *std.Build) void {
    // ---- 第一步：创建 zcdb（配置读入、注册 gc step）----
    var zcdb_instance = zcdb.Instance.create(b, .{
        .gc_step_name = "cdb-gc",
    });
    defer zcdb_instance.finalize();

    // ---- 第二步：正常构建逻辑 ----
    const exe = b.addExecutable(.{
        .name = "myapp",
        .root_source_file = b.path("src/main.zig"),
        .target = b.standardTargetOptions(.{}),
        .optimize = b.standardOptimizeOption(.{}),
    });
    exe.addCSourceFiles(.{
        .files = &.{ "src/helper.c", "src/helper.cpp" },
        .flags = &.{ "-O2" },
    });
    b.installArtifact(exe);

    // ---- 第三步：finalize() 在 defer 中自动执行 ----
    // - 自动注入 -gen-cdb-fragment-path 到所有 C/C++ 编译
    // - 自动挂载 CDBLink 到 install step
}
```

## 与 zmake 集成

zcdb 通过 `b.graph.env_map` 写入 `ZCDB_FLAG` 环境变量（值为 `yes` 或 `force`），zmake 可在 configure 阶段读取该变量，在外部构建系统（cmake、autotools 等）的 CFLAGS/CXXFLAGS 中自动追加 `-gen-cdb-fragment-path`。

## 工作原理

```
                   configure phase
                         │
        ┌────────────────┴────────────────┐
        │  zcdb.Instance.create(b, .{})   │
        │    ├─ 读 -Dcdb 选项             │
        │    ├─ 写 ZCDB_FLAG 环境变量     │
        │    └─ 注册 cdb-gc step          │
        └────────────────┬────────────────┘
                         │
        ┌────────────────┴────────────────┐
        │  构建逻辑（installArtifact 等） │
        └────────────────┬────────────────┘
                         │
        ┌────────────────┴────────────────┐
        │  zcdb_instance.finalize()       │
        │    ├─ 遍历 install step 依赖    │
        │    ├─ 注入 -gen-cdb-fragment-   │
        │    │   path 到所有 C/C++ 编译   │
        │    ├─ 创建 CDBLink step         │
        │    └─ 挂载到 install step 链    │
        └────────────────┬────────────────┘
                         │
                         ▼
                    make phase
                         │
        ┌────────────────┴────────────────┐
        │  zig cc / zig c++ 编译 C/C++    │
        │    └─ 写 frag/*.json            │
        └────────────────┬────────────────┘
                         │
        ┌────────────────┴────────────────┐
        │  CDBLink step（install 前执行） │
        │    ├─ 收集所有 frag/*.json      │
        │    ├─ 去重合并 → cdb.raw        │
        │    ├─ 输出 compile_commands.json│
        │    └─ 创建根目录 symlink        │
        └────────────────┬────────────────┘
                         │
                         ▼
                    install step
```
