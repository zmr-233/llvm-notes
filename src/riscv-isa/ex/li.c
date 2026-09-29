// 一个 32 位常数装进寄存器要几条指令。讲解见 ../02-constants.md。
//
// ---- cell 1：反汇编 ----
//
// -march=rv32im 不开 C，反汇编按十六进制打印立即数，方便和常数对照。
// -Os 按代码体积优化。
//
//   $ just dis ex/li.c -march=rv32im -mabi=ilp32 -Os
//
//     00000000 <c_2047>:
//            0: 7ff00513      addi    a0, zero, 0x7ff
//            4: 00008067      jalr    zero, 0x0(ra)
//
//     00000008 <c_minus2048>:
//            8: 80000513      addi    a0, zero, -0x800
//            c: 00008067      jalr    zero, 0x0(ra)
//
//     00000010 <c_12345000>:
//           10: 12345537      lui     a0, 0x12345
//           14: 00008067      jalr    zero, 0x0(ra)
//
//     00000018 <c_12345678>:
//           18: 12345537      lui     a0, 0x12345
//           1c: 67850513      addi    a0, a0, 0x678
//           20: 00008067      jalr    zero, 0x0(ra)
//
//     00000024 <c_12345800>:
//           24: 12346537      lui     a0, 0x12346
//           28: 80050513      addi    a0, a0, -0x800
//           2c: 00008067      jalr    zero, 0x0(ra)
//
//     00000030 <c_12345fff>:
//           30: 12346537      lui     a0, 0x12346
//           34: fff50513      addi    a0, a0, -0x1
//           38: 00008067      jalr    zero, 0x0(ra)
//
//     0000003c <c_2048>:
//           3c: 00100513      addi    a0, zero, 0x1
//           40: 00b51513      slli    a0, a0, 0xb
//           44: 00008067      jalr    zero, 0x0(ra)
//
// 看点：
//   - addi a0, zero, imm 就是 li a0, imm：x0 加一个 12 位有符号立即数。
//   - c_2047、c_minus2048：在 -2048…2047 以内，一条 addi。
//   - c_12345000：低 12 位是 0，一条 lui。lui 把 20 位立即数放到第 31–12 位，低 12 位清零。
//   - c_12345678：lui 0x12345 装高 20 位，addi 0x678 补低 12 位。
//   - c_12345800：低 12 位 0x800 当作 12 位有符号数是 -2048。所以 lui 装 0x12346，比高 20 位
//     多 1，再由 addi -0x800 减回来。
//   - c_12345fff：同理，0xfff 是 -1，lui 0x12346，addi -1。
//   - c_2048：按上面的拆法是 lui 1 ; addi -0x800。编译器换成了 addi 1 ; slli 11（1 左移 11 位），
//     同样两条，但开 C 时这两条都能压成 16 位（02-constants.md 第 3 节）。

int c_2047(void)       { return 2047; }
int c_minus2048(void)  { return -2048; }
int c_12345000(void)   { return 0x12345000; }
int c_12345678(void)   { return 0x12345678; }
int c_12345800(void)   { return 0x12345800; }
int c_12345fff(void)   { return 0x12345fff; }
int c_2048(void)       { return 2048; }
