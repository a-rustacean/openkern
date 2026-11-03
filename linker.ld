ENTRY(_start)
SECTIONS {
  . = 0x40200000; /* Don't overlap with DTB */
  .text : { *(.text) }
  .data : { *(.data) }
  .bss : { *(.bss COMMON) }
  . = ALIGN(16); /* Double of pointer size */
  . += 0x10000; /* 64kB stack  */
  stack_top = .;
}
