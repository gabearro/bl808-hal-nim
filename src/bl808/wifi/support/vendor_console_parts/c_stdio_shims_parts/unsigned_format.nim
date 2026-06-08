{.emit: """
static void bl808_nim_vendor_print_u32(uint32_t value, uint32_t base) {
  char buf[11];
  unsigned int pos = 0;
  if (value == 0) {
    bl808_nim_vendor_print_char('0');
    return;
  }
  while (value && pos < sizeof(buf)) {
    uint32_t d = value % base;
    buf[pos++] = (char)(d < 10 ? ('0' + d) : ('A' + d - 10));
    value /= base;
  }
  while (pos) {
    bl808_nim_vendor_print_char(buf[--pos]);
  }
}
""".}
