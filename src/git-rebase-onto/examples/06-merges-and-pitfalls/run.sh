#!/usr/bin/env bash
# 06 merge 提交与几个坑：默认拍平；--rebase-merges；分支被别的 worktree 检出；工作区不干净。
source "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"

# mkmerge：child 在 c3 之后 merge 了 side（带进 s1），再提交 c4
mkmerge() { mk; git switch -q child; git merge -q --no-edit side; c c4; git switch -q main; }

mkmerge
note "起点：child 上有一个 merge"
git log --graph --format=%s child | sed 's/^/  /'

note "默认：merge 提交不搬（--no-merges），s1 在 topic..child 里，被拍平进来"
t=$(todo_of --onto main topic child); echo "  要搬: $t"
assert_eq "$t" "pick c1;pick c2;pick c3;pick s1;pick c4"
run git rebase --onto main topic child
echo "  child = $(line child)   main..child 里的 merge 数: $(git rev-list --merges main..child | wc -l)"
assert_eq "$(line child)" "o0 m1 m2 m3 c1 c2 c3 s1 c4"
assert_eq "$(git rev-list --merges main..child | wc -l)" 0

mkmerge
note "--rebase-merges：todo 里多出 label / reset / merge 指令，重建 merge"
g=$work/grab; printf '#!/bin/sh\ngrep -v "^#" "$1" | grep -v "^$" | sed "s/^/  todo| /"\n' > "$g"; chmod +x "$g"
git -c sequence.editor="$g" rebase -i --rebase-merges --onto main topic child 2>/dev/null | grep 'todo|'
git log --graph --format=%s main..child | sed 's/^/  /'
assert_eq "$(git rev-list --merges main..child | wc -l)" 1
assert_eq "$(git log -1 --format=%s child)" c4
assert_eq "$(git log -1 --format=%s child^)" "Merge branch 'side' into child"
# s1 不以 topic 为祖先，默认（no-rebase-cousins）保留原来的分叉点：s1 就是原来那个提交
assert_eq "$(git rev-parse child^^2)" "$(git rev-parse side)"

mk
note "C 被别的 worktree 检出：在别处写 C 会被拒绝；到那个 worktree 里省略 C 执行即可"
git worktree add -q "$work/wt-child" child
rc=0; out=$(run git rebase --onto main topic child) || rc=$?; echo "$out"
assert_eq "$rc" 128
assert_has "$out" "fatal: 'child' is already used by worktree at"
run git -C "$work/wt-child" rebase --onto main topic
assert_eq "$(line child)" "o0 m1 m2 m3 c1 c2 c3"
git worktree remove --force "$work/wt-child"

mk
note "工作区有未提交的修改：拒绝开始；--autostash 先 stash、结束后弹回"
echo dirty >> m3.txt
rc=0; out=$(run git rebase --onto main topic child) || rc=$?; echo "$out"
assert_eq "$rc" 1
assert_has "$out" "cannot rebase: You have unstaged changes."
out=$(run git rebase --autostash --onto main topic child); echo "$out"
assert_has "$out" "Applied autostash."
assert_eq "$(line child)" "o0 m1 m2 m3 c1 c2 c3"
echo "  现在在 $(where) 上，m3.txt = $(cat m3.txt | paste -sd' ' -)"
assert_eq "$(where)" child
assert_eq "$(cat m3.txt | paste -sd' ' -)" "m3 dirty"

mk
note "--autostash：结束时的分支上没有这个文件，stash 应用冲突，stash 留在列表里"
echo dirty >> m3.txt
out=$(run git rebase --autostash --onto side topic child); echo "$out"
assert_has "$out" "applying them"
assert_has "$out" "resulted in conflicts."
echo "  在 $(where) 上，status: $(git status --short | paste -sd' ' -)，stash 条数: $(git stash list | wc -l)"
assert_eq "$(where)" child
assert_eq "$(git status --short)" "DU m3.txt"
assert_eq "$(git stash list | wc -l)" 1

note "--autostash 加 --abort：HEAD 回到 child（不是开始时的 main），在 main 上做的修改被应用到 child 上"
mk; echo "o0 main" > o0.txt; git commit -qam m4
git switch -q child; git reset -q --hard child~2; echo "o0 child" > o0.txt; git commit -qam c2; c c3; git switch -q main
echo dirty >> m3.txt
git rebase --autostash --onto main topic child >/dev/null 2>&1 || true
out=$(run git rebase --abort); echo "$out"
assert_has "$out" "resulted in conflicts."
echo "  在 $(where) 上，status: $(git status --short | paste -sd' ' -)，stash 条数: $(git stash list | wc -l)"
assert_eq "$(where)" child
assert_eq "$(git status --short)" "DU m3.txt"
assert_eq "$(git stash list | wc -l)" 1
echo "ok"
