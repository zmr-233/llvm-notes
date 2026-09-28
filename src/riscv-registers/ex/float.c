// -march 决定有哪些指令，-mabi 决定函数之间用哪些寄存器传浮点值。
// 同一个 fadd 在六种组合下的结果。讲解见 ../04-float.md 第 4 节。
//
// ---- cell 1：没有 F，ilp32 ----
//
//   $ just asm ex/float.c -march=rv32imc -mabi=ilp32 -Os
//
//     fadd:
//             addi    sp, sp, -16
//             sw      ra, 12(sp)                      # 4-byte Folded Spill
//             call    __addsf3
//             lw      ra, 12(sp)                      # 4-byte Folded Reload
//             addi    sp, sp, 16
//             ret
//
// 看点：没有浮点指令，调用软浮点库函数 __addsf3（由 compiler-rt 或 libgcc 提供）。
//
// ---- cell 2：有 F，ilp32 ----
//
//   $ just asm ex/float.c -march=rv32imfc -mabi=ilp32 -Os
//
//     fadd:
//             fmv.w.x fa5, a1
//             fmv.w.x fa4, a0
//             fadd.s  fa5, fa4, fa5
//             fmv.x.w a0, fa5
//             ret
//
// 看点：
//   - 能用 fadd.s 了，但 ilp32 规定 float 参数和返回值经整数寄存器传。
//   - fmv.w.x 把整数寄存器里的 32 位原样搬进浮点寄存器，fmv.x.w 反过来。
//     进两次、出一次，是这个组合在每个函数边界上的代价。
//   - 换来的是和按 ilp32 编译的库、目标文件能链在一起。
//
// ---- cell 3：有 F，ilp32f ----
//
//   $ just asm ex/float.c -march=rv32imfc -mabi=ilp32f -Os
//
//     fadd:
//             fadd.s  fa0, fa0, fa1
//             ret
//
// 看点：参数在 fa0、fa1，返回值在 fa0，一条 fadd.s 就完成。
//
// ---- cell 4：Zfinx ----
//
// -march=rv32imc_zfinx：Zfinx 扩展提供和 F 一样的浮点运算，但操作数是整数寄存器，
// 处理器里没有 f0–f31。
//
//   $ just asm ex/float.c -march=rv32imc_zfinx -mabi=ilp32 -Os
//
//     fadd:
//             fadd.s  a0, a0, a1
//             ret
//
// 看点：fadd.s a0, a0, a1 直接在 x 寄存器上算。参数本来就在整数寄存器里，所以 ABI 用 ilp32。
//
// ---- cell 5：没有 F，却要 ilp32f ----
//
//   $ just asm ex/float.c -march=rv32imc -mabi=ilp32f -Os
//
//     Hard-float 'f' ABI can't be used for a target that doesn't support the F instruction set extension (ignoring target-abi)
//     fadd:
//             addi    sp, sp, -16
//             sw      ra, 12(sp)                      # 4-byte Folded Spill
//             call    __addsf3
//             lw      ra, 12(sp)                      # 4-byte Folded Reload
//             addi    sp, sp, 16
//             ret
//
// 看点：
//   - driver 不拦这个组合。后端打印第一行那条警告，丢掉 -mabi，按 ilp32 生成，
//     结果和 cell 1 一样。
//
// ---- cell 6：Zfinx 配 ilp32f ----
//
//   $ just asm ex/float.c -march=rv32imc_zfinx -mabi=ilp32f -Os
//
//   预期（llvmorg-21.1.8）：先打印和 cell 5 相同的警告，然后 clang 段错误退出：
//
//     Hard-float 'f' ABI can't be used for a target that doesn't support the F instruction set extension (ignoring target-abi)
//     ...
//     4.  Running pass 'Post-RA pseudo instruction expansion pass' on function '@fadd'
//     ...
//     7  clang  0x...  llvm::TargetInstrInfo::lowerCopy(llvm::MachineInstr*, llvm::TargetRegisterInfo const*) const + 312
//     ...
//     clang: error: clang frontend command failed with exit code 139 (use -v to see invocation)
//
// 看点：
//   - 这是个错误的组合，应当报错，21.1.8 却在寄存器分配之后的 pass 里崩溃。
//   - 崩溃时 clang 会把预处理后的源码和复现脚本写进 /tmp，文件名形如 float-xxxxxx.c / .sh，
//     输出末尾会列出路径，看完可以删掉。

float fadd(float a, float b) { return a + b; }
