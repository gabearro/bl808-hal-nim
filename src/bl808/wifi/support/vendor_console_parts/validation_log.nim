proc validationPutsRaw(s: cstring) =
  when not defined(bl808WifiValidationLog):
    if s == nil:
      return
    var i = 0
    while s[i] != '\0':
      hw_validation_log_byte(s[i].uint8)
      inc i
  else:
    discard s
