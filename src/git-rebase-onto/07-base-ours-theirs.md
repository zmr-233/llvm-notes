# 读懂三方冲突块：base、ours、theirs

我用一个很小的例子，把 `<<<<<<<`、`|||||||`、`=======`、`>>>>>>>` 和 base/ours/theirs 从头讲一遍。下面的输出都是我在本机实际跑出来的。

## 三个名字指的是三份完整的文件

三方合并的输入是同一个文件的三个完整版本：

- **base**：两边分头改之前的共同起点。
- **ours**：一边改完的样子。
- **theirs**：另一边改完的样子。

git 不直接拿 ours 和 theirs 比，而是拿 base 分别和两边比。每一段它只问一个问题：和 base 相比，哪一边变了。

- 只有一边变了，就取变了的那边。
- 两边变得一样，就取这个结果。
- 两边都变了而且不一样，git 不替你决定，把三份原文并排写进文件，这就是冲突块。

## 对照：同一个 base，换五种改法

下面是一个三行文件，base 是 `a b c`。命令是 `git merge-file -p --diff3 ours base theirs`，前三栏是三份文件的内容，最后一栏是 git 的处理：

```
     base    ours    theirs   git 的处理
1    a b c   a b c   a B c    只有 theirs 动了 b，自动取 theirs：a B c
2    a b c   a X c   a B c    两边都动了 b，改得不一样：冲突
3    a b c   a c     a b c    只有 ours 动了 b（删掉），自动取 ours：a c
4    a b c   a c     a B c    两边都动了 b（一边删，一边改）：冲突
5    a b c   a B c   a B c    两边改得一样，自动取：a B c
```

第 2 种写进文件的是：

```
a
<<<<<<< ours        从下一行到 ||||||| 之前，是 ours 在这个位置的原文
X
||||||| base        从下一行到 ======= 之前，是 base 在这个位置的原文
b
=======             从下一行到 >>>>>>> 之前，是 theirs 在这个位置的原文
B
>>>>>>> theirs
c
```

第 4 种写进文件的是：

```
a
<<<<<<< ours        ours 在这个位置什么都没有，所以两行标记紧挨着
||||||| base
b
=======
B
>>>>>>> theirs
c
```

三点要记住：

- 块里三段都是原文，不是 diff，里面没有 `+`、`-`。
- 块外面的 `a` 和 `c` 是 git 已经合好的部分，不用管。
- 块的范围是两边改动碰到的所有行合起来。

读一个块的顺序是：先看中间 base，知道原来是什么。再拿上面的 ours 和 base 比，看出 ours 做了什么。再拿下面的 theirs 和 base 比，看出 theirs 做了什么。然后决定这两件事合起来应该得到什么，用这个结果替换从 `<<<<<<<` 到 `>>>>>>>` 的所有行，包括四行标记。

第 2 种要看意图：留 X、留 B，或者写一行兼顾两边。第 4 种要回答的是 b 这一行还该不该存在。如果删它是对的，结果就是 `a c`，theirs 对 b 的修改跟着一起消失。

## rebase 里谁是 base、谁是 ours、谁是 theirs

rebase 先切到新的底座，再把要重放的提交一个一个 pick 上去。每 pick 一个，就是一次三方合并：

- **ours** = `HEAD`，也就是正在重建的分支，已经重放到上一个提交为止。工具把它标成「新base」。
- **theirs** = 正在重放的这个提交。git 把它记在 `REBASE_HEAD`，工具标成「本提交」。
- **base** = 这个提交在原历史里的父提交，即 `REBASE_HEAD^`。pick 一个提交，就是把「父提交到它」这段改动搬到 HEAD 上，所以起点取它的父提交。git 原生的标记直接写成 `parent of <sha>`。

注意这和 `git merge` 的习惯相反。merge 时 ours 是你所在的分支；rebase 时 ours 是你要接上去的那一边，你自己的提交反而是 theirs。工具改标签就是为了避免这个混淆。

## 按你的情况缩小做一个，实跑

构造三个提交：release；「push/pop（半成品）」对应 558ee1c，缩进是歪的；「加 printB（顺手格式化）」对应 664a388，它加了 printB，同时把缩进修正了。然后照 recall 的做法，用 `git rebase --onto <pp>^ <pp> scaffold` 摘掉 push/pop。停下时文件里是这样的，标签是 git 原生的：

```
class P {
public:
  void printA(int x);
  void printB(int x);
  void printC(int x);
<<<<<<< HEAD
||||||| parent of 63fc0a7 (加 printB（顺手格式化）)
  // push/pop
  void printPushPopImm(const MCInst *MI,
                             raw_ostream &O);
=======
  // push/pop
  void printPushPopImm(const MCInst *MI,
                       raw_ostream &O);
>>>>>>> 63fc0a7 (加 printB（顺手格式化）)
};
```

三份原文分别用下面三条命令看：

```
git show HEAD:P.h            ours：release 的样子，没有 push/pop
git show REBASE_HEAD^:P.h    base：push/pop 提交之后的样子，缩进是歪的
git show REBASE_HEAD:P.h     theirs：加了 printB、缩进修正之后的样子
```

更直观的是看 base 出发的两个 diff，冲突就在这两个 diff 碰到同一行的地方：

```
git diff REBASE_HEAD^ HEAD -- P.h           base -> ours
   void printC(int x);
-  // push/pop
-  void printPushPopImm(const MCInst *MI,
-                             raw_ostream &O);
 };

git diff REBASE_HEAD^ REBASE_HEAD -- P.h    base -> theirs
   void printA(int x);
+  void printB(int x);
   void printC(int x);
   // push/pop
   void printPushPopImm(const MCInst *MI,
-                             raw_ostream &O);
+                       raw_ostream &O);
```

ours 要删掉这 3 行，theirs 要改其中 1 行，这就是第 4 种。ours 删的范围是 3 行，所以块覆盖了这 3 行，虽然 theirs 只动了最后一行。theirs 加的 printB 离得远，git 自动合进去了，所以它出现在块外面。

合起来的判断是：这 3 行不该留在 scaffold 里，因为 push/pop 要撤出去；对其中一行的缩进修改，随着这一行一起走。所以用空内容替换整块。删掉后：

```
git diff HEAD -- P.h        重放后的这个提交，在这个文件里只剩加 printB
   void printA(int x);
+  void printB(int x);
   void printC(int x);
```

`add` 并 `rebase --continue` 之后，拿新 scaffold 和旧 scaffold 比：

```
git diff scaffold 63fc0a7   新 scaffold 比旧 scaffold 少的部分
   void printC(int x);
+  // push/pop
+  void printPushPopImm(const MCInst *MI,
+                       raw_ostream &O);
```

少掉的正好是 push/pop 那块，而且缩进已经修正。recall 之后，`$R` 工作区里未暂存的差就是这一段。修缩进的改动没有丢，它跟着 push/pop 进了原料。

## 回到你贴的那块

- `<<<<<<< ours: 新base` 下一行紧接着就是 `||||||| base`：ours 段是空的，所以是第 4 种。
- `||||||| base` 下面 6 行，是 558ee1c 写的原样。
- `=======` 下面 6 行，是 664a388 的版本。和 base 段逐行比，只有最后一行 `const MCSubtargetInfo &STI, raw_ostream &O);` 前面的空格少了。
- 664a388 在这个文件里加的那 3 行（让 hunk 头从 -81 变成 +84 的那 3 行）不在块里，git 已经合在块外面了。

在 forge 上可以用同样的命令看三份原文和两个 diff。先把 banner 第一行 `export R=... WT=...` 粘进 shell：

```bash
f=llvm/lib/Target/RISCV/MCTargetDesc/RISCVInstPrinter.h
git -C $WT diff REBASE_HEAD^ HEAD -- $f           # base -> ours：应当只是删掉 558ee1c 在这个文件加的行
git -C $WT diff REBASE_HEAD^ REBASE_HEAD -- $f    # base -> theirs：664a388 在这个文件的全部改动
```

解法和小例子一样：删掉从 `<<<<<<<` 到 `>>>>>>>` 的全部行，然后

```bash
git -C $WT diff HEAD -- $f     # 只剩 664a388 自己的那 3 行，没有 printRegisterList / printPushPopImm
git -C $WT add -A && git -C $WT rebase --continue
just rebuild --keep
```

## 摘掉 C 时停在 X：ours 不总是 C^

读完上面几节，容易这样复述：

```
git rebase --onto C^ C branch      摘掉 C
ours   = C^
base   = X^
theirs = X                         X 是停下来的那个提交
```

再碰上 X 紧跟在 C 后面（X^ == C），就变成 ours = C^、base = C、theirs = X。于是 ours 看起来是 base 的父提交，开始纠结「ours 和 base 到底什么关系」。

这段复述里 base 和 theirs 是对的，base 只由 X 决定，就是 X^。ours 那一行不对。ours 是 rebase 停下那一刻的 HEAD，也就是 C^ 加上 C 和 X 之间那些提交重放后的新副本。只有 X 是 C 之后第一个被重放的提交时，还没有重放过任何提交，ours 才正好等于 C^。一般形式是：

```
原历史      C^ -> C -> C1 -> C2 -> ... -> X
重放到 X 时
ours   = HEAD = C^ + C1' + C2' + ...     C1' 是 C1 重放后的新提交
base   = X^   = 原历史里 X 的父提交
theirs = X
```

在 C 和 X 之间插一个和冲突文件无关的提交 M，X 就不再紧跟 C：

```bash
git init -q -b rel demo && cd demo && git config merge.conflictStyle diff3
printf 'a\nc\n' > f; echo x > g; git add . && git commit -qm release
git switch -qc br
printf 'a\nb\nc\n' > f; git commit -qam C      # C 在 f 里加了 b
echo y >> g;            git commit -qam M      # M 只动 g，和 f 无关
printf 'a\nB\nc\n' > f; git commit -qam X      # X 把 b 改成 B
C=$(git rev-parse HEAD~2)
git rebase --onto $C^ $C br >/dev/null 2>&1    # 摘掉 C：M 干净重放，停在 X
echo "ours   = $(git log -1 --format='%h %s' HEAD)   它的父 = $(git log -1 --format='%h %s' HEAD^)"
echo "base   = $(git log -1 --format='%h %s' REBASE_HEAD^)"
echo "theirs = $(git log -1 --format='%h %s' REBASE_HEAD)"
```

实跑输出（sha 每次不同）：

```
ours   = 103288f M   它的父 = fb7b587 release     重放出来的新 M，不是 C^
base   = f978ae0 M                                原历史里的 M
theirs = 1c4343b X
```

f 里的冲突块，和前面第 4 种一样是一删一改：

```
a
<<<<<<< HEAD
||||||| parent of 1c4343b (X)
b
=======
B
>>>>>>> 1c4343b (X)
c
```

所以「ours 和 base 无关」要收窄着说。按定义两者确实无关：base 只看 X，ours 只看新分支重放到了哪里。但在「摘掉 C」这种 rebase 里，两者的内容有固定关系。base 是 C^ 加 C 加 C1…，ours 是 C^ 加 C1'…；C 和 X 之间的提交都干净重放时，两者只差一个 C。同一次实跑：

```
git diff REBASE_HEAD^ HEAD -- f     base -> ours
 a
-b
 c

git show C -- f                     C 自己的改动
 a
+b
 c
```

不管 X 是第几个提交，base 到 ours 这个 diff 都是「撤销 C」。X^ == C 只是让 ours 恰好等于 C^，看起来 ours 和 base 像父子关系；换成别的 X，两者不再是父子，这个 diff 不变。如果 C 和 X 之间某个提交也冲突过，是手工解的，ours 和 base 之间还会多出那次解法带来的差别。

由此可以推出：摘掉 C 的 rebase 停下，一定是因为 X 的改动碰到了「撤销 C」动过的行。冲突块里 ours 那一段，是这块区域在 C 之前的样子：

- C 新加的行：ours 段是空的，就是上面的一删一改。
- C 改过的行：ours 段是 C 之前的原文。比如 C 把 b 改成 b2，X 又把 b2 改成 B，停下时是：

```
a
<<<<<<< HEAD
b
||||||| parent of 3c8c9e4 (X)
b2
=======
B
>>>>>>> 3c8c9e4 (X)
c
```
