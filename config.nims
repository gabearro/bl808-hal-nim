## BL808 HAL build configuration
##
## Build for a specific core:
##   nim c -d:bl808m0 examples/m0_blinky.nim
##   nim c -d:bl808d0 examples/d0_uart_hello.nim
##   nim c -d:bl808lp examples/lp_minimal.nim

switch("os", "any")
switch("mm", "none")
switch("d", "release")
switch("opt", "size")
switch("stackTrace", "off")
switch("lineTrace", "off")
switch("checks", "off")
switch("assertions", "off")
switch("threads", "off")
switch("panics", "on")
switch("path", "src")

when defined(bl808m0):
  switch("cpu", "riscv32")
  switch("passC", "-march=rv32imafc -mabi=ilp32f -mcmodel=medlow")
  switch("passC", "-ffunction-sections -fdata-sections -fno-builtin")
  switch("passL", "-march=rv32imafc -mabi=ilp32f -mcmodel=medlow")
  switch("passL", "-nostdlib -nostartfiles -static")
  switch("passL", "-Wl,--gc-sections")
  switch("passL", "-T src/linker/bl808_m0.ld")
  switch("riscv32.any.gcc.exe", "riscv32-unknown-elf-gcc")
  switch("riscv32.any.gcc.linkerexe", "riscv32-unknown-elf-gcc")

elif defined(bl808d0):
  switch("cpu", "riscv64")
  switch("passC", "-march=rv64imafdc -mabi=lp64d -mcmodel=medany")
  switch("passC", "-ffunction-sections -fdata-sections -fno-builtin")
  switch("passL", "-march=rv64imafdc -mabi=lp64d -mcmodel=medany")
  switch("passL", "-nostdlib -nostartfiles -static")
  switch("passL", "-Wl,--gc-sections")
  switch("passL", "-T src/linker/bl808_d0.ld")
  switch("riscv64.any.gcc.exe", "riscv64-unknown-elf-gcc")
  switch("riscv64.any.gcc.linkerexe", "riscv64-unknown-elf-gcc")

elif defined(bl808lp):
  switch("cpu", "riscv32")
  switch("passC", "-march=rv32emc -mabi=ilp32e -mcmodel=medlow")
  switch("passC", "-ffunction-sections -fdata-sections -fno-builtin")
  switch("passL", "-march=rv32emc -mabi=ilp32e -mcmodel=medlow")
  switch("passL", "-nostdlib -nostartfiles -static")
  switch("passL", "-Wl,--gc-sections")
  switch("passL", "-T src/linker/bl808_lp.ld")
  switch("riscv32.any.gcc.exe", "riscv32-unknown-elf-gcc")
  switch("riscv32.any.gcc.linkerexe", "riscv32-unknown-elf-gcc")
