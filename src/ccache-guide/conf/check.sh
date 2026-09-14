#!/usr/bin/env bash
# conf/check.sh —— 让 ccache 逐个解析本目录的配置文件，确认写下的每一项都被接受
#
# 普通配置文件里拼错的键会被 ccache 静默忽略，`ccache -p` 也不报错，所以这里逐项核对：
# 文件里出现的每个键，都必须在 `ccache -p` 的输出里以「(本文件路径) 键 = 」的形式出现。
#
# 可覆盖：CCACHE=<ccache 可执行文件>
set -euo pipefail
CCACHE=${CCACHE:-ccache}
here=$(cd "$(dirname "$0")" && pwd)
tmp=$(mktemp -d "${TMPDIR:-/tmp}/ccache-conf.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
# 环境变量优先于配置文件：若留着 CCACHE_DIR 等变量，文件里的同名项会显示为来自 environment 而被误判
while IFS= read -r v; do unset "$v"; done < <(compgen -e | grep '^CCACHE_' || true)
# 给配置里引用的 CI 变量一个值，便于看清展开结果
export GITHUB_WORKSPACE=/github/workspace RUNNER_TEMP=/runner/temp

echo "ccache $("$CCACHE" --print-version)"

# check_keys <配置文件> <ccache -p 的输出> <来源标记>
check_keys() {
    local k
    for k in $(grep -E '^[a-z_]+ *=' "$1" | cut -d= -f1 | tr -d ' '); do
        if ! grep -qF "($3) $k = " <<<"$2"; then
            echo "✗ $(basename "$1")：$k 没有被接受（拼错了，或这个版本不认识）" >&2
            exit 1
        fi
    done
}

for f in "$here"/*.conf; do
    [[ $f == */project.ccache.conf ]] && continue
    echo "== $(basename "$f")"
    out=$(CCACHE_CONFIGPATH=$f "$CCACHE" -p)
    grep -F "($f)" <<<"$out" | sed "s|($f) ||"
    check_keys "$f" "$out" "$f"
done

echo "== project.ccache.conf（放进一个仓库根目录，从子目录里作为目录级配置文件读取）"
mkdir -p "$tmp/repo/.git" "$tmp/repo/sub/dir"
cp "$here/project.ccache.conf" "$tmp/repo/ccache.conf"
chmod 644 "$tmp/repo/ccache.conf"
out=$(cd "$tmp/repo/sub/dir" && "$CCACHE" -p)
grep -F "($tmp/repo/ccache.conf)" <<<"$out" | sed "s|($tmp/repo/ccache.conf) ||"
check_keys "$tmp/repo/ccache.conf" "$out" "$tmp/repo/ccache.conf"

echo "OK conf"
