#!/usr/bin/env bash
# 03 重复提交：预检（patch-id，比的是 B 那边）与重放后变空（--empty）是两套机制。
source "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"

# mkdup：在 main 末尾加 c1copy，它的改动与 c1 完全相同（新增 c1.txt，内容 c1），只是提交消息不同
mkdup() { mk; echo c1 > c1.txt; git add c1.txt; git commit -qm c1copy; }
pid() { git show "$1" | git patch-id --stable | cut -d' ' -f1; }

mkdup
note "c1copy 与 c1 的 patch-id 相同（提交消息不参与 patch-id）"
echo "  c1     $(pid child~2)"; echo "  c1copy $(pid main)"
assert_eq "$(pid main)" "$(pid child~2)"

note "副本在 B 那边：git rebase main child —— 预检时剔除 c1，todo 里没有它"
t=$(todo_of main child); echo "  要搬: $t"; assert_eq "$t" "pick t1;pick t2;pick c2;pick c3"
out=$(run git rebase main child); echo "$out"
assert_has "$out" "warning: skipped previously applied commit"
assert_has "$out" "hint: use --reapply-cherry-picks to include skipped commits"
echo "  child = $(line child)"; assert_eq "$(line child)" "o0 m1 m2 m3 c1copy t1 t2 c2 c3"

mkdup
note "git cherry -v main child：c1 前缀是 -，表示 main 上已有同 patch-id 的提交"
git cherry -v main child | sed 's/^/    /'
assert_has "$(git cherry -v main child)" "- $(git rev-parse child~2) c1"
note "副本只在 A 上：git rebase --onto main topic child —— 预检不剔除（topic...child 的左边没有副本），c1 进 todo"
t=$(todo_of --onto main topic child); echo "  要搬: $t"; assert_eq "$t" "pick c1;pick c2;pick c3"
out=$(run git rebase --onto main topic child); echo "$out"
assert_not "$out" "skipped previously applied"
assert_has "$out" "c1 -- patch contents already upstream"
echo "  child = $(line child)"; assert_eq "$(line child)" "o0 m1 m2 m3 c1copy c2 c3"

mkdup
note "同上但用 -i（不改 todo）：--empty 默认变成 stop，停在变空的 c1 上"
rc=0; out=$(run git -c sequence.editor=true rebase -i --onto main topic child) || rc=$?; echo "$out"
assert_eq "$rc" 1
assert_has "$out" "The previous cherry-pick is now empty"
assert_eq "$(subj REBASE_HEAD)" c1
run git rebase --skip
echo "  child = $(line child)"; assert_eq "$(line child)" "o0 m1 m2 m3 c1copy c2 c3"

mkdup
note "--empty=keep：变空的 c1 作为空提交留下"
run git rebase --empty=keep --onto main topic child
echo "  child = $(line child)"; assert_eq "$(line child)" "o0 m1 m2 m3 c1copy c1 c2 c3"
echo "  c1 的改动: [$(git diff --stat child~3 child~2)]"; assert_eq "$(git diff --stat child~3 child~2)" ""

mkdup
note "--reapply-cherry-picks：关掉预检，c1 进 todo；重放后变空，再由 --empty=drop 丢掉"
t=$(todo_of --reapply-cherry-picks main child); echo "  要搬: $t"
assert_eq "$t" "pick t1;pick t2;pick c1;pick c2;pick c3"
out=$(run git rebase --reapply-cherry-picks main child); echo "$out"
assert_has "$out" "c1 -- patch contents already upstream"
assert_eq "$(line child)" "o0 m1 m2 m3 c1copy t1 t2 c2 c3"

# mkdup2：c1copy 之后 main 又把 c1.txt 改成 "c1 changed"
mkdup2() { mkdup; echo "c1 changed" > c1.txt; git commit -qam m4; }
mkdup2
note "A 上的副本之后又被改过：预检剔除时没事"
run git rebase main child
assert_eq "$(line child)" "o0 m1 m2 m3 c1copy m4 t1 t2 c2 c3"
assert_eq "$(git show child:c1.txt)" "c1 changed"
mkdup2
note "A 上的副本之后又被改过：--onto 时 c1 被重放，冲突"
rc=0; out=$(run git rebase --onto main topic child) || rc=$?; echo "$out"
assert_eq "$rc" 1
assert_has "$out" "CONFLICT (add/add): Merge conflict in c1.txt"
git status --short | sed 's/^/  status| /'; assert_eq "$(git status --short)" "AA c1.txt"
git rebase --abort

note "副本只在 B 那边、不在 A 上：c1 被预检剔除，结果里根本没有 c1 的改动"
# topic 上加一个 c1 的副本；child 仍从旧 t2 分出，所以副本在 topic...child 的左边
mk; git switch -q topic; echo c1 > c1.txt; git add c1.txt; git commit -qm c1copy-on-topic; git switch -q main
echo "  git cherry -v main child（比较的是 A=main）:"; git cherry -v main child | sed 's/^/    /'
assert_has "$(git cherry -v main child)" "+ $(git rev-parse child~2) c1"
t=$(todo_of --onto main topic child); echo "  要搬: $t"; assert_eq "$t" "pick c2;pick c3"
out=$(run git rebase --onto main topic child); echo "$out"
assert_has "$out" "skipped previously applied commit"
echo "  child = $(line child)    c1.txt 存在吗: $(git cat-file -e child:c1.txt 2>/dev/null && echo 是 || echo 否)"
assert_eq "$(line child)" "o0 m1 m2 m3 c2 c3"
git cat-file -e child:c1.txt 2>/dev/null && fail "c1.txt 不该存在"
echo "ok"
