// RISC-V 没有标志位：比较结果要么写进一个寄存器，要么直接决定分支。讲解见 ../04-control.md 第 1 节。
//
// ---- cell 1 ----
//
// -mllvm -riscv-no-aliases 让汇编按真实指令打印，不折回 bgt、seqz 这类伪指令。
//
//   $ just asm ex/cmp.c -march=rv32im -mabi=ilp32 -Os -mllvm -riscv-no-aliases
//
//     lt:
//             slt     a0, a0, a1
//             jalr    zero, 0(ra)
//     ltu:
//             sltu    a0, a0, a1
//             jalr    zero, 0(ra)
//     eq:
//             xor     a0, a0, a1
//             sltiu   a0, a0, 1
//             jalr    zero, 0(ra)
//     if_lt:
//             bge     a0, a1, .LBB3_2
//             tail    g
//     .LBB3_2:
//             jalr    zero, 0(ra)
//     if_gt:
//             bge     a1, a0, .LBB4_2
//             tail    g
//     .LBB4_2:
//             jalr    zero, 0(ra)
//     if_ltu:
//             bgeu    a0, a1, .LBB5_2
//             tail    g
//     .LBB5_2:
//             jalr    zero, 0(ra)
//
// 看点：
//   - lt、ltu：a < b 的结果（0 或 1）由一条 slt / sltu 直接写进 a0。有符号、无符号是两条指令。
//   - eq：没有「相等则置 1」的指令。先 xor（相等时结果为 0），再 sltiu a0, a0, 1（a0 < 1 即 a0 == 0）。
//   - if_lt：条件分支自己比较两个寄存器。条件成立要调用 g，所以用相反的条件 bge 跳过调用。
//   - if_gt：没有 bgt 这条指令。a > b 的反面是 a <= b，即 b >= a，写成 bge a1, a0，两个操作数对调。
//   - if_ltu：无符号比较用 bgeu。
//   - tail g 是伪指令，展开成 auipc 加 jalr，见 04-control.md 第 4 节。

void g(void);
int  lt(int a, int b)               { return a < b; }
int  ltu(unsigned a, unsigned b)    { return a < b; }
int  eq(int a, int b)               { return a == b; }
void if_lt(int a, int b)            { if (a < b) g(); }
void if_gt(int a, int b)            { if (a > b) g(); }
void if_ltu(unsigned a, unsigned b) { if (a < b) g(); }
