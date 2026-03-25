## BL808 BLE 5.0 controller interface.
##
## The BL808 M0 core uses the BLE controller shared with BL602.
## Precompiled blob: libblecontroller_bl602_m1s1.a (1 master, 1 slave)
##                or libblecontroller_bl602_m8s1.a (8 masters, 1 slave)
##
## Link flags: --passL:"-lblecontroller_bl602_m1s1"
##
## The BLE host stack uses a Zephyr BLE port with standard bt_* APIs.
## This module provides:
##   1. Controller-level init (blob API from ble_lib_api.h)
##   2. HCI on-chip interface for host<->controller communication
##   3. Zephyr BLE host stack declarations (bt_enable, bt_le_adv_*, etc.)

# =============================================================================
# BLE Controller C API (from ble_lib_api.h, libblecontroller.a)
# =============================================================================
when defined(bl808m0):

  proc ble_controller_init*(taskPriority: uint8)
    {.importc, cdecl.}
    ## Initialize BLE controller. `taskPriority` is the RTOS task priority.

  proc ble_controller_deinit*()
    {.importc, cdecl.}

  proc blecontroller_main*()
    {.importc, cdecl.}
    ## BLE controller main loop (call from a dedicated task).

  proc ble_controller_get_lib_ver*(): cstring
    {.importc, cdecl.}
    ## Get BLE controller library version string.

  proc ble_controller_sleep*(maxSleepCycles: int32): int32
    {.importc, cdecl.}
    ## Enter BLE sleep. Returns actual sleep cycles.

  proc ble_controller_sleep_restore*()
    {.importc, cdecl.}
    ## Restore after BLE sleep.

  proc ble_controller_set_tx_pwr*(bleTxPower: cint)
    {.importc, cdecl.}
    ## Set BLE TX power level.

  proc ble_controller_get_tx_pwr*(): int8
    {.importc, cdecl.}

  # --- HCI on-chip interface (host<->controller) ---
  type
    HciRecvCb* = proc(data: ptr uint8, len: uint16): uint8 {.cdecl.}

  proc bt_onchiphci_interface_init*(cb: HciRecvCb): uint8
    {.importc, cdecl.}
    ## Initialize the on-chip HCI interface.
    ## `cb` is called when the controller sends data to the host.

  proc bt_onchiphci_send*(pktType: uint8, destId: uint16,
                          pkt: pointer): int8
    {.importc, cdecl.}
    ## Send an HCI packet from host to controller.

  # --- BLE controller internal symbols (for ISR hookup) ---
  proc bflbble_init*()
    {.importc, cdecl.}

  proc bflbble_isr*()
    {.importc, cdecl.}
    ## BLE interrupt handler — call from the M0 BLE IRQ handler.

  proc bflbble_reset*()
    {.importc, cdecl.}

  proc bflbble_sleep_check*(): cint
    {.importc, cdecl.}
    ## Check if BLE can sleep. Returns 1 if sleepable.

# =============================================================================
# Zephyr BLE Host Stack API (from blestack)
#
# The Bouffalo SDK ports the Zephyr BLE host stack.
# These are the standard Zephyr bt_* APIs.
# Link against the blestack library for these.
# =============================================================================
when defined(bl808m0):

  type
    BtReadyCb* = proc(err: cint) {.cdecl.}
      ## Callback when BLE is ready.

    BtAddrLe* {.importc: "bt_addr_le_t".} = object
      addrType*: uint8
      a*: array[6, uint8]

    BtLeAdvParam* {.importc: "struct bt_le_adv_param".} = object
      ## Advertising parameters.

    BtData* {.importc: "struct bt_data".} = object
      ## Advertising data element.

    BtConnCb* {.importc: "struct bt_conn_cb".} = object
      ## Connection callbacks.

  proc bt_enable*(cb: BtReadyCb): cint
    {.importc, cdecl.}
    ## Enable Bluetooth. Calls `cb` when ready.

  proc bt_set_name*(name: cstring): cint
    {.importc, cdecl.}

  proc bt_get_name*(): cstring
    {.importc, cdecl.}

  proc bt_le_adv_start*(param: ptr BtLeAdvParam,
                        ad: ptr BtData, adLen: csize_t,
                        sd: ptr BtData, sdLen: csize_t): cint
    {.importc, cdecl.}
    ## Start BLE advertising.

  proc bt_le_adv_stop*(): cint
    {.importc, cdecl.}

  proc bt_le_scan_start*(param: pointer, cb: pointer): cint
    {.importc, cdecl.}

  proc bt_le_scan_stop*(): cint
    {.importc, cdecl.}

  proc bt_conn_cb_register*(cb: ptr BtConnCb)
    {.importc, cdecl.}

# =============================================================================
# Higher-level Nim BLE API (M0 only)
# =============================================================================
when defined(bl808m0):

  type
    BleError* = enum
      bleOk = 0
      bleFail = -1
      bleNotInit = -2

  proc bleControllerInit*(priority: uint8 = 5) =
    ## Initialize the BLE controller.
    ble_controller_init(priority)

  proc bleControllerDeinit*() =
    ble_controller_deinit()

  proc bleSetTxPower*(power: int) =
    ## Set BLE TX power (dBm, typically -20 to +10).
    ble_controller_set_tx_pwr(power.cint)

  proc bleGetTxPower*(): int8 =
    ble_controller_get_tx_pwr()

  proc bleGetVersion*(): string =
    ## Get BLE controller library version.
    $ble_controller_get_lib_ver()

  proc bleEnable*(readyCb: BtReadyCb): BleError =
    ## Enable the Zephyr BLE host stack.
    let rc = bt_enable(readyCb)
    if rc == 0: bleOk else: bleFail

  proc bleSetName*(name: string): BleError =
    let rc = bt_set_name(name.cstring)
    if rc == 0: bleOk else: bleFail

  proc bleStartAdvertising*(param: ptr BtLeAdvParam,
                            ad: ptr BtData, adLen: int,
                            sd: ptr BtData = nil, sdLen: int = 0): BleError =
    let rc = bt_le_adv_start(param, ad, adLen.csize_t, sd, sdLen.csize_t)
    if rc == 0: bleOk else: bleFail

  proc bleStopAdvertising*(): BleError =
    let rc = bt_le_adv_stop()
    if rc == 0: bleOk else: bleFail
