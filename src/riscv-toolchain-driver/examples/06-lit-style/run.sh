#!/usr/bin/env bash
# 06 上游怎么测 driver：clang/test/Driver/*.c 里的 RUN 行 + FileCheck。
# 这里把 test.c 里的 RUN 行原样跑一遍；如果给了 FILECHECK=<FileCheck 可执行文件>（任何 LLVM 构建树的 bin/ 里都有），
# 就真用 FileCheck 检查 CHECK 行；否则用 lib.sh 的断言复核同样的事实。
source "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"
require_clang 21
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
T=$work/Inputs/basic_riscv32_tree; mk_basic_tree "$T" riscv32-unknown-elf 8.0.1
cp "$here/test.c" "$work/test.c"
# lit 的替换：%clang → 被测 clang，%s → 本文件，%S → 本文件所在目录
run1="$C21 -### $work/test.c -fuse-ld= --target=riscv32-unknown-elf --rtlib=platform --gcc-toolchain=$work/Inputs/basic_riscv32_tree --sysroot=$work/Inputs/basic_riscv32_tree/riscv32-unknown-elf"
echo "RUN: $run1"
out=$($run1 2>&1)
if [ -n "${FILECHECK:-}" ]; then
  printf '%s\n' "$out" | "$FILECHECK" -check-prefix=C-RV32-BAREMETAL-ILP32 "$work/test.c" && echo "FileCheck: ok"
else
  echo "(没有 FILECHECK，用 shell 断言复核 CHECK 行)"
  l=$(link_line "$out")
  assert_order "$l" 'Inputs/basic_riscv32_tree/lib/gcc/riscv32-unknown-elf/8.0.1/../../../../bin/riscv32-unknown-elf-ld"' \
    '"--sysroot=' '/Inputs/basic_riscv32_tree/riscv32-unknown-elf"' '"-X"' \
    '/Inputs/basic_riscv32_tree/riscv32-unknown-elf/lib/crt0.o"' \
    '/Inputs/basic_riscv32_tree/lib/gcc/riscv32-unknown-elf/8.0.1/crtbegin.o"' \
    '"-L' '/Inputs/basic_riscv32_tree/lib/gcc/riscv32-unknown-elf/8.0.1"' \
    '"-L' '/Inputs/basic_riscv32_tree/riscv32-unknown-elf/lib"' \
    '"--start-group" "-lgcc" "-lc" "-lgloss" "--end-group"' \
    '/Inputs/basic_riscv32_tree/lib/gcc/riscv32-unknown-elf/8.0.1/crtend.o"'
fi
echo "ok"
