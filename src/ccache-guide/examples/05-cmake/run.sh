#!/usr/bin/env bash
# 05-cmake：CMake 接入 ccache 的几种写法，以及它们能不能传进 ExternalProject 子工程
#   A. 缓存变量  -DCMAKE_<LANG>_COMPILER_LAUNCHER=ccache
#   B. 环境变量  CMAKE_<LANG>_COMPILER_LAUNCHER=ccache（CMake ≥ 3.17）
#   C. 全局属性  RULE_LAUNCH_COMPILE（LLVM_CCACHE_BUILD 的做法）
#   D. launcher 写成 CMake 列表：env;KEY=VALUE;ccache
#   E. CMakePresets.json 里的 cacheVariables
#   F. base_dir 与 Ninja 的依赖跟踪
source "$(dirname "$0")/../lib.sh"
for t in cmake ninja; do
    command -v "$t" >/dev/null || {
        echo "SKIP 05-cmake：需要 $t"
        exit 0
    }
done
cp -r "$HERE/proj" "$WORK/proj"
cd "$WORK"
cmake --version | head -1

# expect_ccache <构建目录> yes|no：该目录的 Ninja 构建文件里有没有出现 ccache
expect_ccache() {
    local has=no
    grep -qF -- "$CCACHE" "$1/build.ninja" "$1/CMakeFiles/rules.ninja" && has=yes
    if [[ $has != "$2" ]]; then
        echo "✗ $1 的构建文件里含 ccache：$has，期望 $2" >&2
        exit 1
    fi
    echo "✓ $1 的构建文件里含 ccache：$has"
}

# 打印第一处匹配（找不到不算错）
first_match() { awk -v p="$1" 'index($0, p) { print; exit }' "${@:2}"; }

# 打印非零的计数器（去掉时间戳与容量类）；全为零时打印「（无）」
nonzero() {
    "$CCACHE" --print-stats | awk -F'\t' '$2 != 0 && $1 !~ /timestamp|size|files_in_cache/ { print; n++ } END { if (!n) print "（无）" }'
}

say "A. 缓存变量 CMAKE_<LANG>_COMPILER_LAUNCHER：CMake 把它放在每条编译命令的最前面"
zero
# -S 源码目录；-B 构建目录；-G Ninja 生成 Ninja 构建文件；
# CMAKE_EXPORT_COMPILE_COMMANDS=ON 额外生成 compile_commands.json
run cmake -S proj -B build-a -G Ninja \
    -DCMAKE_C_COMPILER_LAUNCHER="$CCACHE" -DCMAKE_CXX_COMPILER_LAUNCHER="$CCACHE" \
    -DCMAKE_EXPORT_COMPILE_COMMANDS=ON >/dev/null
echo "configure 期间 ccache 的非零计数器（CMake 探测编译器的 try_compile 是否经过 launcher）："
nonzero
echo "build.ninja 里的样子："
first_match 'LAUNCHER = ' build-a/build.ninja
zero
run cmake --build build-a >/dev/null
expect cache_miss 2 # lib.c 与 main.cpp
expect_ccache build-a yes
expect_ccache build-a/child-build no # 子工程是另一次 configure，不继承父工程的缓存变量

say "compile_commands.json 里的命令（clangd 等工具读它）"
python3 -c 'import json, sys; [print(e["command"]) for e in json.load(open(sys.argv[1]))]' build-a/compile_commands.json

say "清掉产物重编：父工程的两个编译全部 direct 命中"
run cmake --build build-a --target clean >/dev/null
zero
run cmake --build build-a >/dev/null
expect direct_cache_hit 2
expect cache_miss 0

say "B1. 环境变量只在首次 configure 时读取，随即写进 CMakeCache.txt"
run env CMAKE_C_COMPILER_LAUNCHER="$CCACHE" CMAKE_CXX_COMPILER_LAUNCHER="$CCACHE" \
    cmake -S proj -B build-b1 -G Ninja >/dev/null
grep '^CMAKE_C_COMPILER_LAUNCHER' build-b1/CMakeCache.txt
run cmake --build build-b1 >/dev/null # build 时环境里已经没有这两个变量
expect_ccache build-b1 yes
expect_ccache build-b1/child-build no # 子工程的 configure 发生在这次 build 里，那时读不到环境变量

say "B2. 环境变量在 configure 与 build 全程都导出：子工程 configure 时也读到了"
(
    export CMAKE_C_COMPILER_LAUNCHER="$CCACHE" CMAKE_CXX_COMPILER_LAUNCHER="$CCACHE"
    run cmake -S proj -B build-b2 -G Ninja >/dev/null
    zero
    run cmake --build build-b2 >/dev/null
)
expect_ccache build-b2/child-build yes
echo "build-b2 的非零计数器："
nonzero

say "C. RULE_LAUNCH_COMPILE：值是原样拼到命令前面的文本，所以能带 KEY=VALUE 环境变量前缀"
run cmake -S proj -B build-c -G Ninja -DDEMO_RULE_LAUNCH=ON \
    "-DDEMO_RULE_LAUNCH_VALUE=CCACHE_STATSLOG=$WORK/rule.stats $CCACHE" >/dev/null
first_match 'CCACHE_STATSLOG=' build-c/build.ninja build-c/CMakeFiles/rules.ninja
run cmake --build build-c >/dev/null
[[ -s $WORK/rule.stats ]] && echo "✓ rule.stats 已生成：前缀里的环境变量传到了 ccache（Ninja 在 Unix 上经 /bin/sh -c 执行命令）"
expect_ccache build-c/child-build no

say "D. 不依赖 shell 的带参写法：launcher 是 CMake 列表（分号分隔），env;KEY=VALUE;ccache"
run cmake -S proj -B build-d -G Ninja \
    "-DCMAKE_C_COMPILER_LAUNCHER=env;CCACHE_STATSLOG=$WORK/list.stats;$CCACHE" \
    "-DCMAKE_CXX_COMPILER_LAUNCHER=env;CCACHE_STATSLOG=$WORK/list.stats;$CCACHE" >/dev/null
first_match 'CCACHE_STATSLOG=' build-d/build.ninja build-d/CMakeFiles/rules.ninja
run cmake --build build-d >/dev/null
[[ -s $WORK/list.stats ]] && echo "✓ list.stats 已生成"

say "E. CMakePresets.json：launcher 写进预设文件随仓库提交，本质仍是 A 的缓存变量"
cat >proj/CMakePresets.json <<EOF
{
  "version": 3,
  "configurePresets": [
    {
      "name": "ccache",
      "generator": "Ninja",
      "binaryDir": "\${sourceDir}/../build-e",
      "cacheVariables": {
        "CMAKE_C_COMPILER_LAUNCHER": "$CCACHE",
        "CMAKE_CXX_COMPILER_LAUNCHER": "$CCACHE"
      }
    }
  ]
}
EOF
# cmake --preset <名字>：按预设 configure，要在含 CMakePresets.json 的源码目录下执行
(cd proj && run cmake --preset ccache >/dev/null)
expect_ccache build-e yes
zero
run cmake --build build-e >/dev/null
expect direct_cache_hit 2 # 与 build-a 的编译命令完全相同（不带 -g，路径都是同样的绝对路径）

say "F. base_dir 与 Ninja 依赖跟踪：ccache 把路径改成相对的之后，改头文件仍然触发重编"
echo "base_dir = $WORK" >"$CCACHE_CONFIGPATH"
run cmake -S proj -B build-f -G Ninja \
    -DCMAKE_C_COMPILER_LAUNCHER="$CCACHE" -DCMAKE_CXX_COMPILER_LAUNCHER="$CCACHE" >/dev/null
run cmake --build build-f >/dev/null
# ninja -t deps <目标>：打印 Ninja 从依赖文件里记下的该目标的依赖
run ninja -C build-f -t deps CMakeFiles/demo.dir/src/lib.c.o
printf '/* touched */\n' >>proj/src/lib.h
zero
run cmake --build build-f >/dev/null
expect direct_cache_miss 2      # lib.c 与 main.cpp 都包含 lib.h，都被 Ninja 重新调度了
expect preprocessed_cache_hit 2 # 只加了注释，预处理输出不变
: >"$CCACHE_CONFIGPATH"

say "程序照常能跑"
run build-a/app

echo "OK 05-cmake"
