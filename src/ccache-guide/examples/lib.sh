# examples/lib.sh —— 各例子共用的脚手架，由 run.sh 以 `source` 引入。
#
# 每个例子都在一次性目录 $WORK 里跑，用自己的缓存目录、配置文件和临时目录，
# 不读也不写你机器上真正的 ccache 缓存；退出时删除 $WORK。
#
# 可覆盖的环境变量：
#   CCACHE=<路径>  用哪个 ccache 可执行文件（默认 PATH 里的 ccache），用来在另一个版本上复核
#   KEEP=1         结束后保留 $WORK，便于翻看调试文件

set -euo pipefail

# 从外部继承来的 CCACHE_* 变量优先级高于任何配置文件，会让结果不可复现，先全部清掉。
# 注意 CCACHE（无下划线）是本脚手架自己的变量，不在此列。
while IFS= read -r v; do unset "$v"; done < <(compgen -e | grep '^CCACHE_' || true)

CCACHE=$(realpath "${CCACHE:-$(command -v ccache)}") # 伪装方式要对它建符号链接，需要绝对路径
HERE=$(cd "$(dirname "${BASH_SOURCE[1]}")" && pwd)  # 调用者（run.sh）所在目录
WORK=$(mktemp -d "${TMPDIR:-/tmp}/ccache-ex.XXXXXX")
if [[ ${KEEP:-} == 1 ]]; then
    echo "WORK=$WORK（KEEP=1：结束后保留）"
else
    trap 'rm -rf "$WORK"' EXIT
fi

export CCACHE_DIR=$WORK/cache              # 本例私有的缓存目录
export CCACHE_CONFIGPATH=$WORK/ccache.conf # 设了它就只读这一份配置文件：系统级、缓存级、目录级都被屏蔽
export CCACHE_TEMPDIR=$WORK/tmp            # 默认在 $XDG_RUNTIME_DIR 下与真缓存共用，这里也隔开（storage helper 的 IPC 端点不跟随它，见 08）
: >"$CCACHE_CONFIGPATH"

echo "ccache: $CCACHE ($("$CCACHE" --print-version))"

# 小节标题
say() { printf '\n== %s\n' "$*"; }

# 回显命令再执行，读输出时能对上是哪条命令
run() {
    printf '$ %s\n' "$*"
    "$@"
}

# 读一个统计计数器。--print-stats 输出「计数器名<TAB>值」，名字是稳定的机器接口，
# 不像 -s 的人类可读文本会随版本调整措辞。
counter() { "$CCACHE" --print-stats | awk -F'\t' -v k="$1" '$1 == k { print $2 }'; }

# expect <计数器> <期望值>：不符立即失败。例子里的每个结论都靠它兑现，而不是靠肉眼读 -s。
expect() {
    local got
    got=$(counter "$1")
    if [[ $got != "$2" ]]; then
        echo "✗ $1 = $got，期望 $2" >&2
        exit 1
    fi
    echo "✓ $1 = $got"
}

# 计数器清零（不影响缓存内容），让下一段只统计自己
zero() { "$CCACHE" -z >/dev/null; }
