// x0：读出恒为 0，写入被丢弃。li、ret、csrr、csrw 这些伪指令都是用 x0 构成的。
// 讲解见 ../02-integer.md 第 1 节。
//
// ---- cell 1：不开 C 扩展，看 4 字节的真实指令 ----
//
// -march=rv32im 里没有 C，每条指令都是 4 字节的基础指令。
// -mllvm -riscv-no-aliases 让汇编输出按真实指令打印，不折回伪指令。
//
//   $ just asm ex/x0.c -march=rv32im -mabi=ilp32 -Os -mllvm -riscv-no-aliases
//
//     zero:
//             addi    a0, zero, 0
//             jalr    zero, 0(ra)
//     read_mcause:
//             csrrs   a0, mcause, zero
//             jalr    zero, 0(ra)
//     write_mtvec:
//             csrrw   zero, mtvec, a0
//             jalr    zero, 0(ra)
//
// 看点：
//   - return 0 在汇编里通常写作 li a0, 0，真实指令是 addi a0, zero, 0：x0 加立即数 0。
//   - 返回 ret 是 jalr zero, 0(ra)：跳到 ra 里的地址，把「下一条指令的地址」写进 x0，即丢掉。
//   - csrr a0, mcause 是 csrrs a0, mcause, zero：读出 mcause 放进 a0，再把 mcause 中
//     「x0 里为 1 的那些位」置 1。rs1 是 x0 时，硬件根本不写 mcause。
//   - csrw mtvec, a0 是 csrrw zero, mtvec, a0：a0 写进 mtvec，旧值写进 x0 丢掉。
//     rd 是 x0 时，硬件根本不读 mtvec。
//
// ---- cell 2：开 C 扩展，看编码和长度 ----
//
//   $ just dis ex/x0.c -march=rv32imc -mabi=ilp32 -Os
//
//     00000000 <zero>:
//            0: 4501          c.li    a0, 0x0
//            2: 8082          c.jr    ra
//
//     00000004 <read_mcause>:
//            4: 34202573      csrrs   a0, mcause, zero
//            8: 8082          c.jr    ra
//
//     0000000a <write_mtvec>:
//            a: 30551073      csrrw   zero, mtvec, a0
//            e: 8082          c.jr    ra
//
// 看点：
//   - addi a0, zero, 0 压缩成 2 字节的 c.li a0, 0；jalr zero, 0(ra) 压缩成 c.jr ra。
//   - CSR 指令没有压缩形式，仍然是 4 字节。编码的高 12 位就是 CSR 地址：
//     34202573 的高 12 位是 0x342（mcause），30551073 的高 12 位是 0x305（mtvec）。

int zero(void) { return 0; }

unsigned read_mcause(void) {
  unsigned v;
  asm volatile("csrr %0, mcause" : "=r"(v));
  return v;
}

void write_mtvec(unsigned v) { asm volatile("csrw mtvec, %0" ::"r"(v)); }
