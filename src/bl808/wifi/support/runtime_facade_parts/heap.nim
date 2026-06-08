proc wpa_supplicant_malloc*(size: csize_t): pointer {.exportc, cdecl.} = c_malloc(size)
proc wpa_supplicant_realloc*(p: pointer; size: csize_t): pointer {.exportc, cdecl.} =
  c_realloc(p, size)
proc wpa_supplicant_zalloc*(nmemb, size: csize_t): pointer {.exportc, cdecl.} =
  c_calloc(nmemb, size)
proc wpa_supplicant_free*(p: pointer) {.exportc, cdecl.} = c_free(p)
proc wpa_supplicant_bzero*(s: pointer; n: csize_t) {.exportc, cdecl.} = zero(s, n.uint)

proc pvPortMalloc*(size: csize_t): pointer {.exportc, cdecl.} = c_malloc(size)
proc pvPortRealloc*(p: pointer; size: csize_t): pointer {.exportc, cdecl.} =
  c_realloc(p, size)
proc pvPortCalloc*(count, size: csize_t): pointer {.exportc, cdecl.} =
  c_calloc(count, size)
proc vPortFree*(p: pointer) {.exportc, cdecl.} = c_free(p)
