// gp（x3）与链接器松弛。讲解见 ../../03-calls.md 第 6 节。
//
// 本实验有四个文件：
//   main.c              全局变量 counter 和读写它的 main
//   start.S             启动代码：装 gp、装 sp、调 main。装 gp 的那两条指令包在 .option norelax 里
//   start-relaxable.S   同上，只是去掉了 .option norelax
//   link.ld             链接脚本：代码放 0x80000000，数据放 0x80010000，
//                       并定义 __global_pointer$ = 数据段起点 + 0x800
//
// just gp <启动文件> <链接参数…> 依次做三件事：
//   1. clang 汇编启动文件，编译 main.c，都带 -march=rv32imc -mabi=ilp32 -mrelax。
//      -mrelax 让汇编器在可以缩短的指令对上附一个 R_RISCV_RELAX 重定位，告诉链接器
//      「这里允许改写」。
//   2. $LLD -T ex/gp/link.ld <链接参数> start.o main.o：按 link.ld 链接成可执行文件。
//   3. $OBJDUMP 反汇编。
// 反汇编里的 <.Lpcrel_hi1> 是汇编器为 la 指令生成的局部标签，不是函数。
//
// ---- cell 1：不开 gp 松弛 ----
//
//   $ just gp ex/gp/start.S
//
//     80000000 <_start>:
//     80000000: 00011197      auipc   gp, 0x11
//     80000004: 80018193      addi    gp, gp, -0x800
//
//     80000008 <.Lpcrel_hi1>:
//     80000008: 00020117      auipc   sp, 0x20
//     8000000c: ff810113      addi    sp, sp, -0x8
//     80000010: 2011          c.jal   0x80000014 <main>
//     80000012: a001          c.j     0x80000012 <.Lpcrel_hi1+0xa>
//
//     80000014 <main>:
//     80000014: 800105b7      lui     a1, 0x80010
//     80000018: 0005a503      lw      a0, 0x0(a1)
//     8000001c: 0505          c.addi  a0, 0x1
//     8000001e: 00a5a023      sw      a0, 0x0(a1)
//     80000022: 8082          c.jr    ra
//
// 看点：
//   - main 访问 counter 用 lui a1, 0x80010 装高 20 位，再用 lw/sw 带低 12 位偏移，共三条 4 字节指令。
//   - 源码里 _start 的 call main 本是 auipc+jalr 8 字节，链接后变成 2 字节的 c.jal：
//     调用目标够近，lld 默认就做这种松弛。gp 松弛则要另外打开。
//
// ---- cell 2：打开 gp 松弛 ----
//
// --relax-gp：允许 lld 把「lui + 访存」改写成相对 gp 的一条访存。llvmorg-21.1.8 的
// lld/ELF/Driver.cpp:1520 里它的默认值是 false。
//
//   $ just gp ex/gp/start.S --relax-gp
//
//     80000000 <_start>:
//     80000000: 00011197      auipc   gp, 0x11
//     80000004: 80018193      addi    gp, gp, -0x800
//
//     80000008 <.Lpcrel_hi1>:
//     80000008: 00020117      auipc   sp, 0x20
//     8000000c: ff810113      addi    sp, sp, -0x8
//     80000010: 2011          c.jal   0x80000014 <main>
//     80000012: a001          c.j     0x80000012 <.Lpcrel_hi1+0xa>
//
//     80000014 <main>:
//     80000014: 8001a503      lw      a0, -0x800(gp)
//     80000018: 0505          c.addi  a0, 0x1
//     8000001a: 80a1a023      sw      a0, -0x800(gp)
//     8000001e: 8082          c.jr    ra
//
// 看点：
//   - lui 没了，lw/sw 直接写 -0x800(gp)。gp = 0x80010000 + 0x800，counter 在 0x80010000，
//     偏移正好是 -0x800。gp 前后各 2 KiB 内的数据都能这样一条指令访问到。
//   - main 从 16 字节缩到 12 字节。
//
// ---- cell 3：.option norelax 做了什么 ----
//
//   $ just reloc ex/gp/start.S -march=rv32imc -mabi=ilp32 -mrelax
//
//      Offset     Info    Type                Sym. Value  Symbol's Name + Addend
//     00000000  00000617 R_RISCV_PCREL_HI20     00000000   __global_pointer$ + 0
//     00000004  00000118 R_RISCV_PCREL_LO12_I   00000000   .Lpcrel_hi0 + 0
//     00000008  00000717 R_RISCV_PCREL_HI20     00000000   __stack_top + 0
//     00000008  00000033 R_RISCV_RELAX                     0
//     0000000c  00000318 R_RISCV_PCREL_LO12_I   00000008   .Lpcrel_hi1 + 0
//     0000000c  00000033 R_RISCV_RELAX                     0
//     00000010  00000813 R_RISCV_CALL_PLT       00000000   main + 0
//     00000010  00000033 R_RISCV_RELAX                     0
//
//   $ just reloc ex/gp/start-relaxable.S -march=rv32imc -mabi=ilp32 -mrelax
//
//      Offset     Info    Type                Sym. Value  Symbol's Name + Addend
//     00000000  00000617 R_RISCV_PCREL_HI20     00000000   __global_pointer$ + 0
//     00000000  00000033 R_RISCV_RELAX                     0
//     00000004  00000118 R_RISCV_PCREL_LO12_I   00000000   .Lpcrel_hi0 + 0
//     00000004  00000033 R_RISCV_RELAX                     0
//     00000008  00000717 R_RISCV_PCREL_HI20     00000000   __stack_top + 0
//     00000008  00000033 R_RISCV_RELAX                     0
//     0000000c  00000318 R_RISCV_PCREL_LO12_I   00000008   .Lpcrel_hi1 + 0
//     0000000c  00000033 R_RISCV_RELAX                     0
//     00000010  00000813 R_RISCV_CALL_PLT       00000000   main + 0
//     00000010  00000033 R_RISCV_RELAX                     0
//
// 看点：
//   - 偏移 0 和 4 是装 gp 的 auipc 和 addi。start.S 里这两条后面没有 R_RISCV_RELAX，
//     start-relaxable.S 里有。psABI 规定链接器只改写带这个标记的位置。
//   - 装 gp 的指令如果被改写成相对 gp 的形式，就是在 gp 还没装好时读 gp。
//     所以启动代码把它包在 .option norelax 里。
//
// ---- cell 4：去掉 .option norelax 再链接 ----
//
//   $ just gp ex/gp/start-relaxable.S --relax-gp
//
//     80000000 <_start>:
//     80000000: 00011197      auipc   gp, 0x11
//     80000004: 80018193      addi    gp, gp, -0x800
//
//     80000008 <.Lpcrel_hi1>:
//     80000008: 00020117      auipc   sp, 0x20
//     8000000c: ff810113      addi    sp, sp, -0x8
//     80000010: 2011          c.jal   0x80000014 <main>
//     80000012: a001          c.j     0x80000012 <.Lpcrel_hi1+0xa>
//
//     80000014 <main>:
//     80000014: 8001a503      lw      a0, -0x800(gp)
//     80000018: 0505          c.addi  a0, 0x1
//     8000001a: 80a1a023      sw      a0, -0x800(gp)
//     8000001e: 8082          c.jr    ra
//
// 看点：和 cell 2 完全相同。ld.lld 21.1.8 的 gp 松弛只改写 lui 开头的指令对，
// 不改写 la 展开成的 auipc+addi，所以这里去掉 norelax 也没出问题。
// 写上 .option norelax，结果就不依赖链接器对这一点的具体实现。

int counter;

int main(void) {
  counter++;
  return counter;
}
