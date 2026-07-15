# ZCDB — 为 Zig 构建系统生成 `compile_commands.json`

收集 zig build 过程中，由 `zig cc / zig c++ / zig build-*` 编译 C/C++ 源文件时产生的 **编译数据库** JSON 片段（`--gen-cdb-fragment-path`），输出标准的 `compile_commands.json` 至项目根目录（build root）。

## 特性

- **零外部依赖**：仅使用 Zig 标准库，无需任何第三方工具或运行时。
- **缓存集成**：与 Zig 缓存系统紧密集成，仅在触发新的编译时重新生成数据库。
- **自动去重**：同一源文件被多次编译后（源码改动、编译选项改动），仅保留最新的编译命令。
- **垃圾回收**：提供 GC step，自动清理"源文件已不存在"的条目，确保编译数据库与实际源码一致。

## 快速开始

### 1. 声明依赖

使用 `zig fetch --save` 引入 zcdb：

> 具体版本请见 [tags 页面](https://github.com/zfl9/zcdb/tags)

```bash
zig fetch --save=zcdb https://github.com/zfl9/zcdb/archive/refs/tags/v0.1.0.tar.gz
```

### 2. 创建 Step

在 `build.zig` 中导入 zcdb 并创建对应的 build step：

```zig
const zcdb = @import("zcdb");

pub fn build(b: *std.Build) void {
    // ... 你的正常构建逻辑 ...
    // 在 C/C++ 编译 flags 中添加 `-gen-cdb-fragment-path zcdb.db_path(b)`

    // 注册 cdb step：生成 compile_commands.json
    const cdb_step = zcdb.create_step(b, "cdb");

    // 注册 cdb-gc step：清理"源文件已不存在"的条目
    const gc_step = zcdb.create_gc_step(b, "cdb-gc");
}
```

### 3. 使用

```bash
# 生成 compile_commands.json
zig build cdb

# 清理"源文件已不存在"的条目
zig build cdb-gc
```

生成的 `compile_commands.json` 出现在项目根目录，clangd 等工具会自动识别。

## API 说明

- `zcdb.create_step(b, name) → *Step` — 收集 `.zig-cache/cdb/` 中的编译命令片段，去重后输出 `compile_commands.json` 到项目根目录。
- `zcdb.create_gc_step(b, name) → *Step` — 检查 `compile_commands.json` 中记录的源文件是否仍存在，移除"源文件已不存在"的条目。

## TODO

- [ ] 透明的注入 cflags，以便自动生成 cdb fragment。
