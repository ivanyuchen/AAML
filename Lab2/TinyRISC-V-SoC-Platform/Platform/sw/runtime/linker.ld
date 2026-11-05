/* sw/runtime/linker.ld */
OUTPUT_ARCH(riscv)
ENTRY(_start)

MEMORY
{
    DDR3_RAM (rwx) : ORIGIN = 0x60000000, LENGTH = 256M
}

_STACK_SIZE = 64M;
_HEAP_SIZE  = 64M;

SECTIONS
{
    .text : {
        . = ALIGN(4);
        _stext = .;
        KEEP(*crt0.o(.text.startup))
        *(.text.startup)
        *(.text .text.*)
        *(.gnu.linkonce.t.*)
        _etext = .;
    } > DDR3_RAM

    .rodata : {
        . = ALIGN(4);
        _srodata = .;
        *(.rodata .rodata.*)
        _erodata = .;
    } > DDR3_RAM

    .data : {
        . = ALIGN(4);
        _sdata = .;
        *(.data .data.*)
        _edata = .;
    } > DDR3_RAM

    .bss : {
        . = ALIGN(4);
        _bss_start = .;
        __bss_start = .;
        *(.bss .bss.*)
        *(COMMON)
        . = ALIGN(4);
        _bss_end = .;
        __bss_end = .;
    } > DDR3_RAM

    .heap (NOLOAD) : {
        . = ALIGN(16);
        _heap_start = .;
        . += _HEAP_SIZE;
        _heap_end = .;
    } > DDR3_RAM

    _end = _heap_start;

    .stack (NOLOAD) : {
        . = ORIGIN(DDR3_RAM) + LENGTH(DDR3_RAM) - _STACK_SIZE;
        . = ALIGN(16);

        _stack_bottom = .;
        . += _STACK_SIZE;
        _stack_top = .;
        __stack_top = .;
    } > DDR3_RAM

    ASSERT(_heap_end <= ORIGIN(DDR3_RAM) + LENGTH(DDR3_RAM),
           "DDR3 RAM overflow: heap")
    ASSERT(_stack_top <= ORIGIN(DDR3_RAM) + LENGTH(DDR3_RAM),
           "DDR3 RAM overflow: stack")
}
