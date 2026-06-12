## BL808 HAL build configuration
##
## Build for a specific core:
##   nim c -d:bl808m0 examples/m0_blinky.nim
##   nim c -d:bl808d0 examples/d0_uart_hello.nim
##   nim c -d:bl808lp examples/lp_minimal.nim

switch("os", "any")
switch("d", "release")
switch("opt", "size")
switch("stackTrace", "off")
switch("lineTrace", "off")
switch("checks", "off")
switch("assertions", "off")
switch("threads", "off")
switch("panics", "on")
switch("path", "src")

when defined(bl808kernel):
  # CPS kernel mode: need ARC for ref objects, malloc for allocator
  switch("mm", "arc")
  switch("d", "useMalloc")
  switch("d", "noSignalHandler")
  switch("noMain", "on")  # We provide our own bare-metal main()
  switch("passL", "-Wl,--as-needed")  # Don't link unneeded libs
  switch("d", "nimNoLibc")  # Suppress -ldl and other libc link flags

when not defined(qemu) and not defined(bl808kernel):
  # Bare-metal mode without kernel: no memory management
  switch("mm", "none")

# Use riscv64-unknown-elf-gcc for ALL targets (multilib supports rv32 and rv64)
const riscvGcc = "riscv64-unknown-elf-gcc"

when defined(bl808m0) or defined(bl808d0) or defined(bl808lp):
  switch("cc", "gcc")
  switch("gcc.exe", riscvGcc)
  switch("gcc.linkerexe", riscvGcc)
  switch("gcc.options.linker", "")  # Clear -ldl from global nim.cfg

when defined(bl808m0):
  switch("cpu", "riscv32")
  switch("riscv32.any.gcc.exe", riscvGcc)
  switch("riscv32.any.gcc.linkerexe", riscvGcc)
  switch("passC", "-march=rv32imafc -mabi=ilp32f -mcmodel=medlow")
  # The M0 BLE HCI path relies on normal call/return frames while crossing
  # Nim/C callbacks; GCC sibling-call optimization can corrupt that path.
  switch("passC", "-ffunction-sections -fdata-sections -fno-builtin -fno-optimize-sibling-calls")
  # Disable GCC -Os crossjumping so assert_err / ke_msg_send tail-call
  # sites match the blob's per-line distinct call sites (T-Head GCC did
  # not aggressively crossjump these). Lifts wifi_fw.nim match rate
  # from ~96% to ~98% of blob call sites.
  switch("passC", "-fno-crossjumping")
  switch("passL", "-march=rv32imafc -mabi=ilp32f -mcmodel=medlow")
  switch("passL", "-nostdlib -nostartfiles -static")
  switch("passL", "-Wl,--gc-sections")
  when defined(bl808jtagram):
    when defined(bl808M0JtagFullRam):
      switch("passL", "-T src/linker/bl808_m0_ram_full.ld")
    else:
      switch("passL", "-T src/linker/bl808_m0_ram.ld")
  elif defined(bl808WifiCachedBss):
    switch("passL", "-T src/linker/bl808_m0_wifi_cached.ld")
  elif defined(bl808WifiNimFw):
    switch("passL", "-T src/linker/bl808_m0_wifi.ld")
  elif defined(bl808enclave):
    switch("passL", "-T src/linker/bl808_m0_enclave.ld")
  elif defined(bl808puf):
    switch("passL", "-T src/linker/bl808_m0_puf.ld")
  else:
    switch("passL", "-T src/linker/bl808_m0.ld")
  switch("passL", "-lgcc")  # GCC builtins (__clzsi2, __ctzsi2, etc.)

elif defined(bl808d0):
  switch("cpu", "riscv64")
  switch("riscv64.any.gcc.exe", riscvGcc)
  switch("riscv64.any.gcc.linkerexe", riscvGcc)
  switch("passC", "-march=rv64imafdc -mabi=lp64d -mcmodel=medany")
  switch("passC", "-ffunction-sections -fdata-sections -fno-builtin")
  switch("passL", "-march=rv64imafdc -mabi=lp64d -mcmodel=medany")
  switch("passL", "-nostdlib -nostartfiles -static")
  switch("passL", "-Wl,--gc-sections")
  when defined(bl808jtagram):
    switch("passL", "-T src/linker/bl808_d0_ram.ld")
  else:
    switch("passL", "-T src/linker/bl808_d0.ld")
  switch("passL", "-lgcc")  # GCC builtins (__clzdi2, __ctzdi2, etc.)

elif defined(bl808lp):
  switch("cpu", "riscv32")
  switch("riscv32.any.gcc.exe", riscvGcc)
  switch("riscv32.any.gcc.linkerexe", riscvGcc)
  # E902 is RV32E: keep LP code and trap entry compatible with x0-x15 only.
  switch("passC", "-march=rv32emc_zicsr -mabi=ilp32e -mcmodel=medlow")
  switch("passC", "-ffunction-sections -fdata-sections -fno-builtin")
  switch("passL", "-march=rv32emc_zicsr -mabi=ilp32e -mcmodel=medlow")
  switch("passL", "-nostdlib -nostartfiles -static")
  switch("passL", "-Wl,--gc-sections")
  when defined(bl808jtagram):
    switch("passL", "-T src/linker/bl808_lp_ram.ld")
  else:
    switch("passL", "-T src/linker/bl808_lp.ld")
  switch("passL", "-lgcc")
