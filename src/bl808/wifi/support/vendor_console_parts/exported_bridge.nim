proc nimVendorPrintChar(c: char) {.exportc: "bl808_nim_vendor_print_char", cdecl.} =
  vendorPrintChar(c)

proc nimVendorPutsRaw(s: cstring) {.exportc: "bl808_nim_vendor_puts_raw", cdecl.} =
  vendorPutsRaw(s)
