#!/usr/bin/env bash
# 02 写法对照：同一个仓库，换 A / B / C 的写法，看搬了哪些提交、结果是什么、HEAD 停在哪。
source "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"

# v <期望搬的提交> <期望 child> <rebase 参数…>：重建仓库、先用 todo_of 看要搬哪些，再真跑
v() {
  local want_todo=$1 want_child=$2; shift 2
  mk
  note "git rebase $*"
  local t; t=$(todo_of "$@"); echo "  要搬: $t"
  assert_eq "$t" "$want_todo"
  run git rebase "$@"
  echo "  child = $(line child)    HEAD 在: $(where)"
  assert_eq "$(line child)" "$want_child"
}

v "pick t1;pick t2;pick c1;pick c2;pick c3" "o0 m1 m2 m3 t1 t2 c1 c2 c3"  main child
v "pick c1;pick c2;pick c3"                 "o0 m1 m2 m3 c1 c2 c3"        --onto main topic child
v "pick t2;pick c1;pick c2;pick c3"         "o0 m1 m2 m3 t2 c1 c2 c3"     --onto main topic~1 child
note "（删提交）c2 不在 child~1..child 里，c3 直接接到 c1 上"
v "pick c3"                                 "o0 m1 t1 t2 c1 c3"           --onto child~2 child~1 child
note "（删连续两个）t2..c2 = c1 c2，c3 直接接到 t2 上"
v "pick c3"                                 "o0 m1 t1 t2 c3"              --onto child~3 child~1 child
note "（B 写成不相干的分支）side 不是 child 的祖先，side..child 照样成立，不报错"
v "pick t1;pick t2;pick c1;pick c2;pick c3" "o0 m1 m2 m3 t1 t2 c1 c2 c3"  --onto main side child
note "（A 写成 X...Y）A = merge-base(main, topic) = m1，t1 t2 从 child 上被删掉"
v "pick c1;pick c2;pick c3"                 "o0 m1 c1 c2 c3"              --onto main...topic topic child
assert_eq "$(git rev-parse child~3)" "$(git rev-parse main~2)"

note "（A...B 有多个 merge-base 时报错）"
# x 与 y 都是 side 与 topic 的合并（父的顺序不同），于是 x、y 的 merge-base 有 s1、t2 两个
mk; git switch -qc x side; git merge -q --no-edit topic; git switch -qc y topic; git merge -q --no-edit side
echo "  merge-base x y: $(git merge-base --all x y | while read -r r; do subj "$r"; done | paste -sd' ' -)"
rc=0; msg=$(git rebase --onto x...y topic child 2>&1) || rc=$?; echo "  | $msg"
assert_eq "$rc" 128; assert_has "$msg" "need exactly one merge base"

note "（--keep-base）A = merge-base(main, child) = m1，要搬 main..child，底座不变"
mk
t=$(todo_of --keep-base main child); echo "  要搬: $t"
assert_eq "$t" "pick t1;pick t2;pick c1;pick c2;pick c3"
run git rebase --keep-base main child
echo "  child = $(line child)"; assert_eq "$(line child)" "o0 m1 t1 t2 c1 c2 c3"

note "（C 写成 sha）结果停在游离 HEAD 上，child 分支不动"
mk; old=$(git rev-parse child)
run git rebase --onto main topic "$old"
echo "  HEAD 在: $(where)  HEAD = $(line HEAD)  child = $(line child)"
assert_eq "$(where)" detached
assert_eq "$(line HEAD)" "o0 m1 m2 m3 c1 c2 c3"
assert_eq "$(git rev-parse child)" "$old"

note "（C 写成 refs/heads/child）同样不算分支名：先找 refs/heads/refs/heads/child，找不到就按普通 rev 解析"
mk; old=$(git rev-parse child)
run git rebase --onto main topic refs/heads/child
assert_eq "$(where)" detached
assert_eq "$(git rev-parse child)" "$old"

note "（省略 C）站在 child 上时，等同于写 C=child"
mk; git switch -q child
run git rebase --onto main topic
assert_eq "$(line child)" "o0 m1 m2 m3 c1 c2 c3"; assert_eq "$(where)" child

note "（省略 C 且站在 main 上）C 取 main：要搬 topic..main = m2 m3，重放到 main 上都变空，被丢弃"
mk; before=$(git rev-parse main)
t=$(todo_of --onto main topic); echo "  要搬: $t"; assert_eq "$t" "pick m2;pick m3"
out=$(run git rebase --onto main topic); echo "$out"
assert_has "$out" "m2 -- patch contents already upstream"
assert_has "$out" "m3 -- patch contents already upstream"
assert_eq "$(git rev-parse main)" "$before"

note "（A 已经是底座）什么都不做"
mk; before=$(git rev-parse child)
out=$(run git rebase --onto topic topic child); echo "$out"
assert_has "$out" "Current branch child is up to date."
assert_eq "$(git rev-parse child)" "$before"
note "（加 --force-rebase）跳过这个判断，照样逐个重放"
out=$(run git rebase --force-rebase --onto topic topic child); echo "$out"
assert_has "$out" "Current branch child is up to date, rebase forced."
assert_has "$out" "Rebasing (3/3)"
# 父、tree、作者、提交者、时间全都没变，所以新提交的 sha 与原来相同；真实环境里提交时间会变，sha 也就变了
assert_eq "$(git rev-parse child)" "$before"
echo "ok"
