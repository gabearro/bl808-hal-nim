{.emit: """
static void bl808_nim_vendor_vprintf(const char *fmt, va_list ap) {
  const char *p = fmt;
  if (!fmt) return;
  while (p && *p) {
    if (*p != '%') {
      bl808_nim_vendor_print_char(*p++);
      continue;
    }
    p++;
    while (*p == '0' || *p == '-' || *p == '+' || *p == ' ' || *p == '#') p++;
    while (*p >= '0' && *p <= '9') p++;
    if (*p == 'l') {
      p++;
      if (*p == 'l') p++;
    }
    switch (*p) {
    case 's':
      bl808_nim_vendor_puts_raw(va_arg(ap, const char *));
      break;
    case 'd':
    case 'i': {
      int v = va_arg(ap, int);
      if (v < 0) {
        bl808_nim_vendor_print_char('-');
        v = -v;
      }
      bl808_nim_vendor_print_u32((uint32_t)v, 10);
      break;
    }
    case 'u':
      bl808_nim_vendor_print_u32(va_arg(ap, unsigned int), 10);
      break;
    case 'p':
      bl808_nim_vendor_puts_raw("0x");
      bl808_nim_vendor_print_u32((uint32_t)(uintptr_t)va_arg(ap, void *), 16);
      break;
    case 'x':
    case 'X':
      bl808_nim_vendor_print_u32(va_arg(ap, unsigned int), 16);
      break;
    case 'c':
      bl808_nim_vendor_print_char((char)va_arg(ap, int));
      break;
    case '%':
      bl808_nim_vendor_print_char('%');
      break;
    default:
      bl808_nim_vendor_print_char('%');
      if (*p) bl808_nim_vendor_print_char(*p);
      break;
    }
    if (*p) p++;
  }
}
""".}
