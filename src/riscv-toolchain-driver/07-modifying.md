# 07 改它的逻辑：定位、改法、验证、坑

> 这一篇是方法，不是清单。前提是已经读过 05 篇（每一行是干什么的）与 03 篇（钩子被谁调用）。
> 例子里的 diff 以 20.1.8 的 `RISCVToolchain.cpp` 为基线；改 21 的 `BareMetal.cpp` 时按 06 篇 §3 的映射表换位置即可，套路完全相同。

## 1. 先定位：这个参数是谁加的

拿到一个"链接行上多了/少了 X"的问题，不要从文件第一行读起，按下面的顺序：

1. `clang ... -###` 拿到实际命令行。
2. 在 `clang/lib/Driver/` 下 grep 那个字符串：`grep -rn '"--start-group"' clang/lib/Driver/`。
   固定字符串一定能 grep 到；路径类参数 grep 它的固定部分（`crtbegin`、`clang_rt.`、`-L`）。
3. grep 到多处时，用 `-ccc-print-bindings` 看链接 Tool 的名字（`RISCV::Linker` 还是 `baremetal::Linker`
   还是 `GNU::Linker`），只看那个类的 `ConstructJob`。
4. 如果字符串来自共享辅助函数（`CommonArgs.cpp` 里的 `AddRunTimeLibs`、`AddLinkerInputs`……），
   再看 `ConstructJob` 在哪一行调用它，以及调用前后的条件。

"想改 X → 改哪里"的速查：

| 想改 | 改哪里（20.1.8 行号） | 备注 |
|---|---|---|
| 默认链接的库（加/删/换顺序） | `ConstructJob` 第 209–221 行 | 注意 `--start-group` 的范围与 `-lgcc` 的位置 |
| crt 文件的名字或来源 | 第 181–197 行、第 223–224 行 | 名字改了要同步改 `FilePaths`（构造函数）让 `GetFilePath` 找得到 |
| 给链接器固定加一个选项 | 第 168–174 行附近（`-m`、`-X` 那一组） | 放在输入之前 |
| 转发一个新的用户选项 | 第 201–205 行的 `addAllArgs` 列表 | 先确认 `Options.td` 里它是否已标 `LinkerInput`（是的话 `AddLinkerInputs` 已经转发了） |
| 一个 `-mfoo` 选项要变成链接器选项 | 第 164–165 行的 `-mno-relax` 模式 | `Args.hasArg(OPT_mfoo)` 后 `push_back` |
| 换默认运行库 / C++ 库 | `GetDefaultRuntimeLibType`（79）/ 新增 `GetDefaultCXXStdlibType` 覆盖 | 用户 `--rtlib`/`--stdlib` 仍优先 |
| 头文件目录 | `AddClangSystemIncludeArgs`（101）、`addLibStdCxxIncludePaths`（119） | 顺序即优先级 |
| sysroot 怎么推 | `computeSysRoot`（130） | 记得空串陷阱 |
| 库/程序去哪找 | 构造函数（50） | 三张表 |
| 什么时候用这个类 | `hasGCCToolchain`（38）+ `Driver.cpp:6763`（20） | 21 里是 `BareMetal::initGCCInstallation` + `detectGCCToolchainAdjacent` |
| 传给 cc1 的固定参数 | `addClangTargetOptions`（94） | 编译侧，不是链接侧 |
| 是否生成 unwind 表 / PIC 默认 | `getDefaultUnwindTableLevel`（89）/ `isPICDefault` 等（继承 `Generic_GCC`） | |

## 2. 四个改法样例

每个样例都是"改哪几行 + 为什么这样改 + 怎么验证"。diff 是示意，不保证能直接 apply。

### 2.1 裸机没有 libgloss，改成自己的板级库

```diff
     CmdArgs.push_back("--start-group");
     CmdArgs.push_back("-lc");
-    CmdArgs.push_back("-lgloss");
+    CmdArgs.push_back("-lmyboard");
     CmdArgs.push_back("--end-group");
```

`libmyboard.a` 必须放在某个 `FilePaths` 目录里（`<sysroot>/lib` 最自然），否则用户得自己 `-L`。
验证：`-###` 里 `--start-group` 后面是 `-lc -lmyboard`；上游测试 `riscv32-toolchain.c` 里所有
`"-lgloss"` 的 CHECK 行都要改。

### 2.2 给链接器无条件加 `--gc-sections`，并让 cc1 生成分段（代码体积）

链接侧：

```diff
   CmdArgs.push_back("-X");
+  CmdArgs.push_back("--gc-sections");
```

编译侧要配合 `-ffunction-sections -fdata-sections`，否则 `--gc-sections` 无事可做。这属于 cc1 参数，
放 `addClangTargetOptions`：

```diff
 void RISCVToolChain::addClangTargetOptions(...) const {
   CC1Args.push_back("-nostdsysteminc");
+  if (!DriverArgs.hasArg(options::OPT_fno_function_sections))
+    CC1Args.push_back("-ffunction-sections");
+  if (!DriverArgs.hasArg(options::OPT_fno_data_sections))
+    CC1Args.push_back("-fdata-sections");
 }
```

注意这里读的是 `DriverArgs`（用户命令行），要留给用户关闭的余地，所以查 `-fno-*`。
验证：cc1 行有 `-ffunction-sections`，链接行有 `--gc-sections`；`-fno-function-sections` 时 cc1 行没有。

### 2.3 转发一个新的 `-m` 选项到链接器

假设要让 `-mno-foo` 变成链接器的 `--no-foo`。三步：

1. `Options.td` 里定义选项（若还没有）：`def mno_foo : Flag<["-"], "mno-foo">, Group<m_Group>, HelpText<"...">;`
   放在 `m_riscv_Features_Group` 附近。`Group<m_Group>` 让它出现在 `-m` 选项的帮助分组里；
   如果它同时要影响代码生成，还要在 `Arch/RISCV.cpp` 的 `getRISCVTargetFeatures` 里处理。
2. `ConstructJob`：
   ```diff
      if (Args.hasArg(options::OPT_mno_relax))
        CmdArgs.push_back("--no-relax");
   +  if (Args.hasArg(options::OPT_mno_foo))
   +    CmdArgs.push_back("--no-foo");
   ```
3. 测试：照 `riscv32-toolchain.c` 里 `CHECK-RV32-NORELAX` / `CHECK-RV32-RELAX-NOT` 那两段写正反两条。

`Options.td` 改了要重新生成 `Options.inc`（`ninja` 会自动做），`OPT_mno_foo` 才存在。

### 2.4 让 `--gcc-install-dir` 也能触发本类（20 上的缺口）

```diff
 bool RISCVToolChain::hasGCCToolchain(const Driver &D, const llvm::opt::ArgList &Args) {
-  if (Args.getLastArg(options::OPT_gcc_toolchain))
+  if (Args.getLastArg(options::OPT_gcc_toolchain, options::OPT_gcc_install_dir_EQ))
     return true;
```

`getLastArg` 接受多个选项 ID，任一存在即返回。这正是 21 的 `initGCCInstallation` 的判据。
验证：04 例子 (c) 那条命令在改后应当出现 `crtbegin.o` 而不是 unused 警告。

## 3. 验证：三层

**第一层：`-###`。** 零成本，改一行看一次。把改动前后的输出用 `sed 's/" "/"\n"/g'` 拆成每参数一行再 `diff`。
不需要任何真实的 RISC-V 工具链，用空文件搭假树（`examples/lib.sh` 的 `mk_basic_tree` 就是这么做的）。

**第二层：driver 的 lit 测试。** 上游每个行为都有对应的 RUN 行，改了行为就得改或加 CHECK 行。
一个测试文件的骨架（[`examples/06-lit-style/test.c`](examples/06-lit-style/test.c) 是能跑的完整版）：

```c
// RUN: %clang -### %s -fuse-ld= \
// RUN:   --target=riscv32-unknown-elf --rtlib=platform \
// RUN:   --gcc-toolchain=%S/Inputs/basic_riscv32_tree \
// RUN:   --sysroot=%S/Inputs/basic_riscv32_tree/riscv32-unknown-elf 2>&1 \
// RUN:   | FileCheck -check-prefix=C-RV32-BAREMETAL-ILP32 %s
// C-RV32-BAREMETAL-ILP32: "{{.*}}Inputs/basic_riscv32_tree/lib/gcc/riscv32-unknown-elf/8.0.1/../../../../bin/riscv32-unknown-elf-ld"
// C-RV32-BAREMETAL-ILP32: "-X"
// C-RV32-BAREMETAL-ILP32: "--start-group" "-lgcc" "-lc" "-lgloss" "--end-group"
```

读法：

- `RUN:` 行是 shell 命令，`lit` 逐条执行；连续的 `RUN:` 用 `\` 续行。`%clang` 是被测 clang，
  `%s` 是本文件，`%S` 是本文件所在目录，`%t` 是给这个测试的临时文件名（`%t/…` 可当临时目录用，
  先 `rm -rf %t && mkdir -p %t`）。
- `2>&1 | FileCheck -check-prefix=X %s`：把 `-###` 的 stderr 交给 FileCheck，FileCheck 只看本文件里
  以 `X:` 开头的注释行。
- `X:` 行**按顺序**在输出里找子串；`X-SAME:` 要求在同一行、上一条匹配之后；`X-NOT:` 要求在
  上一条与下一条之间**不出现**；`{{.*}}` 是正则占位（路径前缀不确定时用）；`[[VAR:.*]]` 捕获、`[[VAR]]` 复用。
- 常见的"环境消毒"参数：`--rtlib=platform`（抵消 `CLANG_DEFAULT_RTLIB`）、`-fuse-ld=`（抵消 `CLANG_DEFAULT_LINKER`）、
  `--sysroot=`（抵消 `DEFAULT_SYSROOT`）、`env "PATH="`（不让宿主 `ld` 被找到）、
  `-no-canonical-prefixes`（软链接的 clang 不被解析回真实路径）、`-resource-dir=`（指向假的资源目录）。
  测试要在任何人的机器上稳定，这些一个都不能少。
- 假树在 `clang/test/Driver/Inputs/`：`basic_riscv32_tree`、`basic_riscv64_tree`（单 multilib）、
  `multilib_riscv_elf_sdk`（七个 multilib）、`basic_riscv32_nogcc_tree`（只有 sysroot 没有 GCC）、
  `multilib_riscv_linux_sdk`（Linux）。里面全是空文件加 `.keep`，`ld` 只是带可执行位的空文件。

跑法（在 LLVM 构建目录里）：

```bash
ninja check-clang-driver                                       # 整个 clang/test/Driver
bin/llvm-lit -v ../clang/test/Driver/riscv32-toolchain.c       # 单个文件，-v 打印失败时的完整输出
bin/llvm-lit -a ../clang/test/Driver/riscv32-toolchain.c       # -a：成功也打印全部命令与输出
```

`FileCheck` 与 `llvm-lit` 在构建目录的 `bin/` 里；官方预编译包不带 `FileCheck`（实测 21.1.8 的
`LLVM-21.1.8-Linux-X64.tar.xz` 没有），所以第二层只能在有构建树的机器上做。

**第三层：真链接。** 前两层只保证"命令行长得对"。文件名拼对了但库的内容不对（ABI 不匹配、multilib
选错）只有真链接才会暴露，而且错误来自 `ld`，不来自 driver。上游把这层放在 `compiler-rt`、
`libc++` 的 runtimes 测试里，driver 测试不做。

## 4. 坑

- **`hasArg` 会 claim。** 读了一个选项就等于告诉 driver"这个选项已处理"，用户不会再收到 unused 警告。
  反过来，条件分支里没读到的选项会警告——`-nolibc` 就是例子。想读但不 claim 用 `hasArgNoClaim` / `getLastArgNoClaim`。
- **所有拼出来的字符串都要 `Args.MakeArgString`。** `CmdArgs` 存的是 `const char*`；直接
  `push_back(std::string(...).c_str())` 是悬空指针，`-###` 下可能碰巧正常、真跑时崩。字面量（`"-X"`）可以直接放。
- **`GetFilePath` 找不到时原样返回。** driver 层不报错，链接行上出现裸名字。改了 crt 名字后先 `-print-file-name=<名字>` 确认。
- **`computeSysRoot` 可能返回空串**（20 及之前）。所有 `computeSysRoot() + "/xxx"` 的地方都可能生成 `/xxx`。
- **`ToolChains` 按 triple 字符串缓存。** 同一次调用里同一 triple 只构造一次；构造函数里读的参数
  （`--gcc-toolchain`、`-march` 等）之后不会再看。所以"依赖某个参数的路径决策"要么放构造函数，
  要么每次在钩子里重算，不能既想缓存又想随参数变。
- **`D.CCCIsCXX()` 看的是程序名。** `clang foo.cpp` 会编译 C++，但链接时 `CCCIsCXX()` 为假，不带 `-lstdc++`。
  这与 GCC 一致，别在这里"修"它。
- **`getEffectiveTriple()` 只在 `ConstructJob` 期间有效**（`RegisterEffectiveTriple`，`ToolChain.h:856`），
  在构造函数或 `computeSysRoot` 里调用会 assert；那里用 `getTriple()`。
- **`Driver::getTargetTriple()` 是原始串。** 拿它拼目录名时，用户写 `--target=riscv32-unknown-unknown-elf`
  与 `riscv32-unknown-elf` 会得到不同目录。要稳定就用 `getTriple().str()`（规范化的），但要接受目录名变长。
- **`-fuse-ld=` 空值 ≠ 没给。** 都是"用默认 ld"，但前者会 claim 这个参数。测试里写空值是有意的。
- **`ResponseFileSupport`。** 参数总长超过系统限制时 driver 会把参数写进 `@file`；`AtFileCurCP()` 表示
  链接器支持这种写法。自己写 `Command` 时别改成 `None()`，否则长命令行会失败。
- **两个 `Args`。** 钩子里的 `DriverArgs` 是用户命令行；`ConstructJob` 里的 `Args` 是经过
  `TranslateArgs` 的派生列表（`Generic_GCC::TranslateArgs`，`Gnu.cpp:3329`，对 RISC-V 基本是透传）。
  一般无差别，但 `-Xarch_` 之类只在后者里展开。
- **多 ToolChain。** `BareMetal` 与 `RISCVToolChain` 在 20 及之前同时存在，同一个选项两边行为可能不同
  （`-fuse-ld` 默认、`-lgloss`、C++ 库）。改动要两边都看，或者先想清楚用户到底会落到哪一边。

## 5. 一个完整的改动应当包含什么

1. `RISCVToolchain.cpp`（或 `BareMetal.cpp`）的改动本身；
2. 若加了选项：`Options.td`；若影响代码生成：`Arch/RISCV.cpp`；
3. `clang/test/Driver/` 里对应测试的 CHECK 行更新，以及新行为的正反两条 RUN；
4. `clang/docs/ReleaseNotes.rst` 的 "RISC-V Support" 一节一句话（上游要求，自己维护也值得照做）；
5. 用 `-###` 在有 GCC 树、无 GCC 树、multilib 树三种布局下各看一遍——这三种布局在本目录的
   `examples/` 里都有现成的假树函数。
