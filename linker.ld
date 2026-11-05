ENTRY(_start)
SECTIONS {
  . = 0x40200000; /* Don't overlap with DTB */
  .text : { *(.text) }
  .data : { *(.data) }
  .bss : { *(.bss COMMON) }
}
