# 05 叠放分支

一个分支基于另一个分支开发（child 基于 topic），父分支后来被改写了（rebase 过、amend 过、整理过提交），
子分支还坐在父分支的旧提交上。这是 `--onto` 最常用的场景。

例子：`examples/05-stacked/run.sh`。

## 起点

例子先把 topic rebase 到 main 上，再把 t2 amend 成新内容（`t2.txt` 改为 `t2 amended`）。child 没动：

```text
topic: o0 m1 m2 m3 t1' t2'      t2' 的内容是 "t2 amended"
child: o0 m1 t1 t2 c1 c2 c3     旧 t1 t2
```

新旧 t1 的 patch-id 相同（rebase 没改它的内容）；新旧 t2 不同（amend 改了内容）。topic 不再是 child 的祖先。
目标是得到 `o0 m1 m2 m3 t1' t2' c1 c2 c3`。

## 直接 `git rebase topic child`

```bash
git rebase topic child
```

B = A = topic。要搬的是 `topic..child` = 旧 t1 旧 t2 c1 c2 c3（旧 t1、t2 从新 topic 不可达）。预检（03 篇）：

- 旧 t1 与左边的 t1' patch-id 相同，剔除。
- 旧 t2 与 t2' 不同，留下。

所以 todo 是 `pick t2;pick c1;pick c2;pick c3`（实测）。旧 t2 被重放到 t2' 上：base = t1（没有 t2.txt），
ours = t2'（`t2 amended`），theirs = 旧 t2（`t2`），两边都新增了 `t2.txt` 且内容不同：

```text
warning: skipped previously applied commit 1f7baed
Rebasing (1/4)
CONFLICT (add/add): Merge conflict in t2.txt
error: could not apply e615b56... t2
```

对照（实测）：父分支只 rebase、没改内容时，旧 t1、旧 t2 与新的 patch-id 都相同，全被预检剔除，todo 只剩 c1 c2 c3，
这条命令能成功，只多两行 `skipped previously applied commit`。父分支一旦改过某个提交的内容，就会在那个提交上冲突。
旧 t2 本来就不是 child 自己的提交，这个冲突是 B 选错带来的，要人去判断旧 t2 与 t2' 的关系，而这不该是搬 child 时的事。

## `git rebase --onto topic <旧t2> child`

```bash
git rebase --onto topic e615b5612435af45c45591471ef481569bdc60bc child
```

- `--onto topic`：A = topic 的新 tip（t2'）。
- `e615b56…`：B = 旧 t2，child 原来的底座。`旧t2..child` = c1 c2 c3。
- `child`：C。

只搬 c1 c2 c3，没有冲突（实测）。结果 child = o0 m1 m2 m3 t1' t2' c1 c2 c3，`t2.txt` 是 `t2 amended`，
topic 重新成为 child 的祖先。

## 旧 tip 从哪找

`--onto` 的难点是 B：父分支的旧 tip 已经不被任何分支指着了。实测里 topic 的 reflog：

```text
topic@{0} commit (amend): t2
topic@{1} rebase (finish): refs/heads/topic onto 8383d433a9725f1d6c3a6833ca72a3edc795c5af
topic@{2} commit: t2
```

- `topic@{1}` 是 rebase 完成后、amend 之前的那个 t2'（`f69f261`），不是旧 t2。
- `topic@{2}` 才是旧 t2（`e615b56`）。

旧 tip 之后 topic 每变动一次（rebase、amend、新提交），旧 tip 在 reflog 里的编号就加一。所以要先看 `git reflog topic`，
找到 child 分出时的那一行，而不是按编号猜。
`git reflog <分支>`：列出这个分支 ref 的变动历史，每行一次变动，最新的在最上面。

其他来源：

- `ORIG_HEAD`：topic 的 rebase 开始时设成了旧 t2，之后的 `commit --amend` 不改它，所以实测里 `ORIG_HEAD` 仍是旧 t2。
  但它只保留到下一次 reset / merge / rebase。
- child 自己：旧 t2 就是 child 上 c1 的父提交。已知 child 上自己的提交有几个（这里 3 个），`child~3` 就是旧 t2（实测）。
  这是最不依赖 reflog 的办法，前提是你知道那个数字。
- `git merge-base --fork-point topic child`：让 git 从 topic 的 reflog 里找（下一节）。

## `--fork-point`

```bash
git merge-base --fork-point topic child
```

- `--fork-point`：不求普通的 merge-base，而是在 topic 的 reflog 里出现过的所有值中，找 child 从哪一个分出来的。
- `topic`：父分支的 ref 名（要读它的 reflog，所以必须是 ref，不能是 sha）。
- `child`：子分支。

实测输出旧 t2（`e615b56`），而普通 `git merge-base topic child` 输出 m1。

实现是：收集 topic 的 reflog 里每一条记录的新值，与 child 一起求 merge-base；只有结果唯一、而且恰好是 reflog 里的某个值时才算找到
（代码阅读：`commit.c:1094-1149` 的 `get_fork_point`）。

`git rebase --fork-point topic child` 用这个结果收窄集合：todo 由 `topic...child` 再加上 `^<fork-point>` 生成
（代码阅读：`builtin/rebase.c:304-306`），于是只剩 c1 c2 c3（实测）。A 仍是 topic。

fork-point 的默认值：

- 命令行写了 B，默认关闭，B 按字面用。所以上面 `git rebase topic child` 冲突了。
- 省略 B（用分支配置的 upstream）时默认打开（代码阅读：`builtin/rebase.c:1654-1655`；手册：`git-rebase.adoc:438-440`）。
  实测：`git branch --set-upstream-to=topic child` 之后，站在 child 上直接 `git rebase`，得到正确结果。
- `--keep-base` 时默认关闭（`builtin/rebase.c:1328-1329`）。

`git branch --set-upstream-to=topic child`：把 child 的 upstream 设为本地分支 topic。实测它写入的配置是
`branch.child.remote = .`（`.` 表示本仓库）与 `branch.child.merge = refs/heads/topic`。

fork-point 依赖 reflog。以下情况会找不到：reflog 被清掉；reflog 过期（`git gc` 会调用 `git reflog expire`，
从当前 tip 可达的记录默认保留 90 天，不可达的默认保留 30 天，见手册 `Documentation/config/gc.adoc` 的
`gc.reflogExpire` 与 `gc.reflogExpireUnreachable`；父分支被改写后，旧 tip 就属于不可达的那一类）；
父分支是在别的仓库里改写后 fetch 过来的，本地 reflog 里没有记到旧值。
实测：`git reflog expire --expire=now --all` 之后，`git merge-base --fork-point` 退出码为 1，
`git rebase --fork-point topic child` 的 todo 退回 `pick t2;pick c1;pick c2;pick c3`，与不加时相同，也就同样会冲突。
找不到时它不报错，只是安静地退回按字面用 B。

`git reflog expire --expire=now --all`：把所有 ref 的 reflog 里早于"现在"的记录删掉，也就是清空。例子用它模拟 reflog 丢失。

## 一次搬整叠：`--update-refs`

另一种做法是不分两步，直接把整叠一起搬。回到原始仓库（topic、child 都没动过）：

```bash
git rebase main child
```

搬 t1 t2 c1 c2 c3，child 正确了，但 topic 还停在旧 t2 上，不再是 child 的祖先（实测）。叠放关系断了。

```bash
git rebase --update-refs main child
```

- `--update-refs`：要搬的提交中，凡是有别的本地分支指着的，搬完后把那个分支也改指到对应的新提交（手册：`git-rebase.adoc:629-638`）。

todo 在 t2 之后多了一行（实测）：

```text
pick t1
pick t2
update-ref refs/heads/topic
pick c1
pick c2
pick c3
```

执行完：

```text
Successfully rebased and updated refs/heads/child.
Updated the following refs with --update-refs:
	refs/heads/topic
```

topic = o0 m1 m2 m3 t1 t2，而且正好是 `child~3`（实测）。这些 `update-ref` 行是生成 todo 时，
按每个 pick 的提交上挂着的分支名插进去的（代码阅读：`sequencer.c:6444-6505` 的 `add_decorations_to_list`，
`6511` 的 `todo_list_add_update_ref_commands`）。`-i` 时在 todo 里删掉某一行，那个分支就不更新
（实测：编辑器换成 `sed -i "/^update-ref /d"`，执行后 child 已搬好，topic 仍是 `o0 m1 t1 t2`）。

`rebase.updateRefs=true` 相当于每次都加 `--update-refs`（实测）；`--no-update-refs` 在单次里关掉它。

一个限制：被别的 worktree 检出的分支不会被更新（手册）。实测把 topic 检出到另一个 worktree 后再执行，
todo 里没有 `update-ref` 行，原位置换成了一行注释：

```text
# Ref refs/heads/topic checked out at '/tmp/rebase-onto.Ur19Xg/wt-topic'
```

执行后 topic 仍是 `o0 m1 t1 t2`（代码阅读：`sequencer.c:6480-6485`）。

## 两种做法怎么选

- 父分支还没改写、要把整叠一起挪到新底座上：`git rebase --update-refs <新底座> <最上层分支>`，一次完成，
  中间每一层都跟着更新。
- 父分支已经单独改写过（在它自己的 worktree 里 rebase、amend 了）：对每个子分支执行
  `git rebase --onto <父的新tip> <父的旧tip> <子>`，从下往上一层一层做。旧 tip 按上一节的办法找。
- 要求每一步都可以被脚本复查时，用 `--onto` 并把三个参数都写成确定的值（sha 或 ref 名），不依赖 reflog、
  不依赖当前在哪个分支上、不依赖 `rebase.updateRefs` 之类的个人配置。
