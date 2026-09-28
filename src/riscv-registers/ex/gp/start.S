/* 启动代码。先装 gp，再装 sp，然后调用 main，返回后原地循环。
   装 gp 的 la 包在 .option norelax 里：汇编器不给这两条指令附 R_RISCV_RELAX，
   链接器就不会把它们改写成相对 gp 的形式。 */
  .section .text.start, "ax"
  .globl _start
_start:
  .option push
  .option norelax
  la    gp, __global_pointer$
  .option pop
  la    sp, __stack_top
  call  main
1:
  j     1b
