// RV64 上一个任意的 64 位常数最多要 8 条指令。条数超过门限，编译器改从内存里的常量池读。
// 讲解见 ../02-constants.md 第 4 节。
//
// ---- cell 1：默认 ----
//
// -march=rv64im -mabi=lp64：64 位整数寄存器，long 是 64 位。
// -mllvm -riscv-no-aliases 让汇编按真实指令打印。
//
//   $ just asm ex/li64.c -march=rv64im -mabi=lp64 -O2 -mllvm -riscv-no-aliases
//
//     .LCPI0_0:
//     c64:
//             lui     a0, %hi(.LCPI0_0)
//             ld      a0, %lo(.LCPI0_0)(a0)
//             jalr    zero, 0(ra)
//
// 看点：
//   - .LCPI0_0 是常量池里存这个 8 字节常数的位置（存数据的那行是汇编指示，被 just asm 删掉了）。
//   - 取值用的是 lui %hi / ld %lo，和 03-addressing.md 里访问全局变量一样。
//
// ---- cell 2：把门限调到 8 ----
//
// -mllvm -riscv-max-build-ints-cost=8：装常数最多允许 8 条指令，超过才用常量池。
//
//   $ just dis ex/li64.c -march=rv64im -mabi=lp64 -O2 -mllvm -riscv-max-build-ints-cost=8
//
//     0000000000000000 <c64>:
//            0: 00247537      lui     a0, 0x247
//            4: 8ad50513      addi    a0, a0, -0x753
//            8: 00e51513      slli    a0, a0, 0xe
//            c: c4d50513      addi    a0, a0, -0x3b3
//           10: 00c51513      slli    a0, a0, 0xc
//           14: 5e750513      addi    a0, a0, 0x5e7
//           18: 00d51513      slli    a0, a0, 0xd
//           1c: ef050513      addi    a0, a0, -0x110
//           20: 00008067      jalr    zero, 0x0(ra)
//
// 看点：
//   - lui、addi 先装出最高的一段，之后每次 slli 左移腾出低位，再 addi 补上 12 位，共 8 条。

long c64(void) { return 0x123456789abcdef0; }
