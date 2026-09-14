#!/usr/bin/env bash
# 共用脚手架：被各 run.sh source。
#
# 需要的环境变量（二选一或都给；缺哪个就 SKIP 对应版本的段落）：
#   CLANG20=<路径>   任意 20.x 的 clang 可执行文件（RISCVToolchain.cpp 还在的最后一个大版本）
#   CLANG21=<路径>   任意 21.x 的 clang 可执行文件（RISCVToolchain.cpp 已并入 BareMetal.cpp）
# 可选：
#   KEEP=1           结束后保留一次性目录，便于翻看
#
# 这些例子只用 clang 的 -### / -v / -print-* 观察 driver 的决策，不真的链接，
# 所以不需要任何 RISC-V 的 GCC、newlib 或 compiler-rt：假的工具链目录树用空文件搭出来即可，
# 上游 clang/test/Driver/Inputs/ 里的假树也是这么做的。
set -euo pipefail

work=$(mktemp -d -t riscv-driver.XXXXXX)
trap 'if [ "${KEEP:-0}" = 1 ]; then echo "保留一次性目录: $work"; else rm -rf "$work"; fi' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }
note() { echo; echo "## $*"; }

# require_clang 20 → 设置全局变量 C20；找不到或版本不对就打印 SKIP 并退出 0
require_clang() {
  local v=$1 var="CLANG$1" c
  c=${!var:-}
  [ -n "$c" ] || c=$(command -v "clang-$v" 2>/dev/null || true)
  if [ -z "$c" ] && command -v clang >/dev/null 2>&1 && clang --version | grep -q "clang version $v\."; then
    c=$(command -v clang)
  fi
  if [ -z "$c" ] || [ ! -x "$c" ]; then echo "SKIP: 没有 clang $v.x（请设 $var=<路径>）"; exit 0; fi
  "$c" --version | grep -q "clang version $v\." || { echo "SKIP: $c 不是 $v.x"; exit 0; }
  printf -v "C$v" '%s' "$c"
  echo "clang $v: $c ($("$c" --version | head -1))"
}

# 断言：$1 是整段文本，其余参数是必须依次出现的子串（位置递增）
assert_order() {
  local rest=$1 s; shift
  for s in "$@"; do
    case "$rest" in
      *"$s"*) rest=${rest#*"$s"} ;;
      *) fail "顺序断言失败：找不到 [$s]（或它出现在前一项之前）" ;;
    esac
  done
}
assert_has() { case "$1" in *"$2"*) ;; *) fail "缺少 [$2]" ;; esac; }
assert_not() { case "$1" in *"$2"*) fail "不该出现 [$2]" ;; *) ;; esac; }

# -### 的输出在 stderr；每条将要执行的命令各占一行，以空格加引号开头。
# cc1_line 取第一条（编译），link_line 取最后一条（链接）。
cc1_line()  { printf '%s\n' "$1" | grep '^ "' | head -1; }
link_line() { printf '%s\n' "$1" | grep '^ "' | tail -1; }

# 把一条 -### 命令行拆成每个参数一行，便于阅读
pretty() { printf '%s\n' "$1" | sed -e 's/^ //' -e 's/" "/"\n  "/g'; }

# 假的 GCC 交叉工具链目录树，形状照抄 clang/test/Driver/Inputs/basic_riscv32_tree：
#   <root>/bin/<triple>-ld                       链接器（空文件、可执行位）
#   <root>/lib/gcc/<triple>/<ver>/crt{begin,end}.o   GCC 安装目录（"GCCInstallPath"）
#   <root>/<triple>/lib/crt0.o                   目标 sysroot 里的 C 库目录（newlib 放这里）
#   <root>/<triple>/include/c++/<ver>/           libstdc++ 头文件
mk_basic_tree() {
  local r=$1 t=$2 v=$3
  mkdir -p "$r/bin" "$r/lib/gcc/$t/$v" "$r/$t/lib" "$r/$t/include/c++/$v"
  : > "$r/bin/$t-ld"; chmod +x "$r/bin/$t-ld"
  : > "$r/lib/gcc/$t/$v/crtbegin.o"; : > "$r/lib/gcc/$t/$v/crtend.o"
  : > "$r/$t/lib/crt0.o"
}

# 带 multilib 的假树，形状照抄 clang/test/Driver/Inputs/multilib_riscv_elf_sdk
# （riscv-gnu-toolchain 默认的 7 个 multilib，triple 固定 riscv64-unknown-elf，gcc 8.2.0）
mk_multilib_tree() {
  local r=$1 t=riscv64-unknown-elf v=8.2.0 g m
  g="$r/lib/gcc/$t/$v"
  mkdir -p "$g" "$r/$t/bin" "$r/$t/lib"
  : > "$r/$t/bin/ld"; chmod +x "$r/$t/bin/ld"
  : > "$g/crtbegin.o"; : > "$g/crtend.o"; : > "$r/$t/lib/crt0.o"
  for m in rv32i/ilp32 rv32im/ilp32 rv32iac/ilp32 rv32imac/ilp32 rv32imafc/ilp32f rv64imac/lp64 rv64imafdc/lp64d; do
    mkdir -p "$g/$m" "$r/$t/lib/$m"
    : > "$g/$m/crtbegin.o"; : > "$g/$m/crtend.o"; : > "$r/$t/lib/$m/crt0.o"
  done
}

printf 'int main(void) { return 0; }\n' > "$work/hello.c"
