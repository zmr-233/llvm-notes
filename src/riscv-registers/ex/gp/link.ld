/* 代码从 0x80000000 开始，启动代码放最前面。
   数据从 0x80010000 开始；__global_pointer$ 定在数据起点 + 0x800，
   这样 gp 的 12 位有符号偏移（-2048 到 2047）正好覆盖数据起点往后 4 KiB。
   栈顶定在 0x80020000。 */
ENTRY(_start)
SECTIONS {
  . = 0x80000000;
  .text : { *(.text.start) *(.text*) }
  . = 0x80010000;
  .data : { *(.sdata*) *(.data*) *(.sbss*) *(.bss*) }
  __global_pointer$ = ADDR(.data) + 0x800;
  __stack_top = 0x80020000;
}
