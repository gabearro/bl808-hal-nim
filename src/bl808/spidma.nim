## SPI DMA transfers (exported by the SPI HAL).
import spi
when defined(bl808m0) or defined(bl808d0) or defined(bl808lp):
  export SpiDmaTransfer, start, poll, cancel
