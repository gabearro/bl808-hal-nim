{.emit: """
int snprintf(char *str, size_t size, const char *fmt, ...) {
  (void)fmt;
  if (str && size) str[0] = 0;
  return 0;
}
""".}
