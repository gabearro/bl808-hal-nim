{.emit: """
int snprintf(char *str, size_t size, const char *fmt, ...) {
  Bl808VendorFormatArgs cursor;
  va_start(cursor.args, fmt);
  int result = bl808_nim_vendor_format(str, size, (char *)fmt, &cursor, 0);
  va_end(cursor.args);
  return result;
}

int sprintf(char *str, const char *fmt, ...) {
  Bl808VendorFormatArgs cursor;
  va_start(cursor.args, fmt);
  int result = bl808_nim_vendor_format(str, SIZE_MAX, (char *)fmt, &cursor, 0);
  va_end(cursor.args);
  return result;
}
""".}
