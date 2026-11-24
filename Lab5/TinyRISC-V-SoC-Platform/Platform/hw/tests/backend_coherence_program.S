# No CBO or fence: the backend must drain MEM and flush cache itself.
.option norvc
.global _start
_start:
    li s0, 0x60010000
    li s1, 0x60010020
    li s2, 0x60010040
    li t0, 0x05000000
    sw t0, 0(s0)
    li t0, 0x03000000
    sw t0, 0(s1)
    li t0, 0x12345678
    sw t0, 0(s2)
    .insn r 0x0b, 7, 1, zero, s0, s1
    .insn r 0x0b, 7, 2, zero, s2, zero
    li t1, 1
    .insn r 0x0b, 7, 3, zero, t1, t1
    .insn r 0x0b, 7, 0, zero, zero, zero
    lw t2, 0(s2)
    .insn r 0x0b, 0, 5, zero, t2, zero
    # Old C is now clean in cache. Change A and repeat without touching C.
    li t0, 0x07000000
    sw t0, 0(s0)
    .insn r 0x0b, 7, 0, zero, zero, zero
    lw t2, 0(s2)
    .insn r 0x0b, 0, 5, zero, t2, zero
1:  j 1b
