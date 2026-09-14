# 06 坑与版本差异

> 核对版本：ccache 4.13.6 与 4.14。每条标明依据：
> **实测**（[`examples/`](examples/) 或正文给出的命令）、**手册**（官方 `doc/manual.adoc`）、
> **代码阅读**（LLVM 23.1.0 源码）、**推论**（由已知机制推出，未实跑）。

## 1. 配置

**1.1 拼错的键没有任何提示**（实测）
缓存级 / 系统级配置文件、环境变量、命令行 `KEY=VALUE` 里不认识的键都被静默忽略，`ccache -p` 也不报错；只有目录级配置文件会报错。
检查办法：`ccache -p` 里找以「(该文件路径) 键 =」开头的行，或用 [`conf/check.sh`](conf/check.sh)。

**1.2 布尔环境变量：写 `0` 报错，写空串为真**（实测）
`CCACHE_COMPRESS=0` 让每次调用都报错退出；想关闭要写 `CCACHE_NOCOMPRESS=1`。`CCACHE_COMPRESS=`（空串）表示开启。

**1.3 `CCACHE_CONFIGPATH` 连目录级配置也屏蔽**（实测）
设了它就只读这一份文件。仓库里的 `ccache.conf` 不生效时先查这个变量。

**1.4 目录级 `ccache.conf` 出问题，每次编译都失败**（实测，4.13+）
文件对所有人可写、写了不允许或不安全的选项、写了不认识的键，ccache 都**报错退出**而不是跳过。
推论：从 4.12 或更早升级到 4.13+ 后，仓库或父目录里一个原本无关的 `ccache.conf` 会突然开始被读取。

**1.5 4.12 删除了 `run_second_cpp` / `CCACHE_CPP2`，4.14 删除了 `cpp_extension`**（实测）
普通配置里残留的这些设置被静默忽略，不影响结果；`cpp_extension` 残留在目录级配置里则会报 unknown option。
LLVM 23.1.0 的 `LLVM_CCACHE_PARAMS` 默认值仍带 `CCACHE_CPP2=yes`（代码阅读），无害。

## 2. 键与命中

**2.1 带 `-g` 的构建换个目录就 miss**（实测：[03](examples/03-cross-dir/run.sh)、[06](examples/06-make-autotools/run.sh)、[07](examples/07-meson/run.sh)）
`hash_dir` 默认为真，有 `-g` 时当前目录进键。容易踩中的默认：autoconf 在不给 `CFLAGS` 时用 `-g -O2`，Meson 默认 `buildtype=debug`。
正解是 `-fdebug-prefix-map=<目录>=<固定名>`。**不要**用 `hash_dir = false` 了事：实测命中后，目标文件调试信息里的编译目录是别人的目录。

**2.2 `base_dir` 改变了编译器看到的路径**（实测 03、05）
编译器拿到的是相对路径：`__FILE__` 展开成 `../src/x.c`，`-MD` 写的依赖文件里也是相对路径。CMake + Ninja 下依赖跟踪仍然正确（05 的 F 段）；
其他生成器与工具未验证，手册提醒可能干扰依赖检测。`base_dir` 不要设成 `/`（手册：连系统头文件路径也会被改写）。

**2.3 `LANG` 不同就 miss**（实测 [04](examples/04-debug-miss/run.sh)）
`LANG`、`LC_ALL`、`LC_CTYPE`、`LC_MESSAGES` 进键。CI 与开发机、不同终端之间常不一致。不在乎警告语言时设 `sloppiness = locale`。

**2.4 `__TIME__` / `__DATE__` 让每次都 miss**（实测 [02](examples/02-cache-key/run.sh)）
设 `sloppiness = time_macros` 后命中，但目标文件里的时间取自入缓存那一刻。

**2.5 编译器文件的 mtime 变了，全部 miss**（实测 02）
重新安装、复制、自己重新构建编译器都会改 mtime；各台机器各自安装的编译器 mtime 也不同。按需换成 `compiler_check = content`、
`string:<值>` 或命令形式。

**2.6 `compiler_check = content` 只看 `%compiler%` 那一个文件**（手册 + 推论）
编译器的实际代码若在别的文件里——典型是以 `LLVM_LINK_LLVM_DYLIB=ON` 构建、代码在 `libLLVM.so` 里的 clang——库变了而这个文件不变，就会假命中。
见 [03 §5.6](03-integration.md)。

**2.7 编译器偷偷读的文件不在键里 → 假命中**（实测 [09](examples/09-hidden-inputs/run.sh)）
实测：包装脚本从 `flags.txt` 读 `-DLEVEL=…`，改了 `flags.txt` 仍 direct 命中，程序输出旧值；加进 `extra_files_to_hash` 后正确。
clang 与可执行文件同目录的隐式配置文件（`<triple>-clang.cfg`）是同类情形（推论，见 03 §5.6）。

**2.8 包装器写在 ccache 与编译器之间**（实测 09）
`ccache distcc gcc` 或让包装器伪装成编译器：ccache 按包装器的 mtime 算键，察觉不到真编译器升级，条目也不与直接编译共享。用 `prefix_command`。

**2.9 `depend_mode` 离不开 `direct_mode`**（实测）
`direct_mode = false` 且 `depend_mode = true` 时，两次相同的编译都是 miss。

**2.10 刚改过的文件不缓存**（手册）
源文件或头文件的 mtime/ctime 不早于 ccache 启动时刻时，ccache 放弃缓存以避开竞态。只在时间戳粒度很粗的文件系统上才常见；
确认没问题可设 `sloppiness = include_file_mtime,include_file_ctime`。

## 3. 构建系统

**3.1 CMake 的启动器环境变量只在首次 configure 时读**（实测 [05](examples/05-cmake/run.sh) B1）
已经 configure 过的构建目录，后来再导出 `CMAKE_<LANG>_COMPILER_LAUNCHER` 没有用；要么删掉 `CMakeCache.txt` 重来，要么用 `-D` 显式给。

**3.2 ExternalProject 子工程不继承启动器**（实测 05）
缓存变量、`RULE_LAUNCH_COMPILE` 都传不过去，只有构建全程导出的环境变量能。LLVM 的 `LLVM_ENABLE_RUNTIMES` 就是这种子构建（代码阅读，03 §5.5）。

**3.3 LLVM 的多个构建目录互相不命中**（实测 [11](examples/11-llvm/run.sh)）
编译命令里有构建目录的绝对路径。`base_dir` 要同时覆盖源码与构建目录（03 §5.4）。

**3.4 GCC + ccache + 预编译头可能假命中**（代码阅读 + 手册）
LLVM 23.1.0 的注释引用 ccache issue #1668：非 Clang 编译器下只改宏定义可能假命中。`LLVM_CCACHE_BUILD` 因此在非 Clang 编译器上自动关预编译头，
launcher 写法只警告（实测 11 的 configure 输出）。非 LLVM 工程同样适用：GCC 编译时要么不用预编译头，要么别用 ccache。
手册对预编译头的要求：`sloppiness` 含 `pch_defines,time_macros`（刚生成的文件还需 `include_file_mtime,include_file_ctime`）；
用 `-include <头文件>` 引入（Clang 还可以 `-include-pch`，GCC 须加 `-fpch-preprocess`）；Clang 另加 `-fno-pch-timestamp`；
用 `#pragma once` 而非 include guard 的头文件可能出问题。以上未实跑。

**3.5 C++20 模块不支持**（手册）
Clang 的 `-fmodules` 有限支持，需要 `sloppiness = modules` 并同时开 direct 与 depend 模式。未实跑。

**3.6 Meson 优先选 sccache**（实测 07）
`PATH` 里 sccache 与 ccache 都有时，自动探测选 sccache。要用 ccache 就在 `CC` 或机器文件里写明。

## 4. 存储与 CI

**4.1 不淘汰，CI 缓存只增不减**（实测 [10](examples/10-ci-lifecycle/run.sh)）
每次保存前按「本作业没用到」淘汰：`--evict-older-than <作业秒数>s`，或 ccache-action 的 `evict-old-files: job`。

**4.2 远端存储没有任何自动清理**（实测 [08](examples/08-remote-storage/run.sh) + 手册）
file 后端用 `ccache --trim-dir`；HTTP 服务端、Redis 自行配置。`--trim-dir` 不要用在本地缓存目录上（手册）。

**4.3 `hard_link = true` 的副作用**（手册）
修改构建树里的目标文件（如 `strip`）会破坏缓存条目；多个构建树共享 inode 与 mtime，make 会误判需要重链接；不压缩。多人共享缓存时尤其不要开。

**4.4 storage helper 的 IPC 端点不跟随 `temporary_dir`**（实测，4.13.6）
设了 `temporary_dir` 后，端点仍在 `$XDG_RUNTIME_DIR/ccache-tmp` 下。

**4.5 内置 HTTP / Redis 支持将被移除**（手册 4.14）
「will be removed in the next non-bug-fix ccache version」。现在就换成 storage helper，见 [04 §4.2](04-remote-storage.md)。

## 5. 版本差异速查

| 版本 | 发布日期 | 与本整理相关的变化 |
|---|---|---|
| 4.12 | 2025-09-14 | 删除 `run_second_cpp`（`CCACHE_CPP2`）；`base_dir` 可写多个目录；展开 `-march=native` 等选项防止跨机器假命中；支持 Clang 的 `--config=`；参数顺序保持不变 |
| 4.12.3 | 2026-02-07 | 修正 Clang 下 `-march=native` 展开中与 CWD 相关部分的哈希 |
| 4.13 | 2026-03-05 | 新增 storage helper；新增目录级配置文件；配置支持多行值；`--evict-older-than` 支持 `h` `m` `ms`；`--recompress-threads` 与 `--trim-recompress-threads` 合并为 `--threads`；正式支持 MSVC；缓存 Clang 分布式 ThinLTO |
| 4.13.1 | 2026-03-09 | storage helper 查找顺序改为 libexec 目录优先于 `PATH` |
| 4.13.3 | 2026-04-12 | 远端返回空响应体视为存储错误而非 miss；支持 `-fsanitize-ignorelist` |
| 4.13.5 | 2026-04-26 | storage helper 默认超时调高为数据 10s、请求 1m |
| 4.13.6 | 2026-05-04 | 修复 MSVC depend 模式下无头文件时 manifest 与结果键可能冲突 |
| 4.14 | 2026-08-23 | 删除 `cpp_extension`；新增 `--dry-run`；file 后端新增 `@layout=local`；新增 `compiler_type = qcc`；哈希 Clang 模块文件内容；检测 C23 `#embed`；清理与淘汰会报告删除的数据量与文件数（实测 `Removed data:` / `Removed files:`）；内置 HTTP / Redis 进入移除倒计时 |

以上出自 ccache 的 NEWS（4.13.6 随包附带、4.14 发布说明），逐版核对于 2026-09-13。

### 升级到 4.14 的检查清单

1. 在所有配置（包括 CI 脚本、`LLVM_CCACHE_PARAMS`）里搜 `run_second_cpp`、`CPP2`、`cpp_extension`，删掉；
2. 用了 `http://` 或 `redis://` 远端的，现在就装上对应的 storage helper——装好后 ccache 自动优先用它（实测日志 `Found remote storage helper`）；
3. 检查构建时的工作目录及其上级里有没有 `ccache.conf`（4.13 起会被读取，见 1.4）；
4. 清理脚本先加 `--dry-run` 跑一遍看删多少。

上一篇：[05 诊断与维护](05-diagnostics.md) ｜ 回到 [README](README.md)。
