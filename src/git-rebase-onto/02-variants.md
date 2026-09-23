# 02 写法对照

同一个实验仓库，A / B / C 换不同写法，逐条看要搬哪些提交、结果是什么、HEAD 停在哪。
每一条都是实测（02），先用 `todo_of` 看要搬的提交，再真跑一遍并断言结果。

例子：`examples/02-variants/run.sh`。

```text
o0 ─ m1 ─ m2 ─ m3                 main
     ├─ s1                        side
     └─ t1 ─ t2                   topic
             └─ c1 ─ c2 ─ c3      child
```

## 总览

每行的格式是：写法 → 要搬的提交 → 结果。除特别说明，执行前 HEAD 在 main 上，执行后 HEAD 在 child 上。

```text
git rebase main child                      搬 t1 t2 c1 c2 c3   → child = o0 m1 m2 m3 t1 t2 c1 c2 c3
git rebase --onto main topic child         搬 c1 c2 c3         → child = o0 m1 m2 m3 c1 c2 c3
git rebase --onto main topic~1 child       搬 t2 c1 c2 c3      → child = o0 m1 m2 m3 t2 c1 c2 c3
git rebase --onto child~2 child~1 child    搬 c3               → child = o0 m1 t1 t2 c1 c3            c2 被删
git rebase --onto child~3 child~1 child    搬 c3               → child = o0 m1 t1 t2 c3               c1 c2 被删
git rebase --onto main side child          搬 t1 t2 c1 c2 c3   → 与第一行相同，不报错
git rebase --onto main...topic topic child 搬 c1 c2 c3         → child = o0 m1 c1 c2 c3               t1 t2 被删
git rebase --onto x...y topic child        （x、y 有两个 merge-base）
                                                               → fatal: 'x...y': need exactly one merge base
git rebase --keep-base main child          搬 t1 t2 c1 c2 c3   → Current branch child is up to date.  底座不变
git rebase --onto main topic <child的sha>  搬 c1 c2 c3         → updated detached HEAD；child 分支不动
git rebase --onto main topic refs/heads/child
                                           搬 c1 c2 c3         → 同上
（在 child 上）git rebase --onto main topic
                                           搬 c1 c2 c3         → 与第二行相同
（在 main 上）git rebase --onto main topic 搬 m2 m3            → 两个都被丢弃，main 不变
git rebase --onto topic topic child        不搬                → Current branch child is up to date.
git rebase -f --onto topic topic child     搬 c1 c2 c3         → 逐个重放
```

下面逐条讲。

## 只换 B

```bash
git rebase main child                  # A = B = main，要搬 main..child
git rebase --onto main topic child     # A = main，B = topic，要搬 topic..child
git rebase --onto main topic~1 child   # A = main，B = topic~1 = t1，要搬 t1..child
```

- `main`（第一行的 B，同时是 A）：`main..child` = t1 t2 c1 c2 c3，全部接到 m3 上。
- `--onto main`：A = main，新底座。
- `topic` / `topic~1`：B。`topic~1` 表示 topic 的第一父提交往回一步，也就是 t1；`t1..child` 里就多了 t2。

三行的 A 相同，结果的差别全部来自 B。B 越往前，被当作"C 自己的提交"一起搬走的越多。

## 删提交

```bash
git rebase --onto child~2 child~1 child
```

- `child~2`（A）：c1。
- `child~1`（B）：c2。`c2..child` 只有 c3。
- `child`（C）。

c3 接到 c1 上，c2 从 child 的历史里消失。在线性历史上，`--onto X Y` 删掉的是 X 之后到 Y 为止（包括 Y）的那一段，
即 `X..Y`。要删 child 上从 c1 到 c2 这两个，写 `--onto child~3 child~1 child`：`t2..c2` = c1 c2，
c3 直接接到 t2 上，结果 child = o0 m1 t1 t2 c3（实测）。

被删的提交没有真的消失，还能从 `ORIG_HEAD`、`child@{1}` 找到（04 篇）。

## B 写成一个不相干的分支

```bash
git rebase --onto main side child
```

side 不是 child 的祖先，`side..child` 仍然成立：child 上所有不在 side 上的提交，也就是 m1 之后的 t1 t2 c1 c2 c3。
git 不检查 B 是不是 C 的祖先，也就不会报错。这一行的结果与 `git rebase main child` 完全相同，
看起来像一次正常的 rebase；只有在你本来只想搬 c1 c2 c3 的时候，才会发现 t1 t2 也被带过去了。

执行前看一眼 `git log --oneline B..C`（`--oneline`：每个提交一行，短 sha 加标题），确认要搬的就是你想搬的，
是避免这类问题最直接的办法。

## A 写成 `X...Y`

```bash
git rebase --onto main...topic topic child
```

- `--onto main...topic`：A 取 main 与 topic 的 merge-base，即 m1。这是 `--onto` 专有的写法，
  与 `rev-list` 里的 `...` 意思不同（手册：`git-rebase.adoc:217-219`；代码阅读：`builtin/rebase.c:1748-1758`）。
  X 或 Y 省略一个时，省略的那个取 HEAD（手册）。
- `topic`（B）：要搬 c1 c2 c3。

结果 child = o0 m1 c1 c2 c3，t1 t2 从 child 上被删掉，child 改为直接从 m1 分出。
实测里断言了 `child~3` 就是 m1（`main~2`）。

两个提交有不止一个 merge-base 时（例子里 x、y 都是 side 与 topic 的合并，只是父的顺序不同，merge-base 有 s1 和 t2 两个），
rebase 拒绝执行：

```text
fatal: 'x...y': need exactly one merge base
```

## `--keep-base`

```bash
git rebase --keep-base main child
```

- `--keep-base`：A 取 B 与 C 的 merge-base（这里是 m1），底座保持不变（手册：`git-rebase.adoc:223-228`）。
- `main`（B）：要搬 `main..child` = t1 t2 c1 c2 c3。

手册说它等价于 `git rebase --reapply-cherry-picks --no-fork-point --onto main...child main child`。
源码里也是这样拼的：`onto_name = upstream + "..." + branch`（代码阅读：`builtin/rebase.c:1740-1745`），
并默认关闭 fork-point、打开 `--reapply-cherry-picks`（`builtin/rebase.c:1319-1330`、`1507-1513`）。

A 已经是底座，历史线性，所以非交互执行时直接打印 `Current branch child is up to date.`，什么都不做。
它的用处在配合 `-i`：在不改变底座的前提下重排、合并、改写 C 上的提交。
todo 里列的是 t1 t2 c1 c2 c3（实测），说明 B 仍然是 main，t1 t2 也算 child 自己的提交。

## C 写成 sha

```bash
git rebase --onto main topic 4b0498fd68f321af9c030e2e8385349dda830f36
```

最后一个参数是 child 的 tip 的 sha，不是分支名。git 把它当作"一个提交"而不是"一个分支"（代码阅读：`builtin/rebase.c:1709-1714`）：

```text
Successfully rebased and updated detached HEAD.
```

结果留在游离 HEAD 上（`o0 m1 m2 m3 c1 c2 c3`），child 分支原封不动。要让 child 指过去，得自己
`git switch -C child`（`-C`：分支已存在也强制重置到当前 HEAD，并切过去）或 `git branch -f child HEAD`
（`-f`：分支已存在也强制改指到 HEAD，不切过去）。
写 `refs/heads/child` 也属于"不是分支名"：git 先拼 `refs/heads/<参数>` 去找本地分支，
`refs/heads/refs/heads/child` 不存在，于是退回按普通 rev 解析，结果同样是 `updated detached HEAD`（实测）。

## 省略 C

```bash
git switch child
git rebase --onto main topic           # 等同于 git rebase --onto main topic child
```

省略 C 时取当前 HEAD 所在的分支。站在 child 上，这与写出 child 完全相同。

站错分支是另一回事。在 main 上执行同一条命令，C 就是 main：

```text
$ git rebase --onto main topic
  | Rebasing (1/2)
  | dropping e6b991f359a9500475e46d27d5a09c67f68e226d m2 -- patch contents already upstream
  | Rebasing (2/2)
  | dropping 8383d433a9725f1d6c3a6833ca72a3edc795c5af m3 -- patch contents already upstream
  | Successfully rebased and updated refs/heads/main.
```

要搬 `topic..main` = m2 m3，接到 main（也就是 m3）上，重放后都没有改动，被丢弃。main 最后回到原来的 tip，
这次没有造成损失。但如果 A 写的是别的提交，main 就真的被改写了。写脚本或处方时把 C 写出来，
或者在 C 所在的 worktree 里执行，避免依赖"当前在哪个分支上"。

## 已经是最新

```bash
git rebase --onto topic topic child
```

A = B = topic，c1 的父提交已经是 topic，历史线性。`can_fast_forward` 判断为真，打印 `Current branch child is up to date.`，
不重放任何提交（代码阅读：`builtin/rebase.c:894-926`）。

加 `--force-rebase`（`-f`）跳过这个判断，照样逐个重放：

```text
Current branch child is up to date, rebase forced.
Rebasing (1/3)
Rebasing (2/3)
Rebasing (3/3)
```

真实环境里提交时间会变，于是得到三个 sha 不同、内容相同的新提交。例子固定了提交时间，
父、tree、作者、提交者、时间都没变，所以新提交的 sha 与原来相同（实测里断言了这一点）。
