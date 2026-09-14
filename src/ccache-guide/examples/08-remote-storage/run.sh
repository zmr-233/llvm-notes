#!/usr/bin/env bash
# 08-remote-storage：本地缓存之外再挂一层远端存储，让多台机器、多个 CI 作业共享结果
#   file 后端（共享目录）与 http 后端（内置实现 / storage helper）
#   read-only、remote_only、reshare、shards、@layout=local（4.14+）、--trim-dir
#
# 可选：HTTP_HELPER=<ccache-storage-http 可执行文件>  运行 storage helper 那一段
source "$(dirname "$0")/../lib.sh"

# 各「机器」共用一份源码目录；不带 -g，所以 CWD 不进键
mkdir -p "$WORK/src"
for i in 1 2 3 4 5 6 7 8; do
    printf 'int f%d(void) { return %d; }\n' "$i" "$i" >"$WORK/src/f$i.c"
done

conf() {
    printf '%s\n' "$@" >"$CCACHE_CONFIGPATH"
    echo "--- ccache.conf"
    cat "$CCACHE_CONFIGPATH"
}
# 切换到另一台「机器」：换一个本地缓存目录（统计计数器也跟着换），并清零
machine() {
    export CCACHE_DIR=$WORK/$1
    echo "--- 机器 $1"
    zero
}
compile() { (cd "$WORK/src" && run "$CCACHE" gcc -c "$1.c" -o "$1.o"); }
# 目录下的缓存条目文件数（不算统计文件与 CACHEDIR.TAG）
entries() { find "$1" -type f ! -name stats ! -name CACHEDIR.TAG 2>/dev/null | wc -l; }
nonzero() {
    "$CCACHE" --print-stats | awk -F'\t' '$2 != 0 && $1 !~ /timestamp|size|files_in_cache/ { print; n++ } END { if (!n) print "（无）" }'
}
# version_ge X：当前 ccache 版本 ≥ X
version_ge() { [[ $(printf '%s\n' "$1" "$("$CCACHE" --print-version)" | sort -V | head -1) == "$1" ]]; }

say "A. file 后端：两台机器各有本地缓存，共享同一个远端目录"
conf "remote_storage = file:$WORK/shared"
machine m1
compile f1
expect cache_miss 1
echo "远端条目数：$(entries "$WORK/shared")"
machine m2
compile f1
nonzero
expect direct_cache_hit 1
expect remote_storage_hit 1
echo "m2 本地条目数：$(entries "$WORK/m2")（远端命中后回填了本地）"
zero
compile f1
expect local_storage_hit 1
expect remote_storage_hit 0

say "B. read-only：只读不写。典型用法：开发机读 CI 填好的远端，但不把本机结果写回去"
conf "remote_storage = file:$WORK/shared read-only"
machine m3
before=$(entries "$WORK/shared")
compile f2
expect cache_miss 1
after=$(entries "$WORK/shared")
[[ $before == "$after" ]] && echo "✓ 远端条目数前后都是 $after：miss 的结果只进了本地"
compile f1
expect remote_storage_hit 1

say "C. remote_only：完全不用本地缓存（统计计数器仍记在本地目录）"
conf "remote_storage = file:$WORK/shared" "remote_only = true"
machine m4
compile f3
compile f3
expect cache_miss 1
expect remote_storage_hit 1
[[ $(entries "$WORK/m4") == 0 ]] && echo "✓ m4 本地条目数为 0"

say "D. reshare：本地命中时也写远端（默认不写）。可用来给一个新的空远端灌数据"
conf "remote_storage = file:$WORK/shared2" "reshare = true"
machine m1 # m1 本地已有 f1
compile f1
expect local_storage_hit 1
((($(entries "$WORK/shared2")) > 0)) && echo "✓ shared2 现有 $(entries "$WORK/shared2") 个条目"

say "启动演示用 HTTP 服务（http_server.py），对象落在 \$WORK/http 下"
python3 "$HERE/http_server.py" "$WORK/http" "$WORK/port" 2>"$WORK/http.log" &
server=$!
trap 'kill $server 2>/dev/null; "$CCACHE" --stop-storage-helpers >/dev/null 2>&1 || true; [[ ${KEEP:-} == 1 ]] || rm -rf "$WORK"' EXIT
for _ in $(seq 50); do
    [[ -s $WORK/port ]] && break
    sleep 0.1
done
port=$(<"$WORK/port")
echo "port=$port"

say "E. http 后端。log_file 记下 ccache 实际走的是内置实现还是 storage helper"
conf "remote_storage = http://127.0.0.1:$port/cache" "log_file = $WORK/ccache-http.log"
machine m5
compile f4
expect cache_miss 1
machine m6
compile f4
expect remote_storage_hit 1
echo "服务端看到的最后几个请求："
tail -4 "$WORK/http.log"
echo "ccache 日志里与 storage/helper 相关的行："
grep -iE 'helper|storage' "$WORK/ccache-http.log" | head -5 || true

say "F. shards：URL 里的 * 被替换成分片名，条目按 rendezvous 哈希分散到各分片"
conf "remote_storage = http://127.0.0.1:$port/shard-* shards=a,b"
machine m7
for i in 1 2 3 4 5 6 7 8; do (cd "$WORK/src" && "$CCACHE" gcc -c "f$i.c" -o "f$i.o"); done
expect cache_miss 8
for s in a b; do echo "shard-$s：$(entries "$WORK/http/shard-$s") 个对象"; done
(($(entries "$WORK/http/shard-a") > 0 && $(entries "$WORK/http/shard-b") > 0)) && echo "✓ 两个分片都分到了对象"

say "G. storage helper（4.13+）：独立的常驻进程负责与远端通信"
if [[ -n ${HTTP_HELPER:-} ]]; then
    # helper=<路径>：指定用哪个助手程序；不写时按 libexec_dirs → ccache 同目录 → PATH 的顺序找 ccache-storage-http
    conf "remote_storage = http://127.0.0.1:$port/via-helper helper=$HTTP_HELPER" "log_file = $WORK/ccache-helper.log"
    machine m8
    compile f5
    expect cache_miss 1
    machine m9
    compile f5
    expect remote_storage_hit 1
    grep -iE 'helper' "$WORK/ccache-helper.log" | head -5 || true
    run "$CCACHE" --stop-storage-helpers
else
    echo "SKIP：设 HTTP_HELPER=<ccache-storage-http 可执行文件路径> 以运行本段"
fi

say "H. file 后端的 @layout=local（4.14+）：把另一份本地缓存目录直接当只读远端"
if version_ge 4.14; then
    conf "remote_storage = file:$WORK/m1 @layout=local"
    machine m10
    compile f1
    expect remote_storage_hit 1
else
    echo "SKIP：需要 ccache ≥ 4.14"
fi

say "I. 远端不会被 ccache 自动清理。file 后端用 --trim-dir 定期修剪（默认按 atime 做 LRU）"
echo "修剪前：$(entries "$WORK/shared") 个条目"
if version_ge 4.14; then
    run "$CCACHE" --trim-dir "$WORK/shared" --trim-max-size 1kB --dry-run
    echo "--dry-run 之后：$(entries "$WORK/shared") 个条目"
fi
run "$CCACHE" --trim-dir "$WORK/shared" --trim-max-size 1kB
echo "修剪后：$(entries "$WORK/shared") 个条目"

echo "OK 08-remote-storage"
