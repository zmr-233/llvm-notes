# call 与 tail：目标文件里是 auipc 加 jalr，链接时再缩短。讲解见 ../04-control.md 第 4 节。
#
# ---- cell 1：目标文件 ----
#
# -mrelax：允许链接器松弛（链接时把指令序列改短）。
#
#   $ just dis ex/call.s -march=rv32i -mrelax
#
#     00000000 <f>:
#            0: 00000097      auipc   ra, 0x0
#            4: 000080e7      jalr    ra, 0x0(ra) <f>
#            8: 00000317      auipc   t1, 0x0
#            c: 00030067      jalr    zero, 0x0(t1) <f+0x8>
#
#     00000010 <g>:
#           10: 00008067      jalr    zero, 0x0(ra)
#
# 看点：
#   - call g 是 auipc ra 加 jalr ra, 0(ra)；tail g 是 auipc t1 加 jalr zero, 0(t1)。
#   - 立即数都是 0，等链接器填。tail 用 t1 暂存地址，因为它不能改 ra：g 要直接返回到 f 的调用者。
#
# ---- cell 2：重定位 ----
#
#   $ just reloc ex/call.s -march=rv32i -mrelax
#
#      Offset     Info    Type                Sym. Value  Symbol's Name + Addend
#     00000000  00000313 R_RISCV_CALL_PLT       00000010   g + 0
#     00000000  00000033 R_RISCV_RELAX                     0
#     00000008  00000313 R_RISCV_CALL_PLT       00000010   g + 0
#     00000008  00000033 R_RISCV_RELAX                     0
#
# 看点：
#   - 每对 auipc、jalr 只有一条 R_RISCV_CALL_PLT，挂在 auipc 上，覆盖两条指令。
#   - 旁边的 R_RISCV_RELAX 允许链接器改写这一对。
#
# ---- cell 3：链接之后 ----
#
#   $ just link ex/call.s -march=rv32i -mrelax
#
#     00000000 <f>:
#            0: 008000ef      jal     ra, 0x8 <g>
#            4: 0040006f      jal     zero, 0x8 <g>
#
#     00000008 <g>:
#            8: 00008067      jalr    zero, 0x0(ra)
#
# 看点：
#   - g 就在几字节之外，两对 8 字节的 auipc、jalr 各缩成一条 4 字节的 jal，后面的代码跟着前移。
#   - call 缩成 jal ra，tail 缩成 jal zero。
#
# ---- cell 4：开 C 扩展再链接 ----
#
#   $ just link ex/call.s -march=rv32ic -mrelax
#
#     00000000 <f>:
#            0: 2011          c.jal   0x4 <g>
#            2: a009          c.j     0x4 <g>
#
#     00000004 <g>:
#            4: 8082          c.jr    ra
#
# 看点：
#   - 进一步缩成 2 字节的 c.jal、c.j。
#
# ---- cell 5：不允许松弛 ----
#
# -mno-relax：汇编器不附 R_RISCV_RELAX，链接器只填立即数，不改短。
#
#   $ just link ex/call.s -march=rv32i -mno-relax
#
#     00000000 <f>:
#            0: 00000097      auipc   ra, 0x0
#            4: 010080e7      jalr    ra, 0x10(ra) <g>
#            8: 00000317      auipc   t1, 0x0
#            c: 00830067      jalr    zero, 0x8(t1) <g>
#
#     00000010 <g>:
#           10: 00008067      jalr    zero, 0x0(ra)
#
# 看点：
#   - 还是两对 auipc、jalr，g 仍在 0x10。
#   - call 的 auipc 在 0，jalr 立即数 0x10；tail 的 auipc 在 8，jalr 立即数 8。都是 g 减去 auipc 的地址。

f:
  call  g
  tail  g
g:
  ret
