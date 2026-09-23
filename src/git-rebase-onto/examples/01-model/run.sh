#!/usr/bin/env bash
# 01 模型：要搬的提交只由 B 与 C 决定；A 只决定落点；执行时直接游离到 A，结束时回写 C 的 ref。
source "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"
mk

note "要搬的提交 = rev-list --reverse --topo-order --no-merges --right-only --cherry-pick B...C（与 -i 生成的 todo 逐条比较）"
for bc in "main child" "topic child" "topic~1 child" "side child" "child~1 child"; do
  set -- $bc
  want=$(git rev-list --reverse --topo-order --no-merges --right-only --cherry-pick "$1...$2" \
         | while read -r x; do echo "pick $(subj "$x")"; done | paste -sd';' -)
  got=$(todo_of --onto main "$1" "$2")
  printf '  B=%-8s C=%-6s todo: %-40s rev-list: %s\n' "$1" "$2" "$got" "$want"
  assert_eq "$got" "$want"
done

note "A 换成什么，要搬的提交都不变（B=topic C=child）"
for a in main side main~3 child; do
  got=$(todo_of --onto "$a" topic child)
  printf '  A=%-6s todo: %s\n' "$a" "$got"
  assert_eq "$got" "pick c1;pick c2;pick c3"
done

note "执行：HEAD 直接游离到 A（reflog 里没有先切到 C 的记录），逐个 pick，最后回写 refs/heads/child 并把 HEAD 接回去"
old=$(git rev-parse child)
run git rebase --onto main topic child
git reflog -5 --format='  HEAD reflog| %gd %gs'
assert_eq "$(git reflog -5 --format=%gs | paste -sd';' -)" \
  "rebase (finish): returning to refs/heads/child;rebase (pick): c3;rebase (pick): c2;rebase (pick): c1;rebase (start): checkout main"
git reflog -1 --format='  child reflog| %gd %gs' child
assert_has "$(git reflog -1 --format=%gs child)" "rebase (finish): refs/heads/child onto $(git rev-parse main)"
assert_eq "$(where)" child
assert_eq "$(line child)" "o0 m1 m2 m3 c1 c2 c3"

note "ORIG_HEAD 与 child@{1} 都是 child 原来的 tip"
echo "  原 tip $(git rev-parse --short "$old")  ORIG_HEAD $(git rev-parse --short ORIG_HEAD)  child@{1} $(git rev-parse --short child@{1})"
assert_eq "$(git rev-parse ORIG_HEAD)" "$old"
assert_eq "$(git rev-parse child@{1})" "$old"

note "重放后：sha 变了，patch-id 与作者信息不变"
for i in 0 1 2; do
  o=$(git rev-parse "$old~$i"); n=$(git rev-parse "child~$i")
  po=$(git show "$o" | git patch-id --stable | cut -d' ' -f1); pn=$(git show "$n" | git patch-id --stable | cut -d' ' -f1)
  printf '  %s  旧 %s  新 %s  patch-id 旧 %s 新 %s\n' "$(subj "$o")" "${o:0:7}" "${n:0:7}" "${po:0:12}" "${pn:0:12}"
  [ "$o" != "$n" ] || fail "sha 应当改变"
  assert_eq "$pn" "$po"
  assert_eq "$(git log -1 --format='%an <%ae> %ad' "$n")" "$(git log -1 --format='%an <%ae> %ad' "$o")"
done
note "用普通命令手工重做一遍，得到的 child 与 rebase 的结果逐位相同（提交者与时间固定，所以 sha 可比）"
mk; git rebase -q --onto main topic child; want=$(git rev-parse child)
mk; git switch -q main
old=$(git rev-parse child)
list=$(git rev-list --reverse --topo-order --no-merges --right-only --cherry-pick topic...child)
git switch -q --detach main
for x in $list; do git cherry-pick --empty=drop "$x" >/dev/null; done
git update-ref refs/heads/child HEAD "$old"
git switch -q child
echo "  rebase: ${want:0:12}   手工: $(git rev-parse --short=12 child)"
assert_eq "$(git rev-parse child)" "$want"
echo "ok"
