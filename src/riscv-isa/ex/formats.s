# 六种 32 位指令格式各举一两条，看编码里每个字段落在哪几位。讲解见 ../01-encoding.md。
#
# ---- cell 1：反汇编 ----
#
# -march=rv32i 只有基础整数指令集，没有 C 扩展，每条指令都是 4 字节。
#
#   $ just dis ex/formats.s -march=rv32i
#
#     00000000 <L>:
#            0: 00c58533      add     a0, a1, a2
#            4: fff58513      addi    a0, a1, -0x1
#            8: 00812503      lw      a0, 0x8(sp)
#            c: 00a12423      sw      a0, 0x8(sp)
#           10: feb508e3      beq     a0, a1, 0x0 <L>
#           14: 12345537      lui     a0, 0x12345
#           18: 12345517      auipc   a0, 0x12345
#           1c: fe5ff0ef      jal     ra, 0x0 <L>
#           20: 00008067      jalr    zero, 0x0(ra)
#
# 看点：
#   - 每行是「偏移: 编码  指令」，编码是这条指令的 32 位值，按十六进制打印。
#   - 每条编码的最低 7 位是 opcode，最低两位都是 11，表示这是一条 32 位指令。
#   - beq 在偏移 0x10，跳回 L（偏移 0），偏移量是 -16；jal 在 0x1c，偏移量是 -28。
#     这两个数怎么从编码里拆出来，见 01-encoding.md 第 4 节。

L:
  add   a0, a1, a2
  addi  a0, a1, -1
  lw    a0, 8(sp)
  sw    a0, 8(sp)
  beq   a0, a1, L
  lui   a0, 0x12345
  auipc a0, 0x12345
  jal   ra, L
  jalr  zero, 0(ra)
