// 把重复的代码抽成公共片段来省体积：Machine Outliner、-msave-restore、Zcmp。讲解见 ../07-outline.md。
//
// mid_*：三个函数开头算同一个 s，只有最后一步不同。
// end_*：三个函数都先调用 use，然后只差一步运算，之后是同样的尾声。
//
// ---- cell 1：-Oz 下的外提 ----
//
// -Oz 按体积优化得比 -Os 更狠；clang 给 -Oz 编译的函数加上 minsize 属性。
// -mllvm -riscv-no-aliases 按真实指令打印（c.jr、c.lw 等不折回 ret、lw）。
//
//   $ just asm ex/outline.c -march=rv32imc -mabi=ilp32 -Oz -mllvm -riscv-no-aliases
//
//     mid_mul:
//             call    t0, OUTLINED_FUNCTION_0
//             mul     a0, a0, a1
//             c.jr    ra
//     mid_div:
//             call    t0, OUTLINED_FUNCTION_0
//             div     a0, a0, a1
//             c.jr    ra
//     mid_rem:
//             call    t0, OUTLINED_FUNCTION_0
//             rem     a0, a0, a1
//             c.jr    ra
//     end_add:
//             c.addi  sp, -16
//             c.swsp  ra, 12(sp)                      # 4-byte Folded Spill
//             c.swsp  s0, 8(sp)                       # 4-byte Folded Spill
//             c.lw    a4, 0(a0)
//             c.lw    a5, 4(a0)
//             c.lw    a2, 8(a0)
//             c.lw    a3, 12(a0)
//             c.mv    s0, a1
//             c.mv    a0, a4
//             c.mv    a1, a5
//             call    use
//             c.add   a0, s0
//             tail    OUTLINED_FUNCTION_1
//     end_sub:
//             c.addi  sp, -16
//             c.swsp  ra, 12(sp)                      # 4-byte Folded Spill
//             c.swsp  s0, 8(sp)                       # 4-byte Folded Spill
//             c.lw    a4, 0(a0)
//             c.lw    a5, 4(a0)
//             c.lw    a2, 8(a0)
//             c.lw    a3, 12(a0)
//             c.mv    s0, a1
//             c.mv    a0, a4
//             c.mv    a1, a5
//             call    use
//             c.sub   a0, s0
//             tail    OUTLINED_FUNCTION_1
//     end_xor:
//             c.addi  sp, -16
//             c.swsp  ra, 12(sp)                      # 4-byte Folded Spill
//             c.swsp  s0, 8(sp)                       # 4-byte Folded Spill
//             c.lw    a4, 0(a0)
//             c.lw    a5, 4(a0)
//             c.lw    a2, 8(a0)
//             c.lw    a3, 12(a0)
//             c.mv    s0, a1
//             c.mv    a0, a4
//             c.mv    a1, a5
//             call    use
//             c.xor   a0, s0
//             tail    OUTLINED_FUNCTION_1
//     OUTLINED_FUNCTION_0:
//             c.lw    a2, 0(a0)
//             c.lw    a3, 4(a0)
//             c.lw    a4, 8(a0)
//             c.lw    a0, 12(a0)
//             slli    a5, a2, 1
//             c.add   a2, a5
//             slli    a5, a3, 2
//             c.add   a3, a5
//             slli    a5, a4, 3
//             c.sub   a5, a4
//             slli    a4, a0, 3
//             c.add   a0, a4
//             c.add   a2, a3
//             c.add   a0, a5
//             c.add   a0, a2
//             c.jr    t0
//     OUTLINED_FUNCTION_1:
//             c.lwsp  ra, 12(sp)
//             c.lwsp  s0, 8(sp)
//             c.addi  sp, 16
//             c.jr    ra
//
// 看点：
//   - OUTLINED_FUNCTION_0 是 mid_* 开头那段算 s 的代码。三个函数用 call t0 调用它，它以 c.jr t0 返回：
//     返回地址放在 t0，ra 不动，和 ../06-ras.md 第 8 节的 millicode 一样。
//   - OUTLINED_FUNCTION_1 是 end_* 共同的尾声：取回 ra、s0，还栈，返回。三个函数用 tail 跳过去，
//     它的 c.jr ra 直接回到 end_* 的调用者。这相当于编译器现场生成了一个 __riscv_restore。
//   - end_* 开头的序言和取参数也是重复的，没有被抽出。
//
// ---- cell 2：外提的开关 ----
//
// just size 打印 .text 的字节数：链接前（目标文件）和链接后（链接器松弛之后）。
// 这里的 use 没有定义，just size 让链接器把它当作 0，只为量大小。
//
//   $ just size ex/outline.c -march=rv32imc -mabi=ilp32 -Os
//
//     链接前 246 字节，链接后 228 字节
//
//   $ just size ex/outline.c -march=rv32imc -mabi=ilp32 -Oz
//
//     链接前 204 字节，链接后 156 字节
//
//   $ just size ex/outline.c -march=rv32imc -mabi=ilp32 -Oz -mno-outline
//
//     链接前 246 字节，链接后 228 字节
//
//   $ just size ex/outline.c -march=rv32imc -mabi=ilp32 -Os -mllvm -enable-machine-outliner
//
//     链接前 204 字节，链接后 156 字节
//
//   $ just size ex/outline.c -march=rv32imc -mabi=ilp32 -Os -moutline
//
//     clang: warning: 'riscv32' does not support '-moutline'; flag ignored [-Woption-ignored]
//     链接前 246 字节，链接后 228 字节
//
// 看点：
//   - -Oz 比 -Os 小，差别全来自外提：-Oz -mno-outline 和 -Os 一样大。
//   - -mno-outline 关掉外提。-mllvm -enable-machine-outliner 让外提对所有函数都跑，-Os 也不例外。
//   - clang 21.1.8 对 riscv32 不认 -moutline，报 warning 后忽略。
//   - 链接前后差得多：目标文件里每个 call、tail 都是 8 字节的 auipc 加 jalr，链接器松弛之后才缩短。
//     只看目标文件会低估外提的收益。
//
// ---- cell 3：和 -msave-restore、Zcmp 放在一起 ----
//
//   $ just size ex/outline.c -march=rv32imc -mabi=ilp32 -Oz -msave-restore
//
//     链接前 202 字节，链接后 142 字节
//
//   $ just size ex/outline.c -march=rv32imc_zcmp -mabi=ilp32 -Oz
//
//     链接前 166 字节，链接后 136 字节
//
//   $ just size ex/outline.c -march=rv32imc_zcmp -mabi=ilp32 -Oz -mno-outline
//
//     链接前 216 字节，链接后 198 字节
//
// 看点：
//   - -msave-restore 的数字不含 __riscv_save_N、__riscv_restore_N 的本体。它们在库里，整个程序只有一份，
//     这里没有链接进来。
//   - Zcmp 用 cm.push、cm.popret 做序言和尾声（riscv-registers 的 03 第 2 节）。end_* 的尾声只剩一条
//     2 字节的 cm.popret，没什么可抽；外提只抽出 mid_* 那段，仍然省下 62 字节。

int mid_mul(int *p, int k) { int s = p[0] * 3 + p[1] * 5 + p[2] * 7 + p[3] * 9; return s * k; }
int mid_div(int *p, int k) { int s = p[0] * 3 + p[1] * 5 + p[2] * 7 + p[3] * 9; return s / k; }
int mid_rem(int *p, int k) { int s = p[0] * 3 + p[1] * 5 + p[2] * 7 + p[3] * 9; return s % k; }

int use(int, int, int, int);
int end_add(int *p, int k) { return use(p[0], p[1], p[2], p[3]) + k; }
int end_sub(int *p, int k) { return use(p[0], p[1], p[2], p[3]) - k; }
int end_xor(int *p, int k) { return use(p[0], p[1], p[2], p[3]) ^ k; }
