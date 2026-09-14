#!/usr/bin/env bash
# 11-llvm：LLVM 自己的开关 LLVM_CCACHE_BUILD 做了什么；它与直接给 CMAKE_<LANG>_COMPILER_LAUNCHER 的区别；
# 两个同时开会怎样；两个构建目录怎样互相命中。每个构建目录 configure 一次、只编译 LLVMSupport 里的一个目标文件
#
# 需要：LLVM_SRC=<llvm-project 源码根目录>、cmake、ninja、gcc/g++。共 configure 五次，需要几分钟
source "$(dirname "$0")/../lib.sh"
if [[ -z ${LLVM_SRC:-} ]]; then
    echo "SKIP 11-llvm：设 LLVM_SRC=<llvm-project 源码根目录>"
    exit 0
fi
for t in cmake ninja; do
    command -v "$t" >/dev/null || {
        echo "SKIP 11-llvm：需要 $t"
        exit 0
    }
done
grep -E 'set\(LLVM_VERSION_(MAJOR|MINOR|PATCH)' "$LLVM_SRC/cmake/Modules/LLVMVersion.cmake"
cd "$WORK"

# LLVM_CCACHE_BUILD 靠 find_program(ccache) 找程序；让 PATH 里第一个 ccache 就是要测的那个
mkdir -p bin
ln -s "$CCACHE" bin/ccache
export PATH="$WORK/bin:$PATH"

# 公共 configure 参数：
#   -G Ninja                          生成 Ninja 构建文件
#   -DCMAKE_BUILD_TYPE=Release        不带 -g（带 -g 时的跨目录问题见 03-cross-dir）
#   -DLLVM_TARGETS_TO_BUILD=host      只要本机架构的后端，configure 快一些
#   -DCMAKE_C_COMPILER / CXX_COMPILER 用 GCC：LLVM 对「非 Clang + ccache + 预编译头」有专门处理，用 GCC 才看得到
common=(-G Ninja -DCMAKE_BUILD_TYPE=Release -DLLVM_TARGETS_TO_BUILD=host
    -DCMAKE_C_COMPILER=gcc -DCMAKE_CXX_COMPILER=g++)
obj=lib/Support/CMakeFiles/LLVMSupport.dir/StringRef.cpp.o

first_match() { awk -v p="$1" 'index($0, p) { print; exit }' "${@:2}"; }
# build_obj <构建目录>：删掉那个目标文件，让 ninja 重编它（首次还会先生成它依赖的头文件）
build_obj() {
    rm -f "$1/$obj"
    run ninja -C "$1" "$obj" >/dev/null
}

say "A. -DLLVM_CCACHE_BUILD=ON：llvm/CMakeLists.txt 把「环境变量前缀 + ccache」塞进全局属性 RULE_LAUNCH_COMPILE"
run cmake -S "$LLVM_SRC/llvm" -B build-a "${common[@]}" \
    -DLLVM_CCACHE_BUILD=ON -DLLVM_CCACHE_DIR="$CCACHE_DIR" >a.log 2>&1
grep -i 'precompiled' a.log || true
first_match 'CCACHE_' build-a/CMakeFiles/rules.ninja
zero
build_obj build-a
expect cache_miss 1
zero
build_obj build-a
expect direct_cache_hit 1

say "B. 只给 -DCMAKE_<LANG>_COMPILER_LAUNCHER=ccache（不开 LLVM_CCACHE_BUILD）"
run cmake -S "$LLVM_SRC/llvm" -B build-b "${common[@]}" \
    -DCMAKE_C_COMPILER_LAUNCHER=ccache -DCMAKE_CXX_COMPILER_LAUNCHER=ccache >b.log 2>&1
grep -i -A2 'precompiled' b.log || true
first_match 'LAUNCHER = ' build-b/build.ninja
zero
build_obj build-b
expect cache_miss 1 # 没有命中 A 存下的结果：构建目录换了（原因见 D）

say "C. 两个都开：RULE_LAUNCH_COMPILE 排在 \${LAUNCHER} 之前，命令里有两层 ccache"
run cmake -S "$LLVM_SRC/llvm" -B build-c "${common[@]}" \
    -DLLVM_CCACHE_BUILD=ON -DCMAKE_C_COMPILER_LAUNCHER=ccache -DCMAKE_CXX_COMPILER_LAUNCHER=ccache >c.log 2>&1
first_match 'CCACHE_' build-c/CMakeFiles/rules.ninja
first_match 'LAUNCHER = ' build-c/build.ninja
zero
build_obj build-c
expect cache_miss 1 # 只记了一次：两层 ccache 没有重复查缓存、重复计数

say "D. 两个构建目录要互相命中：base_dir 须同时覆盖源码目录与构建目录"
echo "编译命令里的 -I 全是绝对路径，其中有构建目录下的（放生成的头文件）："
ninja -C build-a -t commands "$obj" | tail -1 | tr ' ' '\n' | grep '^-I'
# base_dir 是路径列表（4.12+，冒号分隔）。本例的源码不在 $WORK 下，所以列两项；
# 平时把源码与各构建目录放在同一个上级目录下，设这一个上级目录即可
echo "base_dir = $LLVM_SRC:$WORK" >"$CCACHE_CONFIGPATH"
for d in build-d1 build-d2; do
    run cmake -S "$LLVM_SRC/llvm" -B "$d" "${common[@]}" -DLLVM_CCACHE_BUILD=ON >"$d.log" 2>&1
done
zero
build_obj build-d1
expect cache_miss 1
zero
build_obj build-d2
expect direct_cache_hit 1
: >"$CCACHE_CONFIGPATH"

echo "OK 11-llvm"
