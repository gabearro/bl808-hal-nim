{.emit: """
#include <stdarg.h>
#include <stdint.h>
#include <stddef.h>
#include <stdio.h>

extern void bl808_nim_vendor_print_char(char c);
extern void bl808_nim_vendor_puts_raw(char *s);
extern int bl808_nim_vendor_format(void *, size_t, char *, void *, uint32_t);
""".}
