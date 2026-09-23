#!/usr/bin/env bash
# 05 叠放分支：父分支被改写后搬子分支；旧 tip 从哪找；--fork-point；--update-refs。
source "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"

# prep：topic 先 rebase 到 main 上，再把 t2 amend 成 "t2 amended"；child 仍坐在旧 t2 上。设置 $oldt2
prep() {
  mk; oldt2=$(git rev-parse topic)
  git rebase -q main topic
  echo "t2 amended" > t2.txt; git commit -q --amend -a --no-edit
  git switch -q main
}

prep
note "起点"
echo "  topic = $(line topic)    t2.txt = $(git show topic:t2.txt)"
echo "  child = $(line child)    （旧 t1 t2）"
git merge-base --is-ancestor topic child && fail "topic 不该是 child 的祖先"
echo "  child~3 = $(git rev-parse --short child~3)（旧 t2 = ${oldt2:0:7}）"; assert_eq "$(git rev-parse child~3)" "$oldt2"

note "直接 git rebase topic child：B=topic，要搬旧 t1 t2 c1 c2 c3；旧 t1 被预检剔除（与新 t1 同 patch-id），旧 t2 不同，重放冲突"
t=$(todo_of topic child); echo "  要搬: $t"; assert_eq "$t" "pick t2;pick c1;pick c2;pick c3"
rc=0; out=$(run git rebase topic child) || rc=$?; echo "$out"
assert_eq "$rc" 1
assert_has "$out" "skipped previously applied commit"
assert_has "$out" "CONFLICT (add/add): Merge conflict in t2.txt"
git rebase --abort

note "git rebase --onto topic <旧t2> child：只搬 c1 c2 c3"
t=$(todo_of --onto topic "$oldt2" child); echo "  要搬: $t"; assert_eq "$t" "pick c1;pick c2;pick c3"
run git rebase --onto topic "$oldt2" child
echo "  child = $(line child)    t2.txt = $(git show child:t2.txt)"
assert_eq "$(line child)" "o0 m1 m2 m3 t1 t2 c1 c2 c3"
assert_eq "$(git show child:t2.txt)" "t2 amended"
git merge-base --is-ancestor topic child || fail "topic 应是 child 的祖先"

note "对照：父分支只 rebase、没改内容时，旧 t1 t2 全被预检剔除，直接 git rebase topic child 也能成功"
mk; git rebase -q main topic; git switch -q main
t=$(todo_of topic child); echo "  要搬: $t"; assert_eq "$t" "pick c1;pick c2;pick c3"
out=$(run git rebase topic child); echo "$out"
assert_eq "$(line child)" "o0 m1 m2 m3 t1 t2 c1 c2 c3"

prep
note "旧 tip 从哪找：ORIG_HEAD 还是旧 t2（commit --amend 不改 ORIG_HEAD）；topic@{1} 不是，topic@{2} 才是"
git reflog -3 --format='  topic reflog| %gd %gs' topic
echo "  旧 t2 = ${oldt2:0:7}  ORIG_HEAD = $(git rev-parse --short ORIG_HEAD)  topic@{1} = $(git rev-parse --short topic@{1})  topic@{2} = $(git rev-parse --short topic@{2})"
assert_eq "$(git rev-parse ORIG_HEAD)" "$oldt2"
[ "$(git rev-parse topic@{1})" != "$oldt2" ] || fail "topic@{1} 不该是旧 t2"
assert_eq "$(git rev-parse topic@{2})" "$oldt2"
assert_has "$(git reflog -1 --format=%gs topic@{1})" "rebase (finish)"

note "--fork-point：拿 child 与 topic reflog 里的每一个旧值求 merge-base，得到旧 t2，当作 B"
fp=$(git merge-base --fork-point topic child); echo "  merge-base --fork-point topic child = ${fp:0:7}   普通 merge-base = $(subj "$(git merge-base topic child)")"
assert_eq "$fp" "$oldt2"
t=$(todo_of --fork-point topic child); echo "  要搬: $t"; assert_eq "$t" "pick c1;pick c2;pick c3"

note "省略 B 时（用分支配置的 upstream），fork-point 默认打开"
git branch -q --set-upstream-to=topic child; git switch -q child
echo "  branch.child.remote = $(git config branch.child.remote)   branch.child.merge = $(git config branch.child.merge)"
assert_eq "$(git config branch.child.remote)" "."
assert_eq "$(git config branch.child.merge)" "refs/heads/topic"
run git rebase
assert_eq "$(line child)" "o0 m1 m2 m3 t1 t2 c1 c2 c3"

prep
note "reflog 里没有旧 t2 时，fork-point 找不到，退回按字面用 B，照样冲突"
git reflog expire --expire=now --all
rc=0; git merge-base --fork-point topic child >/dev/null || rc=$?; echo "  merge-base --fork-point 退出码: $rc"
assert_eq "$rc" 1
t=$(todo_of --fork-point topic child); echo "  要搬: $t"; assert_eq "$t" "pick t2;pick c1;pick c2;pick c3"

mk
note "一次搬整叠：不加 --update-refs 时 topic 留在原地"
run git rebase main child
echo "  child = $(line child)   topic = $(line topic)"
assert_eq "$(line topic)" "o0 m1 t1 t2"
git merge-base --is-ancestor topic child && fail "topic 不该再是 child 的祖先"

mk
note "--update-refs：todo 里在 t2 之后多一行 update-ref，topic 跟着指到新 t2"
t=$(todo_of --update-refs main child); echo "  todo: $t"
assert_eq "$t" "pick t1;pick t2;update-ref refs/heads/topic;pick c1;pick c2;pick c3"
out=$(run git rebase --update-refs main child); echo "$out"
assert_has "$out" "Updated the following refs with --update-refs:"
echo "  child = $(line child)   topic = $(line topic)"
assert_eq "$(line topic)" "o0 m1 m2 m3 t1 t2"
assert_eq "$(git rev-parse topic)" "$(git rev-parse child~3)"

mk
note "-i 时从 todo 里删掉 update-ref 那一行，topic 就不更新"
g=$work/drop-uref; printf '#!/bin/sh\nsed -i "/^update-ref /d" "$1"\n' > "$g"; chmod +x "$g"
git -c sequence.editor="$g" rebase -q -i --update-refs main child
echo "  child = $(line child)   topic = $(line topic)"
assert_eq "$(line child)" "o0 m1 m2 m3 t1 t2 c1 c2 c3"
assert_eq "$(line topic)" "o0 m1 t1 t2"

mk
note "rebase.updateRefs=true 等于默认加 --update-refs"
git -c rebase.updateRefs=true rebase -q main child; t=$(line topic); echo "  topic = $t"
assert_eq "$t" "o0 m1 m2 m3 t1 t2"

mk
note "--update-refs 不更新被别的 worktree 检出的分支"
git worktree add -q "$work/wt-topic" topic
t=$(todo_of --update-refs main child); echo "  todo: $t"
assert_not "$t" "update-ref"
# 原位置换成了一行注释（todo_of 滤掉了注释，这里单独看原文）
g=$work/grab; printf '#!/bin/sh\ngrep "checked out at" "$1"\n: > "$1"\n' > "$g"; chmod +x "$g"
cmt=$(git -c sequence.editor="$g" rebase -i --update-refs main child 2>/dev/null || true); echo "  todo 原文里: $cmt"
assert_has "$cmt" "# Ref refs/heads/topic checked out at '$work/wt-topic'"
run git rebase --update-refs main child
echo "  topic = $(line topic)"; assert_eq "$(line topic)" "o0 m1 t1 t2"
git worktree remove --force "$work/wt-topic"
echo "ok"
