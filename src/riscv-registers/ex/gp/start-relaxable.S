/* 和 start.S 相同，只是装 gp 的 la 没有包在 .option norelax 里。 */
  .section .text.start, "ax"
  .globl _start
_start:
  la    gp, __global_pointer$
  la    sp, __stack_top
  call  main
1:
  j     1b
