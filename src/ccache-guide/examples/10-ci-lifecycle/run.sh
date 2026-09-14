#!/usr/bin/env bash
# 10-ci-lifecycle：CI 作业里缓存的一生——恢复、限额、清零、构建、统计、淘汰、保存
# 用本地目录模拟 CI 的缓存存储：对 GitHub Actions cache、GitLab cache 而言，缓存目录只是「一个能存取的 tar 包」
source "$(dirname "$0")/../lib.sh"

# gen_sources <目录> <数量> <f1 的版本号>：造一批源文件；版本号只改 f1.c 的返回值
gen_sources() {
    mkdir -p "$1"
    for i in $(seq "$2"); do
        printf 'int f%d(void) { return %d; }\n' "$i" "$i" >"$1/f$i.c"
    done
    printf 'int f1(void) { return %d; }\n' "$(($3 * 100))" >"$1/f1.c"
}

# job <名字> <源文件数> <f1 版本号>：一次 CI 作业，每次都在一台全新的 runner（新目录）上
job() {
    local name=$1 n=$2 rev=$3 ws=$WORK/runner-$1
    say "作业 $name：$n 个源文件，f1 版本 $rev"
    mkdir -p "$ws"
    export CCACHE_DIR=$ws/ccache

    # 1. 恢复：上一个作业存下的缓存目录（tar 保留文件 mtime，LRU 信息随之保留）
    if [[ -f $WORK/store/ccache.tar ]]; then
        run tar -xf "$WORK/store/ccache.tar" -C "$ws"
    fi
    # 2. 限额：-M 把 max_size 写进配置文件（这里是 $CCACHE_CONFIGPATH，平时是 $CCACHE_DIR/ccache.conf）
    run "$CCACHE" -M 50MB
    # 3. 清零计数器，作业结束时的统计就只属于本作业
    zero
    local start
    start=$(date +%s)

    # 4. 构建
    gen_sources "$ws/src" "$n" "$rev"
    for i in $(seq "$n"); do
        (cd "$ws/src" && "$CCACHE" gcc -O2 -c "f$i.c" -o "f$i.o")
    done
}

# finish：统计、淘汰、保存
finish() {
    local start=$1
    # 5. 统计
    run "$CCACHE" -s
    # 6. 淘汰本作业没用到的条目。命中会刷新条目的 mtime，新写入的条目 mtime 本就是现在，
    #    所以「早于本作业开始」的就是没用到的。不淘汰的话，缓存包会随历史无限膨胀直到撞上 max_size
    echo "淘汰前 files_in_cache = $(counter files_in_cache)"
    run "$CCACHE" --evict-older-than "$(($(date +%s) - start + 1))s"
    echo "淘汰后 files_in_cache = $(counter files_in_cache)"
    # 7. 保存
    mkdir -p "$WORK/store"
    run tar -cf "$WORK/store/ccache.tar" -C "$(dirname "$CCACHE_DIR")" ccache
}

t=$(date +%s)
job 1 20 1
expect cache_miss 20
finish "$t"

sleep 2 # finish 里的年龄按整秒算，作业之间至少隔开 1 秒，上一个作业的条目才会「早于」本作业开始

t=$(date +%s)
job 2 20 2
expect direct_cache_hit 19
expect cache_miss 1 # 只有 f1.c 变了
finish "$t"         # 旧版 f1 的条目本作业没用到 → 被淘汰

sleep 2

t=$(date +%s)
job 3 10 2 # 工程删掉了一半文件
expect direct_cache_hit 10
finish "$t"
# 每次成功编译产生 2 个条目文件：manifest + result
expect files_in_cache 20

say "附：namespace 与 --evict-namespace。多个工程共用一个缓存目录时，各用一个命名空间，可以单独清掉"
export CCACHE_DIR=$WORK/ns-cache
mkdir -p "$WORK/ns" && cd "$WORK/ns"
printf 'int a(void) { return 1; }\n' >a.c
printf 'int b(void) { return 2; }\n' >b.c
run "$CCACHE" namespace=proj-a gcc -c a.c -o a.o
run "$CCACHE" namespace=proj-b gcc -c b.c -o b.o
zero
run "$CCACHE" namespace=proj-b gcc -c a.c -o a.o # 同一条编译换个命名空间：命名空间是键的一部分 → miss
expect cache_miss 1
expect files_in_cache 6
run "$CCACHE" --evict-namespace proj-a
expect files_in_cache 4

echo "OK 10-ci-lifecycle"
