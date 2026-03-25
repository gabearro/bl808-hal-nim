{.used.}

proc rawoutput(s: string) =
  discard

proc panic(s: string) {.noreturn.} =
  rawoutput(s)
  while true:
    discard
