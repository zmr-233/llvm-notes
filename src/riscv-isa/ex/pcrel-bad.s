# pcrel.s 的错误写法：%pcrel_lo 的括号里写目标 label，而不是 auipc 的标签。
# cell 写在 pcrel.s 的 cell 5。

f:
  auipc t0, %pcrel_hi(label)
  jalr  zero, %pcrel_lo(label)(t0)
  .space 0x100BF8
label:
  ret
