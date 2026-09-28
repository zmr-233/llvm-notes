// 向量寄存器 v0–v31、vl、vtype、vlenb，以及 v0 作掩码。讲解见 ../05-vector.md。
//
// ---- cell 1 ----
//
// -march=rv32imcv：加上 V 扩展。
//
//   $ just asm ex/vector.c -march=rv32imcv -mabi=ilp32 -Os
//
//     vadd:
//             blez    a3, .LBB0_3
//             li      a4, 0
//             csrr    a5, vlenb
//             srli    a6, a5, 1
//             add     a7, a6, a3
//             neg     t0, a6
//             addi    a7, a7, -1
//             and     a7, a7, t0
//             slli    t0, a5, 1
//             vsetvli a5, zero, e32, m2, ta, ma
//             vid.v   v8
//     .LBB0_2:                                # =>This Inner Loop Header: Depth=1
//             vsaddu.vx       v10, v8, a4
//             vmsltu.vx       v0, v10, a3
//             vle32.v v10, (a1), v0.t
//             vle32.v v12, (a2), v0.t
//             add     a4, a4, a6
//             add     a2, a2, t0
//             vadd.vv v10, v12, v10
//             vse32.v v10, (a0), v0.t
//             add     a0, a0, t0
//             add     a1, a1, t0
//             bne     a7, a4, .LBB0_2
//     .LBB0_3:
//             ret
//
// 看点：
//   - csrr a5, vlenb：读只读 CSR vlenb，得到一个向量寄存器的字节数 VLEN/8。编译时不知道
//     VLEN，只能运行时读。
//   - vsetvli a5, zero, e32, m2, ta, ma：设置 vtype 和 vl。
//     e32 表示元素 32 位；m2 表示 LMUL=2，两个相邻的 v 寄存器合成一组当一个用；
//     ta/ma 表示不关心尾部元素和被掩掉的元素的旧值。
//     rs1 写 zero（x0）而 rd 不是 x0，含义是把 vl 设成最大值：一组能装下的元素个数。
//   - 于是每轮处理 2×VLEN/32 = vlenb/2 个元素（srli a6, a5, 1），前进 2×vlenb 字节（slli t0, a5, 1）。
//   - v8、v10、v12 全是偶数号：LMUL=2 时一组必须从偶数号开始，v8 表示 v8–v9 这一组。
//   - vid.v v8 让 v8 组的第 k 个元素等于 k；每轮 vsaddu.vx 加上已处理的个数 a4，得到本轮
//     每个元素的下标。vmsltu.vx v0, v10, a3 算出「下标 < n」的掩码，放进 v0：带掩码的
//     指令（vle32.v …, v0.t）只从 v0 读掩码。数组末尾不足一组时，掩掉的元素既不读也不写，
//     所以不需要单独的标量尾循环。

void vadd(int *restrict d, const int *a, const int *b, int n) {
  for (int i = 0; i < n; i++)
    d[i] = a[i] + b[i];
}
