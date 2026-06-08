{.emit: """
void bl808_nim_os_printf(char *fmt, ...) {
  va_list ap;
  va_start(ap, fmt);
  bl808_nim_vendor_vprintf(fmt, ap);
  va_end(ap);
}

void bl808_nim_os_log_write(uint32_t level, char *tag, char *file,
                            int line, char *fmt, ...) {
  (void)level;
  (void)tag;
  (void)file;
  (void)line;
  va_list ap;
  va_start(ap, fmt);
  bl808_nim_vendor_vprintf(fmt, ap);
  va_end(ap);
}
""".}
