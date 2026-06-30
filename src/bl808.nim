## BL808 Hardware Abstraction Layer for the Pine64 Ox64.
##
## Complete HAL covering all peripherals on D0 (C906), M0 (E907), and LP (E902).
##
## Build for a specific core:
##   nim c -d:bl808m0 your_firmware.nim   # M0 (E907, RV32IMAFC, 320 MHz)
##   nim c -d:bl808d0 your_firmware.nim   # D0 (C906, RV64IMAFDC, 480 MHz)
##   nim c -d:bl808lp your_firmware.nim   # LP (E902, RV32EMC, 150 MHz)

when not defined(bl808m0) and not defined(bl808d0) and not defined(bl808lp):
  {.error: "Must define target core: -d:bl808m0, -d:bl808d0, or -d:bl808lp".}

# Foundation
import bl808/mmio;    export mmio
import bl808/memmap;  export memmap
import bl808/core;    export core
when defined(bl808d0):
  import bl808/mmu;   export mmu
  import bl808/vm;    export vm

# Clock and system control
import bl808/glb;     export glb
import bl808/cache;   export cache
import bl808/emi;     export emi
import bl808/tzc;     export tzc
import bl808/pds;     export pds

# GPIO and basic peripherals
import bl808/gpio;    export gpio
import bl808/uart;    export uart
import bl808/spi;     export spi
import bl808/i2c;     export i2c
import bl808/pwm;     export pwm
import bl808/timer;   export timer
import bl808/ir;      export ir
import bl808/can;     export can
import bl808/cks;     export cks

# Analog
import bl808/adc;     export adc

# Audio
import bl808/i2s;     export i2s
import bl808/audio;   export audio
import bl808/pdm;     export pdm

# DMA
import bl808/dma;     export dma
import bl808/dma2d;   export dma2d

# Inter-processor communication
import bl808/ipc;     export ipc
import bl808/irq;     export irq

# Flash and storage
import bl808/flash;   export flash
import bl808/sdh;     export sdh
import bl808/psram;   export psram

# Connectivity
import bl808/usb;     export usb
import bl808/emac;    export emac
import bl808/wifi;    export wifi
import bl808/ble;     export ble

# Security
import bl808/sec;     export sec
import bl808/efuse;   export efuse
import bl808/pka;     export pka

# Multimedia (D0 subsystem)
import bl808/dvp;     export dvp
import bl808/mipi;    export mipi
import bl808/dbi;     export dbi
import bl808/osd;     export osd
import bl808/mjpeg;   export mjpeg
import bl808/h264;    export h264
import bl808/npu;     export npu
import bl808/lz4;     export lz4

# Radio blobs (reimplemented from objdump disassembly)
import bl808/blecontroller; export blecontroller
import bl808/wifi_fw;       export wifi_fw

# Startup (must be last — references irq)
import bl808/startup; export startup
