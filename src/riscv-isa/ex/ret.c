// 参数与返回值放在哪。讲解见 ../05-calls.md 第 5 节。
//
// r64    返回 64 位整数
// r2     返回 8 字节的结构体
// r3     返回 12 字节的结构体
// call3  调用一个返回 12 字节结构体的函数，取它的 c 字段
// take9  有 9 个参数，第 9 个放不进 a0–a7
// call9  调用一个有 9 个参数的函数
//
// ---- cell 1：RV32 ----
//
//   $ just asm ex/ret.c -march=rv32im -mabi=ilp32 -Os
//
//     r64:
//             addi    a0, a0, 1
//             seqz    a2, a0
//             add     a1, a1, a2
//             ret
//     r2:
//             ret
//     r3:
//             sw      a1, 0(a0)
//             sw      a2, 4(a0)
//             sw      a3, 8(a0)
//             ret
//     call3:
//             addi    sp, sp, -16
//             sw      ra, 12(sp)                      # 4-byte Folded Spill
//             mv      a0, sp
//             call    use3
//             lw      a0, 8(sp)
//             lw      ra, 12(sp)                      # 4-byte Folded Reload
//             addi    sp, sp, 16
//             ret
//     take9:
//             lw      a1, 0(sp)
//             add     a0, a1, a0
//             ret
//     call9:
//             addi    sp, sp, -16
//             sw      ra, 12(sp)                      # 4-byte Folded Spill
//             li      t0, 9
//             li      a0, 1
//             li      a1, 2
//             li      a2, 3
//             li      a3, 4
//             li      a4, 5
//             li      a5, 6
//             li      a6, 7
//             li      a7, 8
//             sw      t0, 0(sp)
//             call    give9
//             lw      ra, 12(sp)                      # 4-byte Folded Reload
//             addi    sp, sp, 16
//             ret
//
// 看点：
//   - r64：RV32 上 64 位整数占两个寄存器，x 在 a0（低 32 位）、a1（高 32 位），返回值也在
//     a0、a1。seqz a2, a0 在低 32 位加 1 后变成 0 时得 1，把进位加到 a1。
//   - r2：8 字节的结构体不超过两个寄存器，用 a0、a1 返回。a、b 进来时恰好在 a0、a1，
//     函数体只剩 ret。
//   - r3：12 字节超过两个寄存器，改由调用者准备内存。a0 是这块内存的地址，
//     a、b、c 顺延到 a1–a3，函数把三个字段写进去。
//   - call3：调用者在自己的栈帧里留出 12 字节，mv a0, sp 把地址当作第一个参数，
//     调用之后从 8(sp) 读出 c。
//   - take9：第 9 个参数 i 在栈上，进入函数时位于 0(sp)。
//   - call9：调用者把 9 写到自己栈帧的 0(sp)，前 8 个放 a0–a7。
//
// ---- cell 2：RV64 ----
//
// 同一份代码按 RV64 编译，一个寄存器 8 字节，两个寄存器 16 字节。
//
//   $ just asm ex/ret.c -march=rv64im -mabi=lp64 -Os
//
//     r64:
//             addi    a0, a0, 1
//             ret
//     r2:
//             slli    a1, a1, 32
//             slli    a0, a0, 32
//             srli    a0, a0, 32
//             or      a0, a1, a0
//             ret
//     r3:
//             slli    a1, a1, 32
//             slli    a0, a0, 32
//             slli    a2, a2, 32
//             srli    a0, a0, 32
//             or      a0, a1, a0
//             srli    a1, a2, 32
//             ret
//     call3:
//             addi    sp, sp, -16
//             sd      ra, 8(sp)                       # 8-byte Folded Spill
//             call    use3
//             sext.w  a0, a1
//             ld      ra, 8(sp)                       # 8-byte Folded Reload
//             addi    sp, sp, 16
//             ret
//     take9:
//             ld      a1, 0(sp)
//             addw    a0, a1, a0
//             ret
//     call9:
//             addi    sp, sp, -16
//             sd      ra, 8(sp)                       # 8-byte Folded Spill
//             li      t0, 9
//             li      a0, 1
//             li      a1, 2
//             li      a2, 3
//             li      a3, 4
//             li      a4, 5
//             li      a5, 6
//             li      a6, 7
//             li      a7, 8
//             sd      t0, 0(sp)
//             call    give9
//             ld      ra, 8(sp)                       # 8-byte Folded Reload
//             addi    sp, sp, 16
//             ret
//
// 看点：
//   - r64：64 位整数只占一个寄存器。
//   - r2：8 字节的结构体放进一个 a0，a 在低 32 位，b 在高 32 位。slli、srli 先清掉 a 的高
//     32 位（int 参数进来时符号扩展到 64 位），再和左移过的 b 拼起来。
//   - r3：12 字节不超过 16 字节，不再走内存：a、b 拼进 a0，c 在 a1 的低 32 位。
//   - call3：不再准备内存，c 直接从 a1 取，sext.w 把低 32 位符号扩展成 int 的 64 位形式。
//   - take9、call9：栈上的参数按 8 字节存取（ld、sd）。

long long r64(long long x) { return x + 1; }

struct two { int a, b; };
struct two r2(int a, int b) { struct two r = {a, b}; return r; }

struct three { int a, b, c; };
struct three r3(int a, int b, int c) { struct three r = {a, b, c}; return r; }

struct three use3(void);
int call3(void) { return use3().c; }

int take9(int a, int b, int c, int d, int e, int f, int g, int h, int i) { return a + i; }

int give9(int, int, int, int, int, int, int, int, int);
int call9(void) { return give9(1, 2, 3, 4, 5, 6, 7, 8, 9); }
