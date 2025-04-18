/* Tell the linker that we want an x86_64 ELF64 output file */
OUTPUT_FORMAT(elf64-x86-64)

KERNEL_PHYS_START = 0xffffffff80000000;
KERNEL_STACK_SIZE = 0x4000;

/* We want the symbol _start to be our entry point */
ENTRY(_start)

/* Define the program headers we want so the bootloader gives us the right */
/* MMU permissions; this also allows us to exert more control over the linking */
/* process. */
PHDRS
{
    limine_requests PT_LOAD;
    text PT_LOAD;
    rodata PT_LOAD;
    data PT_LOAD;
}

SECTIONS
{
    /* We want to be placed in the topmost 2GiB of the address space, for optimisations */
    /* and because that is what the Limine spec mandates. */
    /* Any address in this region will do, but often 0xffffffff80000000 is chosen as */
    /* that is the beginning of the region. */
    . = KERNEL_PHYS_START;
    __kernel_start = .;

    /* Define a section to contain the Limine requests and assign it to its own PHDR */
    .limine_requests : ALIGN(CONSTANT(MAXPAGESIZE)) {
        KEEP(*(.limine_requests_start))
        KEEP(*(.limine_requests))
        KEEP(*(.limine_requests_end))
    } :limine_requests

    .text : ALIGN(CONSTANT(MAXPAGESIZE)) {
        __kernel_code_start = .;
        *(.text .text.*)
        __kernel_code_end = .;
    } :text

    .rodata : ALIGN(CONSTANT(MAXPAGESIZE)) {
        __kernel_rodata_start = .;
        *(.rodata .rodata.*)
        __kernel_rodata_end = .;
    } :rodata

    .data : ALIGN(CONSTANT(MAXPAGESIZE)) {
        __kernel_data_start = .;
        *(.data .data.*)
        __kernel_data_end = .;
    } :data

    /* NOTE: .bss needs to be the last thing mapped to :data, otherwise lots of */
    /* unnecessary zeros will be written to the binary. */
    /* If you need, for example, .init_array and .fini_array, those should be placed */
    /* above this. */
    .bss : ALIGN(CONSTANT(MAXPAGESIZE)) {
        __kernel_bss_start = .;
        *(COMMON*)
        *(.bss .bss.*)
        __kernel_bss_end = .;

        . = ALIGN(16);
        __kernel_stack_bottom = .;
        . += KERNEL_STACK_SIZE;
        __kernel_stack_top = .;
    } :data

    /* Discard .note.* and .eh_frame* since they may cause issues on some hosts. */
    /DISCARD/ : {
        *(.eh_frame*)
        *(.note .note.*)
    }

    __kernel_end = .;
}
