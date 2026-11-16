{.emit: """
typedef struct { va_list args; } Bl808VendorFormatArgs;

static int64_t bl808_nim_vendor_arg_signed(void *opaque, unsigned int kind) {
  Bl808VendorFormatArgs *cursor = opaque;
  switch (kind) {
  case 1: return (signed char)va_arg(cursor->args, int);
  case 2: return (short)va_arg(cursor->args, int);
  case 3: return va_arg(cursor->args, long);
  case 4: return va_arg(cursor->args, long long);
  case 5: return va_arg(cursor->args, intmax_t);
  case 6: return _Generic((size_t)0,
    unsigned int: (int64_t)va_arg(cursor->args, int),
    unsigned long: (int64_t)va_arg(cursor->args, long),
    unsigned long long: (int64_t)va_arg(cursor->args, long long));
  case 7: return va_arg(cursor->args, ptrdiff_t);
  default: return va_arg(cursor->args, int);
  }
}

static uint64_t bl808_nim_vendor_arg_unsigned(void *opaque, unsigned int kind) {
  Bl808VendorFormatArgs *cursor = opaque;
  switch (kind) {
  case 1: return (unsigned char)va_arg(cursor->args, int);
  case 2: return (unsigned short)va_arg(cursor->args, int);
  case 3: return va_arg(cursor->args, unsigned long);
  case 4: return va_arg(cursor->args, unsigned long long);
  case 5: return va_arg(cursor->args, uintmax_t);
  case 6: return va_arg(cursor->args, size_t);
  case 7: return _Generic((ptrdiff_t)0,
    int: (uint64_t)va_arg(cursor->args, unsigned int),
    long: (uint64_t)va_arg(cursor->args, unsigned long),
    long long: (uint64_t)va_arg(cursor->args, unsigned long long));
  default: return va_arg(cursor->args, unsigned int);
  }
}

static char *bl808_nim_vendor_arg_string(void *opaque) {
  return va_arg(((Bl808VendorFormatArgs *)opaque)->args, char *);
}

static uintptr_t bl808_nim_vendor_arg_pointer(void *opaque) {
  return (uintptr_t)va_arg(((Bl808VendorFormatArgs *)opaque)->args, void *);
}

static int bl808_nim_vendor_vprintf(const char *fmt, va_list args) {
  Bl808VendorFormatArgs cursor;
  va_copy(cursor.args, args);
  int result = bl808_nim_vendor_format(NULL, 0, (char *)fmt, &cursor, 1);
  va_end(cursor.args);
  return result;
}
""".}
