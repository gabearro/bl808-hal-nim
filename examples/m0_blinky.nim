## M0 blinky example — toggles an LED on a GPIO pin.
##
## Build: nim c -d:bl808m0 examples/m0_blinky.nim
##
## On the Ox64, there is no dedicated LED pin — connect an LED
## to GPIO8 (or change the pin below).

import bl808

const LedPin = 8'u32  # Change to your actual LED GPIO pin

proc main() {.exportc, cdecl.} =
  systemInit()

  # Enable GPIO clock
  enablePeriphClock(periphTimer)

  # Configure LED pin as output
  gpioInitOutput(LedPin, drive2)

  # Blink forever
  while true:
    gpioSet(LedPin)
    delayMs(500)
    gpioClear(LedPin)
    delayMs(500)
