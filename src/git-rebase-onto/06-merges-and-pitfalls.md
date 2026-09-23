# 06 merge 提交与其他坑

前几篇没覆盖的几种情况：C 上有 merge 提交；C 被别的 worktree 检出；工作区不干净。最后把各篇里的坑集中列一遍。

例子：`examples/06-merges-and-pitfalls/run.sh`。

## merge 提交默认被拍平

例子让 child 在 c3 之后 merge 了 side（带进 s1），再提交 c4：

```text
* c4
*   Merge branch 'side' into child
|\
| * s1
* | c3
* | c2
* | c1
* | t2
* | t1
|/
* m1
* o0
```

```bash
git rebase --onto main topic child
```

`topic..child` = c1 c2 c3 s1 合并提交 c4。生成 todo 时 `max_parents = 1`，merge 提交被去掉
（代码阅读：`sequencer.c:6170-6171`），s1 是普通提交，留下：

```text
要搬: pick c1;pick c2;pick c3;pick s1;pick c4
```

结果 child = o0 m1 m2 m3 c1 c2 c3 s1 c4，`main..child` 里没有 merge（实测）。s1 从"merge 进来的另一条线"
变成了 child 线上的一个普通提交，排在 c3 之后。merge 提交本身的内容（包括解决冲突时手写的部分）没有被重放：
如果原来的 merge 有冲突解决，拍平后要在重放 s1 或它之后的提交时重新解决一遍（推论）。

## `--rebase-merges`

```bash
git rebase --rebase-merges --onto main topic child
```

- `--rebase-merges`（`-r`）：保留 merge 结构。todo 里多出 `label`（给当前 HEAD 起个临时名字）、`reset`（把 HEAD 移到某个 label 或提交）、
  `merge`（重新做一次合并）三种指令。

实测生成的 todo：

```text
label onto
reset be22c73 # m1
pick 0a83bba # s1
label side
reset onto
pick fd05a98 # c1
pick b0ee4bb # c2
pick 4b0498f # c3
merge -C bb0f573 side # Merge branch 'side' into child
pick 8f82a96 # c4
```

逐行：

- `label onto`：把起点（A，这里是 main）记为 `onto`。
- `reset be22c73 # m1`、`pick s1`、`label side`：在 m1 上重放 s1，记为 `side`。s1 的祖先里没有 B（topic），
  默认（`no-rebase-cousins`）保留它原来的分叉点 m1，而不是接到 A 上（手册）。父没变，所以 s1 就是原来那个提交（实测断言了 `child^^2` 等于 side）。
- `reset onto`、`pick c1 c2 c3`：回到 A，重放 child 自己的提交。
- `merge -C bb0f573 side`：重新合并 `side`，`-C <提交>` 表示沿用原 merge 提交的消息。
- `pick c4`。

结果保留了一个 merge（实测）：

```text
* c4
*   Merge branch 'side' into child
|\
| * s1
* c3
* c2
* c1
```

但 merge 是重新做的：原 merge 里手工解决的冲突、手工追加的修改不会被带过来，要重新解决
（手册：`git-rebase.adoc:519-527` 的 `--rebase-merges` 条目，"Any resolved merge conflicts or manual amendments
in these merge commits will have to be resolved/re-applied manually"）。

## 分支被别的 worktree 检出

```bash
git worktree add ../wt-child child
git rebase --onto main topic child
```

- `git worktree add <路径> <分支>`：在 `<路径>` 建一个新的工作区，检出 `<分支>`。一个分支同一时刻只能被一个 worktree 检出。

第二条命令直接报错，退出码 128（实测）：

```text
fatal: 'child' is already used by worktree at '/tmp/rebase-onto.g8EkUg/wt-child'
```

C 是本地分支名时，rebase 先检查它有没有被别的 worktree 检出（代码阅读：`builtin/rebase.c:1704` 的 `die_if_checked_out`）。
到那个 worktree 里执行，省略 C 即可：

```bash
git -C ../wt-child rebase --onto main topic
```

- `-C <路径>`：先切换到 `<路径>` 再执行后面的 git 命令，效果等于 `cd <路径> && git …`。

实测成功，child = o0 m1 m2 m3 c1 c2 c3。脚本里给出 rebase 处方时，写成"在 C 的 worktree 里、省略 C"的形式更稳：
不依赖 C 当前被谁检出，也不会误改当前 worktree 所在的分支。

## 工作区不干净

```bash
echo dirty >> m3.txt
git rebase --onto main topic child
```

工作区有未提交的修改时拒绝开始（实测，退出码 1）：

```text
error: cannot rebase: You have unstaged changes.
error: Please commit or stash them.
```

```bash
git rebase --autostash --onto main topic child
```

- `--autostash`：开始前把未提交的修改存成一个 stash，结束后再应用回去（手册：`git-rebase.adoc:605-611`）。
  `rebase.autoStash=true` 相当于每次都加（手册：`Documentation/config/rebase.adoc`）。

实测输出里有 `Created autostash: …` 和 `Applied autostash.`。注意应用回去的位置是结束时的 HEAD，也就是 child，
而不是开始时所在的 main。例子里修改的是 `m3.txt`，rebase 后 child 上正好也有 `m3.txt`，所以能干净地应用上。

应用不上时的两个实测：

- 改成 `--onto side topic child`：结束时的 child 上没有 `m3.txt`，stash 应用冲突。rebase 本身成功，
  但输出里有 `Your local changes are stashed, however applying them resulted in conflicts.`，
  `git status --short` 是 `DU m3.txt`（我方删除、对方修改），stash 留在列表里。
- 中途冲突后 `--abort`：`--abort` 也会应用 autostash，而 `--abort` 把 HEAD 放回 C（04 篇），于是在 main 上做的修改被应用到
  child 上，同样得到 `DU m3.txt`，stash 留在列表里。开始时站在 main 上、以为放弃之后会回到 main 的人，
  会发现自己在 child 上，还多了一个冲突。

在别的分支上有未提交修改时，先自己 `git stash` 或提交，比依赖 `--autostash` 把修改带到另一个分支上更清楚。

## 坑的清单

这些情况都不报错，或者报错信息不指向真正的原因。括号里是详细讲解所在的篇。

- B 写成了不是 C 祖先的提交。`B..C` 照样成立，搬的比想要的多（02）。执行前看 `git log --oneline B..C`。
- 省略 C 且当前不在 C 上。C 取了当前分支，改写的是别的分支（02）。
- C 写成 sha 或 `refs/heads/<名字>`。rebase 成功，但只更新了游离 HEAD，分支没动（02）。
- 父分支改写后直接 `git rebase <父> <子>`。父的旧提交被当成子的提交一起搬，内容改过的会冲突（05）。
- 预检比的是 B 那边，不是 A。副本只在 B 那边时，改动会从结果里消失，唯一的提示是一行 warning（03）。
  用 `git cherry -v A C` 核对。
- 副本在 A 上、之后又被改过：`--onto` 下这个提交会被重放并冲突，不带 `--onto` 时则被预检剔除（03）。
- rebase 冲突时 ours 是新底座那边，theirs 是你自己分支上的提交，与 merge 时相反（04）。
- `--abort` 之后 HEAD 停在 C 上，不回到开始时所在的分支（04）。
- `topic@{1}` 不一定是父分支的旧 tip，要看 `git reflog topic`（05）。
- 显式写了 B 时 fork-point 关闭；省略 B 时打开。同一个 B，写出来和不写结果可能不同（05）。
- fork-point 找不到分叉点时不报错，安静地退回按字面用 B（05）。
- `--update-refs` 不更新被别的 worktree 检出的分支，只在 todo 里留一行注释（05）。
- C 上的 merge 默认被拍平；`--rebase-merges` 保留结构但重新做 merge。两种情况下 merge 里的冲突解决都不会被带过来（本篇）。
- `--autostash` 把修改应用到结束时的分支上，`--abort` 时也是 C 而不是开始时的分支；应用冲突时 stash 留在列表里（本篇）。
- 个人配置会改变行为：`rebase.updateRefs`、`rebase.autoSquash`、`rebase.autoStash`、`rebase.forkPoint`、
  `merge.conflictStyle`。写给别人照做的命令时，要么显式写出对应选项，要么说明依赖的配置。
