#!/usr/bin/env bash
# 04 没有 GCC 安装目录时的三种情况：
#   (a) clang 旁边有 <triple>/lib/crt0.o（"GCC 相邻"）→ 20 走 RISCVToolChain（compiler-rt 变体），21 走 BareMetal 的相邻分支
#   (b) 什么都没有 → 20/21 都是 BareMetal，sysroot 退到 lib/clang-runtimes/<triple>
#   (c) 20 的分派只认 --gcc-toolchain 与相邻 crt0.o；--gcc-install-dir 在 20 上被当作未使用参数
source "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"
require_clang 20; require_clang 21
t=riscv32-unknown-elf
for V in 20 21; do c=C$V
  P=$work/adj$V; mkdir -p "$P/bin" "$P/$t/lib"; ln -s "${!c}" "$P/bin/clang"
  : > "$P/bin/$t-ld"; chmod +x "$P/bin/$t-ld"; : > "$P/$t/lib/crt0.o"
  B=$work/bare$V; mkdir -p "$B/bin"; ln -s "${!c}" "$B/bin/clang"; : > "$B/bin/$t-ld"; chmod +x "$B/bin/$t-ld"
done
common=(-no-canonical-prefixes --target=$t --rtlib=platform -fuse-ld=ld "$work/hello.c")

note "(a) 相邻 crt0.o：20 = RISCVToolChain 无 GCC 分支（clang_rt.crtbegin.o + libclang_rt.builtins.a），21 = BareMetal 相邻分支"
for V in 20 21; do P=$work/adj$V
  out=$("$P/bin/clang" "${common[@]}" -### 2>&1); l=$(link_line "$out"); echo "[$V]"; pretty "$l"
  assert_has "$(cc1_line "$out")" "\"-internal-isystem\" \"$P/bin/../$t/include\""
  assert_has "$l" "\"$P/bin/$t-ld\""
  assert_has "$l" "\"$P/bin/../$t/lib/crt0.o\""
  assert_has "$l" "/riscv32-unknown-unknown-elf/clang_rt.crtbegin.o\""
  assert_has "$l" "\"-L$P/bin/../$t/lib\""
  assert_has "$l" '"-lgloss"'
  assert_has "$l" "/riscv32-unknown-unknown-elf/clang_rt.crtend.o\""
done
assert_order "$(link_line "$("$work/adj20/bin/clang" "${common[@]}" -### 2>&1)")" '"--start-group" "-lc" "-lgloss" "--end-group"' 'libclang_rt.builtins.a"'
assert_order "$(link_line "$("$work/adj21/bin/clang" "${common[@]}" -### 2>&1)")" '"--start-group"' 'libclang_rt.builtins.a"' '"-lc" "-lgloss" "--end-group"'

note "(b) 什么都没有：BareMetal，sysroot = bin/../lib/clang-runtimes/$t；crt0.o 找不到就原样写裸名字"
for V in 20 21; do B=$work/bare$V
  out=$("$B/bin/clang" "${common[@]}" -### 2>&1); l=$(link_line "$out"); echo "[$V]"; pretty "$l"
  assert_has "$(cc1_line "$out")" "\"$B/bin/../lib/clang-runtimes/$t/include\""
  assert_has "$l" '"-Bstatic"'
  assert_has "$l" '"crt0.o"'
  assert_has "$l" "\"-L$B/bin/../lib/clang-runtimes/$t/lib\""
  assert_has "$l" 'libclang_rt.builtins.a"'
  assert_not "$l" '"-lgloss"'
done
# 20 的 BareMetal 链接器默认是 ld.lld，且不传 -m；21 统一成了 GetLinkerPath()+"-m"
assert_has "$(link_line "$("$work/bare20/bin/clang" "${common[@]}" -### 2>&1)")" '"ld.lld"'
assert_not "$(link_line "$("$work/bare20/bin/clang" "${common[@]}" -### 2>&1)")" '"-m" "elf32lriscv"'
assert_has "$(link_line "$("$work/bare21/bin/clang" "${common[@]}" -### 2>&1)")" "\"$work/bare21/bin/$t-ld\" \"-Bstatic\" \"-m\" \"elf32lriscv\""

note "(c) 20 上 --gcc-install-dir 不触发 RISCVToolChain；21 上可以"
T=$work/gcc; mk_basic_tree "$T" $t 8.0.1
o20=$("$C20" --target=$t --gcc-install-dir="$T/lib/gcc/$t/8.0.1" -fuse-ld= -### "$work/hello.c" 2>&1)
assert_has "$o20" "warning: argument unused during compilation: '--gcc-install-dir="
assert_not "$(link_line "$o20")" '"-lgloss"'
o21=$("$C21" --target=$t --gcc-install-dir="$T/lib/gcc/$t/8.0.1" -fuse-ld= -### "$work/hello.c" 2>&1)
assert_not "$o21" 'argument unused'
assert_has "$(link_line "$o21")" "\"$T/lib/gcc/$t/8.0.1/crtbegin.o\""
echo "ok"
