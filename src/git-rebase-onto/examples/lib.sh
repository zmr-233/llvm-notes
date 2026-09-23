#!/usr/bin/env bash
# 共用脚手架：被各 run.sh source。
#
# 可选环境变量：
#   GIT=<路径>   换一个 git 可执行文件复核（默认 PATH 里的 git）
#   KEEP=1       结束后保留一次性目录，便于进去自己敲命令
#
# 每个例子在 mktemp -d 建的一次性目录里建仓库，不碰你机器上的任何仓库。
# 全局与系统级 git 配置一律屏蔽，作者、提交者与时间固定，所以同一版本 git 上每次得到的 sha 相同。
set -euo pipefail

work=$(mktemp -d -t rebase-onto.XXXXXX)
trap 'if [ "${KEEP:-0}" = 1 ]; then echo "保留一次性目录: $work"; else rm -rf "$work"; fi' EXIT

GIT=$(command -v "${GIT:-git}") || { echo "找不到 git" >&2; exit 1; }
git() { command "$GIT" "$@"; }
echo "git: $GIT ($(git --version))"

# 屏蔽 ~/.gitconfig 与 /etc/gitconfig：rebase.updateRefs、rebase.autoSquash、pull.rebase 之类的个人配置会改变结果
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME='A U Thor' GIT_AUTHOR_EMAIL=author@example.com
export GIT_COMMITTER_NAME='C O Mitter' GIT_COMMITTER_EMAIL=committer@example.com
export GIT_AUTHOR_DATE='2026-01-01T00:00:00Z' GIT_COMMITTER_DATE='2026-01-01T00:00:00Z'
export GIT_EDITOR=true          # 需要编辑提交消息时（--continue 等）直接接受默认消息
unset GIT_SEQUENCE_EDITOR

fail() { echo "FAIL: $*" >&2; exit 1; }
note() { echo; echo "## $*"; }
assert_eq()  { [ "$1" = "$2" ] || fail "期望 [$2]，实际 [$1]"; }
assert_has() { case "$1" in *"$2"*) ;; *) fail "缺少 [$2]" ;; esac; }
assert_not() { case "$1" in *"$2"*) fail "不该出现 [$2]" ;; *) ;; esac; }

# c <名字>：新建文件 <名字>.txt，内容就是名字，提交消息也是名字
c() { echo "$1" > "$1.txt"; git add "$1.txt"; git commit -qm "$1"; }

# mk：在 $work/r 重建实验仓库，并 cd 进去。
#
#   o0 ─ m1 ─ m2 ─ m3                 main
#        ├─ s1                        side
#        └─ t1 ─ t2                   topic
#                └─ c1 ─ c2 ─ c3      child
#
# 每个提交只新增一个自己名字的文件，彼此不冲突。结束时停在 main 上。
mk() {
  cd "$work"; rm -rf r
  git init -q -b main --object-format=sha1 r; cd r
  c o0; c m1
  git switch -qc side; c s1
  git switch -q main; c m2; c m3
  git switch -qc topic main~2; c t1; c t2
  git switch -qc child; c c1; c c2; c c3
  git switch -q main
}

# line <rev>：从根到 <rev> 的提交消息，空格分隔
line() { git log --reverse --format=%s "$1" | paste -sd' ' -; }
# subj <rev>…：每个 rev 的提交消息，空格分隔
subj() { local r; for r in "$@"; do git log -1 --format=%s "$r"; done | paste -sd' ' -; }
# where：HEAD 在哪个分支上；游离时打印 detached
where() { git symbolic-ref -q --short HEAD || echo detached; }

# todo_of <rebase 参数…>：用 -i 让 rebase 生成 todo，抄出非注释行后清空 todo，
# rebase 因此以 "nothing to do" 退出，什么也不改。打印 "pick <短sha> # <消息>" 那几行里的消息部分与指令。
todo_of() {
  local grab=$work/grab-todo out=$work/todo.out msg
  printf '#!/bin/sh\ngrep -v "^#" "$1" | grep -v "^$" > "%s" || true\n: > "$1"\n' "$out" > "$grab"; chmod +x "$grab"
  rm -f "$out"
  msg=$(git -c sequence.editor="$grab" rebase -i "$@" 2>&1) || true
  [ -f "$out" ] || fail "rebase 没有走到生成 todo 这一步: $msg"
  [ -d .git/rebase-merge ] && fail "todo_of 之后 rebase 仍在进行"
  sed -E 's/^(pick|p) [0-9a-f]+ # /pick /' "$out" | paste -sd';' -
}

# run <命令…>：打印命令，执行，把 rebase 进度行里的回车换成换行，去掉空行，逐行加前缀打印；返回命令的退出码
run() {
  echo "\$ $*"
  local rc=0 out
  out=$("$@" 2>&1) || rc=$?
  printf '%s\n' "$out" | tr '\r' '\n' | grep -v '^$' | sed 's/^/  | /' || true
  return $rc
}
