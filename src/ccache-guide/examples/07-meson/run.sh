#!/usr/bin/env bash
# 07-meson：Meson 会自己在 PATH 里找编译器缓存并加到编译命令前面——什么时候找、什么时候不找、找到谁
source "$(dirname "$0")/../lib.sh"
for t in meson ninja; do
    command -v "$t" >/dev/null || {
        echo "SKIP 07-meson：需要 $t"
        exit 0
    }
done
meson --version
cp -r "$HERE/proj" "$WORK/proj"
cd "$WORK"

# 让 PATH 里第一个 ccache 就是本例要测的那一个
mkdir -p "$WORK/bin"
ln -s "$CCACHE" "$WORK/bin/ccache"
export PATH="$WORK/bin:$PATH"

# 构建目录 build.ninja 里 C 编译规则的命令行，去掉各程序路径的目录部分
rule() {
    awk '/^rule c_COMPILER$/ { getline; sub(/^ *command = /, ""); print; exit }' "$1/build.ninja" |
        sed -E 's|/[^ ]*/||g'
}
# expect_rule <构建目录> <期望的命令开头>
expect_rule() {
    local got
    got=$(rule "$1")
    if [[ $got != "$2"* ]]; then
        echo "✗ $1：编译命令是「$got」，期望以「$2」开头" >&2
        exit 1
    fi
    echo "✓ $1：$got"
}

say "A. 不设 CC：Meson 自动探测到 ccache，加在默认编译器 cc 前面"
unset CC
# meson setup <构建目录> <源码目录>：配置一个构建目录；meson compile -C <构建目录>：在其中构建
run meson setup build-auto proj >/dev/null
expect_rule build-auto "ccache cc "
zero
run meson compile -C build-auto >/dev/null
expect cache_miss 1

say "B. 设了 CC=gcc：Meson 原样使用，不再自动加 ccache（这也是关闭自动探测的办法）"
run env CC=gcc meson setup build-cc proj >/dev/null
expect_rule build-cc "gcc "
zero
run meson compile -C build-cc >/dev/null
expect cache_miss 0
expect direct_cache_hit 0

say "C. CC=\"ccache gcc\"：显式指定"
run env CC="ccache gcc" meson setup build-explicit proj >/dev/null
expect_rule build-explicit "ccache gcc "
zero
run meson compile -C build-explicit >/dev/null
# 没有命中 A 的结果：Meson 默认 buildtype=debug 带 -g，有 -g 时 hash_dir 把当前目录放进键（机理见 03-cross-dir）
awk '/^ *ARGS = / { print; exit }' build-explicit/build.ninja
expect cache_miss 1

say "D. native file（机器文件）里把编译器写成数组：可提交进仓库，不依赖环境变量"
cat >"$WORK/native.ini" <<'EOF'
[binaries]
c = ['ccache', 'gcc']
EOF
run meson setup build-native proj --native-file "$WORK/native.ini" >/dev/null
expect_rule build-native "ccache gcc " # 只有一层：编译器已显式给出，Meson 不再自动探测
zero
run meson compile -C build-native >/dev/null
expect cache_miss 1

say "D2. 同时有 CC 环境变量与机器文件：机器文件生效"
run env CC=gcc meson setup build-env-native proj --native-file "$WORK/native.ini" >/dev/null
expect_rule build-env-native "ccache gcc "

say "E. PATH 里同时有 sccache：Meson 选 sccache。放一个假的 sccache（只回应 --version，其余原样 exec）来观察"
cat >"$WORK/bin/sccache" <<'EOF'
#!/bin/sh
if [ "$1" = --version ]; then echo "sccache 0.0.0-fake"; exit 0; fi
exec "$@"
EOF
chmod +x "$WORK/bin/sccache"
run meson setup build-both proj >/dev/null
expect_rule build-both "sccache cc "

echo "OK 07-meson"
