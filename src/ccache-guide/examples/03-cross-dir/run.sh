#!/usr/bin/env bash
# 03-cross-dir：同一份源码在两个目录里（两个人、两个 checkout、两台 CI 机器）怎样共享命中
#   base_dir：把命令行里的绝对路径改写成相对路径
#   hash_dir：带 -g 时把 CWD 放进键，防止调试信息里的编译目录串台
#   -fdebug-prefix-map：从源头消除调试信息里的绝对路径，让 hash_dir 失去必要
source "$(dirname "$0")/../lib.sh"

# 在 <根>/proj 下造一份工程。__FILE__ 故意留着：它会把「编译器看到的源文件路径」写进目标文件
mkproj() {
    mkdir -p "$1/proj/src" "$1/proj/include" "$1/proj/build"
    printf '#define ANSWER 42\n' >"$1/proj/include/x.h"
    cat >"$1/proj/src/x.c" <<'EOF'
#include "x.h"
const char *where = __FILE__;
int answer(void) { return ANSWER; }
EOF
}
mkproj "$WORK/alice"
mkproj "$WORK/bob"

# 覆写本例的配置文件并打印出来
conf() {
    printf '%s\n' "$@" >"$CCACHE_CONFIGPATH"
    echo "--- ccache.conf"
    cat "$CCACHE_CONFIGPATH"
}

# build <根> [gcc 选项…]：在 <根>/proj/build 里、用 CMake 风格的绝对路径编译
build() {
    local root=$1
    shift
    (cd "$root/proj/build" && run "$CCACHE" gcc "$@" -I"$root/proj/include" -c "$root/proj/src/x.c" -o x.o)
}
comp_dir() { readelf --debug-dump=info "$1/proj/build/x.o" | awk '/DW_AT_comp_dir/ { print $NF; exit }'; }
file_macro() { strings "$1/proj/build/x.o" | grep 'x\.c$'; }

say "不设 base_dir：两人的命令行里 -I 与源文件路径都不同 → 各自 miss"
conf ""
build "$WORK/alice"
build "$WORK/bob"
expect cache_miss 2
echo "bob 的 __FILE__ = $(file_macro "$WORK/bob")"

say "base_dir = 两人共同的上级目录：ccache 先把落在其下的绝对路径改写成相对 CWD 的路径，再算键、再调用编译器"
conf "base_dir = $WORK"
zero
build "$WORK/alice"
build "$WORK/bob"
expect cache_miss 1
expect direct_cache_hit 1
# 编译器实际拿到的是相对路径，所以 __FILE__ 也变了——这是改写的可见副作用
[[ $(file_macro "$WORK/bob") == ../src/x.c ]] && echo "✓ bob 的 __FILE__ = ../src/x.c"

say "加上 -g：hash_dir 默认为真，CWD 进键 → 即使有 base_dir，两人也各自 miss"
zero
build "$WORK/alice" -g
build "$WORK/bob" -g
expect cache_miss 2
echo "alice 的 DW_AT_comp_dir = $(comp_dir "$WORK/alice")"

say "hash_dir = false：bob 命中了——但他的目标文件里写着 alice 的编译目录"
conf "base_dir = $WORK" "hash_dir = false"
zero
build "$WORK/alice" -g
build "$WORK/bob" -g
expect cache_miss 1
expect direct_cache_hit 1
[[ $(comp_dir "$WORK/bob") == "$WORK/alice/proj/build" ]] &&
    echo "✓ bob 的 DW_AT_comp_dir = $(comp_dir "$WORK/bob")  ← 调试器会去 alice 的目录找源码"

say "正解：-fdebug-prefix-map=<工程根>=<固定名>。调试信息里不再有绝对路径，ccache 据此不再把 CWD 进键"
conf "base_dir = $WORK" # hash_dir 回到默认的 true
zero
build "$WORK/alice" -g -fdebug-prefix-map="$WORK/alice/proj=/proj"
build "$WORK/bob" -g -fdebug-prefix-map="$WORK/bob/proj=/proj"
expect cache_miss 1
expect direct_cache_hit 1
[[ $(comp_dir "$WORK/bob") == /proj/build ]] && echo "✓ bob 的 DW_AT_comp_dir = /proj/build（两人一致且都正确）"

say "base_dir 的已知副作用：-MD 写出的依赖文件里也是相对路径"
zero
build "$WORK/bob" -MD -MF x.d
cat "$WORK/bob/proj/build/x.d"
grep -q '\.\./src/x\.c' "$WORK/bob/proj/build/x.d" && echo "✓ .d 里是 ../src/x.c 而不是绝对路径"

echo "OK 03-cross-dir"
