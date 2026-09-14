# 01 driver 的模型：一条 `clang` 命令是怎么变成两个子进程的

> 核对版本：源码 llvmorg-21.1.8（行号以它为准，另注的除外）；命令输出来自官方预编译的 clang 20.1.8 与 21.1.8。
> 「实测」指 [`examples/`](examples/) 里对应脚本的断言。

## 1. 是什么

你敲的 `clang` 这个可执行文件**不是编译器**，是**driver**（驱动程序）。它做的事只有一件：
读懂 GCC 风格的命令行，决定要跑哪几个子进程、每个子进程的参数是什么，然后依次跑。真正
编译 C 代码的是同一个二进制以 `clang -cc1` 身份运行的那次调用（"cc1"这个名字沿用自 GCC）；
汇编由 cc1 顺手做掉（集成汇编器）；链接则要去找一个外部程序 `ld`。

所以对裸机 RISC-V 来说，一条最普通的命令

```bash
clang --target=riscv32-unknown-elf hello.c
```

最终只会变成两个子进程（实测：[`01-phases`](examples/01-phases/run.sh)）：

```text
 ".../bin/clang-21" "-cc1" "-triple" "riscv32-unknown-unknown-elf" ... "-o" "/tmp/hello-xxxx.o" "-x" "c" "hello.c"
 ".../bin/riscv32-unknown-elf-ld" ... "/tmp/hello-xxxx.o" ... "-o" "a.out"
```

`RISCVToolchain.cpp` 决定的就是这两行里**与"这个目标平台的工具链长什么样"有关**的部分：
cc1 那行的 `-isysroot`、`-internal-isystem`（头文件去哪找）、`-nostdsysteminc`；ld 那行的
几乎全部（用哪个 ld、`-m`、`crt0.o`、`-L`、`-lc -lgloss -lgcc`）。剩下的（`-target-feature`、
`-O2`、`-g`……）由 `Clang.cpp` 这个"cc1 参数翻译器"决定，与工具链无关。

## 2. 看见 driver 在想什么：四个开关

| 开关 | 输出什么 | 打到哪 |
|---|---|---|
| `-###` | 将要执行的每条命令（不执行）。每条一行，以一个空格加引号开头 | stderr |
| `-v` | 执行并打印命令，另外打印工具链探测过程（`Found candidate GCC installation:` 等） | stderr |
| `-ccc-print-phases` | Action 树：输入 → 预处理 → 编译 → 后端 → 汇编 → 链接 | stderr |
| `-ccc-print-bindings` | 每个 Action 绑定到哪个 Tool、输入输出文件名 | stderr |

四个都在 stderr，脚本里要 `2>&1`（实测里踩过一次）。`-###` 是本整理里用得最多的工具：
它让你**不需要任何真实的 RISC-V 工具链**就能看到 driver 的全部决策，上游的 driver 测试
（`clang/test/Driver/*.c`）也全靠它。

`-ccc-print-phases` 对上面那条命令的输出：

```text
            +- 0: input, "hello.c", c
         +- 1: preprocessor, {0}, cpp-output
      +- 2: compiler, {1}, ir
   +- 3: backend, {2}, assembler
+- 4: assembler, {3}, object
5: linker, {4}, image
```

六个 Action。`-ccc-print-bindings` 告诉你它们被合并成了两个 Job：

```text
# "riscv32-unknown-unknown-elf" - "clang", inputs: ["hello.c"], output: "/tmp/hello-xxxx.o"
# "riscv32-unknown-unknown-elf" - "baremetal::Linker", inputs: ["/tmp/hello-xxxx.o"], output: "a.out"
```

0–4 五个 Action 都给了名叫 `clang` 的 Tool（因为 cc1 自带预处理器、自带汇编器，`Tool::hasIntegratedCPP()` /
`hasIntegratedAssembler()` 为真时 driver 会把相邻阶段合并）；5 给了链接 Tool。
这个链接 Tool 的名字就是版本差异的第一个可见信号：**20.x 打印 `RISCV::Linker`，21.x 打印
`baremetal::Linker`**——前者定义在 `RISCVToolchain.h:53`（20.1.8），后者在 `BareMetal.h:118`。
06 篇讲这个变化。

## 3. 五个阶段与三个对象

上游文档 `clang/docs/DriverInternals.rst` 把 driver 分成五个阶段：**Parse**（解析参数）→
**Pipeline**（建 Action 树）→ **Bind**（给 Action 选 Tool、定文件名）→ **Translate**（Tool 把参数翻译成
子进程命令行）→ **Execute**。改 `RISCVToolchain.cpp` 就是改第三、四阶段里"归这个平台管"的部分。
涉及的对象一共三个，都在 `clang/include/clang/Driver/`：

**`ToolChain`**（`ToolChain.h:92`）——"一个目标平台上的一整套工具与库"。它是一个大基类，
几乎全是虚函数，每个平台一个子类：`Linux`、`Darwin`、`BareMetal`、以前的 `RISCVToolChain`……
子类回答的问题分三类：

- 平台默认值：默认运行库是 libgcc 还是 compiler-rt（`GetDefaultRuntimeLibType`）、默认 C++ 库
  （`GetDefaultCXXStdlibType`）、默认要不要 unwind 表、是否默认 PIC……
- 路径：头文件去哪找（`AddClangSystemIncludeArgs`）、库与 crt 文件去哪找（三张路径表，03 篇）、
  链接器去哪找（`GetLinkerPath`）、sysroot 是什么（`computeSysRoot`）；
- 工具：链接这个 Action 用哪个 Tool 对象（`buildLinker`）。

**`Tool`**（`Tool.h:32`）——"会构造一种子进程命令行的东西"。核心只有一个纯虚函数
`ConstructJob(Compilation&, JobAction&, Output, Inputs, Args, LinkingOutput)`：把参数翻译成一条命令，
`C.addCommand(...)` 塞进去。`RISCVToolchain.cpp` 里的 `tools::RISCV::Linker::ConstructJob`（20.1.8 第 152 行）
就是这样一个函数，它把 `--target=riscv32-unknown-elf hello.c` 翻译成上面那行 `ld` 命令。

**`Command`**（`Job.h:106`）——一条具体命令：可执行文件路径、参数数组、输入输出、以及
"参数太长时能不能写进响应文件"（`ResponseFileSupport`，`Job.h:44`；GNU ld 与 lld 都支持 `@file`，
所以 RISC-V 用 `AtFileCurCP()`）。

调用链：`Driver::BuildJobs`（`Driver.cpp:5235`）→ `BuildJobsForAction` → `TC.SelectTool(*JA)`
（`ToolChain.cpp:1061`：编译类 Action 给 `clang`，链接类 Action 走 `getTool(AC)` → `getLink()` →
子类的 `buildLinker()`）→ `T->ConstructJob(...)`（`Driver.cpp:6102`）。`buildLinker()` 只在第一次
调用时执行一次，结果缓存在 `ToolChain::Link` 里。

## 4. Driver 对象上你会反复用到的几个字段

`ToolChain` 的每个方法都能拿到 `getDriver()`，`RISCVToolchain.cpp` 用到了下面这些
（定义在 `Driver.h`，赋值在 `Driver::Driver`，`Driver.cpp:258`）：

| 字段 | 值 | 来源 |
|---|---|---|
| `Dir` | `clang` 可执行文件所在目录，例如 `<prefix>/bin` | `parent_path(ClangExecutable)`。默认会先解析符号链接；`-no-canonical-prefixes` 关掉解析，上游测试用它把 clang 软链进临时目录冒充一套安装 |
| `ResourceDir` | `<Dir>/../lib/clang/<主版本>`，例如 `.../lib/clang/21` | `GetResourcesPath`（`Driver.cpp:184`）。clang 自带头文件（`stddef.h` 等）在 `<ResourceDir>/include`，compiler-rt 在 `<ResourceDir>/lib/<triple>/` |
| `SysRoot` | `--sysroot=` 的值；没给就是空串（除非构建时配置了 `DEFAULT_SYSROOT`） | `BuildCompilation`（`Driver.cpp:1650`） |
| `TargetTriple` / `getTargetTriple()` | `--target=` 的**原始字符串**，例如 `riscv32-unknown-elf` | 未规范化。`RISCVToolchain.cpp` 用它拼 `<Dir>/../riscv32-unknown-elf`，所以目录名必须和你敲的 `--target` 一字不差 |
| `CCCIsCXX()` | 是否 `clang++` / `--driver-mode=g++` | 由**程序名**决定，不由输入文件后缀决定。`clang x.cpp` 会编译 C++ 但链接时不带 `-lstdc++` |
| `isUsingLTO()` / `getLTOMode()` | `-flto` / `-flto=thin` | 21 的 BareMetal 链接器据此加 `-plugin-opt`；20 的 `RISCV::Linker` 根本不看它 |

**两种 triple**。`--target=riscv32-unknown-elf` 经 `llvm::Triple::normalize` 变成
`riscv32-unknown-unknown-elf`（`elf` 被识别为 environment，中间补一个 unknown 的 OS），这是
`ToolChain::getTriple()`、cc1 的 `-triple`、`-print-target-triple` 看到的；而 `Driver::getTargetTriple()`
仍是原串。只写 `--target=riscv32` 则规范化后也只有 `riscv32`（缺的分量不会补），cc1 收到的就是
`-triple riscv32`（实测，两版一致）。

## 5. 谁来当这条命令的 ToolChain：`Driver::getToolChain`

`Driver.cpp:6788`。按 `Target.getOS()` 分发：Linux、Darwin、FreeBSD……各有各的类；
`riscv32-unknown-elf` 的 OS 是 `UnknownOS`，落进 `default:` 分支，再按 `Target.getArch()` 分发：

```cpp
// 21.1.8, Driver.cpp:6961
case llvm::Triple::riscv32:
case llvm::Triple::riscv64:
  TC = std::make_unique<toolchains::BareMetal>(*this, Target, Args);
  break;
```

而 20.1.8（`Driver.cpp:6763`）与 15.0.7（`Driver.cpp:6112`）是：

```cpp
case llvm::Triple::riscv32:
case llvm::Triple::riscv64:
  if (toolchains::RISCVToolChain::hasGCCToolchain(*this, Args))
    TC = std::make_unique<toolchains::RISCVToolChain>(*this, Target, Args);
  else
    TC = std::make_unique<toolchains::BareMetal>(*this, Target, Args);
  break;
```

两点要记住：

- 这个 `switch` 只在 OS 是 unknown 时才到得了。`riscv32-unknown-linux-gnu` 在上面的
  `case llvm::Triple::Linux:` 就被 `toolchains::Linux` 接走了，`RISCVToolchain.cpp` 从来不管 Linux 目标
  （实测 [`02-gcc-tree`](examples/02-gcc-tree/run.sh) 之外的 K 组对照：Linux 目标的链接行有
  `-dynamic-linker`、`crt1.o crti.o … crtn.o`、`--eh-frame-hdr`，完全是另一套逻辑，见 02 篇末尾）。
- 结果按 `Target.str()` 缓存在 `Driver::ToolChains` 里（`Driver.cpp:6791`）。同一次调用里同一个
  triple 只构造一次 ToolChain 对象，所以**构造函数里做的探测（找 GCC、算 sysroot）只发生一次**，
  之后所有钩子读的都是构造时算好的成员。

`hasGCCToolchain` 是 2020 年加进去的分叉点（`45ba2392d7e0`），06 篇有它的来龙去脉。

## 6. 参数的"已使用"位

driver 解析完全部参数后，每个 `Arg` 带一个 claimed 位。`Args.hasArg(X)`、`getLastArg(X)`、
`addAllArgs` 都会顺手把匹配到的参数标为已用；编译结束时没被标过的参数触发
`warning: argument unused during compilation`。这解释了实验里几个现象：

- `--unwindlib=platform` 在裸机 RISC-V 上报 unused：因为 `RISCVToolChain::GetUnwindLibType`
  直接 `return UNW_None`，没有去 `getLastArg(OPT_unwindlib_EQ)`（20.1.8 第 84 行；21 的
  BareMetal 同样如此）。
- `-nolibc` 在 20.1.8 与 21.1.8 都报 unused：两版的 RISC-V 裸机链接器都没查它（上游 2025-07-31
  才给 BareMetal 加上，`15f65afc7aa5`，在 21 分支之后）。
- `-static` 不报 unused，但也**没有任何效果**——`Options.td:6090` 给它标了 `NoArgumentUnused`，
  而 `RISCV::Linker` 从不读它。想知道一个选项到底有没有被工具链处理，看 `-###` 输出，不要看有没有警告。

这个机制也是你改代码时的一个约束：加了新的判断 `Args.hasArg(OPT_foo)`，就等于替用户"消费"了
`-foo`；反过来忘了读某个选项，用户会看到 unused 警告——这是提醒你漏了，别用 `ClaimAllArgs` 把它捂住。

## 7. 本篇之后

02 篇补链接零基础：`-###` 那行 `ld` 命令里每个词是什么意思、为什么非有不可。
读完再回来看 `RISCVToolchain.cpp` 的 `ConstructJob`，每一行都能对上号。
