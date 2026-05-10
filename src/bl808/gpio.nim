## BL808 GPIO driver.
##
## Each GPIO pin has a single 32-bit configuration register at
## GLB_BASE + 0x8C4 + pin*4, containing mode, function, pull, drive,
## interrupt config, and I/O value all in one register.

import mmio, memmap

# =============================================================================
# GPIO configuration register fields (per-pin, 32-bit)
# =============================================================================
const
  GlbUartCfg1 = GlbBase + 0x154'u
  GlbUartCfg2 = GlbBase + 0x158'u
  UartSigDisabled = 0x0F'u32
  Uart0TxSignal = 2'u32
  Uart0RxSignal = 3'u32

  GpioIe*           = 0          # Input enable
  GpioSmt*          = 1          # Schmitt trigger
  GpioDrvShift*     = 2          # Drive strength [3:2]
  GpioDrvMask*      = 0x03'u32 shl GpioDrvShift
  GpioPu*           = 4          # Pull-up
  GpioPd*           = 5          # Pull-down
  GpioOe*           = 6          # Output enable
  GpioFuncSelShift* = 8          # Function select [12:8]
  GpioFuncSelMask*  = 0x1F'u32 shl GpioFuncSelShift
  GpioIntModeShift* = 16         # Interrupt mode [19:16]
  GpioIntModeMask*  = 0x0F'u32 shl GpioIntModeShift
  GpioIntClr*       = 20         # Interrupt clear (write 1)
  GpioIntStat*      = 21         # Interrupt status (read)
  GpioIntMask*      = 22         # Interrupt mask (1 = masked)
  GpioO*            = 24         # Output value
  GpioSet*          = 25         # Atomic set output
  GpioClr*          = 26         # Atomic clear output
  GpioI*            = 28         # Input value (read)
  GpioMode*         = 30         # Pin mode

# =============================================================================
# GPIO function selection values
# =============================================================================
type
  GpioFunc* = enum
    funcSdh         = 0   # SD Host
    funcSpi0        = 1   # SPI0
    funcFlash       = 2   # Serial flash
    funcI2s         = 3   # I2S
    funcPdm         = 4   # PDM
    funcI2c0        = 5   # I2C0
    funcI2c1        = 6   # I2C1
    funcUart        = 7   # UART
    funcEmac        = 8   # Ethernet MAC
    funcCam         = 9   # Camera
    funcAnalog      = 10  # Analog
    funcGpio        = 11  # GPIO (digital I/O)
    funcPwm0        = 16  # PWM0
    funcPwm1        = 17  # PWM1
    funcSpi1        = 18  # SPI1 (D0)
    funcI2c2        = 19  # I2C2 (D0)
    funcI2c3        = 20  # I2C3 (D0)
    funcMmUart      = 21  # UART3 (D0)
    funcDpi         = 22  # DPI display
    funcJtagLp      = 25  # JTAG LP (E902)
    funcJtagM0      = 26  # JTAG M0 (E907)
    funcJtagD0      = 27  # JTAG D0 (C906)

  GpioDrive* = enum
    drive0 = 0
    drive1 = 1
    drive2 = 2
    drive3 = 3

  GpioPull* = enum
    pullNone
    pullUp
    pullDown

  GpioIntMode* = enum
    intFallingEdge   = 0
    intRisingEdge    = 1
    intLowLevel      = 2
    intHighLevel     = 3
    intBothEdges     = 4

# =============================================================================
# Pin configuration address
# =============================================================================
proc pinCfgAddr(pin: uint32): uint {.inline.} =
  GpioConfigBase + pin * 4

# =============================================================================
# Pin configuration API
# =============================================================================
proc gpioSetFunction*(pin: uint32, function: GpioFunc) =
  ## Set the alternate function for a GPIO pin.
  regModify(pinCfgAddr(pin), GpioFuncSelMask, function.uint32 shl GpioFuncSelShift)

proc gpioSetDrive*(pin: uint32, drive: GpioDrive) =
  regModify(pinCfgAddr(pin), GpioDrvMask, drive.uint32 shl GpioDrvShift)

proc gpioSetPull*(pin: uint32, pull: GpioPull) =
  let regAddr = pinCfgAddr(pin)
  case pull
  of pullNone:
    regClear(regAddr, (1'u32 shl GpioPu) or (1'u32 shl GpioPd))
  of pullUp:
    regSet(regAddr, 1'u32 shl GpioPu)
    regClear(regAddr, 1'u32 shl GpioPd)
  of pullDown:
    regClear(regAddr, 1'u32 shl GpioPu)
    regSet(regAddr, 1'u32 shl GpioPd)

proc gpioSetSchmitt*(pin: uint32, enable: bool) =
  if enable:
    regSet(pinCfgAddr(pin), 1'u32 shl GpioSmt)
  else:
    regClear(pinCfgAddr(pin), 1'u32 shl GpioSmt)

# =============================================================================
# GPIO output
# =============================================================================
proc gpioInitOutput*(pin: uint32, drive: GpioDrive = drive1, pull: GpioPull = pullNone) =
  ## Configure a pin as GPIO output.
  let regAddr = pinCfgAddr(pin)
  var cfg = regRead(regAddr)
  # Set function to GPIO, enable output, disable input
  cfg = cfg and not (GpioFuncSelMask or GpioDrvMask or (1'u32 shl GpioIe))
  cfg = cfg or (funcGpio.uint32 shl GpioFuncSelShift)
  cfg = cfg or (1'u32 shl GpioOe)
  cfg = cfg or (drive.uint32 shl GpioDrvShift)
  cfg = cfg or (1'u32 shl GpioSmt)
  # Pull configuration
  cfg = cfg and not ((1'u32 shl GpioPu) or (1'u32 shl GpioPd))
  case pull
  of pullUp:   cfg = cfg or (1'u32 shl GpioPu)
  of pullDown: cfg = cfg or (1'u32 shl GpioPd)
  of pullNone: discard
  regWrite(regAddr, cfg)

proc gpioWrite*(pin: uint32, high: bool) {.inline.} =
  ## Set a GPIO output pin high or low.
  let regAddr = pinCfgAddr(pin)
  if high:
    regSet(regAddr, 1'u32 shl GpioSet)
  else:
    regSet(regAddr, 1'u32 shl GpioClr)

proc gpioSet*(pin: uint32) {.inline.} =
  ## Set a GPIO output pin high (atomic).
  regSet(pinCfgAddr(pin), 1'u32 shl GpioSet)

proc gpioClear*(pin: uint32) {.inline.} =
  ## Set a GPIO output pin low (atomic).
  regSet(pinCfgAddr(pin), 1'u32 shl GpioClr)

proc gpioToggle*(pin: uint32) {.inline.} =
  ## Toggle a GPIO output pin.
  let regAddr = pinCfgAddr(pin)
  let current = (regRead(regAddr) shr GpioO) and 1
  if current == 1:
    regSet(regAddr, 1'u32 shl GpioClr)
  else:
    regSet(regAddr, 1'u32 shl GpioSet)

# =============================================================================
# GPIO input
# =============================================================================
proc gpioInitInput*(pin: uint32, pull: GpioPull = pullNone) =
  ## Configure a pin as GPIO input.
  let regAddr = pinCfgAddr(pin)
  var cfg = regRead(regAddr)
  cfg = cfg and not (GpioFuncSelMask or (1'u32 shl GpioOe))
  cfg = cfg or (funcGpio.uint32 shl GpioFuncSelShift)
  cfg = cfg or (1'u32 shl GpioIe)
  cfg = cfg or (1'u32 shl GpioSmt)
  cfg = cfg and not ((1'u32 shl GpioPu) or (1'u32 shl GpioPd))
  case pull
  of pullUp:   cfg = cfg or (1'u32 shl GpioPu)
  of pullDown: cfg = cfg or (1'u32 shl GpioPd)
  of pullNone: discard
  regWrite(regAddr, cfg)

proc gpioRead*(pin: uint32): bool {.inline.} =
  ## Read the current input level of a GPIO pin.
  (regRead(pinCfgAddr(pin)) and (1'u32 shl GpioI)) != 0

# =============================================================================
# GPIO interrupts
# =============================================================================
proc gpioSetInterrupt*(pin: uint32, mode: GpioIntMode) =
  ## Configure GPIO interrupt mode and unmask the interrupt.
  ## To disable, use gpioDisableInterrupt instead.
  let regAddr = pinCfgAddr(pin)
  regModify(regAddr, GpioIntModeMask, mode.uint32 shl GpioIntModeShift)
  # Unmask interrupt
  regClear(regAddr, 1'u32 shl GpioIntMask)

proc gpioDisableInterrupt*(pin: uint32) =
  ## Disable GPIO interrupt for this pin.
  regSet(pinCfgAddr(pin), 1'u32 shl GpioIntMask)

proc gpioClearInterrupt*(pin: uint32) =
  ## Clear the interrupt flag for a pin.
  regSet(pinCfgAddr(pin), 1'u32 shl GpioIntClr)

proc gpioInterruptActive*(pin: uint32): bool =
  (regRead(pinCfgAddr(pin)) and (1'u32 shl GpioIntStat)) != 0

# =============================================================================
# Alternate function setup helpers
# =============================================================================
proc setUartSignal(pin, uartSignal: uint32) =
  ## Route a GPIO UART pad to a concrete UART signal.
  ##
  ## BL808 uses GPIO function 7 plus GLB_UART_CFG1/2 signal nibbles. The vendor
  ## bflb_gpio_uart_init helper updates both, and clears duplicate signal routes.
  let sig = int(pin mod 12'u32)
  let signal = uartSignal and 0x0F'u32
  var cfg1 = regRead(GlbUartCfg1)
  var cfg2 = regRead(GlbUartCfg2)

  if sig < 8:
    let shift = sig * 4
    cfg1 = (cfg1 and not (0x0F'u32 shl shift)) or (signal shl shift)
  else:
    let shift = (sig - 8) * 4
    cfg2 = (cfg2 and not (0x0F'u32 shl shift)) or (signal shl shift)

  if signal != UartSigDisabled:
    for i in 0 ..< 8:
      if i != sig:
        let shift = i * 4
        if ((cfg1 shr shift) and 0x0F'u32) == signal:
          cfg1 = (cfg1 and not (0x0F'u32 shl shift)) or
                 (UartSigDisabled shl shift)
    for i in 8 ..< 12:
      if i != sig:
        let shift = (i - 8) * 4
        if ((cfg2 shr shift) and 0x0F'u32) == signal:
          cfg2 = (cfg2 and not (0x0F'u32 shl shift)) or
                 (UartSigDisabled shl shift)

  regWrite(GlbUartCfg1, cfg1)
  regWrite(GlbUartCfg2, cfg2)

proc gpioSetupUart*(txPin, rxPin: uint32) =
  ## Configure a pair of pins for UART (function 7).
  setUartSignal(txPin, Uart0TxSignal)
  setUartSignal(rxPin, Uart0RxSignal)

  let txAddr = pinCfgAddr(txPin)
  var txCfg = 0'u32
  txCfg = txCfg or (1'u32 shl GpioIntMask)
  txCfg = txCfg or (1'u32 shl GpioIe) or (1'u32 shl GpioSmt)
  txCfg = txCfg or (1'u32 shl GpioPu)
  txCfg = txCfg or (drive1.uint32 shl GpioDrvShift)
  txCfg = txCfg or (funcUart.uint32 shl GpioFuncSelShift)
  txCfg = txCfg or (1'u32 shl GpioMode)
  regWrite(txAddr, txCfg)

  let rxAddr = pinCfgAddr(rxPin)
  var rxCfg = 0'u32
  rxCfg = rxCfg or (1'u32 shl GpioIntMask)
  rxCfg = rxCfg or (1'u32 shl GpioIe) or (1'u32 shl GpioSmt)
  rxCfg = rxCfg or (1'u32 shl GpioPu)
  rxCfg = rxCfg or (drive1.uint32 shl GpioDrvShift)
  rxCfg = rxCfg or (funcUart.uint32 shl GpioFuncSelShift)
  rxCfg = rxCfg or (1'u32 shl GpioMode)
  regWrite(rxAddr, rxCfg)

proc gpioSetupSdh*(clkPin, cmdPin, dat0Pin, dat1Pin, dat2Pin, dat3Pin: uint32) =
  ## Configure six pins for the SD Host controller.
  for pin in [clkPin, cmdPin, dat0Pin, dat1Pin, dat2Pin, dat3Pin]:
    let regAddr = pinCfgAddr(pin)
    var cfg = regRead(regAddr)
    cfg = cfg and not (GpioFuncSelMask or GpioDrvMask)
    cfg = cfg or (funcSdh.uint32 shl GpioFuncSelShift)
    cfg = cfg or (drive2.uint32 shl GpioDrvShift)
    cfg = cfg or (1'u32 shl GpioIe) or (1'u32 shl GpioSmt)
    if pin == clkPin:
      cfg = cfg or (1'u32 shl GpioOe)
      cfg = cfg and not ((1'u32 shl GpioPu) or (1'u32 shl GpioPd))
    else:
      cfg = cfg or (1'u32 shl GpioPu)
      cfg = cfg and not (1'u32 shl GpioPd)
    regWrite(regAddr, cfg)

proc gpioSetupSpi*(sclkPin, mosiPin, misoPin, csPin: uint32, isMm: bool = false) =
  ## Configure pins for SPI.
  let function = if isMm: funcSpi1 else: funcSpi0

  for pin in [sclkPin, mosiPin, csPin]:
    let regAddr = pinCfgAddr(pin)
    var cfg = regRead(regAddr)
    cfg = cfg and not GpioFuncSelMask
    cfg = cfg or (function.uint32 shl GpioFuncSelShift)
    cfg = cfg or (1'u32 shl GpioOe) or (1'u32 shl GpioSmt)
    regWrite(regAddr, cfg)

  let misoAddr = pinCfgAddr(misoPin)
  var misoCfg = regRead(misoAddr)
  misoCfg = misoCfg and not GpioFuncSelMask
  misoCfg = misoCfg or (function.uint32 shl GpioFuncSelShift)
  misoCfg = misoCfg or (1'u32 shl GpioIe) or (1'u32 shl GpioSmt)
  regWrite(misoAddr, misoCfg)

proc gpioSetupI2c*(sdaPin, sclPin: uint32, which: range[0..3] = 0) =
  ## Configure pins for I2C with open-drain pull-ups.
  let function = case which
    of 0: funcI2c0
    of 1: funcI2c1
    of 2: funcI2c2
    of 3: funcI2c3

  for pin in [sdaPin, sclPin]:
    let regAddr = pinCfgAddr(pin)
    var cfg = regRead(regAddr)
    cfg = cfg and not GpioFuncSelMask
    cfg = cfg or (function.uint32 shl GpioFuncSelShift)
    cfg = cfg or (1'u32 shl GpioIe) or (1'u32 shl GpioOe)
    cfg = cfg or (1'u32 shl GpioSmt) or (1'u32 shl GpioPu)
    regWrite(regAddr, cfg)
