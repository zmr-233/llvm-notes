// tp（x4）是线程指针：每个线程一份的 __thread 变量按「tp + 偏移」访问。
// 讲解见 ../03-calls.md 第 7 节。
//
// ---- cell 1 ----
//
//   $ just asm ex/tp.c -march=rv32imc -mabi=ilp32 -Os
//
//     bump:
//             lui     a0, %tprel_hi(per_thread)
//             add     a1, a0, tp, %tprel_add(per_thread)
//             lw      a0, %tprel_lo(per_thread)(a1)
//             addi    a0, a0, 1
//             sw      a0, %tprel_lo(per_thread)(a1)
//             ret
//     per_thread:
//
// 看点：
//   - lui 装入 per_thread 相对线程存储块起点偏移的高 20 位，add ..., tp 加上 tp，
//     lw/sw 用偏移的低 12 位访问。%tprel_hi/%tprel_add/%tprel_lo 是交给链接器填偏移的标记。
//   - 编译器只读 tp，不写 tp。tp 由启动代码或操作系统设置。
//   - 最后一行 per_thread: 是变量本身的标签，它所在段的汇编指示被 just asm 过滤掉了。

__thread int per_thread;

int bump(void) { return ++per_thread; }
