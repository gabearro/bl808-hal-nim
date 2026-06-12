proc validationPutsRaw(s: cstring) =
  when not defined(bl808WifiValidationLog):
    if s == nil:
      return
    var charIndex = 0
    while s[charIndex] != '\0':
      hw_validation_log_byte(s[charIndex].uint8)
      inc charIndex
  else:
    discard s
