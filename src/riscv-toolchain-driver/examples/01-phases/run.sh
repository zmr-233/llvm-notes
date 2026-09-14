#!/usr/bin/env bash
# 01 观察 driver 的五个阶段：-ccc-print-phases（Action 树）、-ccc-print-bindings（Tool 绑定）、-###（最终命令）。
# 同一条命令在 20（RISCVToolChain）和 21（BareMetal）上只有"链接工具的名字"不同。
source "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"
require_clang 20; require_clang 21
T=$work/gcc; mk_basic_tree "$T" riscv32-unknown-elf 8.0.1
common=(--target=riscv32-unknown-elf --gcc-toolchain="$T" --sysroot="$T/riscv32-unknown-elf" -fuse-ld= "$work/hello.c")

note "阶段树（两版相同；注意它打在 stderr）"
ph=$("$C20" "${common[@]}" -ccc-print-phases 2>&1)
printf '%s\n' "$ph"
assert_has "$ph" '0: input, "'"$work"'/hello.c", c'
assert_has "$ph" '1: preprocessor, {0}, cpp-output'
assert_has "$ph" '2: compiler, {1}, ir'
assert_has "$ph" '3: backend, {2}, assembler'
assert_has "$ph" '4: assembler, {3}, object'
assert_has "$ph" '5: linker, {4}, image'
[ "$("$C21" "${common[@]}" -ccc-print-phases 2>&1)" = "$ph" ] || fail "21 的阶段树与 20 不同"

note "Tool 绑定（也在 stderr）：0-4 五个 Action 合并给一个 clang 工具，5 归链接工具"
b20=$("$C20" "${common[@]}" -ccc-print-bindings 2>&1 | grep "^# ")
b21=$("$C21" "${common[@]}" -ccc-print-bindings 2>&1 | grep "^# ")
printf '%s\n' "$b20" "$b21"
assert_has "$b20" '"riscv32-unknown-unknown-elf" - "clang", inputs: ["'"$work"'/hello.c"]'
assert_has "$b20" '"RISCV::Linker"'      # 20：RISCVToolchain.cpp 里的 tools::RISCV::Linker
assert_has "$b21" '"baremetal::Linker"'  # 21：BareMetal.cpp 里的 tools::baremetal::Linker

note "-###：真正要执行的两条命令（stderr），第一条 cc1，最后一条链接"
out=$("$C20" "${common[@]}" -### 2>&1)
n=$(printf '%s\n' "$out" | grep -c '^ "')
[ "$n" = 2 ] || fail "期望 2 条命令，得到 $n"
cc1=$(cc1_line "$out")
assert_order "$cc1" '"-cc1"' '"-triple" "riscv32-unknown-unknown-elf"' '"-nostdsysteminc"' '"-target-abi" "ilp32"' '"-isysroot"' '"-internal-isystem"'
echo "cc1 里由 RISCVToolChain 决定的部分："
printf '%s\n' "$cc1" | grep -o '"-nostdsysteminc"\|"-isysroot" "[^"]*"\|"-internal-isystem" "[^"]*"'
echo "链接命令："; pretty "$(link_line "$out")"
echo "ok"
