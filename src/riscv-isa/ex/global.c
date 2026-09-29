// 访问全局变量的两种写法：绝对地址（-mcmodel=medlow）与相对 pc（-mcmodel=medany）。
// 讲解见 ../03-addressing.md。
//
// ---- cell 1：medlow ----
//
// -mcmodel=medlow：按绝对地址访问，要求变量地址能用 lui + 12 位偏移表示。
//
//   $ just asm ex/global.c -march=rv32im -mabi=ilp32 -Os -mcmodel=medlow -mllvm -riscv-no-aliases
//
//     get:
//             lui     a0, %hi(g)
//             lw      a0, %lo(g)(a0)
//             jalr    zero, 0(ra)
//     set:
//             lui     a1, %hi(g)
//             sw      a0, %lo(g)(a1)
//             jalr    zero, 0(ra)
//     addr:
//             lui     a0, %hi(g)
//             addi    a0, a0, %lo(g)
//             jalr    zero, 0(ra)
//     get_sc:
//             lui     a0, %hi(sc)
//             lb      a0, %lo(sc)(a0)
//             jalr    zero, 0(ra)
//     get_uc:
//             lui     a0, %hi(uc)
//             lbu     a0, %lo(uc)(a0)
//             jalr    zero, 0(ra)
//     g:
//     sc:
//     uc:
//
// 看点：
//   - %hi(g)、%lo(g) 是 g 的地址拆成的高 20 位和低 12 位，由链接器填入。
//   - get 用 lw 读，set 用 sw 写，addr 用 addi 算出地址本身。三者的第一条都是同一条 lui。
//   - get_sc 读 signed char 用 lb（符号扩展），get_uc 读 unsigned char 用 lbu（零扩展）。
//   - 最后三行 g、sc、uc 是变量本身的标签。
//
// ---- cell 2：medany ----
//
// -mcmodel=medany：按相对当前 pc 的距离访问。
//
//   $ just asm ex/global.c -march=rv32im -mabi=ilp32 -Os -mcmodel=medany -mllvm -riscv-no-aliases
//
//     get:
//     .Lpcrel_hi0:
//             auipc   a0, %pcrel_hi(g)
//             lw      a0, %pcrel_lo(.Lpcrel_hi0)(a0)
//             jalr    zero, 0(ra)
//     set:
//     .Lpcrel_hi1:
//             auipc   a1, %pcrel_hi(g)
//             sw      a0, %pcrel_lo(.Lpcrel_hi1)(a1)
//             jalr    zero, 0(ra)
//     addr:
//     .Lpcrel_hi2:
//             auipc   a0, %pcrel_hi(g)
//             addi    a0, a0, %pcrel_lo(.Lpcrel_hi2)
//             jalr    zero, 0(ra)
//     get_sc:
//     .Lpcrel_hi3:
//             auipc   a0, %pcrel_hi(sc)
//             lb      a0, %pcrel_lo(.Lpcrel_hi3)(a0)
//             jalr    zero, 0(ra)
//     get_uc:
//     .Lpcrel_hi4:
//             auipc   a0, %pcrel_hi(uc)
//             lbu     a0, %pcrel_lo(.Lpcrel_hi4)(a0)
//             jalr    zero, 0(ra)
//     g:
//     sc:
//     uc:
//
// 看点：
//   - lui %hi(g) 换成了 auipc %pcrel_hi(g)，前面多一个标签 .Lpcrel_hiN。
//   - 第二条的 %pcrel_lo 括号里写的是这个标签，不是 g。原因见 03-addressing.md 第 4 节。

int g;
int get(void) { return g; }
void set(int v) { g = v; }
int *addr(void) { return &g; }

signed char sc;
unsigned char uc;
int get_sc(void) { return sc; }
int get_uc(void) { return uc; }
