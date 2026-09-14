# 04 找 GCC、选 multilib：`GCCInstallationDetector` 与 RISC-V 的硬编码表

> 核对版本：llvmorg-21.1.8 的 `clang/lib/Driver/ToolChains/Gnu.cpp`（这部分代码 15 → 21 几乎没变，
> 变的是 20 → 21 多了 `--gcc-install-dir` 的分支）。实测：[`02-gcc-tree`](examples/02-gcc-tree/run.sh)、
> [`03-multilib`](examples/03-multilib/run.sh)。

`RISCVToolChain` 构造函数的第一行 `GCCInstallation.init(Triple, Args)` 是整个文件里最"重"的
一句：它决定了后面所有路径。这一篇把它拆开。

## 1. 一套 GCC 交叉工具链长什么样

以 riscv-gnu-toolchain 装出来的目录为例（这也是上游测试假树 `Inputs/basic_riscv32_tree` 的形状）：

```text
<prefix>/
├── bin/
│   ├── riscv32-unknown-elf-gcc
│   ├── riscv32-unknown-elf-ld          ← 链接器，名字带 triple 前缀
│   └── ...
├── lib/gcc/riscv32-unknown-elf/8.0.1/  ← "GCC 安装目录"：crtbegin.o crtend.o libgcc.a
│   └── (multilib 子目录，如 rv32im/ilp32/)
└── riscv32-unknown-elf/                ← 目标 sysroot：与 triple 同名
    ├── bin/ld                          ← 同一个链接器的另一份，不带前缀
    ├── include/                        ← newlib 头文件；c++/8.0.1/ 是 libstdc++ 头文件
    └── lib/                            ← crt0.o libc.a libm.a libgloss.a libstdc++.a
        └── (multilib 子目录)
```

clang 的探测器要从这棵树里认出三个东西，都存在 `GCCInstallationDetector` 的成员里（`Gnu.h:193`）：

| 成员 | 值（本例） | 用途 |
|---|---|---|
| `GCCInstallPath` | `<prefix>/lib/gcc/riscv32-unknown-elf/8.0.1` | 找 `crtbegin.o`、`libgcc.a`；multilib 子目录以它为根 |
| `GCCParentLibPath` | `<prefix>/lib/gcc/riscv32-unknown-elf/8.0.1/../../..` = `<prefix>/lib` | 往上一层就是 `<prefix>`：`<ParentLibPath>/../bin` 找 `ld`，`<ParentLibPath>/../<triple>` 就是 sysroot |
| `GCCTriple` | `riscv32-unknown-elf` | 目录名里那个 triple，可能与 `--target` 不同（rv32 可以用 `riscv64-unknown-elf` 的 multilib 工具链） |
| `Version` | `8.0.1` | 拼 `include/c++/8.0.1` |

路径里那串 `../../../..` 就是这么来的：driver 从不 `realpath`，全部靠拼接。

## 2. `init` 的流程（`Gnu.cpp:2095`）

```text
1. 候选 triple 列表 CandidateTripleAliases：
     --target 原样（riscv32-unknown-unknown-elf）；去掉 vendor 的（riscv32-unknown-elf）；
     再加架构表里的：riscv32-unknown-linux-gnu、riscv32-unknown-elf（Gnu.cpp:2435–2440, 2714）
   候选 lib 目录 CandidateLibDirs：/lib32、/lib（rv32）；/lib64、/lib（rv64）
   还有 biarch 变体：rv32 目标顺带把 rv64 的 triple 与目录也列进去（反之亦然）

2. 如果给了 --gcc-install-dir=<dir>：不扫描，直接把 <dir> 当 GCCInstallPath，
   从路径倒推 Version 与 Triple，返回。（Gnu.cpp:2127）

3. 如果给了 --gcc-triple=<t>：候选 triple 只剩这一个。

4. 前缀列表 Prefixes：
     给了 --gcc-toolchain=<p>            → 只有 <p>（Gnu.cpp:2071 getGCCToolchainDir）
     否则                                  → --sysroot（若有）及其下的发行版目录、
                                             <Dir>/..（clang 自己的安装前缀）、
                                             /usr 等默认目录（AddDefaultGCCPrefixes, :2256）

5. 三重循环：for 前缀 × for lib 目录 × for 候选 triple →
     ScanLibDirForGCCTriple(<prefix><libdir>, triple)（Gnu.cpp:2791）：
       在 <libdir>/gcc/<triple>/ 与 <libdir>/gcc-cross/<triple>/ 下枚举子目录，
       每个子目录名当版本号解析（GCCVersion::Parse，:1997），
       < 4.1.1 的跳过，比当前已选的小或相等的跳过，
       ScanGCCForMultilibs 成功的就选中，记下 InstallPath / ParentLibPath / Triple / Version。
   任一前缀下找到了就不再看后面的前缀（"Skip other prefixes once a GCC installation is found"）。
```

几个实测能观察到的结论：

- **版本大者胜**：假树里同时放 `8.0.1` 与 `9.2.0`，`-v` 显示两条 `Found candidate`、一条
  `Selected GCC installation: .../9.2.0`。想用小的只能 `--gcc-install-dir=` 精确指定
  （21 上生效；20 上 `--gcc-install-dir` 根本不会让 RISC-V 进入 `RISCVToolChain`，见 06 篇）。
- **`--gcc-toolchain` 指向的是 `<prefix>`**，不是 `lib/gcc/...`；选项说明（`Options.td:734`）写得很清楚：
  "a directory where Clang can find 'include' and 'lib{,32,64}/gcc{,-cross}/$triple/$version'"。
- 候选 triple 里有 `riscv32-unknown-linux-gnu`：所以一个只有 Linux GCC 的前缀也会被裸机目标选中
  （上游测试 `riscv32-toolchain.c` 的 `RESOURCE-INC` 段就是这样，`-internal-isystem` 指到了
  `riscv32-unknown-linux-gnu/include`）。目录顺序按 `RISCV32Triples` 数组：linux-gnu 在 elf 之前，
  但"版本大者胜"优先于顺序。
- `GCC_INSTALL_PREFIX`（CMake 配置项）已弃用，21 的 CMake 直接报错拒绝（`clang/CMakeLists.txt:219`）；
  代替品是 `--gcc-install-dir` 或配置文件。

`-v` 输出的四类行（`GCCInstallationDetector::print`，`Gnu.cpp:2234`）：

```text
Found candidate GCC installation: <每个被枚举到的版本目录>
Selected GCC installation: <选中的>
Candidate multilib: <每个 multilib 变体>        ← 仅当有 multilib
Selected multilib: <选中的变体>                  ← 仅当选中了非默认的
```

## 3. multilib 是什么

一套交叉工具链要服务多种 ISA/ABI 组合（rv32i、rv32imac、rv32imafc+ilp32f……），每种组合的
`libc.a`、`libgcc.a`、`crt0.o` 都得单独编一份。GCC 的做法是把它们放在**以选项命名的子目录**里，
`lib/gcc/<triple>/<ver>/rv32im/ilp32/crtbegin.o`、`<triple>/lib/rv32im/ilp32/libc.a`，然后由
driver 根据 `-march`/`-mabi` 选一个子目录。这套机制叫 multilib，上游文档 `clang/docs/Multilib.rst`
讲了通用部分；对 GCC 安装目录里的 multilib，clang 走的是"硬编码"那条路。

clang 里的表示（`Multilib.h:35`）：

```cpp
class Multilib {
  std::string GCCSuffix;      // 加在 GCCInstallPath 后面的子目录，如 "/rv32im/ilp32"
  std::string OSSuffix;       // 加在 sysroot 后面的（RISC-V 裸机不用）
  std::string IncludeSuffix;  // 加在 include 目录后面的
  flags_list Flags;           // 选中它需要哪些 flag，如 {"-march=rv32im", "-mabi=ilp32"}
  ...
};
class MultilibSet { std::vector<Multilib> Multilibs; ...; bool select(D, Flags, Selected); };
```

`select`（`Multilib.cpp:216`）的规则：给一组"当前命令行的 flag"，一个变体的 `Flags` 是它的
子集就算匹配。`addMultilibFlag(Enabled, "-march=rv32im", Flags)`（`CommonArgs.cpp:2429`）把
条件为真的写成 `-march=rv32im`、为假的写成 `!march=rv32im`，"`!`"前缀表示"必须不匹配"，
这样 `rv32im` 的库不会被 `-march=rv32imac` 选中。

## 4. RISC-V 裸机的硬编码表（`Gnu.cpp:1722`）

`ScanGCCForMultilibs`（`Gnu.cpp:2754`）按架构分派，RISC-V 进 `findRISCVMultilibs`（`:1778`），
OS 为 unknown 时再进 `findRISCVBareMetalMultilibs`（`:1722`）：

```cpp
constexpr RiscvMultilib RISCVMultilibSet[] = {
    {"rv32i", "ilp32"},     {"rv32im", "ilp32"},     {"rv32iac", "ilp32"},
    {"rv32imac", "ilp32"},  {"rv32imafc", "ilp32f"}, {"rv64imac", "lp64"},
    {"rv64imafdc", "lp64d"}};
```

七个变体，就是 riscv-gnu-toolchain 默认 `--enable-multilib` 时装出来的七个目录，路径规则
`${march}/${mabi}`。之后：

1. `FilterOut(NonExistent)`：`<GCCInstallPath>/<变体>/crtbegin.o` 不存在的变体剔除——所以假树里
   每个 multilib 子目录必须放 `crtbegin.o`，否则 `-print-multi-lib` 看不到它；
2. `setFilePathsCallback`：选中变体后要追加到 `FilePaths` 的目录，三条：
   `<GCCInstallPath>/<suffix>`、`<GCCInstallPath>/../../../../riscv64-unknown-elf/lib/<suffix>`、
   同样的 `riscv32-unknown-elf` 版本。这是 `RISCVToolchain.cpp` 第 25–32 行 `addMultilibsFilePaths`
   消费的东西（`addPathIfExists` 只加真实存在的）。注意这里**写死了两个 triple 名**，
   工具链的 sysroot 目录如果叫别的名字，multilib 的 `crt0.o` 就找不到；
3. 用当前 `-march`（`riscv::getRISCVArch`）与 `-mabi`（`getRISCVABI`）算出 flag 列表，
   `selectRISCVMultilib` 选。

`-print-multi-lib` 打印候选表（实测，两版一致）：

```text
rv32i/ilp32;@march=rv32i@mabi=ilp32
rv32im/ilp32;@march=rv32im@mabi=ilp32
...
rv64imafdc/lp64d;@march=rv64imafdc@mabi=lp64d
```

格式照抄 GCC：`目录;@flag@flag`。`-print-multi-directory` 打印当前选项选中的目录，没选中打印 `.`。

## 5. 选不到精确匹配时的"重用"：`selectRISCVMultilib`（`Gnu.cpp:1616`）

用户写 `-march=rv32imc`，表里没有 `rv32imc`。GCC 有 `MULTILIB_REUSE` 让 `rv32imc` 复用 `rv32im`
的库（多一个 C 扩展只影响指令编码，不影响 ABI 与库的内容），clang 在这个函数里实现了等价物：

1. 先试精确匹配；
2. 失败则把每个变体的 `-march=` 拆成单个扩展 flag（`-i -m -zmmul ...`），把用户的 `-march` 也拆开，
   再加 `-m32`/`-m64`；对每个变体，要求它的扩展集合是用户的**子集**；
3. 硬约束：ABI 必须完全相同；变体没有 `a`（原子）扩展时用户也不能有——软件原子与硬件原子
   混用会出错，所以 `rv32imac` **不会**复用 `rv32im`（实测：`-march=rv32imac -mabi=ilp32` 选中
   `rv32imac/ilp32`，`rv32imc` 选中 `rv32im/ilp32`）；
4. 多个变体满足时按表里的顺序选最后一个匹配的（`select` 的语义），也就是扩展最多的那个。

实测的选择结果（20 与 21 相同）：

| `-march` | `-mabi` | 选中 |
|---|---|---|
| rv32imac | ilp32 | rv32imac/ilp32（精确） |
| rv32imc | ilp32 | rv32im/ilp32（重用） |
| rv32imafdc | ilp32f | rv32imafc/ilp32f（重用） |
| rv32imafdc | ilp32d | `.`（没有 ilp32d 的库，ABI 不同不能重用） |
| rv64imafc | lp64 | rv64imac/lp64 |
| rv32imafc_zfh | ilp32 | rv32imac/ilp32 |

`-v` 里 `Selected multilib: rv32im/ilp32;@i@m@zmmul@m32@mabi=ilp32` 就是拆成扩展之后的内部表示。

选中后 `RISCVToolChain` 构造函数把结果搬进基类的 `Multilibs` / `SelectedMultilibs`
（`RISCVToolchain.cpp` 第 55–56 行），链接行上 `crt0.o`、`crtbegin.o`、`-L` 全都带上子目录，
而且**子目录在前、根目录在后**（`-L$G/rv32im/ilp32` 先于 `-L$G`），保证同名库优先取变体的。

## 6. 默认 `-march` / `-mabi` 从哪来（`Arch/RISCV.cpp`）

multilib 选择和 cc1 的 `-target-feature` 都依赖这两个值，逻辑在 `clang/lib/Driver/ToolChains/Arch/RISCV.cpp`：

`getRISCVArch`（`:246`），按顺序：显式 `-march=`；`-mcpu=` 对应的默认 ISA；由 `-mabi=` 推
（`ilp32*` → `rv32imafdc`，`ilp32e` → `rv32e`）；最后按 triple——**裸机（OS unknown）是 `rv32imac`/`rv64imac`**，
其他 OS 是 `rv32imafdc`/`rv64imafdc`。

`getRISCVABI`（`:185`）：显式 `-mabi=`；否则由 `-march` 算（`RISCVISAInfo::computeDefaultABI`：
有 `d` → `ilp32d`，有 `e` → `ilp32e`，否则 `ilp32`）；再否则按 triple（裸机 `ilp32`/`lp64`）。

所以不带任何 `-m` 选项的 `--target=riscv32-unknown-elf` 是 `rv32imac` + `ilp32`，multilib 表里
恰好有这一项——这就是 03 例子"默认选中 rv32imac/ilp32"的来源。注释里说明这与 GCC 的默认
（`config.gcc` 里由 `--with-arch` 决定）刻意不同，是 clang 自己定的裸机默认值。

## 7. Linux 目标的另一张表

`findRISCVMultilibs` 对非裸机 triple 用另一组硬编码（`Gnu.cpp:1786`）：`lib32/ilp32`、`lib32/ilp32f`、
`lib32/ilp32d`、`lib64/lp64`、`lib64/lp64f`、`lib64/lp64d`，flag 是 `-m32`/`-m64` 加 `-mabi=`。
这是 riscv-gnu-toolchain 的 Linux 布局。`RISCVToolchain.cpp` 用不到它，但 `-print-multi-lib` 对
`riscv32-unknown-linux-gnu` 打印的是这张表，别混淆。

## 8. `multilib.yaml`：BareMetal 才有的第二条路

`BareMetal`（20 与 21）在**没有** GCC 安装时会去 `<Dir>/../lib/clang-runtimes/multilib.yaml` 找
配置文件（`BareMetal.cpp:304–349`），有则完全按文件选目录，这是上游文档 `Multilib.rst` 讲的
"EXPERIMENTAL multilib via configuration file"，flag 由 `ToolChain::getMultilibFlags`
（`ToolChain.cpp:339`；RISC-V 部分 `:326`，产生规范化的 `-march=rv32i2p1_m2p0_...`）生成，
`-print-multi-flags-experimental` 能看到这些 flag。`RISCVToolChain` 没有这条路；21 里的 RISC-V
只有在没找到 GCC、也没有相邻 `crt0.o` 时才会走到它（`BareMetal.cpp:343`）。
