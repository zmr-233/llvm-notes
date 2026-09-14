#!/usr/bin/env bash
# 09-hidden-inputs：编译器读了 ccache 看不见的输入 → 假命中，拿到过期的目标文件
#   extra_files_to_hash：把那个输入显式放进键
#   prefix_command：distcc 一类「不改变输出」的包装器应当挂在这里
source "$(dirname "$0")/../lib.sh"
mkdir -p "$WORK/tc" "$WORK/src" && cd "$WORK/src"

cat >"$WORK/tc/mycc" <<'EOF'
#!/bin/sh
# 编译器包装脚本：每次调用都从自己旁边的 flags.txt 读额外参数
exec gcc $(cat "$(dirname "$0")/flags.txt") "$@"
EOF
chmod +x "$WORK/tc/mycc"
echo "-DLEVEL=1" >"$WORK/tc/flags.txt"

cat >level.c <<'EOF'
#include <stdio.h>
int main(void) { printf("LEVEL=%d\n", LEVEL); return 0; }
EOF

build() {
    run "$CCACHE" "$WORK/tc/mycc" -c level.c -o level.o
    gcc level.o -o level
}
# check_level <N> [说明]：程序输出必须是 LEVEL=<N>
check_level() {
    local got
    got=$(./level)
    if [[ $got != "LEVEL=$1" ]]; then
        echo "✗ 程序输出 $got，期望 LEVEL=$1" >&2
        exit 1
    fi
    echo "✓ 程序输出 $got ${2:-}"
}

say "flags.txt = -DLEVEL=1，第一次编译"
build
expect cache_miss 1
check_level 1

say "flags.txt 改成 -DLEVEL=2：源码、命令行、包装脚本文件本身都没变 → direct 命中"
echo "-DLEVEL=2" >"$WORK/tc/flags.txt"
zero
build
expect direct_cache_hit 1
check_level 1 "← 假命中：flags.txt 早已是 LEVEL=2"

say "修复：extra_files_to_hash 把 flags.txt 的内容放进键"
echo "extra_files_to_hash = $WORK/tc/flags.txt" >"$CCACHE_CONFIGPATH"
zero
build
expect cache_miss 1
check_level 2

say "此后再改 flags.txt 都会如实 miss"
echo "-DLEVEL=3" >"$WORK/tc/flags.txt"
zero
build
expect cache_miss 1
check_level 3

say "prefix_command：让 ccache 去调用包装器，而不是把包装器写在 ccache 与编译器之间"
cat >"$WORK/tc/logwrap" <<'EOF'
#!/bin/sh
# distcc 式包装器：不改变编译结果，只记下自己被调用（真实场景里它把编译发往别的机器）
echo "$*" >>"$(dirname "$0")/wrap.log"
exec "$@"
EOF
chmod +x "$WORK/tc/logwrap"
echo "prefix_command = $WORK/tc/logwrap" >"$CCACHE_CONFIGPATH"
: >"$WORK/tc/wrap.log"
zero
run "$CCACHE" gcc -DLEVEL=9 -c level.c -o level.o
run "$CCACHE" gcc -DLEVEL=9 -c level.c -o level.o
expect cache_miss 1
expect direct_cache_hit 1
echo "wrap.log："
cat "$WORK/tc/wrap.log"
[[ $(wc -l <"$WORK/tc/wrap.log") == 1 ]] &&
    echo "✓ 包装器只在 miss 时被调用一次，且只包编译、不包预处理（要包预处理另设 prefix_command_cpp）"

say "对照：把包装器写在 ccache 与编译器之间。ccache 把 logwrap 当成了编译器（按它的 mtime 算键），与上面的条目不共享"
: >"$CCACHE_CONFIGPATH"
zero
run "$CCACHE" "$WORK/tc/logwrap" gcc -DLEVEL=9 -c level.c -o level.o
expect cache_miss 1

echo "OK 09-hidden-inputs"
