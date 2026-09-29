// 条件分支要跳过的距离越来越远时，编译器生成什么。讲解见 ../04-control.md 第 3 节。
//
// asm volatile(".space N") 在函数里塞 N 字节的 0，当作一段 N 字节长的代码。条件不成立时要跳过它。
// 编译器估计代码长度时认得 .space，所以知道这段有多长。
//
// ---- cell 1：汇编 ----
//
// -O2：按速度优化。-mllvm -riscv-no-aliases：按真实指令打印。
//
//   $ just asm ex/far.c -march=rv32im -mabi=ilp32 -O2 -mllvm -riscv-no-aliases
//
//     near_:
//             beq     a0, a1, .LBB0_2
//     .LBB0_2:
//             jalr    zero, 0(ra)
//     mid:
//             bne     a0, a1, .LBB1_1
//             jal     zero, .LBB1_2
//     .LBB1_1:
//     .LBB1_2:
//             jalr    zero, 0(ra)
//     far_:
//             addi    sp, sp, -16
//             bne     a0, a1, .LBB2_1
//             jump    .LBB2_2, a0
//     .LBB2_1:
//     .LBB2_2:
//             addi    sp, sp, 16
//             jalr    zero, 0(ra)
//
// 看点：
//   - near_：跳过 16 字节，beq 够得着。
//   - mid：跳过 8 KiB，超出 beq 的 ±4 KiB。改成相反条件的 bne 跳过下一条，下一条 jal 跳 ±1 MiB。
//   - far_：跳过 1 MiB，jal 也够不着。jal 换成 jump .LBB2_2, a0，即 auipc a0 加 jalr，
//     a0 只用来暂存地址。
//   - far_ 开头的 addi sp, sp, -16 是给暂存寄存器预留的栈槽，这里没用上（04-control.md 第 3 节）。
//   - 空行的标签之间原本是 .space，被 just asm 删掉了。
//
// ---- cell 2：反汇编 far_ 的 jump ----
//
// -mno-relax：让汇编器直接填好 auipc、jalr 的立即数。
//
//   $ just dis ex/far.c -march=rv32im -mabi=ilp32 -O2 -mno-relax
//
//     00000000 <near_>:
//            0: 00b50a63      beq     a0, a1, 0x14 <near_+0x14>
//                     ...
//           14: 00008067      jalr    zero, 0x0(ra)
//
//     00000018 <mid>:
//           18: 00b51463      bne     a0, a1, 0x20 <mid+0x8>
//           1c: 0040206f      jal     zero, 0x2020 <mid+0x2008>
//                     ...
//         2020: 00008067      jalr    zero, 0x0(ra)
//
//     00002024 <far_>:
//         2024: ff010113      addi    sp, sp, -0x10
//         2028: 00b51663      bne     a0, a1, 0x2034 <far_+0x10>
//         202c: 00100517      auipc   a0, 0x100
//         2030: 00850067      jalr    zero, 0x8(a0) <far_+0x100010>
//                     ...
//       102034: 01010113      addi    sp, sp, 0x10
//       102038: 00008067      jalr    zero, 0x0(ra)
//
// 看点：
//   - far_ 的 auipc 在 0x202c，目标在 0x102034，相差 D = 0x100008：auipc a0, 0x100，jalr 0x8(a0)。
//   - 算法同 pcrel.s：两个立即数都从 D 拆出来，jalr 自己的地址 0x2030 不参与。

void near_(int a, int b) { if (a != b) asm volatile(".space 16"); }
void mid(int a, int b)   { if (a != b) asm volatile(".space 8192"); }
void far_(int a, int b)  { if (a != b) asm volatile(".space 1048576"); }
