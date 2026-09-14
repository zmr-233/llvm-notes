# 刻意不写 CC：用 make 的内建默认值 cc，由命令行 `make CC="ccache gcc"` 覆盖。
# 命令行上给的变量优先于 Makefile 里的赋值与内建默认值。
CFLAGS = -O2
OBJS = a.o b.o

app: $(OBJS)
	$(CC) $(CFLAGS) -o $@ $^

%.o: %.c
	$(CC) $(CFLAGS) -c $< -o $@

clean:
	rm -f app $(OBJS)

.PHONY: clean
