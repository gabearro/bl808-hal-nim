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

when defined(bl808ZkBuild):
  switch("path", "build/zkbuild-deps/portable")

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
  when defined(bl808AllcoreWasmHttp) and not defined(bl808WifiPreserveCallSites):
    # Merge identical tails so the manager fits below the retained LP image.
    switch("passC", "-fcrossjumping")
  else:
    # Keep distinct assert_err / ke_msg_send sites for blob comparisons.
    switch("passC", "-fno-crossjumping")
  switch("passL", "-march=rv32imafc -mabi=ilp32f -mcmodel=medlow")
  switch("passL", "-nostdlib -nostartfiles -static")
  switch("passL", "-Wl,--gc-sections")
  when defined(bl808jtagram):
    when defined(bl808CsiCapture):
      switch("passL", "-T src/linker/bl808_m0_wifi_csi_ram.ld")
    elif defined(bl808ZkBuild):
      when defined(bl808ZkLoaderTest):
        quit("The proof-gated loader test requires its flash layout; omit bl808jtagram")
      switch("passL", "-T src/linker/bl808_m0_zkproof_ram.ld")
    elif defined(bl808UsbAnchorResident):
      switch("passL", "-T src/linker/bl808_m0_usb_anchor_resident.ld")
    elif defined(bl808M0CachedRam):
      switch("passL", "-T src/linker/bl808_m0_ram_cached.ld")
    elif defined(bl808M0JtagFullRam):
      switch("passL", "-T src/linker/bl808_m0_ram_full.ld")
    else:
      switch("passL", "-T src/linker/bl808_m0_ram.ld")
  elif defined(bl808UsbAnchorApp):
    switch("passL", "-T src/linker/bl808_m0_usb_anchor_app.ld")
  elif defined(bl808ZkBuild):
    switch("passL", "-T src/linker/bl808_m0_zkproof_flash.ld")
  elif defined(bl808AllcoreWasmHttp):
    when defined(bl808WifiMbedTlsCachedWram):
      when not defined(bl808WifiMbedTlsSha1Lease):
        quit("Cached Mbed TLS code requires the hardware lease")
      switch("passC", "-DBL808_WIFI_MBEDTLS_CACHED_WRAM")
      switch("passL", "-T src/linker/bl808_m0_wifi_cached_hot.ld")
    switch("passL", "-T src/linker/bl808_m0_allcore_http.ld")
  elif defined(bl808WifiApp):
    # A Wi-Fi application: 1 MB PSRAM heap, its own globals in PSRAM.
    switch("passL", "-T src/linker/bl808_m0_wifi_app.ld")
  elif defined(bl808WifiHttpServer):
    switch("passL", "-T src/linker/bl808_m0_wifi_http.ld")
  elif defined(bl808WifiCachedBss):
    switch("passL", "-T src/linker/bl808_m0_wifi_cached.ld")
  elif defined(bl808CsiCapture):
    switch("passL", "-T src/linker/bl808_m0_wifi_csi.ld")
  elif defined(bl808WifiNimFw):
    switch("passL", "-T src/linker/bl808_m0_wifi.ld")
  elif defined(bl808EnclaveWram):
    switch("passL", "-T src/linker/bl808_m0_enclave_wram.ld")
  elif defined(bl808enclave):
    switch("passL", "-T src/linker/bl808_m0_enclave.ld")
  elif defined(bl808puf):
    switch("passL", "-T src/linker/bl808_m0_puf.ld")
  elif defined(bl808LargeStack):
    switch("passL", "-T src/linker/bl808_m0_model_smoke.ld")
  else:
    switch("passL", "-T src/linker/bl808_m0.ld")
  switch("passL", "-lgcc")  # GCC builtins (__clzsi2, __ctzsi2, etc.)

elif defined(bl808d0):
  when defined(bl808jtagram) and defined(bl808D0Xip):
    quit("D0 XIP and JTAG RAM are mutually exclusive build modes")
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
  elif defined(bl808D0Xip):
    switch("passL", "-T src/linker/bl808_d0_xip.ld")
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
  when defined(bl808WasmFull) and not defined(bl808jtagram):
    switch("passL", "-Wl,--defsym=__bl808_lp_stack_bytes=4096")
  when defined(bl808jtagram):
    switch("passL", "-T src/linker/bl808_lp_ram.ld")
  else:
    switch("passL", "-T src/linker/bl808_lp.ld")
  switch("passL", "-lgcc")
