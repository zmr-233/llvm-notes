# 05 `RISCVToolchain.cpp` 逐段精读

> 文本以 llvmorg-20.1.8 为准（这是含有这个文件的最后一个大版本；与 20.1.1 逐字节相同）。
> 15.0.7 与它的差异共五处，在 06 篇逐条说明。实测：[`examples/`](examples/) 全部六个脚本。
> 建议对照 [`01`](01-driver-model.md)–[`04`](04-gcc-detection-and-multilib.md) 读：每个函数只讲它自己的事，背景都在前四篇。

文件只有 232 行，两个类：`toolchains::RISCVToolChain`（ToolChain 子类，回答"这个平台长什么样"）
和 `tools::RISCV::Linker`（Tool 子类，构造链接命令）。头文件 `RISCVToolchain.h` 只有声明。

## 0. 头与 `using`（第 9–23 行）

```cpp
#include "RISCVToolchain.h"
#include "CommonArgs.h"                 // AddLinkerInputs / AddRunTimeLibs / addPathIfExists 等共享辅助函数
#include "clang/Driver/Compilation.h"   // Compilation::addCommand
#include "clang/Driver/InputInfo.h"     // InputInfo：一个输入是文件名还是参数
#include "clang/Driver/Options.h"       // options::OPT_* 常量（由 Options.td 生成）
#include "llvm/Option/ArgList.h"        // ArgList / ArgStringList
#include "llvm/Support/FileSystem.h"    // llvm::sys::fs::exists
#include "llvm/Support/Path.h"          // llvm::sys::path::append
#include "llvm/Support/raw_ostream.h"

using namespace clang::driver;
using namespace clang::driver::toolchains;
using namespace clang::driver::tools;
using namespace clang;
using namespace llvm::opt;
```

三个会反复出现的类型：`ArgList`（解析后的命令行，`hasArg`/`getLastArg`/`addAllArgs`），
`ArgStringList`（`SmallVector<const char*>`，正在拼的子进程参数），`Args.MakeArgString(Twine)`
（把临时字符串复制进 `ArgList` 拥有的内存，返回 `const char*`——**所有拼出来的路径都必须过它**，
因为 `ArgStringList` 只存裸指针，临时 `std::string` 一析构就悬空）。
`SmallString<128>` 是 LLVM 的栈上字符串（前 128 字节不分配堆），`StringRef` 是不拥有内存的
字符串视图，`Twine` 是延迟拼接的字符串表达式，三者都是 LLVM 处处使用的惯用法。

注意 21 里 `CommonArgs.h` 搬到了 `clang/Driver/CommonArgs.h`（`a42bb8b57a6d`），06 篇的接线清单有。

## 1. `addMultilibsFilePaths`（第 25–32 行）

```cpp
static void addMultilibsFilePaths(const Driver &D, const MultilibSet &Multilibs,
                                  const Multilib &Multilib, StringRef InstallPath,
                                  ToolChain::path_list &Paths) {
  if (const auto &PathsCallback = Multilibs.filePathsCallback())
    for (const auto &Path : PathsCallback(Multilib))
      addPathIfExists(D, InstallPath + Path, Paths);
}
```

04 篇 §4 第 2 条那个回调的消费者：对选中的 multilib，回调返回三条相对路径，拼在
`GCCInstallPath` 后面，存在的加进 `FilePaths`。`addPathIfExists`（`CommonArgs.cpp:348`）
只做 `exists` 判断。无 multilib 时回调为空，函数什么都不做。

## 2. `hasGCCToolchain`（第 34–47 行）

```cpp
// This function tests whether a gcc installation is present either
// through gcc-toolchain argument or in the same prefix where clang
// is installed. This helps decide whether to instantiate this toolchain
// or Baremetal toolchain.
bool RISCVToolChain::hasGCCToolchain(const Driver &D, const llvm::opt::ArgList &Args) {
  if (Args.getLastArg(options::OPT_gcc_toolchain))
    return true;

  SmallString<128> GCCDir;
  llvm::sys::path::append(GCCDir, D.Dir, "..", D.getTargetTriple(), "lib/crt0.o");
  return llvm::sys::fs::exists(GCCDir);
}
```

**是什么**：静态函数，在 ToolChain 对象存在之前被 `Driver::getToolChain` 调用，决定 RISC-V 裸机
目标用这个类还是用 `BareMetal`。两个条件之一为真即选本类：命令行上有 `--gcc-toolchain=`
（**只看有没有，不看值对不对**，`--gcc-toolchain=` 空值也算）；或者 clang 旁边有
`<Dir>/../<原始 --target 字符串>/lib/crt0.o`。

**为什么这样设计**：2020 年（`45ba2392d7e0`）有人要做"不依赖 GCC、用 lld + compiler-rt + 自带 libc"
的 RISC-V 裸机工具链，`BareMetal` 更合适，但直接切换会破坏所有依赖 GCC 树的用户。于是加了这个
启发式："看起来有 GCC 就走老路"。作者在提交说明里自己写了 "I will be happy to hear if there
is a better way to choose between these two toolchains"——它一直是权宜之计，五年后被 21 的合并终结。

**两个陷阱**（实测，[`04-no-gcc`](examples/04-no-gcc/run.sh)）：

- 只认 `--gcc-toolchain`，不认 `--gcc-install-dir`。20.x 上只给 `--gcc-install-dir=` 会落到
  `BareMetal`，然后这个参数被报 unused。
- `--gcc-toolchain=` 空值：进了本类，`GCCInstallation.init` 找不到东西，`isValid()` 为假，
  于是变成 §5 说的"无 GCC 分支"，且 sysroot 推导会得到空串——链接行上出现 `-L/lib`（宿主的 `/lib`！）
  和裸的 `crt0.o`。上游测试 `baremetal-undefined-symbols.c` 在 20 里就是靠这个组合让 RISC-V 走
  `RISCV::Linker` 又不依赖真实工具链。

## 3. 构造函数（第 49–73 行）

```cpp
RISCVToolChain::RISCVToolChain(const Driver &D, const llvm::Triple &Triple, const ArgList &Args)
    : Generic_ELF(D, Triple, Args) {
  GCCInstallation.init(Triple, Args);
  if (GCCInstallation.isValid()) {
    Multilibs = GCCInstallation.getMultilibs();
    SelectedMultilibs.assign({GCCInstallation.getMultilib()});
    path_list &Paths = getFilePaths();
    // Add toolchain/multilib specific file paths.
    addMultilibsFilePaths(D, Multilibs, SelectedMultilibs.back(),
                          GCCInstallation.getInstallPath(), Paths);
    getFilePaths().push_back(GCCInstallation.getInstallPath().str());
    ToolChain::path_list &PPaths = getProgramPaths();
    // Multilib cross-compiler GCC installations put ld in a triple-prefixed
    // directory off of the parent of the GCC installation.
    PPaths.push_back(Twine(GCCInstallation.getParentLibPath() + "/../" +
                           GCCInstallation.getTriple().str() + "/bin").str());
    PPaths.push_back((GCCInstallation.getParentLibPath() + "/../bin").str());
  } else {
    getProgramPaths().push_back(D.Dir);
  }
  getFilePaths().push_back(computeSysRoot() + "/lib");
}
```

逐行：

- 初始化列表 `Generic_ELF(D, Triple, Args)`：基类链一路构造上去。`ToolChain` 基类构造函数塞入
  `<ResourceDir>/lib/<triple>` 等通用路径（03 篇 §1）；`Generic_GCC` 构造函数把 `D.Dir` 塞进 `ProgramPaths`。
- `GCCInstallation.init(Triple, Args)`：04 篇的全部探测在这一行发生。注意传的是规范化后的
  `Triple`（`riscv32-unknown-unknown-elf`），`init` 内部自己生成 `riscv32-unknown-elf` 等候选。
- `isValid()` 为真（找到了 GCC）：
  - 把探测器算出的 multilib 集合与选中项搬到基类成员。`SelectedMultilibs` 是一个向量（2023 年
    `edc1130c0ac0` 之前是单个 `SelectedMultilib`，15.0.7 里是 `SelectedMultilib = GCCInstallation.getMultilib();`），
    这里只放一个元素。基类的 `getCompilerRTPath()` 会用 `SelectedMultilibs.back().gccSuffix()`，
    `-print-multi-directory` 也读它。
  - `FilePaths` 追加：multilib 子目录（若有）→ `GCCInstallPath`（`crtbegin.o`、`libgcc.a` 所在）。
  - `ProgramPaths` 追加：`<prefix>/<gcc triple>/bin`（riscv-gnu-toolchain 把不带前缀的 `ld` 放这里）→
    `<prefix>/bin`（带前缀的 `riscv32-unknown-elf-ld` 在这里）。03 篇 §3 说过查找是"先按名字后按目录"，
    所以带前缀的名字总是先被找到。
- `isValid()` 为假：只把 `D.Dir` 加进 `ProgramPaths`——其实 `Generic_GCC` 已经加过一次了，这一句
  是多余的（无害）。链接器就在 clang 旁边找 `riscv32-unknown-elf-ld`（04 例子 (a) 的情形）。
- 最后一行无条件：`computeSysRoot() + "/lib"` 进 `FilePaths`——`crt0.o`、`libc.a` 所在。
  `computeSysRoot()` 返回空串时这一项变成 `"/lib"`，就是 §2 说的陷阱。

构造完成后，对实验 A（有 GCC 树、给了 `--sysroot`）三张表的内容：

```text
ProgramPaths: [$R/bin, $G/../../../../riscv32-unknown-elf/bin, $G/../../../../bin]
FilePaths:    [$G, $S/lib]                          ← multilib 回调没加东西（假树无 multilib）
LibraryPaths: [$R/lib/clang/20/lib/riscv32-unknown-unknown-elf]
```

`-print-search-dirs` 打印的正是它们（`libraries:` 前面还会带一个 `ResourceDir`）。

## 4. `buildLinker`（第 75–77 行）

```cpp
Tool *RISCVToolChain::buildLinker() const { return new tools::RISCV::Linker(*this); }
```

覆盖 `Generic_GCC::buildLinker`（那个返回调用 `gcc` 的 `gcc::Linker`）。返回裸 `new` 指针，
所有权由基类的 `std::unique_ptr<Tool> Link` 接管（`ToolChain.cpp:579`）。

## 5. 三个默认值（第 79–92 行）

```cpp
ToolChain::RuntimeLibType RISCVToolChain::GetDefaultRuntimeLibType() const {
  return GCCInstallation.isValid() ? ToolChain::RLT_Libgcc : ToolChain::RLT_CompilerRT;
}
ToolChain::UnwindLibType RISCVToolChain::GetUnwindLibType(const llvm::opt::ArgList &Args) const {
  return ToolChain::UNW_None;
}
ToolChain::UnwindTableLevel RISCVToolChain::getDefaultUnwindTableLevel(const llvm::opt::ArgList &Args) const {
  return UnwindTableLevel::None;
}
```

- 运行库默认：有 GCC 用 libgcc，没有用 compiler-rt（2019 年 `e0f22fe04a5c` 加的，此前无 GCC 时也硬要 `-lgcc`）。
  用户 `--rtlib=` 优先，这里只是 `platform` 时的回答。
- unwind 库：覆盖的是 `GetUnwindLibType(Args)` 而不是 `GetDefaultUnwindLibType()`，所以**用户的
  `--unwindlib=` 被彻底忽略**，还会报 unused（03 篇 §4）。
- unwind 表：`None`，cc1 不收 `-funwind-tables`。这是 2024 年（`f1e0392b822e`）为代码体积加的；
  15.0.7 没有这个函数，继承 `Generic_GCC` 的 `Asynchronous`，所以 15 编出来的裸机代码每个函数都带 `.eh_frame`。
  迁移时如果对比 15 与 20+ 的产物体积，这是一个差异来源。

## 6. `addClangTargetOptions`（第 94–99 行）

```cpp
void RISCVToolChain::addClangTargetOptions(const llvm::opt::ArgList &DriverArgs,
                                           llvm::opt::ArgStringList &CC1Args, Action::OffloadKind) const {
  CC1Args.push_back("-nostdsysteminc");
}
```

给 cc1 的唯一附加参数。含义见 03 篇 §5：关掉 cc1 内置的宿主头文件目录。没有调用
`Generic_ELF::addClangTargetOptions`，所以 `-fno-use-init-array` 在这个工具链上不会传递（代码阅读；
RISC-V 后端默认就用 `.init_array`，实际影响很小）。

## 7. `AddClangSystemIncludeArgs`（第 101–117 行）

```cpp
void RISCVToolChain::AddClangSystemIncludeArgs(const ArgList &DriverArgs, ArgStringList &CC1Args) const {
  if (DriverArgs.hasArg(options::OPT_nostdinc))
    return;

  if (!DriverArgs.hasArg(options::OPT_nobuiltininc)) {
    SmallString<128> Dir(getDriver().ResourceDir);
    llvm::sys::path::append(Dir, "include");
    addSystemInclude(DriverArgs, CC1Args, Dir.str());
  }

  if (!DriverArgs.hasArg(options::OPT_nostdlibinc)) {
    SmallString<128> Dir(computeSysRoot());
    llvm::sys::path::append(Dir, "include");
    addSystemInclude(DriverArgs, CC1Args, Dir.str());
  }
}
```

两个目录，两个开关，顺序固定：先 `<ResourceDir>/include`（clang 自带的 `stddef.h`、`stdint.h`、
`stdatomic.h`……），后 `<sysroot>/include`（newlib）。顺序是 2022 年反复 revert 了三次才定下来的
（`079d13668bf1` → `c1f17b0a9ea0`）：反了的话 newlib 的 `stdint.h` 会盖掉 clang 的，而 clang 的头文件
用 `#include_next` 假定自己在前。实测 cc1 行：

```text
"-internal-isystem" "$R/lib/clang/20/include" "-internal-isystem" "$S/include"
```

`computeSysRoot()` 为空时第二个目录是 `/include`——同样是那个空串陷阱。

## 8. `addLibStdCxxIncludePaths`（第 119–128 行）

```cpp
void RISCVToolChain::addLibStdCxxIncludePaths(const llvm::opt::ArgList &DriverArgs,
                                              llvm::opt::ArgStringList &CC1Args) const {
  const GCCVersion &Version = GCCInstallation.getVersion();
  StringRef TripleStr = GCCInstallation.getTriple().str();
  const Multilib &Multilib = GCCInstallation.getMultilib();
  addLibStdCXXIncludePaths(computeSysRoot() + "/include/c++/" + Version.Text,
                           TripleStr, Multilib.includeSuffix(), DriverArgs, CC1Args);
}
```

只在 C++ 输入且 `-stdlib=libstdc++`（默认）时被 `Generic_GCC::AddClangCXXStdlibIncludeArgs` 调用。
算出 `<sysroot>/include/c++/<GCC 版本>`，交给基类的 `addLibStdCXXIncludePaths`（`Gnu.cpp:3225`）
展开成三个目录：`.../c++/8.0.1`、`.../c++/8.0.1/riscv32-unknown-elf`（`bits/c++config.h` 在这）、
`.../c++/8.0.1/backward`。没找到 GCC 时 `Version.Text` 是空串、目录不存在，基类函数
`exists` 检查失败直接返回，什么都不加——libstdc++ 头文件本来就是 GCC 装的。

## 9. `computeSysRoot`（第 130–150 行）

```cpp
std::string RISCVToolChain::computeSysRoot() const {
  if (!getDriver().SysRoot.empty())
    return getDriver().SysRoot;

  SmallString<128> SysRootDir;
  if (GCCInstallation.isValid()) {
    StringRef LibDir = GCCInstallation.getParentLibPath();
    StringRef TripleStr = GCCInstallation.getTriple().str();
    llvm::sys::path::append(SysRootDir, LibDir, "..", TripleStr);
  } else {
    // Use the triple as provided to the driver. Unlike the parsed triple
    // this has not been normalized to always contain every field.
    llvm::sys::path::append(SysRootDir, getDriver().Dir, "..", getDriver().getTargetTriple());
  }

  if (!llvm::sys::fs::exists(SysRootDir))
    return std::string();

  return std::string(SysRootDir);
}
```

三级优先：用户 `--sysroot` → `<prefix>/<gcc triple>`（GCC 树里那个与 triple 同名的目录）→
`<clang 的 bin>/../<原始 --target>`。后两者要求目录真的存在，否则返回**空串**，调用方不检查，
于是 `"" + "/lib"`、`"" + "/include"` 就成了 `/lib`、`/include`。实测 C（有 GCC、无 `--sysroot`）
得到 `$G/../../../../riscv32-unknown-elf`，D 的注释解释了为什么用原始 triple 串。

注意它没有被 `RISCV::Linker` 用来生成 `--sysroot=`：那里用的是 `D.SysRoot`。

## 10. `RISCV::Linker::ConstructJob`（第 152–231 行）

整个文件的重心。签名里 `Output` 是最终产物（`a.out`），`Inputs` 是上游 Action 的产物列表
（一般是若干 `.o` 加上 `LinkerInput` 类的参数），`Args` 是这个工具链翻译过的参数表，
`C` 是本次编译的上下文，最后 `C.addCommand` 把命令交给它。

### 10.1 开头三项（第 157–174 行）

```cpp
  const ToolChain &ToolChain = getToolChain();
  const Driver &D = ToolChain.getDriver();
  ArgStringList CmdArgs;

  if (!D.SysRoot.empty())
    CmdArgs.push_back(Args.MakeArgString("--sysroot=" + D.SysRoot));

  if (Args.hasArg(options::OPT_mno_relax))
    CmdArgs.push_back("--no-relax");

  bool IsRV64 = ToolChain.getArch() == llvm::Triple::riscv64;
  CmdArgs.push_back("-m");
  if (IsRV64) {
    CmdArgs.push_back("elf64lriscv");
  } else {
    CmdArgs.push_back("elf32lriscv");
  }
  CmdArgs.push_back("-X");
```

- `--sysroot=`：只转发用户显式给的（02 篇 §2）。
- `--no-relax`：2024 年加（`be8e462a0c27`）。位置在 `-m` 之前——顺序对 `ld` 无所谓，但写测试时要知道。
- `-m`：按位宽硬编码。21 改成查 `getLDMOption` 表，效果相同。
- `-X`：丢弃临时局部符号，2022 年加（`c324c938becd`）。

### 10.2 链接器与 crt 文件（第 176–197 行）

```cpp
  std::string Linker = getToolChain().GetLinkerPath();

  bool WantCRTs = !Args.hasArg(options::OPT_nostdlib, options::OPT_nostartfiles);

  const char *crtbegin, *crtend;
  auto RuntimeLib = ToolChain.GetRuntimeLibType(Args);
  if (RuntimeLib == ToolChain::RLT_Libgcc) {
    crtbegin = "crtbegin.o";
    crtend = "crtend.o";
  } else {
    assert (RuntimeLib == ToolChain::RLT_CompilerRT);
    crtbegin = ToolChain.getCompilerRTArgString(Args, "crtbegin", ToolChain::FT_Object);
    crtend = ToolChain.getCompilerRTArgString(Args, "crtend", ToolChain::FT_Object);
  }

  if (WantCRTs) {
    CmdArgs.push_back(Args.MakeArgString(ToolChain.GetFilePath("crt0.o")));
    CmdArgs.push_back(Args.MakeArgString(ToolChain.GetFilePath(crtbegin)));
  }
```

- `GetLinkerPath()`：03 篇 §3。结果只在最后 `Command` 里用。
- `hasArg(A, B)` 是"A 或 B 任一存在"。`-nostdlib`/`-nostartfiles` 都关掉 crt 文件。
- libgcc 情形下 `crtbegin` 是裸名字，靠 `GetFilePath` 在 `FilePaths`（含 `GCCInstallPath`）里找；
  compiler-rt 情形下 `getCompilerRTArgString(..., "crtbegin", FT_Object)`（`ToolChain.cpp:794` → `getCompilerRT`，`:765`）
  直接算出 `<ResourceDir>/lib/<triple>/clang_rt.crtbegin.o` 的绝对路径（`FT_Object` 决定前缀无 `lib`、后缀 `.o`），
  再过一遍 `GetFilePath`——绝对路径 `exists` 就原样返回，不存在也原样返回（前面说的第 8 条）。
- `crt0.o` 永远是裸名字查找，命中 `<sysroot>/lib/crt0.o`。

### 10.3 输入与用户选项（第 199–205 行）

```cpp
  AddLinkerInputs(ToolChain, Inputs, Args, CmdArgs, JA);

  Args.addAllArgs(CmdArgs, {options::OPT_L, options::OPT_u});

  ToolChain.AddFilePathLibArgs(Args, CmdArgs);
  Args.addAllArgs(CmdArgs, {options::OPT_T_Group, options::OPT_s, options::OPT_t, options::OPT_r});
```

- `AddLinkerInputs`（`CommonArgs.cpp:452`）：把 `Inputs` 逐个输出——`.o` 文件名直接输出；
  `LinkerInput` 类参数（`-l`、`-e`、`-Wl,` 展开项、`-Xlinker`、`-r`……）`renderAsInput` 原样输出；
  两者按命令行相对顺序混排（02 篇 §7）。还有个细节：`TC.isCrossCompiling()` 为真时**不**读环境变量
  `LIBRARY_PATH`；RISC-V 目标在 x86 宿主上恒为交叉，所以这个 GCC 惯例在这里无效。
- `addAllArgs`：把用户写的所有 `-L`、`-u` 按原顺序输出（`-L` 是 `RenderJoined`，输出成 `-L/dir` 一个词；
  `-u` 是 `JoinedOrSeparate`，用户怎么写就怎么输出）。这个重载在 2023 年才叫 `addAllArgs`
  （`4eecfda50a4e`），15.0.7 是两次 `AddAllArgs` 单参调用。
- `AddFilePathLibArgs`（`ToolChain.cpp:1530`）：`FilePaths` 每项变成 `-L`。**用户的 `-L` 在前**，
  所以用户目录里的同名库优先于工具链的。
- 第二组 `addAllArgs`：`-T`（及 `-Ttext=` 等整组）、`-s`、`-t`、`-r`。15.0.7 这组还有 `OPT_e` 与
  `OPT_Z_Flag`：前者导致 `-e` 出现两次（它同时是 `LinkerInput`），2023 年删掉（`62281227bf7c`）；
  后者 `-Z` 是 Darwin 专有，2023 年删掉（`993e83948044`）。`-r` 到 20 仍然重复出现，同样的原因。

### 10.4 默认库（第 207–221 行）

```cpp
  // TODO: add C++ includes and libs if compiling C++.

  if (!Args.hasArg(options::OPT_nostdlib) && !Args.hasArg(options::OPT_nodefaultlibs)) {
    if (D.CCCIsCXX()) {
      if (ToolChain.ShouldLinkCXXStdlib(Args))
        ToolChain.AddCXXStdlibLibArgs(Args, CmdArgs);
      CmdArgs.push_back("-lm");
    }
    CmdArgs.push_back("--start-group");
    CmdArgs.push_back("-lc");
    CmdArgs.push_back("-lgloss");
    CmdArgs.push_back("--end-group");
    AddRunTimeLibs(ToolChain, ToolChain.getDriver(), CmdArgs, Args);
  }
```

- 那行 `TODO` 是 2018 年留下的，C++ 库其实已经处理了（`f553287b5889` 2022 年加了 `-lm`）；注释没更新。
- `CCCIsCXX()`：`clang++` 模式。`ShouldLinkCXXStdlib`（`ToolChain.cpp:1505`）再排除 `-nostdlib++`。
  `AddCXXStdlibLibArgs`（`:1511`）按 `GetCXXStdlibType` 输出 `-lstdc++` 或 `-lc++`——**不会**加
  `-lsupc++`、`-lc++abi`、`-lunwind`，这些在 21 的 BareMetal 里也一样（Linux 那边由 `Linux.cpp` 覆盖处理）。
- `--start-group -lc -lgloss --end-group`：newlib 的 libc 与 libgloss 互相引用（02 篇 §4）。
  即使是 compiler-rt 情形也照加 `-lgloss`——这是本类"假定 newlib 存在"的地方之一。
- `AddRunTimeLibs`（`CommonArgs.cpp:2365`）：libgcc → `AddLibgcc`（`:2346`）；`-static`/`-static-libgcc`
  或非 C++ 时输出 `-lgcc`，再 `AddUnwindLibrary`（`UNW_None`，什么都不加），C++ 时 `-lgcc` 放在
  unwind 库之后——对本类等价于一个 `-lgcc`。compiler-rt → `getCompilerRTArgString(Args, "builtins")`
  给出 `libclang_rt.builtins.a` 的绝对路径。`-lgcc` 在 group **之外**——如果 `libgloss.a` 里的某个成员
  引用了 `libgcc.a` 的符号（例如软除法），单向扫描仍能解决（`-lgcc` 在后面）；反过来 `libgcc.a` 引用
  libc 的情况才会出问题，21 把它挪进 group 就是为了这个。

### 10.5 收尾（第 223–230 行）

```cpp
  if (WantCRTs)
    CmdArgs.push_back(Args.MakeArgString(ToolChain.GetFilePath(crtend)));

  CmdArgs.push_back("-o");
  CmdArgs.push_back(Output.getFilename());
  C.addCommand(std::make_unique<Command>(JA, *this, ResponseFileSupport::AtFileCurCP(),
                                         Args.MakeArgString(Linker), CmdArgs, Inputs, Output));
}
```

`crtend.o` 必须在所有库之后（02 篇 §3）。`Command` 的参数：来源 Action、创建它的 Tool、
响应文件策略（`@file`，当前代码页编码）、可执行文件、参数、输入（用于 `-###` 之外的依赖追踪）、输出。

## 11. 逐词回看实验 A 的链接行

```text
"$G/../../../../bin/riscv32-unknown-elf-ld"     ← GetLinkerPath：ProgramPaths[2] 里的带前缀名字
"--sysroot=$S"                                  ← 10.1，用户给了 --sysroot
"-m" "elf32lriscv" "-X"                         ← 10.1
"$S/lib/crt0.o"                                 ← 10.2，GetFilePath 在 FilePaths[1]=$S/lib 命中
"$G/crtbegin.o"                                 ← 10.2，libgcc 名字，FilePaths[0]=$G 命中
"/tmp/hello-xxxx.o"                             ← 10.3 AddLinkerInputs
"-L$G" "-L$S/lib"                               ← 10.3 AddFilePathLibArgs（FilePaths 原顺序）
"--start-group" "-lc" "-lgloss" "--end-group"   ← 10.4
"-lgcc"                                         ← 10.4 AddRunTimeLibs（RLT_Libgcc）
"$G/crtend.o"                                   ← 10.5
"-o" "a.out"
```

## 12. `RISCV::Linker` 没有实现的东西

与 `Gnu.cpp:283` 的 `gnutools::Linker` 对照，下面这些在这里**不存在**（用户传了也不会到链接器，
多数还不报 unused）：

| 选项/功能 | Linux 链接器怎么做 | 这里 |
|---|---|---|
| `-static` / `-shared` / `-pie` / `-static-pie` | `-static`、`-shared`、`-pie`、`-dynamic-linker` | 忽略（裸机本来就是静态；`-static` 因 `NoArgumentUnused` 不警告） |
| `-flto` | `addLTOOptions` → `-plugin LLVMgold.so -plugin-opt=…`（21 的 BareMetal 有） | 忽略；bitcode `.o` 交给 lld 仍能 LTO，但 `-O` 级别、`mcpu` 传不过去 |
| `-fsanitize=` 运行库 | `addSanitizerRuntimes` | 无 |
| `-pthread`、OpenMP | `-lpthread`、`addOpenMPRuntime` | 无 |
| `-nolibc` | 跳过 `-lc` | 忽略且报 unused（21.1.8 同；21 之后加了） |
| `--unwindlib=` | 按值加 `-lgcc_s`/`-lunwind` | 恒不加，报 unused |
| `-Wl,--as-needed` 之类 | 原样透传 | 原样透传（这个有） |
| `-static-libstdc++` | `-Bstatic -lstdc++ -Bdynamic` | 忽略（21 的 BareMetal 有此逻辑） |
| `crtfastmath.o`（`-ffast-math`） | `addFastMathRuntimeIfAvailable` | 无 |
| profile 运行库（`-fprofile-*`） | `addProfileRTLibs` | 无（`BareMetal::SupportsProfiling` 也返回 false） |
| `-e`、`-T`、`-u`、`-s`、`-t`、`-r`、`-L`、`-l`、`-Wl,`、`-Xlinker`、`-mno-relax`、`--sysroot` | 有 | 有 |

这张表就是"想在 RISC-V 裸机工具链上加功能"时的备选清单：每一项在 `Gnu.cpp` 或 21 的
`BareMetal.cpp` 里都有现成实现可以照抄，07 篇讲怎么抄。
