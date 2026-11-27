## DMA request routes for sample, display, and waveform FIFOs.
##
## Configure the peripheral before starting a transfer. A completed transfer
## has moved the requested FIFO entries. The peripheral may still have data
## to shift out.

import adc, audio, dma, dmafifo, dbi, i2s, ir, memmap, pdm
export dmafifo, IrDmaTx, DbiDmaTx

func mcu(request: DmaPeriphId; address, control: uint; bit: int;
         direction: DmaFifoDirection): DmaFifoEndpoint =
  const controller = if defined(bl808lp): dma1 else: dma0
  DmaFifoEndpoint(controller: controller, request: request.uint32, address: address,
                  enableRegister: control, enableMask: 1'u32 shl bit,
                  width: width32, direction: direction)

func multimedia(request: DmaMmPeriphId; address, control: uint; bit: int;
                direction: DmaFifoDirection): DmaFifoEndpoint =
  DmaFifoEndpoint(controller: dma2, request: request.uint32, address: address,
                  enableRegister: control, enableMask: 1'u32 shl bit,
                  width: width32, direction: direction)

const
  GpioWaveFifoControl* = GlbBase + 0xB00'u
  GpioWaveFifoData* = GlbBase + 0xB04'u
  DsiFifoControl* = MipiDsiBase + 0x60'u
  DsiFifoTxData* = MipiDsiBase + 0x68'u
  DsiFifoRxData* = MipiDsiBase + 0x6C'u

  GpadcDmaRx* = mcu(dmaPeriphAdcRx, GpipGpadcDmaRdata, GpipGpadcConfig, GpipDmaEn, dmaFifoRead)
  GpdacDmaTx* = mcu(dmaPeriphDacTx, DacDmaWdata, DacDmaConfig, DacDmaTxEn, dmaFifoWrite)
  AudioDmaRx* = mcu(dmaPeriphAudioRx, AudioRxFifoData, AudioRxFifoCtrl,
                    AuadcRxDrqEn, dmaFifoRead)
  AudioDmaTx* = mcu(dmaPeriphAudioTx, AudacTxFifoData, AudacTxFifoCtrl,
                    AudacTxDrqEn, dmaFifoWrite)
  PdmDmaRx* = mcu(dmaPeriphPdmRx, PdmRxFifoData, PdmRxFifoCtrl, PdmRxDrqEn, dmaFifoRead)
  I2sDmaRx* = mcu(dmaPeriphI2sRx, I2sFifoRdata, I2sFifoCfg0, I2sFifoDmaRxEn, dmaFifoRead)
  I2sDmaTx* = mcu(dmaPeriphI2sTx, I2sFifoWdata, I2sFifoCfg0, I2sFifoDmaTxEn, dmaFifoWrite)
  GpioWaveDmaTx* = mcu(dmaPeriphGpioTx, GpioWaveFifoData, GpioWaveFifoControl, 0, dmaFifoWrite)
  DsiDmaTx* = multimedia(dmaMmDsiTx, DsiFifoTxData, DsiFifoControl, 0, dmaFifoWrite)
  DsiDmaRx* = multimedia(dmaMmDsiRx, DsiFifoRxData, DsiFifoControl, 1, dmaFifoRead)
