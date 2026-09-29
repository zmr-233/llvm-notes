# %pcrel_hi 与 %pcrel_lo：auipc 加 jalr 跳到 1 MiB 以外的 label。讲解见 ../03-addressing.md 第 4 节。
#
# 设计：auipc 在偏移 4，label 在偏移 0x100c04，两者相差 D = 0x100c00。D 的低 12 位是 0xc00，
# 不小于 0x800，能看到高 20 位的进位。本目录另外两个文件 pcrel-gap.s、pcrel-bad.s 是它的变体，
# 它们的 cell 也写在这里。
#
# ---- cell 1：汇编器直接算出立即数 ----
#
# -mno-relax 关掉链接器松弛。同一文件里的 label 距离已定，汇编器自己把两个立即数填好。
#
#   $ just dis ex/pcrel.s -march=rv32i -mno-relax
#
#     00000000 <f>:
#            0: 00b51663      bne     a0, a1, 0xc <skip>
#            4: 00101297      auipc   t0, 0x101
#            8: c0028067      jalr    zero, -0x400(t0) <label>
#
#     0000000c <skip>:
#                     ...
#
#     00100c04 <label>:
#       100c04: 00008067      jalr    zero, 0x0(ra)
#
# 看点：
#   - auipc t0, 0x101：t0 = 4 + 0x101000 = 0x101004。高 20 位是 0x101 而不是 0x100，进了 1。
#   - jalr zero, -0x400(t0)：跳到 0x101004 - 0x400 = 0x100c04，正好是 label。
#   - -0x400 = D - (0x101 << 12)，只和 D 有关。jalr 自己的地址 8 没有参与。
#   - 中间一行 ... 是 objdump 对 .space 那一大段 0 的省略。
#
# ---- cell 2：开松弛时留给链接器的重定位 ----
#
# -mrelax 打开链接器松弛。汇编器不再自己填，而是给两条指令各留一条重定位。
#
#   $ just reloc ex/pcrel.s -march=rv32i -mrelax
#
#      Offset     Info    Type                Sym. Value  Symbol's Name + Addend
#     00000000  00000310 R_RISCV_BRANCH         0000000c   skip + 0
#     00000004  00000517 R_RISCV_PCREL_HI20     00100c04   label + 0
#     00000004  00000033 R_RISCV_RELAX                     0
#     00000008  00000418 R_RISCV_PCREL_LO12_I   00000004   .Ltmp0 + 0
#     00000008  00000033 R_RISCV_RELAX                     0
#
# 看点：
#   - 偏移 4（auipc）：R_RISCV_PCREL_HI20，符号是 label。
#   - 偏移 8（jalr）：R_RISCV_PCREL_LO12_I，符号是 .Ltmp0，它就是源码里 1: 这个标签，
#     指向 auipc，不指向 label。
#   - R_RISCV_RELAX 表示这里允许链接器改写成更短的序列。
#
# ---- cell 3：链接器算出的结果 ----
#
#   $ just link ex/pcrel.s -march=rv32i -mrelax
#
#     00000000 <f>:
#            0: 00b51663      bne     a0, a1, 0xc <skip>
#
#     00000004 <.Ltmp0>:
#            4: 00101297      auipc   t0, 0x101
#            8: c0028067      jalr    zero, -0x400(t0) <label>
#
#     0000000c <skip>:
#                     ...
#
#     00100c04 <label>:
#       100c04: 00008067      jalr    zero, 0x0(ra)
#
# 看点：
#   - 和 cell 1 一模一样：ld.lld 从 jalr 的重定位找到 .Ltmp0，在那里找到 auipc 的重定位，
#     用同一个 D 算出低 12 位。
#   - .Ltmp0 在链接后的符号表里还在，所以反汇编多打印了一个 <.Ltmp0> 标签。
#
# ---- cell 4：auipc 和 jalr 之间插一条指令（ex/pcrel-gap.s）----
#
#   $ just dis ex/pcrel-gap.s -march=rv32i -mno-relax
#
#     00000000 <f>:
#            0: 00b51863      bne     a0, a1, 0x10 <skip>
#            4: 00101297      auipc   t0, 0x101
#            8: 00160613      addi    a2, a2, 0x1
#            c: c0028067      jalr    zero, -0x400(t0) <label>
#
#     00000010 <skip>:
#                     ...
#
#     00100c04 <label>:
#       100c04: 00008067      jalr    zero, 0x0(ra)
#
# 看点：
#   - jalr 从偏移 8 挪到了 0xc，立即数还是 -0x400。auipc 和 label 的位置没变，D 就没变。
#
# ---- cell 5：%pcrel_lo 里直接写 label（ex/pcrel-bad.s）----
#
#   $ just dis ex/pcrel-bad.s -march=rv32i
#
#     ex/pcrel-bad.s:6:16: error: could not find corresponding %pcrel_hi
#       jalr  zero, %pcrel_lo(label)(t0)
#                    ^
#     error: recipe `dis` failed with exit code 1
#
# 看点：
#   - 汇编器要在括号里的地址上找一条带 %pcrel_hi 的指令，label 那里是 ret，找不到，报错。

f:
  bne   a0, a1, skip
1:
  auipc t0, %pcrel_hi(label)
  jalr  zero, %pcrel_lo(1b)(t0)
skip:
  .space 0x100BF8
label:
  ret
