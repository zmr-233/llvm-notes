#!/usr/bin/env bash
# 03 GCC multilib：硬编码的 7 个 riscv-gnu-toolchain 目录、按 -march/-mabi 选目录、以及"重用"规则。
source "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"
require_clang 20; require_clang 21
M=$work/sdk; mk_multilib_tree "$M"
G=$M/lib/gcc/riscv64-unknown-elf/8.2.0
args=(--target=riscv32-unknown-elf --gcc-toolchain="$M" --sysroot= --rtlib=platform -fuse-ld=ld "$work/hello.c")

note "-print-multi-lib：候选表（两版相同）"
ml=$("$C20" --target=riscv32-unknown-elf --gcc-toolchain="$M" -print-multi-lib); printf '%s\n' "$ml"
[ "$(printf '%s\n' "$ml" | wc -l)" = 7 ] || fail "期望 7 行"
assert_has "$ml" 'rv32im/ilp32;@march=rv32im@mabi=ilp32'
[ "$("$C21" --target=riscv32-unknown-elf --gcc-toolchain="$M" -print-multi-lib)" = "$ml" ] || fail "21 与 20 的候选表不同"

note "-print-multi-directory：给定 -march/-mabi 选中哪个目录（'.' 表示没选中、退回根目录）"
check() { local V=$1 a=$2 b=$3 want=$4 c=C$1 got
  got=$("${!c}" --target=riscv64-unknown-elf --gcc-toolchain="$M" -march="$a" -mabi="$b" -print-multi-directory)
  printf '  [%s] -march=%-16s -mabi=%-7s -> %s\n' "$V" "$a" "$b" "$got"
  [ "$got" = "$want" ] || fail "期望 $want"; }
for V in 20 21; do
  check $V rv32imac ilp32 rv32imac/ilp32      # 精确命中
  check $V rv32imc  ilp32 rv32im/ilp32        # 重用：imc 是 im 的超集，且都不含 a
  check $V rv32imafdc ilp32f rv32imafc/ilp32f # 重用：imafdc ⊃ imafc，ABI 相同
  check $V rv32imafdc ilp32d .                # 没有 ilp32d 的库：ABI 必须相同 → 退回根
  check $V rv64imafc lp64 rv64imac/lp64       # 重用
  check $V rv32imafc_zfh ilp32 rv32imac/ilp32 # 带 zfh 也能退到子集
  check $V rv32i ilp32 rv32i/ilp32
done

note "-v：Candidate multilib 列表与 Selected multilib（选中后 flags 被拆成单个扩展）"
v=$("$C20" "${args[@]}" -march=rv32imc -mabi=ilp32 -### -v 2>&1 | grep -E 'multilib'); printf '%s\n' "$v"
assert_has "$v" 'Selected multilib: rv32im/ilp32;@i@m@zmmul@m32@mabi=ilp32'

note "链接命令：crt0.o / crtbegin.o / -L 全部带上 multilib 子目录（先子目录，后根目录）"
for V in 20 21; do c=C$V
  l=$(link_line "$(env PATH= "${!c}" "${args[@]}" -march=rv32im -mabi=ilp32 -### 2>&1)"); echo "[$V]"; pretty "$l"
  assert_order "$l" "\"$G/../../../../riscv64-unknown-elf/bin/ld\"" '"-m" "elf32lriscv"' \
    "\"$G/../../../../riscv64-unknown-elf/lib/rv32im/ilp32/crt0.o\"" "\"$G/rv32im/ilp32/crtbegin.o\"" \
    "\"-L$G/rv32im/ilp32\"" "\"-L$G/../../../../riscv64-unknown-elf/lib/rv32im/ilp32\"" "\"-L$G\"" "\"-L$G/../../../../riscv64-unknown-elf/lib\"" \
    '"-lgloss"' "\"$G/rv32im/ilp32/crtend.o\""
done
note "头文件目录：20 用 <sysroot>/include；21 把 multilib 的 includeSuffix 也拼了进去（实测差异，见 06 篇）"
i20=$(cc1_line "$("$C20" "${args[@]}" -march=rv32im -mabi=ilp32 -### 2>&1)" | grep -o '"-internal-isystem" "[^"]*riscv64-unknown-elf[^"]*"')
i21=$(cc1_line "$("$C21" "${args[@]}" -march=rv32im -mabi=ilp32 -### 2>&1)" | grep -o '"-internal-isystem" "[^"]*riscv64-unknown-elf[^"]*"')
echo "[20] $i20"; echo "[21] $i21"
assert_has "$i20" '/riscv64-unknown-elf/include"'
assert_has "$i21" '/riscv64-unknown-elf/rv32im/ilp32/include"'
echo "ok"
