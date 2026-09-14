#!/usr/bin/env bash
# 02 有 GCC 交叉工具链时的链接命令：20（RISCVToolChain）与 21（BareMetal 合并后）逐项对照。
source "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"
require_clang 20; require_clang 21
T=$work/gcc; mk_basic_tree "$T" riscv32-unknown-elf 8.0.1
G=$T/lib/gcc/riscv32-unknown-elf/8.0.1          # GCCInstallation.getInstallPath()
S=$T/riscv32-unknown-elf                        # sysroot（<ParentLibPath>/../<gcc triple>）
args=(--target=riscv32-unknown-elf --gcc-toolchain="$T" --rtlib=platform -fuse-ld= "$work/hello.c")

note "-v 里能看到探测过程（两版相同）"
v=$("$C20" "${args[@]}" --sysroot="$S" -### -v 2>&1 | grep -E 'candidate|Selected')
printf '%s\n' "$v"
assert_has "$v" "Found candidate GCC installation: $G"
assert_has "$v" "Selected GCC installation: $G"

note "20：显式 --sysroot"
l20=$(link_line "$("$C20" "${args[@]}" --sysroot="$S" -### 2>&1)"); pretty "$l20"
assert_order "$l20" \
  "\"$G/../../../../bin/riscv32-unknown-elf-ld\"" \
  "\"--sysroot=$S\"" '"-m" "elf32lriscv"' '"-X"' \
  "\"$S/lib/crt0.o\"" "\"$G/crtbegin.o\"" \
  '.o"' \
  "\"-L$G\"" "\"-L$S/lib\"" \
  '"--start-group" "-lc" "-lgloss" "--end-group" "-lgcc"' \
  "\"$G/crtend.o\"" '"-o" "a.out"'
assert_not "$l20" '"-Bstatic"'

note "21：同一命令。多了 -Bstatic；-lgcc 挪进了 --start-group；.o 挪到了 -L 之后；多了 resource-dir 下的 -L"
l21=$(link_line "$("$C21" "${args[@]}" --sysroot="$S" -### 2>&1)"); pretty "$l21"
assert_order "$l21" \
  "\"$G/../../../../bin/riscv32-unknown-elf-ld\"" \
  "\"--sysroot=$S\"" '"-Bstatic"' '"-m" "elf32lriscv"' '"-X"' \
  "\"$S/lib/crt0.o\"" "\"$G/crtbegin.o\"" \
  "\"-L$G\"" "\"-L$S/lib\"" '"-L' 'riscv32-unknown-unknown-elf"' \
  '.o"' \
  '"--start-group" "-lgcc" "-lc" "-lgloss" "--end-group"' \
  "\"$G/crtend.o\"" '"-o" "a.out"'

note "不给 --sysroot：sysroot 从 GCC 安装目录推出来（<ParentLibPath>/../<triple>），路径里带 ../../../.."
l=$(link_line "$("$C20" "${args[@]}" --sysroot= -### 2>&1)")
assert_has "$l" "\"$G/../../../../riscv32-unknown-elf/lib/crt0.o\""
assert_not "$l" '"--sysroot='
l=$(link_line "$("$C21" "${args[@]}" --sysroot= -### 2>&1)")
assert_has "$l" "\"$G/../../../../riscv32-unknown-elf/lib/crt0.o\""

note "C++：-lstdc++ -lm 出现在 C 库之前；头文件多了 include/c++/8.0.1 三个目录"
for V in 20 21; do c=C$V
  out=$("${!c}" --driver-mode=g++ "${args[@]}" --sysroot="$S" -### 2>&1)
  assert_order "$(link_line "$out")" '"-lstdc++" "-lm" "--start-group"'
  assert_order "$(cc1_line "$out")" "\"$S/include/c++/8.0.1\"" "\"$S/include/c++/8.0.1/riscv32-unknown-elf\"" "\"$S/include/c++/8.0.1/backward\""
done

note "两个候选版本：选大的；--gcc-install-dir 可以指定小的（21 有效；20 的分派只看 --gcc-toolchain，见 04）"
T2=$work/twover; mk_basic_tree "$T2" riscv32-unknown-elf 8.0.1; mkdir -p "$T2/lib/gcc/riscv32-unknown-elf/9.2.0"; : > "$T2/lib/gcc/riscv32-unknown-elf/9.2.0/crtbegin.o"
v=$("$C21" --target=riscv32-unknown-elf --gcc-toolchain="$T2" -fuse-ld= -### "$work/hello.c" -v 2>&1 | grep -E 'candidate|Selected'); printf '%s\n' "$v"
assert_has "$v" "Selected GCC installation: $T2/lib/gcc/riscv32-unknown-elf/9.2.0"
v=$("$C21" --target=riscv32-unknown-elf --gcc-install-dir="$T2/lib/gcc/riscv32-unknown-elf/8.0.1" -fuse-ld= -### "$work/hello.c" -v 2>&1 | grep -E 'Selected'); printf '%s\n' "$v"
assert_has "$v" "Selected GCC installation: $T2/lib/gcc/riscv32-unknown-elf/8.0.1"
echo "ok"
