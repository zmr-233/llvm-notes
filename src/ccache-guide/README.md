# ccache 系统整理

ccache 是 C/C++ 编译器前面的一层缓存：同样的编译做第二次时，直接取出上次的输出。这份整理讲清楚它**拿什么当键**、
**怎么配置**、**怎么接进各种构建系统**（重点是 CMake 与 LLVM）、**怎么跨机器共享**、**命中率不好时怎么查**，以及**有哪些坑**。
每个结论都配有能直接跑的例子，脚本里用断言兑现，而不是靠肉眼读输出。

## 核对环境

2026-09-13 在 Linux x86_64 上核对：

| 组件 | 版本 |
|---|---|
| ccache | 4.13.6（发行版包）与 4.14（官方预编译二进制）。所有例子两个版本都跑通 |
| 编译器 | GCC 16.2.1 |
| 构建系统 | GNU Make 4.4.1、Autoconf 2.73、Automake 1.18.1、CMake 4.4.3、Ninja 1.13.2、Meson 1.12.0 |
| LLVM 源码 | 23.1.0 |
| 远端存储助手 | ccache-storage-http-go 0.10 |

写在正文里的结论分四种依据，都就地标注：**实测**（例子或正文给出的命令）、**手册**（官方 `doc/manual.adoc`）、
**代码阅读**（LLVM 源码，给出文件与行号）、**推论**（由已验证的机制推出，未实跑）。没有实跑的配置片段也会写明「未实跑」。

## 读法

| 篇 | 内容 |
|---|---|
| [01 模型](01-model.md) | 缓存什么；键由什么组成；preprocessor / direct / depend 三种模式；本地缓存目录的布局 |
| [02 配置](02-configuration.md) | 六个配置来源与优先级；语法细节；目录级配置文件的安全限制；全部选项分组详解 |
| [03 接入构建系统](03-integration.md) | 前缀与伪装；Make、Autotools、CMake、Meson；LLVM 的 `LLVM_CCACHE_BUILD`；CI；distcc |
| [04 远端存储](04-remote-storage.md) | file / HTTP / Redis 后端；storage helper；分片；共享场景 |
| [05 诊断与维护](05-diagnostics.md) | 统计、单次构建统计、debug 模式找 miss 原因、清理淘汰、排查清单 |
| [06 坑与版本差异](06-pitfalls.md) | 按类别整理的坑；4.12–4.14 的变化；升级检查清单 |

第一次读按 01 → 06 顺序。只想马上用起来：先看 03 里对应的构建系统，再挑一份 [`conf/`](conf/) 里的配置。

## 目录

```text
ccache-guide/
├── 01-model.md … 06-pitfalls.md
├── conf/                       现成的配置文件，逐项注释
│   ├── personal.conf           个人开发机
│   ├── llvm-dev.conf           开发 LLVM
│   ├── ci.conf                 CI 作业
│   ├── team-shared.conf        多人共享本地缓存
│   ├── remote.conf             只读共享远端缓存
│   ├── project.ccache.conf     随仓库提交的目录级配置
│   └── check.sh                校验每个键都被 ccache 接受
└── examples/
    ├── lib.sh                  共用脚手架：一次性目录、私有缓存、断言
    ├── run-all.sh              依次跑全部例子与 conf/check.sh
    ├── 01-basics/              前缀与伪装；哪些调用不缓存
    ├── 02-cache-key/           三种模式各自对什么敏感；__TIME__；compiler_check
    ├── 03-cross-dir/           base_dir、hash_dir、-fdebug-prefix-map
    ├── 04-debug-miss/          stats_log、debug 模式、diff 找 miss 原因、--inspect
    ├── 05-cmake/               启动器的几种写法；ExternalProject；Presets；base_dir 与 Ninja
    ├── 06-make-autotools/      Make 与 Autotools；autoconf 默认 -g 的坑
    ├── 07-meson/               Meson 的自动探测
    ├── 08-remote-storage/      file / HTTP / helper / 分片 / read-only / remote_only / reshare / trim
    ├── 09-hidden-inputs/       隐藏输入导致假命中；extra_files_to_hash；prefix_command
    ├── 10-ci-lifecycle/        CI 缓存的恢复、统计、淘汰、保存；namespace；GitHub Actions 示例
    └── 11-llvm/                LLVM_CCACHE_BUILD 与 launcher；多个构建目录
```

## 跑例子

每个例子在 `mktemp -d` 建的一次性目录里运行，用自己的缓存目录与配置文件，不读也不写你机器上真正的 ccache 缓存，结束时自动删除。

```bash
examples/run-all.sh                            # 全部例子 + conf/check.sh；成功的只打印一行
bash examples/03-cross-dir/run.sh              # 单个例子，完整输出
KEEP=1 bash examples/04-debug-miss/run.sh      # KEEP=1：结束后保留一次性目录，便于翻看调试文件
CCACHE=/opt/ccache-4.14/ccache examples/run-all.sh   # CCACHE=<路径>：换一个 ccache 可执行文件复核
```

依赖：gcc、GNU Make、binutils（`readelf`、`strings`）、Python 3。05 需要 cmake 与 ninja，06 需要 autoconf 与 automake，
07 需要 meson，缺了会打印 SKIP。两个例子要额外的环境变量：

```bash
# 08 的 storage helper 段：HTTP_HELPER=<ccache-storage-http 可执行文件>
HTTP_HELPER=/opt/ccache-storage-http-go/ccache-storage-http bash examples/08-remote-storage/run.sh
# 11：LLVM_SRC=<llvm-project 源码根目录>。configure 五次，需要几分钟
LLVM_SRC=$HOME/src/llvm-project bash examples/11-llvm/run.sh
```

核对时用的 4.14 与助手程序都取自官方发布页：

```bash
# -f：HTTP 出错时返回非零；-s：不显示进度；-S：出错时仍打印错误；-L：跟随重定向；-O：按远端文件名保存
curl -fsSLO https://github.com/ccache/ccache/releases/download/v4.14/ccache-4.14-linux-x86_64-glibc.tar.gz
curl -fsSLO https://github.com/ccache/ccache-storage-http-go/releases/download/v0.10/ccache-storage-http-go-0.10-linux-amd64.tar.gz
tar xzf ccache-4.14-linux-x86_64-glibc.tar.gz                      # x 解包，z 经 gzip，f 指定文件
tar xzf ccache-storage-http-go-0.10-linux-amd64.tar.gz
```

在 PyPI 上装 cmake、ninja、meson 到一个虚拟环境，是在不动系统包的前提下补齐 05、07、11 依赖的一种办法：

```bash
python3 -m venv venv                           # 在 ./venv 建虚拟环境
venv/bin/python -m pip install cmake ninja meson
PATH=$PWD/venv/bin:$PATH examples/run-all.sh
```

## 来源

- ccache 官方手册：`doc/manual.adoc`，tag `v4.13.6` 与 `v4.14`（github.com/ccache/ccache）；发行版包附带的 4.13.6 手册与该 tag 逐字节相同
- ccache 发布说明：ccache.dev/releasenotes.html；4.13.6 包附带的 `NEWS`
- storage helper 列表：ccache.dev/storage-helpers.html；ccache-storage-http-go 的 README
- LLVM 23.1.0：`llvm/CMakeLists.txt`、`llvm/cmake/modules/HandleLLVMOptions.cmake`、`llvm/cmake/modules/LLVMExternalProjectUtils.cmake`、
  `llvm/runtimes/CMakeLists.txt`、`llvm/docs/CMake.md`
- hendrikmuhs/ccache-action：`action.yml`、`src/save.ts`（main 分支，2026-09-13）
