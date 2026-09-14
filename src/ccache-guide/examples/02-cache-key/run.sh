#!/usr/bin/env bash
# 02-cache-key：缓存键里有什么。direct / preprocessor / depend 三种模式各自对什么敏感；
# __TIME__ 与 sloppiness；compiler_check 的几种取值
source "$(dirname "$0")/../lib.sh"
mkdir -p "$WORK/src" && cd "$WORK/src"

cat >calc.h <<'EOF'
#define SCALE 3
EOF
cat >calc.c <<'EOF'
#include "calc.h"
int scale(int x) { return x * SCALE; }
EOF

# build [KEY=VALUE…] -- [gcc 选项…]：KEY=VALUE 写在 ccache 与编译器之间，是优先级最高的配置来源
build() {
    local conf=()
    while [[ $1 != -- ]]; do
        conf+=("$1")
        shift
    done
    shift
    run "$CCACHE" "${conf[@]}" gcc "$@" -c calc.c -o calc.o
}

say "基线：第一次 miss，第二次 direct 命中"
build -- -O2
build -- -O2
expect cache_miss 1
expect direct_cache_hit 1

say "只改注释：源文件字节变了 → direct 键变了；预处理输出里注释已被删掉、没变 → preprocessed 命中"
zero
sed -i '2s|$| /* only a comment */|' calc.c # 附在第 2 行行尾：行号不变，gcc -E 的输出逐字节相同
build -- -O2
expect direct_cache_miss 1
expect preprocessed_cache_hit 1

say "同一条命令再来：上一步命中后，新的 direct 键已记进 manifest，这回走 direct"
zero
build -- -O2
expect direct_cache_hit 1

say "多一个没用到的 -D：命令行变了 → direct miss；-D/-I 不直接进 preprocessor 键（它们的效果已体现在输出里）→ preprocessed 命中"
zero
build -- -O2 -DUNUSED=1
expect direct_cache_miss 1
expect preprocessed_cache_hit 1

say "-O2 改 -O0：影响代码生成的选项在两种键里都有 → 彻底 miss"
zero
build -- -O0
expect cache_miss 1

say "改头文件：direct 模式按 manifest 记下的头文件哈希逐个比对，对不上；预处理输出也变了 → miss"
zero
sed -i 's/SCALE 3/SCALE 4/' calc.h
build -- -O2
expect cache_miss 1

say "只 touch 头文件、内容不变：manifest 里记的是头文件内容的哈希而不是 mtime → 仍然 direct 命中"
zero
run touch calc.h
build -- -O2
expect direct_cache_hit 1

say "direct_mode=false：只剩 preprocessor 模式。每次都要跑一遍 gcc -E，命中也只会记在 preprocessed 上"
zero
build direct_mode=false -- -O2
expect preprocessed_cache_hit 1
expect direct_cache_hit 0

say "depend 模式（要求 -MD/-MMD）：从不跑预处理器，头文件清单取自编译器自己写的 .d 文件"
zero
build depend_mode=true -- -O2 -MD
build depend_mode=true -- -O2 -MD
expect cache_miss 1
expect direct_cache_hit 1
say "代价：没有 preprocessor 模式兜底。再改一次注释就是 miss，而上面默认模式下它能 preprocessed 命中"
zero
sed -i '2s|$| /* another comment */|' calc.c
build depend_mode=true -- -O2 -MD
expect cache_miss 1
expect preprocessed_cache_hit 0

cat >stamp.c <<'EOF'
const char *built_at = __TIME__;
EOF

say "__TIME__：源码里出现它，direct 模式直接放弃；预处理输出每秒不同 → 每次 miss"
zero
run "$CCACHE" gcc -c stamp.c -o stamp.o
sleep 1.1
run "$CCACHE" gcc -c stamp.c -o stamp.o
expect cache_miss 2

say "sloppiness=time_macros：声明「__TIME__ 的值无所谓」。代价是目标文件里的时间取自入缓存那一刻"
# -C（--clear）清空缓存、保留配置。上一段刚存进的结果若与这一秒的 __TIME__ 同值，会被 preprocessed 命中而干扰计数
run "$CCACHE" -C
zero
run "$CCACHE" sloppiness=time_macros gcc -c stamp.c -o stamp.o
first=$(strings stamp.o | grep -E '^[0-9]{2}:[0-9]{2}:[0-9]{2}$')
sleep 1.1
run "$CCACHE" sloppiness=time_macros gcc -c stamp.c -o stamp.o
again=$(strings stamp.o | grep -E '^[0-9]{2}:[0-9]{2}:[0-9]{2}$')
expect cache_miss 1
expect direct_cache_hit 1
[[ $first == "$again" ]] && echo "✓ 两次的 __TIME__ 都是 $first"

# 下面要 touch 编译器文件，不能动系统的 gcc，于是复制一份驱动程序。
# gcc 驱动按自身所在位置找 cc1，挪了位置就找不到；-B<目录> 把 cc1 所在目录加进它的程序搜索路径。
mkdir -p "$WORK/tc"
cp "$(command -v gcc)" "$WORK/tc/gcc"
TC=("$WORK/tc/gcc" -B"$(dirname "$(gcc -print-prog-name=cc1)")/")

say "compiler_check=mtime（默认）：编译器文件的 mtime 与大小进键。touch 编译器 → miss"
zero
run "$CCACHE" "${TC[@]}" -O2 -c calc.c -o calc.o
run touch "$WORK/tc/gcc"
run "$CCACHE" "${TC[@]}" -O2 -c calc.c -o calc.o
expect cache_miss 2

say "compiler_check=content：哈希编译器文件的字节。touch 不再让键失效"
zero
run "$CCACHE" compiler_check=content "${TC[@]}" -O2 -c calc.c -o calc.o
run touch "$WORK/tc/gcc"
run "$CCACHE" compiler_check=content "${TC[@]}" -O2 -c calc.c -o calc.o
expect cache_miss 1
expect direct_cache_hit 1

say "compiler_check=<命令>：哈希命令的输出。%compiler% 替换为编译器路径；值里有空格，整个 KEY=VALUE 作一个参数"
zero
run "$CCACHE" "compiler_check=%compiler% -dumpfullversion -dumpmachine" "${TC[@]}" -O2 -c calc.c -o calc.o
run touch "$WORK/tc/gcc"
run "$CCACHE" "compiler_check=%compiler% -dumpfullversion -dumpmachine" "${TC[@]}" -O2 -c calc.c -o calc.o
expect cache_miss 1
expect direct_cache_hit 1

echo "OK 02-cache-key"
