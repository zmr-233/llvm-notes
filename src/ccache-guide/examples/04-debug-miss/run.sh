#!/usr/bin/env bash
# 04-debug-miss：「什么都没改，为什么 miss」的排查流程
#   1. stats_log：只统计这一次构建，不受同一缓存上其他构建干扰
#   2. debug 模式：每个目标文件旁（或 debug_dir 下）写出 ccache-input-text，即参与哈希的全部输入
#   3. diff 两次构建的 input-text，差异就是 miss 的原因
source "$(dirname "$0")/../lib.sh"
mkdir -p "$WORK/src" && cd "$WORK/src"

cat >m.c <<'EOF'
#include <stdio.h>
int main(void) { puts("same code"); return 0; }
EOF

cat >"$CCACHE_CONFIGPATH" <<EOF
# 本次构建的统计另记一份，事后用 --show-log-stats 查看
stats_log = $WORK/build.stats
# debug 模式：写出参与哈希的输入与每个目标文件的日志
debug = true
# 调试文件不放在目标文件旁边，而是按绝对路径镜像到这个目录下
debug_dir = $WORK/dbg
EOF
run cat "$CCACHE_CONFIGPATH"

say "两个人用同一份源码、同一条命令编译，唯一差别是各自终端的 LANG"
run env LANG=C "$CCACHE" gcc -c m.c -o m.o
rm m.o
run env LANG=zh_CN.UTF-8 "$CCACHE" gcc -c m.c -o m.o
expect cache_miss 2

say "--show-log-stats：只看 stats_log 里记下的这两次"
run "$CCACHE" --show-log-stats

say "debug_dir 下每次编译一组文件；文件名带时间戳，不会互相覆盖"
find "$WORK/dbg" -type f | sed "s|^$WORK/dbg||" | sort

say "diff 两次的 ccache-input-text：差异一目了然"
mapfile -t inputs < <(find "$WORK/dbg" -name '*.ccache-input-text' | sort)
diff "${inputs[0]}" "${inputs[1]}" | tee "$WORK/diff.txt" || true
grep -q 'zh_CN' "$WORK/diff.txt" && echo "✓ 差异在 LANG：ccache 把 LANG / LC_ALL / LC_CTYPE / LC_MESSAGES 放进键，因为它们会改变诊断信息的语言"

say "每个目标文件的 ccache-log 记着它走了哪条路（Result: 行是结论）"
mapfile -t logs < <(find "$WORK/dbg" -name '*.ccache-log' | sort)
grep 'Result: ' "${logs[1]}"

say "修复：sloppiness = locale（接受「缓存里的警告文本可能是另一种语言」）"
echo "sloppiness = locale" >>"$CCACHE_CONFIGPATH"
zero
rm m.o
run env LANG=C "$CCACHE" gcc -c m.c -o m.o
rm m.o
run env LANG=zh_CN.UTF-8 "$CCACHE" gcc -c m.c -o m.o
expect cache_miss 1
expect direct_cache_hit 1

say "--inspect：直接读缓存条目。条目按键的前两个十六进制位分两级子目录存放，类型写在文件头里"
manifest=
while IFS= read -r f; do
    type=$("$CCACHE" --inspect "$f" | awk -F': ' '/^Entry type/ { print $2 }')
    echo "${f#"$CCACHE_DIR"/}  →  $type"
    [[ $type == *manifest* ]] && manifest=$f
done < <(find "$CCACHE_DIR" -type f ! -name stats ! -name CACHEDIR.TAG | sort)
echo "--- 一个 manifest 的内容：记着哪些头文件、各自的哈希，以及对应的结果键"
"$CCACHE" --inspect "$manifest" | sed -n '1,30p'

say "recache：怀疑缓存里有坏结果时，强制重编并覆盖（不读缓存，但写缓存）"
zero
rm m.o
run env CCACHE_RECACHE=1 LANG=C "$CCACHE" gcc -c m.c -o m.o
expect recache 1

echo "OK 04-debug-miss"
