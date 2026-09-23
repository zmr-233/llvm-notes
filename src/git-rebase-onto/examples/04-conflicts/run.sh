#!/usr/bin/env bash
# 04 冲突与恢复：base / ours / theirs 各是谁；进行中的状态存在哪；--continue / --skip / --abort / --quit；事后撤销。
source "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"

# mkconf：main 把 o0.txt 改成 "o0 main"（m4）；child 改成 c1 → c2 → c3，其中 c2 把 o0.txt 改成 "o0 child"
mkconf() {
  mk
  echo "o0 main" > o0.txt; git commit -qam m4
  git switch -q child; git reset -q --hard child~2
  echo "o0 child" > o0.txt; git commit -qam c2; c c3
  git switch -q main
}

mkconf; old=$(git rev-parse child); oldc2=$(git rev-parse child~1)
note "停在 c2 上"
rc=0; run git -c merge.conflictStyle=diff3 rebase --onto main topic child || rc=$?
assert_eq "$rc" 1

note "三个 stage：1 = base = c2 的原父（c1）里的内容；2 = ours = HEAD；3 = theirs = 正在重放的 c2"
for s in 1 2 3; do echo "  :$s:o0.txt = $(git show :$s:o0.txt)"; done
assert_eq "$(git show :1:o0.txt)" "o0"
assert_eq "$(git show :2:o0.txt)" "o0 main"
assert_eq "$(git show :3:o0.txt)" "o0 child"

note "工作区里的冲突标记（diff3 风格，多出 ||||||| 一段 base）：ours 标为 HEAD，base 标为 'parent of <c2>'，theirs 标为 <c2>"
sed 's/^/  o0.txt| /' o0.txt
m=$(cat o0.txt); short=$(git rev-parse --short "$oldc2")
assert_has "$m" "<<<<<<< HEAD"
assert_has "$m" "||||||| parent of $short (c2)"
assert_has "$m" ">>>>>>> $short (c2)"

note "HEAD 游离在已经重放好的 c1 上；REBASE_HEAD 是正在重放的旧 c2"
echo "  分支: [$(git branch --show-current)]  HEAD: $(line HEAD)  REBASE_HEAD: $(subj REBASE_HEAD) $(git rev-parse --short REBASE_HEAD)"
assert_eq "$(git branch --show-current)" ""
assert_eq "$(line HEAD)" "o0 m1 m2 m3 m4 c1"
assert_eq "$(git rev-parse REBASE_HEAD)" "$oldc2"

note "--ours 取的是 main 那边，--theirs 取的是 child 自己的提交"
git checkout -q --ours o0.txt;   echo "  --ours   → $(cat o0.txt)"; assert_eq "$(cat o0.txt)" "o0 main"
git checkout -q --theirs o0.txt; echo "  --theirs → $(cat o0.txt)"; assert_eq "$(cat o0.txt)" "o0 child"

note ".git/rebase-merge/ 里的状态"
d=.git/rebase-merge
echo "  onto      = $(cat $d/onto | cut -c1-7)   (main = $(git rev-parse --short main))"
echo "  orig-head = $(cat $d/orig-head | cut -c1-7)   (child 原 tip = ${old:0:7})"
echo "  head-name = $(cat $d/head-name)"
echo "  done      = $(grep -v '^#' $d/done | sed -E 's/^pick [0-9a-f]+ # //' | paste -sd' ' -)"
echo "  todo      = $(grep -v '^#' $d/git-rebase-todo | sed -E 's/^pick [0-9a-f]+ # //' | paste -sd' ' -)"
assert_eq "$(cat $d/onto)" "$(git rev-parse main)"
assert_eq "$(cat $d/orig-head)" "$old"
assert_eq "$(cat $d/head-name)" "refs/heads/child"
assert_eq "$(grep -v '^#' $d/done | sed -E 's/^pick [0-9a-f]+ # //' | paste -sd' ' -)" "c1 c2"
assert_eq "$(grep -v '^#' $d/git-rebase-todo | sed -E 's/^pick [0-9a-f]+ # //' | paste -sd' ' -)" "c3"

note "--continue：写好解决结果、git add、继续；冲突后的这次提交会打开编辑器（COMMIT_EDITMSG）改消息"
echo "o0 main+child" > o0.txt; git add o0.txt
ed=$work/editor; printf '#!/bin/sh\necho "$1" > "%s/editor-called"\n' "$work" > "$ed"; chmod +x "$ed"
GIT_EDITOR=$ed run git rebase --continue
echo "  编辑器收到: $(cat "$work/editor-called")"
assert_has "$(cat "$work/editor-called")" "COMMIT_EDITMSG"
assert_eq "$(line child)" "o0 m1 m2 m3 m4 c1 c2 c3"
assert_eq "$(git show child:o0.txt)" "o0 main+child"
assert_eq "$(where)" child

note "事后撤销：ORIG_HEAD 与 child@{1} 都还指着原 tip"
echo "  ORIG_HEAD = $(git rev-parse --short ORIG_HEAD)  child@{1} = $(git rev-parse --short child@{1})  原 tip = ${old:0:7}"
git reflog -2 --format='  child reflog| %gd %gs' child
assert_eq "$(git rev-parse ORIG_HEAD)" "$old"
run git reset --hard ORIG_HEAD
assert_eq "$(git rev-parse child)" "$old"

mkconf
note "--skip：丢掉正在重放的 c2，接着做 c3"
git rebase --onto main topic child >/dev/null 2>&1 || true
echo "解了一半" > o0.txt     # 解了一半的内容会被 --skip 一起丢掉
run git rebase --skip
assert_eq "$(cat o0.txt)" "o0 main"
echo "  child = $(line child)   o0.txt = $(git show child:o0.txt)"
assert_eq "$(line child)" "o0 m1 m2 m3 m4 c1 c3"
assert_eq "$(git show child:o0.txt)" "o0 main"

mkconf; old=$(git rev-parse child)
note "--abort：child 回到原 tip；HEAD 停在 child 上，不回到开始时所在的 main"
echo "  开始时在: $(where)"
git rebase --onto main topic child >/dev/null 2>&1 || true
run git rebase --abort
echo "  之后在: $(where)   child 回到原 tip: $([ "$(git rev-parse child)" = "$old" ] && echo 是)"
assert_eq "$(git rev-parse child)" "$old"
assert_eq "$(where)" child

mkconf; old=$(git rev-parse child)
note "--quit：删掉进行中的状态，但 HEAD 留在原地（游离在重放了一半的链上），child 不动"
git rebase --onto main topic child >/dev/null 2>&1 || true
run git rebase --quit
echo "  HEAD 在: $(where)   HEAD = $(line HEAD)   rebase-merge 还在吗: $([ -d .git/rebase-merge ] && echo 在 || echo 不在)"
assert_eq "$(where)" detached
assert_eq "$(line HEAD)" "o0 m1 m2 m3 m4 c1"
assert_eq "$(git rev-parse child)" "$old"
[ -d .git/rebase-merge ] && fail "rebase-merge 应已删除"
echo "ok"
