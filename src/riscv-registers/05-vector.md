# 05 向量寄存器

实验 `ex/vector.c`（`-march=rv32imcv -mabi=ilp32 -Os`），把 `d[i] = a[i] + b[i]` 向量化后的循环：

```
        csrr     a5, vlenb
        srli     a6, a5, 1
        slli     t0, a5, 1
        vsetvli  a5, zero, e32, m2, ta, ma
        vid.v    v8
loop:   vsaddu.vx  v10, v8, a4
        vmsltu.vx  v0, v10, a3
        vle32.v    v10, (a1), v0.t
        vle32.v    v12, (a2), v0.t
        vadd.vv    v10, v12, v10
        vse32.v    v10, (a0), v0.t
        …指针加 t0，a4 加 a6，回到 loop
```

（摘录，完整输出见实验文件。）

## 1. v0–v31 与 vlenb

- 32 个，每个 VLEN 位。VLEN 由处理器决定，编译时不知道。
- vlenb（CSR 0xC22）是只读的，值为 VLEN/8，即一个向量寄存器的字节数（`RISCV/RISCVSystemOperands.td:86`；
  QEMU v11.1.1 `target/riscv/tcg/csr.c` 的 read_vlenb 返回配置里的 vlenb）。
- 循环开头 `csrr a5, vlenb` 就是在运行时问 VLEN。后面 `srli a6, a5, 1` 算出每轮处理的元素个数，
  `slli t0, a5, 1` 算出每轮前进的字节数，都由它推出（第 3 节）。

## 2. vl 与 vtype

- vtype（CSR 0xC21）描述当前怎么解释向量寄存器：元素多宽、几个寄存器合成一组等。
- vl（CSR 0xC20）是接下来的向量指令处理几个元素。
- 两者的地址位 11:10 都是 11，是只读 CSR（地址规则见 06 第 1 节），不能用 csrw 改；
  只能用 vsetvli、vsetivli、vsetvl 三条指令一起设置。
- `vsetvli a5, zero, e32, m2, ta, ma` 逐项：
  - `e32`：元素 32 位。
  - `m2`：LMUL=2，两个相邻的 v 寄存器合成一组，当一个寄存器用。
  - `ta, ma`：不关心尾部元素（第 vl 个之后的）和被掩掉的元素的旧值。
  - rs1 写 `zero`：请求的元素个数。rs1 是 x0 而 rd 不是 x0 时，vl 设成最大值，即一组能装下的
    元素个数；rd 和 rs1 都是 x0 时，保持 vl 不变、只改 vtype（QEMU `target/riscv/tcg/insn_trans/trans_rvv.c.inc`
    的 do_vsetvl）。这是 x0 在向量指令里的特殊含义。
  - rd（a5）：写回实际设置的 vl。

## 3. LMUL 与寄存器组

- LMUL=2 时，一组由两个相邻寄存器组成，起点必须是偶数号：v8 表示 v8–v9 这一组，v10 表示 v10–v11。
  实验里用到的 v8、v10、v12 都是偶数号。
- 每轮处理的元素个数 = 2 × VLEN / 32 = vlenb / 2，前进的字节数 = 2 × vlenb。
- LLVM 里每种 LMUL 各有一个寄存器类（`RISCV/RISCVRegisterInfo.td:779` 起）：
  - VR（LMUL=1）的分配顺序是 v8–v31，然后 v7 到 v0 倒序。:774 的注释说明：后 8 个倒过来，
    是为了不无谓地挡住更大 LMUL 的寄存器组，同时让 v0 排在最后。
  - VRM2 只含偶数号的组，VRM4 只含 4 的倍数号，VRM8 只含 v0、v8、v16、v24。
  - 所以向量化的代码通常从 v8 开始用。

## 4. v0 与掩码

- 带掩码的向量指令写作 `…, v0.t`，掩码只能来自 v0。LLVM 里对应只含 V0 一个寄存器的 VMV0 类
  （`RISCV/RISCVRegisterInfo.td:799`）。
- 实验里 `vid.v v8` 让 v8 组的第 k 个元素等于 k；每轮 `vsaddu.vx` 加上已处理的个数 a4，得到本轮每个
  元素的下标；`vmsltu.vx v0, v10, a3` 算出「下标 < n」的掩码放进 v0。数组末尾不足一组时，掩掉的元素
  既不读也不写，所以不需要另写一个标量的尾循环。

## 5. 其他向量状态

- vstart（0x008）、vxsat（0x009）、vxrm（0x00A）、vcsr（0x00F），地址见 `RISCV/RISCVSystemOperands.td:80–83`。
- LLVM 把 VL、VTYPE、VXSAT、VXRM 放进保留集（`RISCV/RISCVRegisterInfo.cpp:159–162`），寄存器分配不碰它们；
  vsetvli 由专门的 pass `RISCV/RISCVInsertVSETVLI.cpp` 按需插入。
- mstatus.VS（位 10:9）和浮点的 FS 同理：VS 为 Off 时向量指令非法（QEMU `trans_rvv.c.inc` 的 require_rvv
  检查 VS 不为 DISABLED）。

## 6. 调用约定

- 标准调用约定下，v 寄存器全部是调用者保存：`CSR_ILP32_LP64` 等列表里没有 V 寄存器。
- 函数加 `__attribute__((riscv_vector_cc))`（clang `include/clang/Basic/Attr.td:3471`）后改用向量调用约定，
  v1–v7、v24–v31 变成被调用者保存（`RISCV/RISCVCallingConv.td:29` 的 CSR_V，:33 起的 `…_V` 列表）。
