#!/usr/bin/env bash
# examples/run-all.sh —— 依次运行全部例子与 conf/check.sh；任一失败即停
#
# 可选环境变量：
#   CCACHE=<ccache 可执行文件>             在另一个 ccache 版本上复核
#   HTTP_HELPER=<ccache-storage-http 路径>  运行 08 里 storage helper 那一段
#   LLVM_SRC=<llvm-project 源码根目录>      运行 11（configure 三次 LLVM，要几分钟）
# 缺 cmake / ninja / meson / autotools 的例子会打印 SKIP 并跳过。
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)

# one <名字> <脚本>：运行一个脚本，成功只打印最后一行 OK/SKIP，失败打印输出末尾并退出
one() {
    local log
    log=$(mktemp "${TMPDIR:-/tmp}/ccache-run.XXXXXX")
    if bash "$2" >"$log" 2>&1; then
        echo "✓ $1  $(grep -E '^(OK|SKIP)' "$log" | tail -1)"
        rm -f "$log"
    else
        echo "✗ $1（完整输出：$log）"
        tail -20 "$log"
        exit 1
    fi
}

for d in "$here"/[0-9][0-9]-*/; do
    one "$(basename "$d")" "$d/run.sh"
done
one conf "$here/../conf/check.sh"
