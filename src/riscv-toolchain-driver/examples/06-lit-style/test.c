// 一份最小的 driver 测试，RUN/CHECK 行照抄自上游 clang/test/Driver/riscv32-toolchain.c（llvmorg-21.1.8）
// 的 C-RV32-BAREMETAL-ILP32 段。放进 clang/test/Driver/ 后用
//   ninja -C <build> check-clang-driver          （整目录）
//   <build>/bin/llvm-lit -v clang/test/Driver/riscv32-custom.c   （单文件）
// 运行。lit 逐行执行 RUN:，把 %clang/%s/%S 替换掉；FileCheck 按 CHECK 行的顺序在输出里找子串。
//
// UNSUPPORTED: system-windows

// RUN: %clang -### %s -fuse-ld= \
// RUN:   --target=riscv32-unknown-elf --rtlib=platform \
// RUN:   --gcc-toolchain=%S/Inputs/basic_riscv32_tree \
// RUN:   --sysroot=%S/Inputs/basic_riscv32_tree/riscv32-unknown-elf 2>&1 \
// RUN:   | FileCheck -check-prefix=C-RV32-BAREMETAL-ILP32 %s

// C-RV32-BAREMETAL-ILP32: "{{.*}}Inputs/basic_riscv32_tree/lib/gcc/riscv32-unknown-elf/8.0.1/../../../../bin/riscv32-unknown-elf-ld"
// C-RV32-BAREMETAL-ILP32: "--sysroot={{.*}}/Inputs/basic_riscv32_tree/riscv32-unknown-elf"
// C-RV32-BAREMETAL-ILP32: "-X"
// C-RV32-BAREMETAL-ILP32: "{{.*}}/Inputs/basic_riscv32_tree/riscv32-unknown-elf/lib/crt0.o"
// C-RV32-BAREMETAL-ILP32: "{{.*}}/Inputs/basic_riscv32_tree/lib/gcc/riscv32-unknown-elf/8.0.1/crtbegin.o"
// C-RV32-BAREMETAL-ILP32: "-L{{.*}}/Inputs/basic_riscv32_tree/lib/gcc/riscv32-unknown-elf/8.0.1"
// C-RV32-BAREMETAL-ILP32: "-L{{.*}}/Inputs/basic_riscv32_tree/riscv32-unknown-elf/lib"
// C-RV32-BAREMETAL-ILP32: "--start-group" "-lgcc" "-lc" "-lgloss" "--end-group"
// C-RV32-BAREMETAL-ILP32: "{{.*}}/Inputs/basic_riscv32_tree/lib/gcc/riscv32-unknown-elf/8.0.1/crtend.o"
