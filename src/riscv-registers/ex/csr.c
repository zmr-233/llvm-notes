// CSR 的地址、访问指令，以及汇编器不检查的事。讲解见 ../06-csr.md 第 1–3 节。
//
// ---- cell 1：反汇编 ----
//
//   $ just dis ex/csr.c -march=rv32imc -mabi=ilp32 -Os
//
//     00000000 <read_mstatus>:
//            0: 30002573      csrrs   a0, mstatus, zero
//            4: 8082          c.jr    ra
//
//     00000006 <read_mstatus_by_number>:
//            6: 30002573      csrrs   a0, mstatus, zero
//            a: 8082          c.jr    ra
//
//     0000000c <enable_mie>:
//            c: 30046073      csrrsi  zero, mstatus, 0x8
//           10: 8082          c.jr    ra
//
//     00000012 <disable_mie>:
//           12: 30047073      csrrci  zero, mstatus, 0x8
//           16: 8082          c.jr    ra
//
//     00000018 <write_cycle>:
//           18: c0051073      csrrw   zero, cycle, a0
//           1c: 8082          c.jr    ra
//
// 看点：
//   - 按名字写 mstatus 和按编号写 0x300，生成的编码完全相同（30002573）。名字只是汇编器
//     里的一张表，编码里只有 12 位地址。
//   - csrsi mstatus, 8 是 csrrsi zero, mstatus, 8：把 mstatus 的第 3 位（MIE，
//     M 级全局中断开关）置 1，旧值丢进 x0。csrci 同理，把它清 0。立即数只有 5 位。
//   - write_cycle 往只读的 cycle（0xC00）写值，编译、汇编都没有报错。
//     地址 0xC00 的位 11:10 是 11，表示只读，执行时处理器报非法指令异常。
//     检查在硬件里做，汇编器不做。

unsigned read_mstatus(void) {
  unsigned v;
  asm volatile("csrr %0, mstatus" : "=r"(v));
  return v;
}

unsigned read_mstatus_by_number(void) {
  unsigned v;
  asm volatile("csrr %0, 0x300" : "=r"(v));
  return v;
}

void enable_mie(void) { asm volatile("csrsi mstatus, 8"); }

void disable_mie(void) { asm volatile("csrci mstatus, 8"); }

void write_cycle(unsigned v) { asm volatile("csrw cycle, %0" ::"r"(v)); }
