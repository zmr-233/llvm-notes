#!/usr/bin/env bash
# 01-basics：两种运行方式（前缀 / 伪装）；第一次 miss、第二次 hit；哪些调用 ccache 根本不缓存
source "$(dirname "$0")/../lib.sh"
mkdir -p "$WORK/src" && cd "$WORK/src"

cat >greet.h <<'EOF'
const char *greet(void);
EOF
cat >greet.c <<'EOF'
#include "greet.h"
const char *greet(void) { return "hello"; }
EOF
cat >hello.c <<'EOF'
#include <stdio.h>
#include "greet.h"
int main(void) { puts(greet()); return 0; }
EOF

say "前缀方式：编译命令前加 ccache。第一次必然 miss，真编译一遍，结果入缓存"
# gcc -c：只编译不链接；-o：输出文件名。ccache 只缓存「一个源文件 → 一个目标文件」这种调用
run "$CCACHE" gcc -c hello.c -o hello.o
expect cache_miss 1
expect direct_cache_hit 0

say "删掉产物，同一条命令再来一次：direct 模式命中，真编译器没有被调用"
rm hello.o
run "$CCACHE" gcc -c hello.c -o hello.o
expect direct_cache_hit 1

say "-s（--show-stats）是给人看的摘要；脚本请用 --print-stats"
run "$CCACHE" -s

say "伪装方式：名叫 gcc、指向 ccache 的符号链接排在 PATH 最前"
mkdir -p "$WORK/bin"
ln -s "$CCACHE" "$WORK/bin/gcc"
rm hello.o
(
    export PATH="$WORK/bin:$PATH"
    run command -v gcc # 找到的是那个符号链接
    # ccache 从 argv[0] 得知自己要扮演 gcc，再沿 PATH 找第一个「不是指向 ccache 的链接」的 gcc
    run gcc -c hello.c -o hello.o
)
# 与前缀方式命中同一条缓存：编译器名、真实编译器文件、参数全都相同
expect direct_cache_hit 2

say "disable：直接调用真编译器，连计数器都不动"
zero
rm hello.o
# env VAR=值 命令：只对这一条命令设环境变量。布尔型的 CCACHE_* 变量「设了即为真」
run env CCACHE_DISABLE=1 "$CCACHE" gcc -c hello.c -o hello.o
expect cache_miss 0
expect direct_cache_hit 0
[[ -f hello.o ]] && echo "✓ hello.o 照常生成"

say "不可缓存的调用：ccache 原样转交真编译器，只在对应计数器上记一笔"
zero
run "$CCACHE" gcc -c greet.c -o greet.o
expect cache_miss 1

run "$CCACHE" gcc hello.o greet.o -o hello # 没有 -c：这是链接
expect called_for_link 1

run "$CCACHE" gcc -c hello.c greet.c # 一次编两个源文件
expect multiple_source_files 1

run "$CCACHE" gcc -E hello.c -o hello.i # -E：只预处理
expect called_for_preprocessing 1

cat >nocache.c <<'EOF'
/* ccache:disable */
int nocache(void) { return 0; }
EOF
run "$CCACHE" gcc -c nocache.c -o nocache.o # 源文件前 4096 字节里出现 ccache:disable
expect disabled 1

printf 'int broken(void) { return }\n' >broken.c
run "$CCACHE" gcc -c broken.c -o broken.o 2>/dev/null || echo "（编译失败，符合预期；失败的结果不入缓存）"
expect compile_failed 1

say "链接出来的程序照常能跑"
run ./hello

echo "OK 01-basics"
