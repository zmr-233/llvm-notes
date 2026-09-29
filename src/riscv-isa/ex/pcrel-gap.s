# pcrel.s 的变体：auipc 和 jalr 之间多一条 addi，jalr 后移 4 字节，label 的位置不变。
# cell 写在 pcrel.s 的 cell 4。

f:
  bne   a0, a1, skip
1:
  auipc t0, %pcrel_hi(label)
  addi  a2, a2, 1
  jalr  zero, %pcrel_lo(1b)(t0)
skip:
  .space 0x100BF4
label:
  ret
