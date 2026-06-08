{.emit: """
__attribute__((weak)) int printf(const char *fmt, ...) {
  va_list ap;
  va_start(ap, fmt);
  bl808_nim_vendor_vprintf(fmt, ap);
  va_end(ap);
  return 0;
}

__attribute__((weak)) int puts(const char *s) {
  bl808_nim_vendor_puts_raw(s);
  bl808_nim_vendor_puts_raw("\r\n");
  return 0;
}
""".}
