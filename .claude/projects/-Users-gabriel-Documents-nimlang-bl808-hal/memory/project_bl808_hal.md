---
name: BL808 HAL Project
description: Nim HAL for BL808 tri-core RISC-V SoC on Pine64 Ox64 (128Mbit flash)
type: project
---

BL808 HAL written in Nim targeting all three cores: D0 (C906 RV64), M0 (E907 RV32), LP (E902 RV32E).

**Why:** Enable writing bare-metal firmware for the Ox64 entirely in Nim — covering GPIO, UART, SPI, I2C, Timer, DMA, IPC, interrupts, flash, and power management.

**How to apply:** Build with `-d:bl808m0`, `-d:bl808d0`, or `-d:bl808lp`. Register addresses and bit fields sourced from Bouffalo SDK headers and BL808 Reference Manual v1.3. IPC uses 16KB XRAM at 0x40000000 for shared message passing between cores.
