# 03 `ToolChain` 基类：`RISCVToolChain` 继承了什么、覆盖了什么

> 核对版本：llvmorg-21.1.8 的 `clang/include/clang/Driver/ToolChain.h` 与 `clang/lib/Driver/ToolChain.cpp`
> （这些接口在 15 → 21 之间基本没变，变了的在 06 篇单列）。

`RISCVToolChain` 的继承链是 `ToolChain` → `Generic_GCC` → `Generic_ELF` → `RISCVToolChain`
（`RISCVToolchain.h:19`）。21 里接手的 `BareMetal` 也改成了继承 `Generic_ELF`（20 及之前它直接
继承 `ToolChain`）。读 `RISCVToolchain.cpp` 时真正需要知道的基类内容只有五块：三张路径表、
文件与程序的查找顺序、三个"库类型"的选择、头文件钩子、以及 `Generic_GCC` 带来的 `GCCInstallation`。

## 1. 三张路径表

`ToolChain.h:151–158`：

```cpp
path_list LibraryPaths;   // 找运行库（compiler-rt）的目录
path_list FilePaths;      // 找文件（crt*.o、库）的目录，也是链接行上 -L 的来源
path_list ProgramPaths;   // 找程序（ld、as）的目录
```

`path_list` 是 `SmallVector<std::string, 16>`——LLVM 自己的向量类型，前 16 个元素放在对象
内部不用堆分配，其余用法与 `std::vector` 相同。三张表都由**构造函数**填：基类构造函数
（`ToolChain.cpp:89`）先塞几条通用的，子类构造函数再追加。`RISCVToolChain` 构造函数
（20.1.8 第 50–73 行）追加的是：

| 表 | 追加的项 | 条件 |
|---|---|---|
| `FilePaths` | multilib 回调给出的目录（04 篇）、`GCCInstallation.getInstallPath()`（放 `crtbegin.o` 的那个）、`computeSysRoot() + "/lib"`（放 `crt0.o` 的那个） | 前两项仅当找到 GCC |
| `ProgramPaths` | `<ParentLibPath>/../<gcc triple>/bin`、`<ParentLibPath>/../bin`；找不到 GCC 时是 `D.Dir` | |

基类构造函数塞进去的通用项，对 RISC-V 裸机而言只有一条会真的存在：
`getRuntimePath()`（`ToolChain.cpp:999`）= `<ResourceDir>/lib/<triple>`，例如
`lib/clang/21/lib/riscv32-unknown-unknown-elf`，进 `LibraryPaths`。这就是 21 的链接行上多出来的那个
`-L.../lib/clang/21/lib/riscv32-unknown-unknown-elf`（`BareMetal.cpp:651` 把 `LibraryPaths` 也输出成
`-L`；20 的 `RISCV::Linker` 只输出 `FilePaths`）。另外两条 `getStdlibPath()`（`<Dir>/../lib/<triple>`）
与 `getArchSpecificLibPaths()`（`<ResourceDir>/lib/baremetal/riscv32` 之类）都要目录真的存在才加。

`-print-search-dirs` 打印的就是这些表（`programs:` = `ProgramPaths`，`libraries:` = `ResourceDir` +
`FilePaths`）。实测（有 GCC 树）：

```text
programs: =$R/bin:$G/../../../../riscv32-unknown-elf/bin:$G/../../../../bin
libraries: =$R/lib/clang/21:$G:$S/lib
```

## 2. 找一个文件：`GetFilePath`

`ToolChain::GetFilePath(Name)`（`ToolChain.cpp:1071`）转给 `Driver::GetFilePath`（`Driver.cpp:6510`），
顺序固定：

1. `-B<prefix>` 给的每个前缀（`PrefixDirs`；前缀以 `=` 开头则相对 sysroot）；
2. `<ResourceDir>/Name`；
3. `TC.getCompilerRTPath()/Name`（21 的 BareMetal 覆盖了这个函数，见 06 篇）；
4. `<Dir>/../Name`；
5. `LibraryPaths` 里的每个目录；
6. `FilePaths` 里的每个目录；
7. `<ResourceDir>/../../Name`；
8. 都没有：**原样返回 `Name`**。

第 8 条是很多"奇怪输出"的根源：链接行上出现裸的 `"crt0.o"` 或 `"crtbegin.o"` 就是它。
链接器随后会在 `-L` 目录里找这个名字，找得到就没事，找不到才报错——所以 driver 层不报错。

`RISCV::Linker` 里 `ToolChain.GetFilePath("crt0.o")`、`GetFilePath(crtbegin)` 走的都是这条路，
`crt0.o` 靠第 6 条里的 `computeSysRoot()/lib` 命中，`crtbegin.o` 靠 `GCCInstallation.getInstallPath()`
命中，`clang_rt.crtbegin.o` 靠第 5 条的 `<ResourceDir>/lib/<triple>` 命中。

## 3. 找一个程序：`GetProgramPath` 与 `GetLinkerPath`

`Driver::GetProgramPath(Name)`（`Driver.cpp:6575`）：

1. `-B` 前缀（目录则在目录里找，否则当作文件名前缀拼接）；
2. 先把名字变成候选列表 `generatePrefixedToolNames`：`<triple>-Name`、`Name`
   （例如 `riscv32-unknown-elf-ld` 与 `ld`）。对每个候选，依次在 `ProgramPaths` 每个目录里找
   **可执行**文件，再退到 `PATH`；
3. 都没有：原样返回 `Name`。

注意顺序是"先按名字、后按目录"：`riscv32-unknown-elf-ld` 在任何目录里被找到都优先于 `ld`。
这就是实验里 `$G/../../../../bin/riscv32-unknown-elf-ld` 胜出的原因（它在 `ProgramPaths` 第二项），
以及 04 例子里假树 `bin/` 下只有一个空的可执行文件 `riscv32-unknown-elf-ld` 也够用的原因
（driver 只检查可执行位，不检查内容）。

`GetLinkerPath`（`ToolChain.cpp:1079`）在此之上处理 `-fuse-ld=`：

- 没给或 `-fuse-ld=ld`：`GetProgramPath(getDefaultLinker())`，默认链接器名是 `"ld"`
  （`ToolChain.h:498`；20 的 `BareMetal` 覆盖成 `"ld.lld"`，21 去掉了这个覆盖，见 06）；
- `-fuse-ld=lld`：找 `ld.lld`；`-fuse-ld=bfd`：找 `ld.bfd`。实测 `-fuse-ld=lld -B<clang 的 bin>`
  得到 `.../bin/ld.lld`；
- `--ld-path=<path>`：直接用这个可执行文件，优先级最高。

上游测试里常见的 `-fuse-ld=`（空值）就是"用默认 `ld`"，目的是抵消构建时的 `CLANG_DEFAULT_LINKER`
配置，让测试在任何构建配置下都稳定。

## 4. 三个"库类型"与 `platform`

三个枚举，三个 `Get*Type(Args)`，三个 `GetDefault*Type()`：

| 类型 | 选项 | 枚举 | 基类默认 | `RISCVToolChain` 的回答 |
|---|---|---|---|---|
| 编译器运行库 | `--rtlib=` | `RLT_Libgcc` / `RLT_CompilerRT` | `RLT_Libgcc`（`ToolChain.h:501`） | 找到 GCC → libgcc，否则 compiler-rt（第 79 行） |
| C++ 标准库 | `--stdlib=` | `CST_Libstdcxx` / `CST_Libcxx` | `CST_Libstdcxx`（`:505`） | 不覆盖，即 libstdc++ |
| unwind 库 | `--unwindlib=` | `UNW_None` / `UNW_CompilerRT` / `UNW_Libgcc` | `UNW_None`（`:509`） | 覆盖了 `GetUnwindLibType` 本身，恒 `UNW_None`（第 84 行） |

`Get*Type(Args)` 的逻辑（`ToolChain.cpp:1299`、`1361`、`1325`）都是同一个模板：先看用户选项，
没有就看构建时配置 `CLANG_DEFAULT_RTLIB` / `CLANG_DEFAULT_CXX_STDLIB` / `CLANG_DEFAULT_UNWINDLIB`
（发行版打包的 clang 常把它们设成 compiler-rt / libc++），值是 `platform` 或空则回退到
`GetDefault*Type()`。结果缓存在 `runtimeLibType` 等 `mutable std::optional` 成员里，一个 ToolChain
对象只算一次。**上游测试里到处写 `--rtlib=platform` 就是为了绕过 `CLANG_DEFAULT_RTLIB`**，
让"平台默认值"真的是代码里的默认值。

这三个值在 `RISCV::Linker::ConstructJob` 里的消费点：`GetRuntimeLibType` 决定 `crtbegin.o` 用哪套名字
（第 182 行）和 `AddRunTimeLibs` 加 `-lgcc` 还是 builtins.a（第 220 行）；`GetCXXStdlibType` 决定
`AddCXXStdlibLibArgs` 加 `-lstdc++` 还是 `-lc++`（`ToolChain.cpp:1511`）；`GetUnwindLibType` 在
`AddUnwindLibrary`（`CommonArgs.cpp:2288`）里，`UNW_None` 时直接返回什么都不加。

还有一个不是"库"但同类的默认值：`getDefaultUnwindTableLevel(Args)`。它决定 cc1 收不收到
`-funwind-tables=1/2`（`Clang.cpp:6010`），也就是要不要为每个函数生成 `.eh_frame` 展开表。
`Generic_GCC` 对 RISC-V 默认 `Asynchronous`（`Gnu.cpp:2984`，为 Linux 准备）；`RISCVToolChain`
在 2024 年覆盖成 `None`（第 89 行，`f1e0392b822e`）——裸机代码体积敏感，没有异常就不该带展开表。
实测 cc1 行上确实没有 `-funwind-tables`（Linux 目标有 `-funwind-tables=2`）。

## 5. 头文件钩子与 `-internal-isystem`

`Clang.cpp` 构造 cc1 命令时按固定顺序调用 ToolChain 的三个钩子：

| 钩子 | 调用点 | `RISCVToolChain` 的实现 |
|---|---|---|
| `AddClangCXXStdlibIncludeArgs` | `Clang.cpp:1115`，仅 C++ 输入 | 不覆盖；`Generic_GCC` 的版本（`Gnu.cpp:3148`）按 `GetCXXStdlibType` 分派到 `addLibStdCxxIncludePaths`（这个 `RISCVToolChain` 覆盖了，第 119 行） |
| `AddClangSystemIncludeArgs` | `Clang.cpp:1152` | 覆盖（第 101 行）：先 `<ResourceDir>/include`，再 `<sysroot>/include` |
| `addClangTargetOptions` | `Clang.cpp:5343` / `6043` | 覆盖（第 94 行）：只加 `-nostdsysteminc` |

三个钩子都通过静态辅助函数 `addSystemInclude`（`ToolChain.cpp:1395`）往 cc1 参数里追加
`-internal-isystem <dir>`。`-internal-isystem` 是 cc1 专用的选项，相当于"driver 替你算出来的
系统头文件目录"，用户不该直接写。**顺序即搜索顺序**：C++ 的三个目录在最前，然后 clang 自带头文件，
最后 sysroot 的 `include`——所以 `stddef.h`、`stdint.h` 用 clang 的，`stdio.h` 用 newlib 的。

`-nostdsysteminc` 的作用（`Options.td:8570`，落到 `HeaderSearchOptions::UseStandardSystemIncludes = false`；
`InitHeaderSearch.cpp:178`、`:195`）：关掉 cc1 自己那套"按 triple 猜系统头文件目录"的老逻辑
（`/usr/local/include`、`/usr/include` 之类）。这套老逻辑对多数 OS 已经关闭（`ShouldAddDefaultIncludePaths`，
`InitHeaderSearch.cpp:211`，Linux、Windows 等都返回 false，"由 driver 管理"），但对 OS 为 unknown 的 triple
它**仍然返回 true**——也就是说 `riscv32-unknown-elf` 不加这个参数的话，cc1 会把宿主的 `/usr/local/include`、
`/usr/include` 放进搜索路径。交叉编译时这些宿主目录绝不能进搜索路径，所以裸机工具链一律加它，
把头文件目录的决定权完全收归 driver。`-nostdinc`（全关）、`-nobuiltininc`
（不要 clang 自带的）、`-nostdlibinc`（不要 sysroot 的）三个用户选项在 `AddClangSystemIncludeArgs` 里
逐个处理。

## 6. `Generic_GCC` 与 `Generic_ELF` 带来的东西

`RISCVToolChain` 之所以继承 `Generic_ELF` 而不是直接继承 `ToolChain`，是为了拿到 `Generic_GCC`
（`Gnu.h:146`）的这些成员：

- `GCCInstallationDetector GCCInstallation`（`Gnu.h:289`）——找 GCC 安装目录的探测器，04 篇专讲。
  `RISCVToolChain` 构造函数第一句就是 `GCCInstallation.init(Triple, Args)`。
- `buildAssembler()` → `gnutools::Assembler`（`Gnu.cpp:2970`）：`-fno-integrated-as` 时调用外部 `as`，
  并把 `-mabi`/`-march` 传过去（`Gnu.cpp:686`）。实测 `-fno-integrated-as -c` 得到
  `"as" "-mabi" "ilp32" "-march" "rv32imac"`。默认走集成汇编器（`IsIntegratedAssemblerDefault`，
  `Gnu.cpp:3022` 返回 true），所以平时看不到 `as`。
- `buildLinker()` 的默认实现是 `gcc::Linker`（`Gnu.cpp:2974`，去调用 `gcc` 来链接）——`RISCVToolChain`
  必须覆盖它，否则会去找一个叫 `gcc` 的程序。
- `printVerboseInfo`（`Gnu.cpp:2976`）——`-v` 时打印 `Found candidate GCC installation:` 那几行。
- `addLibStdCXXIncludePaths(IncludeDir, Triple, IncludeSuffix, ...)`（`Gnu.cpp:3225`，注意大写的 `CXX`）——
  给定 `include/c++/<ver>` 目录，追加三个 `-internal-isystem`。`RISCVToolChain::addLibStdCxxIncludePaths`
  （小写 `Cxx`，第 119 行）只是算好目录后调它。
- `Generic_ELF::addClangTargetOptions`（`Gnu.cpp:3371`）——处理 `-fno-use-init-array`。`RISCVToolChain`
  覆盖了同名函数**且没有调用基类版本**，所以 RISC-V 上 `-fno-use-init-array` 不会传给 cc1（实测未验证，代码阅读）。

`Generic_GCC` 的构造函数（`Gnu.cpp:2945`）还会把 `D.Dir` 塞进 `ProgramPaths`，所以即使找到了 GCC，
clang 自己的 `bin` 也始终在程序搜索路径里（`-print-search-dirs` 的第一项）。

## 7. 一张"谁调用它"的总表

把 `RISCVToolChain` 覆盖的每个虚函数与它的调用点放在一起，改代码时先查这张表，就知道
改动会影响哪条命令的哪一段：

| `RISCVToolChain` 成员（20.1.8 行号） | 谁调用 | 影响 |
|---|---|---|
| `hasGCCToolchain`（38，静态） | `Driver::getToolChain`（20: `Driver.cpp:6763`） | 选 `RISCVToolChain` 还是 `BareMetal` |
| 构造函数（50） | `Driver::getToolChain` | 三张路径表、multilib 选择 |
| `buildLinker`（75） | `ToolChain::getLink`（`ToolChain.cpp:579`） | 链接 Tool 是哪个类 |
| `GetDefaultRuntimeLibType`（79） | `ToolChain::GetRuntimeLibType`（`:1299`） | crt 文件名、`-lgcc`/builtins.a |
| `GetUnwindLibType`（84） | `AddUnwindLibrary`（`CommonArgs.cpp:2288`） | 是否加 `-lgcc_s`/`-lunwind`（这里恒不加） |
| `getDefaultUnwindTableLevel`（89） | `Clang.cpp:6010` | cc1 的 `-funwind-tables` |
| `addClangTargetOptions`（94） | `Clang.cpp:5343` | cc1 的 `-nostdsysteminc` |
| `AddClangSystemIncludeArgs`（101） | `Clang.cpp:1152` | cc1 的 C 头文件 `-internal-isystem` |
| `addLibStdCxxIncludePaths`（119） | `Generic_GCC::AddClangCXXStdlibIncludeArgs`（`Gnu.cpp:3148`）← `Clang.cpp:1115` | cc1 的 C++ 头文件目录 |
| `computeSysRoot`（130） | 构造函数、上两个钩子；**不是** `Driver::SysRoot` | `-internal-isystem <sysroot>/include`、`FilePaths` 里的 `<sysroot>/lib` |
| `RISCV::Linker::ConstructJob`（152） | `Driver::BuildJobsForActionNoCache`（`Driver.cpp:6102`） | 整条链接命令 |

`computeSysRoot` 这一行要特别注意：`ConstructJob` 里判断要不要给链接器传 `--sysroot=`
用的是 `D.SysRoot`（用户显式给的），而头文件与 `crt0.o` 的目录用的是 `computeSysRoot()`
（可能是推导出来的）。两者不一致是设计使然，不是 bug。
