## Board wiring and fixed platform numbers for the Ox64 (BL808, M0 core).
## Constants only, so host tests can import it.
##
##   PCM5102A               SSD1322 OLED (4-wire SPI)     VS1838B IR receiver
##   BCK   GPIO20           SCLK (D0)  GPIO27             S   GPIO19
##   LCK   GPIO21           SDIN (D1)  GPIO25             +   3V3
##   DIN   GPIO23           CS         GPIO24             -   GND
##   SCK   GND              D/C        GPIO28
##   FMT   GND (I2S)        RES        GPIO29
##   XSMT  3V3 (unmuted)    VCC/GND    3V3/GND
##   VIN   3V3 or 5V, GND
##
## BL808 pin functions repeat every four GPIOs (datasheet pin tables):
##   GPIO mod 4 = 0: I2S_BCLK / SPI_SS     1: I2S_FS / SPI_MOSI
##                2: I2S_DI   / SPI_MISO   3: I2S_DO / SPI_SCLK
## Kept clear: UART0 console (14, 15), JTAG (6, 7, 12, 13), the microSD
## nets (0..5) and the D0 console (16, 17). GPIO22 and GPIO26 stay free:
## 26 is where the OLED data line moves if the GLB "SPI0 swap MOSI/MISO"
## bit has to be set (see `OledSpiSwap`).

# By path, not `bl808/flash_layout`: host tests build without the repo's
# config, so `src` is not on their module path.
import ../../src/bl808/flash_layout

const
  ConsoleTxPin* = 14'u32
  ConsoleRxPin* = 15'u32
  ConsoleBaud* {.intdefine.} = 230_400

  I2sBclkPin* {.intdefine.} = 20
  I2sFsPin* {.intdefine.} = 21
  I2sDoPin* {.intdefine.} = 23

  OledSclkPin* {.intdefine.} = 27
  OledSdinPin* {.intdefine.} = 25
  OledCsPin* {.intdefine.} = 24
  OledDcPin* {.intdefine.} = 28
  OledResPin* {.intdefine.} = 29
  OledSpiSwap* = defined(radioOledSpiSwap)
    ## Build with -d:radioOledSpiSwap -d:OledSdinPin=26 if the panel stays
    ## dark: it swaps which of the two SPI data pads is the output.
  OledSpiHz* = 9_000_000
    ## The SSD1322 takes at most 10 MHz.

  IrPin* {.intdefine.} = 19

  # ---- Flash: presets and remembered settings -------------------------------
  # Physical flash offsets: the HAL's application-data partition (512 KB
  # below the WASM store, clear of the M0/LP/D0 images). Erase unit: one
  # 4 KB sector; records are upstream's 256-byte pages.
  StoreOffset* {.intdefine.} = AppDataFlashOffset.int
  StoreSectors* = 128
  FlashSector* = 4096
  FlashPage* = 256
  SettingsRingSector* = 0     ## 2 sectors = 32 record slots
  UrlRingSector* = 2          ## 2 sectors = 32 record slots
  RingSectors* = 2
  PresetMarkerSector* = 4
  PresetFirstSector* = 5      ## slots 1..99, one sector each (5..103)

static:
  doAssert I2sBclkPin mod 4 == 0, "I2S_BCLK needs a GPIO with pin mod 4 == 0"
  doAssert I2sFsPin mod 4 == 1, "I2S_FS needs a GPIO with pin mod 4 == 1"
  doAssert I2sDoPin mod 4 == 3, "I2S_DO needs a GPIO with pin mod 4 == 3"
  doAssert OledSclkPin mod 4 == 3, "SPI_SCLK needs a GPIO with pin mod 4 == 3"
  doAssert OledSdinPin mod 4 == (if OledSpiSwap: 2 else: 1),
    "the OLED data pin must be the SPI pad that is the master's output"
  doAssert PresetFirstSector + 99 <= StoreSectors
  doAssert StoreSectors * FlashSector <= AppDataFlashLen.int
