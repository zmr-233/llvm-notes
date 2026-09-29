# 手写汇编里 beq 的目标太远时，汇编器怎么处理。讲解见 ../04-control.md 第 3 节。
#
# SPACE 是汇编器里的符号，值由命令行给出：-Wa,--defsym,SPACE=N 里，-Wa, 把逗号后面的参数
# 转交给汇编器，--defsym SPACE=N 定义符号 SPACE 的值为 N。.space SPACE 就是 N 字节的 0。
#
# ---- cell 1：16 字节 ----
#
#   $ just dis ex/far.s -march=rv32i -Wa,--defsym,SPACE=16
#
#     00000000 <f>:
#            0: 00b50a63      beq     a0, a1, 0x14 <L>
#                     ...
#
#     00000014 <L>:
#           14: 00008067      jalr    zero, 0x0(ra)
#
# ---- cell 2：8 KiB ----
#
#   $ just dis ex/far.s -march=rv32i -Wa,--defsym,SPACE=8192
#
#     00000000 <f>:
#            0: 00b51463      bne     a0, a1, 0x8 <f+0x8>
#            4: 0040206f      jal     zero, 0x2008 <L>
#                     ...
#
#     00002008 <L>:
#         2008: 00008067      jalr    zero, 0x0(ra)
#
# ---- cell 3：1 MiB ----
#
#   $ just dis ex/far.s -march=rv32i -Wa,--defsym,SPACE=1048576
#
#     ex/far.s:45:17: error: fixup value out of range
#       beq   a0, a1, L
#                     ^
#     error: recipe `dis` failed with exit code 1
#
# 看点：
#   - cell 1：beq 原样保留。
#   - cell 2：汇编器把 beq 改写成 bne 跳过下一条，加一条 jal，和编译器生成的一样（far.c 的 mid）。
#   - cell 3：改写后的 jal 也够不着，汇编器报错。它不会再换成 auipc 加 jalr：那需要一个空闲寄存器，
#     汇编器不知道哪个寄存器此刻没在用。

f:
  beq   a0, a1, L
  .space SPACE
L:
  ret
