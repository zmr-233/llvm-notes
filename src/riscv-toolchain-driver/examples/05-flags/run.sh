#!/usr/bin/env bash
# 05 常用链接相关选项在 RISC-V 裸机链接命令里的效果（有 GCC 树，20 与 21 对照）。
source "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"
require_clang 20; require_clang 21
T=$work/gcc; mk_basic_tree "$T" riscv32-unknown-elf 8.0.1
G=$T/lib/gcc/riscv32-unknown-elf/8.0.1; S=$T/riscv32-unknown-elf
base=(--target=riscv32-unknown-elf --gcc-toolchain="$T" --sysroot="$S" --rtlib=platform -fuse-ld= "$work/hello.c")
ln() { local c=C$1; shift; link_line "$("${!c}" "${base[@]}" "$@" -### 2>&1)"; }

for V in 20 21; do
  note "[$V] -nostdlib：不要 crt*，也不要默认库（只剩 -L 与用户输入）"
  l=$(ln $V -nostdlib); pretty "$l"; assert_not "$l" 'crt0.o'; assert_not "$l" '"-lc"'; assert_not "$l" 'crtend.o'
  note "[$V] -nostartfiles：不要 crt*，保留默认库"
  l=$(ln $V -nostartfiles); assert_not "$l" 'crt0.o'; assert_has "$l" '"-lgloss"'
  note "[$V] -nodefaultlibs：保留 crt*，不要默认库"
  l=$(ln $V -nodefaultlibs); assert_has "$l" 'crt0.o'; assert_has "$l" 'crtend.o'; assert_not "$l" '"-lc"'
  note "[$V] -mno-relax → --no-relax（位置不同：20 在 -m 之前，21 在 -X 之后）"
  l=$(ln $V -mno-relax); assert_has "$l" '"--no-relax"'
  note "[$V] --rtlib=compiler-rt：crt{begin,end} 换成 clang_rt.crt{begin,end}.o，-lgcc 换成 libclang_rt.builtins.a 的绝对路径"
  l=$(ln $V --rtlib=compiler-rt --unwindlib=compiler-rt); pretty "$l"
  assert_has "$l" 'riscv32-unknown-unknown-elf/clang_rt.crtbegin.o"'; assert_has "$l" 'libclang_rt.builtins.a"'; assert_not "$l" '"-lgcc"'
  note "[$V] -static / -nolibc：都不改变链接命令（-nolibc 还会报 unused）"
  out=$("$(eval echo \$C$V)" "${base[@]}" -static -nolibc -### 2>&1)
  assert_has "$out" "argument unused during compilation: '-nolibc'"
  assert_has "$(link_line "$out")" '"-lc"'
  note "[$V] -T / -u / -Wl, / -Xlinker / -e / -s / -L / -l 的落点"
  l=$(ln $V -T link.ld -u foo -Wl,--defsym=X=1 -Xlinker --gc-sections -e _entry -s -L/opt/mylib -lmylib); pretty "$l"
  assert_order "$l" '"--defsym=X=1" "--gc-sections" "-e" "_entry" "-lmylib"'   # 这些是"链接器输入"，按命令行相对顺序、与 .o 混排
  assert_has "$l" '"-u" "foo"'; assert_has "$l" '"-T" "link.ld"'; assert_has "$l" '"-s"'; assert_has "$l" '"-L/opt/mylib"'
done
assert_order "$(ln 20 -mno-relax)" '"--no-relax"' '"-m" "elf32lriscv"'
assert_order "$(ln 21 -mno-relax)" '"-m" "elf32lriscv" "-X" "--no-relax"'
# 20：-T/-s/-t/-r 在 -L 之后、默认库之前；21：-T 紧跟在 -L 之前的一组里
assert_order "$(ln 20 -T link.ld -L/opt/mylib)" '"-L/opt/mylib"' '"-T" "link.ld"' '"--start-group"'
assert_order "$(ln 21 -T link.ld -L/opt/mylib)" '"-T" "link.ld"' '"-L/opt/mylib"' '"--start-group"'

note "-flto：20 的 RISCV::Linker 不传任何 LTO 选项；21 的 BareMetal 传 -plugin-opt=…（bfd 还加 -plugin LLVMgold.so）"
l=$(ln 20 -flto -O2); assert_not "$l" 'plugin'
l=$(ln 21 -flto -O2); assert_has "$l" '"-plugin-opt=mcpu=generic-rv32"'; assert_has "$l" '"-plugin-opt=O2"'; assert_has "$l" 'LLVMgold.so"'

note "-fuse-ld=lld：在 -B/程序路径/PATH 里找 ld.lld"
d=$(dirname "$C21"); l=$(link_line "$("$C21" "${base[@]}" -fuse-ld=lld -B"$d" -### 2>&1)"); assert_has "$l" "\"$d/ld.lld\""

note "-print-* 系列：不跑编译，直接问 driver 它会怎么找"
for V in 20 21; do c=C$V
  echo "[$V] search-dirs:"; "${!c}" --target=riscv32-unknown-elf --gcc-toolchain="$T" --sysroot="$S" -print-search-dirs
  p=$("${!c}" --target=riscv32-unknown-elf --gcc-toolchain="$T" --sysroot="$S" -print-file-name=crt0.o); [ "$p" = "$S/lib/crt0.o" ] || fail "print-file-name crt0.o: $p"
  p=$("${!c}" --target=riscv32-unknown-elf --gcc-toolchain="$T" --sysroot="$S" -print-file-name=libc.a); [ "$p" = "libc.a" ] || fail "找不到时应原样返回: $p"
  p=$("${!c}" --target=riscv32-unknown-elf --gcc-toolchain="$T" -print-prog-name=ld); [ "$p" = "$G/../../../../bin/riscv32-unknown-elf-ld" ] || fail "print-prog-name ld: $p"
  p=$("${!c}" --target=riscv32-unknown-elf --gcc-toolchain="$T" -print-libgcc-file-name); [ "$p" = "libgcc.a" ] || fail "libgcc: $p"
  p=$("${!c}" --target=riscv32-unknown-elf --gcc-toolchain="$T" --rtlib=compiler-rt -print-libgcc-file-name); assert_has "$p" 'riscv32-unknown-unknown-elf/libclang_rt.builtins.a'
  p=$("${!c}" --target=riscv32-unknown-elf -print-target-triple); [ "$p" = riscv32-unknown-unknown-elf ] || fail "triple: $p"
done
echo "ok"
