#!/usr/bin/env bash
# 06-make-autotools：没有 launcher 概念的构建系统，靠「把 CC 换成 ccache gcc」接入
#   Make：命令行覆盖 CC
#   Autotools：./configure CC="ccache gcc"，值被写进生成的 Makefile，之后的 make 不必再给
source "$(dirname "$0")/../lib.sh"
cp -r "$HERE/make" "$HERE/autotools" "$WORK/"

nonzero() { "$CCACHE" --print-stats | awk -F'\t' '$2 != 0 && $1 !~ /timestamp|size|files_in_cache/'; }

say "Make：CC 是一个会被 shell 按空格拆开的字符串，所以 \"ccache gcc\" 能直接用"
zero
# -C <目录>：先进入该目录再执行；-j4：最多 4 个任务并行（ccache 天然支持并发调用）
run make -C "$WORK/make" -j4 CC="$CCACHE gcc" >/dev/null
expect cache_miss 2      # a.c、b.c
expect called_for_link 1 # 链接那一步也经过了 ccache，被原样转交
run make -C "$WORK/make" clean >/dev/null
zero
run make -C "$WORK/make" -j4 CC="$CCACHE gcc" >/dev/null
expect direct_cache_hit 2

say "Autotools：先生成 configure（autoreconf -i：运行 autoconf/automake 等，并补齐缺失的辅助脚本）"
(cd "$WORK/autotools" && run autoreconf -i >/dev/null 2>&1)

say "out-of-tree configure，CC 作为参数传给 configure"
mkdir -p "$WORK/autotools/build"
cd "$WORK/autotools/build"
zero
run ../configure CC="$CCACHE gcc" >/dev/null
echo "configure 期间的非零计数器（configure 的探测程序也经过了 ccache）："
nonzero
grep '^CC = ' Makefile # configure 把 CC 写进了生成的 Makefile

say "之后的 make 不必再给 CC"
zero
run make >/dev/null
expect cache_miss 1
run make clean >/dev/null
zero
run make >/dev/null
expect direct_cache_hit 1
run ./hello

say "另开一个构建目录重新 configure + make：hello.c 反而 miss"
mkdir -p "$WORK/autotools/build2"
cd "$WORK/autotools/build2"
run ../configure CC="$CCACHE gcc" >/dev/null
zero
run make >/dev/null
expect cache_miss 1
grep '^CFLAGS = ' Makefile
echo "原因：用户不给 CFLAGS 时 autoconf 默认 -g -O2；有 -g 时 hash_dir 把当前目录放进键（机理见 03-cross-dir），build 与 build2 的键不同"

say "修复：CFLAGS 加 -fdebug-prefix-map=<构建目录>=.，调试信息不再含绝对路径，ccache 随之不再把目录放进键"
for d in build3 build4; do
    mkdir -p "$WORK/autotools/$d"
    cd "$WORK/autotools/$d"
    run ../configure CC="$CCACHE gcc" CFLAGS="-g -O2 -fdebug-prefix-map=$PWD=." >/dev/null
    zero
    run make >/dev/null
done
expect direct_cache_hit 1 # build4 命中了 build3 的结果

echo "OK 06-make-autotools"
