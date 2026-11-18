ENTRY(_start)
SECTIONS {
  . = 0x40200000; /* Don't overlap with the DTB at RAM start. */

  __kernel_start = .;

  .text : ALIGN(4096) {
    __text_start = .;
    *(.text .text.*)
    . = ALIGN(4096);
    __text_end = .;
  }

  .rodata : ALIGN(4096) {
    __rodata_start = .;
    *(.rodata .rodata.*)
    . = ALIGN(4096);
    __rodata_end = .;
  }

  .data : ALIGN(4096) {
    __data_start = .;
    *(.data .data.*)
    *(.data.rel.ro .data.rel.ro.*)
    *(.sdata .sdata.*)
    *(.got .got.*)
    . = ALIGN(4096);
    __data_end = .;
  }

  .bss : ALIGN(4096) {
    __bss_start = .;
    *(.bss .bss.*)
    *(.sbss .sbss.*)
    *(COMMON)
    . = ALIGN(4096);
    __bss_end = .;
  }

  __kernel_end = .;

  /DISCARD/ : {
    *(.eh_frame)
    *(.eh_frame_hdr)
    *(.eh_frame.*)
  }
}
