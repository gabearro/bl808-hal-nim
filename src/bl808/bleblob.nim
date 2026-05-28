## Optional vendor BLE controller bridge for hardware validation.
##
## The default BL808 vendor path links the BL808 BT/BLE controller archive and
## matching vendor RF archive kept beside this module. Alternate legacy
## controller/RF combinations remain available behind explicit compile-time
## defines.

when defined(bl808m0):
  {.compile: "bleblob_support.c".}
  when defined(bl808BleVendorBtble):
    {.passC: "-DBL808_BLEBLOB_USE_BTBLE=1".}
    when defined(bl808BleVendorQcc743):
      {.passC: "-DBL808_BLEBLOB_USE_QCC743=1".}
      when defined(bl808BleVendorQccPhyInit):
        {.passC: "-DBL808_BLEBLOB_QCC_PHY_INIT=1".}
      when defined(bl808BleVendorBl616PhyRf):
        {.passL: "-L/Users/gabriel/Documents/nimlang/bl808-sdk-ref/drivers/soc/bl616/phyrf/lib-gcc_10.2.0-toolchain_V2.6.1".}
      else:
        {.passL: "-Lbuild/vendor_qcc743".}
    elif defined(bl808BleVendorQccRf):
      {.passC: "-DBL808_BLEBLOB_USE_QCC743_PHYRF=1".}
      {.passL: "-Lbuild/vendor_bl808_fw -Lbuild/vendor_qcc743".}
    elif defined(bl808BleVendorBl808PhyRf):
      {.passC: "-DBL808_BLEBLOB_USE_BL808_PHYRF=1".}
      {.passC: "-DBL808_BLEBLOB_REPLACE_RWIP_DRIVER=1".}
      {.passL: "-Wl,--wrap=rwip_init -Wl,--wrap=rwip_reset".}
      when defined(bl808WifiVendor):
        {.passC: "-DBL808_BLEBLOB_WIFI_COEX=1".}
        # The combined WiFi/BLE validation image links the BL808 BLE RF archive
        # beside the WiFi PHY/RF archive. They overlap on common PHY entry
        # points, but each still supplies symbols the other archive lacks.
        {.passL: "-Wl,--allow-multiple-definition".}
      when defined(bl808BleBlobBl808FullRfInit):
        {.passC: "-DBL808_BLEBLOB_BL808_FULL_RF_INIT=1".}
      {.passL: "-Lsrc/bl808 -Lbuild/vendor_bl808_fw".}
    elif defined(bl808BleVendorBl606pPhyRf):
      {.passC: "-DBL808_BLEBLOB_USE_BL606P_PHYRF=1".}
      when defined(bl808BleVendorBl606pNoPhyInit):
        {.passC: "-DBL808_BLEBLOB_BL606P_NO_PHY_INIT=1".}
      when defined(bl808BleVendorBl606pNoChannelForce):
        {.passC: "-DBL808_BLEBLOB_BL606P_NO_CHANNEL_FORCE=1".}
      {.passL: "-Lbuild/vendor_bl808_fw -Lbuild/bl_iot_sdk_ref/components/platform/soc/bl606p/bl606p_phyrf/lib".}
    elif defined(bl808BleVendorBl616Controller):
      {.passC: "-DBL808_BLEBLOB_USE_BL616_CONTROLLER=1".}
      when defined(bl808BleVendorBl616ControllerM10):
        {.passC: "-DBL808_BLEBLOB_USE_BL616_CONTROLLER_M10=1".}
      {.passC: "-DBL808_BLEBLOB_USE_BL606P_PHYRF=1".}
      when defined(bl808BleVendorBl606pNoPhyInit):
        {.passC: "-DBL808_BLEBLOB_BL606P_NO_PHY_INIT=1".}
      when defined(bl808BleVendorBl606pNoChannelForce):
        {.passC: "-DBL808_BLEBLOB_BL606P_NO_CHANNEL_FORCE=1".}
      {.passL: "-Lbuild/vendor_bl808_fw -Lbuild/sdk_bl808_fw/components/wireless/bluetooth/btblecontroller/lib -Lbuild/bl_iot_sdk_ref/components/platform/soc/bl606p/bl606p_phyrf/lib".}
    else:
      when defined(bl808BleSkipRfInit):
        {.passC: "-DBL808_BLEBLOB_SKIP_RF_INIT=1".}
        {.passL: "-Wl,--wrap=rf_init".}
      when defined(bl808BleRfRestoreInit):
        {.passC: "-DBL808_BLEBLOB_RF_RESTORE_INIT=1".}
        {.passL: "-Wl,--wrap=rf_init".}
      {.passL: "-Lsrc/bl808 -Lbuild/vendor_bl808_fw".}
    {.passL: "-Wl,--wrap=udelay -Wl,--wrap=wait_us -Wl,--wrap=rwip_time_get".}
    when defined(bl808BleVendorCaptureLlcStart):
      {.passC: "-DBL808_BLEBLOB_CAPTURE_LLC_START=1".}
      {.passL: "-Wl,--wrap=llc_start".}
    when defined(bl808BleVendorTrace):
      {.passC: "-DBL808_BLEBLOB_TRACE_INIT=1".}
      {.passL: "-Wl,--wrap=rwip_init -Wl,--wrap=btble_rf_init -Wl,--wrap=co_time_init".}
      {.passL: "-Wl,--wrap=hci_initialize -Wl,--wrap=rwip_driver_init -Wl,--wrap=rwble_init".}
      {.passL: "-Wl,--wrap=btble_aes_init -Wl,--wrap=btble_ke_timer_flush -Wl,--wrap=btble_ke_flush".}
      {.passL: "-Wl,--wrap=sch_arb_init -Wl,--wrap=sch_prog_init -Wl,--wrap=sch_plan_init".}
      {.passL: "-Wl,--wrap=sch_alarm_init -Wl,--wrap=sch_slice_init -Wl,--wrap=lld_init -Wl,--wrap=llm_init".}
    when not defined(bl808BleVendorQcc743):
      {.passC: "-DBL808_BLEBLOB_WRAP_BTBLE_HEAP=1".}
      {.passL: "-Wl,--wrap=btble_ke_mem_init -Wl,--wrap=btble_ke_malloc -Wl,--wrap=btble_ke_free".}
    when defined(bl808BleVendorQcc743):
      when defined(bl808BleVendorBl616PhyRf):
        {.passL: "-Wl,--start-group -Lbuild/vendor_qcc743 -lbtblecontroller_qcc743_ble1m0s1bredr0 -lbl616_phyrf -Wl,--end-group".}
      else:
        {.passL: "-Wl,--start-group -lbtblecontroller_qcc743_ble1m0s1bredr0 -lqcc743_phyrf -Wl,--end-group".}
    elif defined(bl808BleVendorQccRf):
      {.passL: "-Wl,--start-group -lbtblecontroller_bl808_ble1m0s1bredr0 -lqcc743_phyrf -Wl,--end-group".}
    elif defined(bl808BleVendorBl808PhyRf):
      {.passL: "-Wl,--wrap=rf_init".}
      {.passL: "-Wl,--start-group -lbtblecontroller_bl808_ble1m0s1bredr0 -lrf_bl808 -Wl,--end-group".}
    elif defined(bl808BleVendorBl606pPhyRf):
      {.passL: "-Wl,--wrap=rf_init".}
      {.passL: "-Wl,--start-group -lbtblecontroller_bl808_ble1m0s1bredr0 -lbl606p_phyrf -Wl,--end-group".}
    elif defined(bl808BleVendorBl616Controller):
      {.passL: "-Wl,--wrap=rf_init".}
      when defined(bl808BleVendorBl616ControllerM10):
        {.passL: "-Wl,--start-group -lbtblecontroller_bl616_ble1m10s1bredr0 -lbl606p_phyrf -Wl,--end-group".}
      else:
        {.passL: "-Wl,--start-group -lbtblecontroller_bl616_ble1m0s1bredr0 -lbl606p_phyrf -Wl,--end-group".}
    else:
      {.passL: "-Wl,--start-group -lbtblecontroller_bl808_ble1m0s1bredr0 -lrf_bl808 -Wl,--end-group".}
  else:
    {.passL: "-L/Users/gabriel/Documents/nimlang/bl808-sdk-ref/components/wireless/bluetooth/blecontroller/lib".}
  when defined(bl808BleVendorBtble):
    discard
  elif defined(bl808BleVendorRf):
    {.passC: "-DBL808_BLEBLOB_USE_BL616_PHYRF=1".}
    {.passL: "-L/Users/gabriel/Documents/nimlang/bl808-sdk-ref/drivers/soc/bl616/phyrf/lib-gcc_10.2.0-toolchain_V2.6.1".}
    {.passL: "-Wl,--wrap=udelay -Wl,--wrap=wait_us".}
    {.passL: "-Wl,--start-group -lblecontroller_bl602_m1s1 -lbl616_phyrf -Wl,--end-group".}
  else:
    {.passL: "-lblecontroller_bl602_m1s1".}

  type
    HciRecvCb* = proc(pktType: uint8, srcId: uint16, param: ptr uint8,
                      paramLen: uint8) {.cdecl.}

    HciCmdStruct* = object
      opcode*: uint16
      params*: ptr uint8
      paramLen*: uint8

    HciPktStruct* = object
      hciCmd*: HciCmdStruct

  const
    BtHciCmd* = 0'u8

  when defined(bl808BleVendorBtble):
    proc btble_controller_init(taskPriority: uint8)
      {.importc: "btble_controller_init", cdecl.}
    proc btble_controller_deinit()
      {.importc: "btble_controller_deinit", cdecl.}
    proc btblecontroller_main_c()
      {.importc: "btblecontroller_main", cdecl.}
    proc btble_controller_get_lib_ver(): cstring
      {.importc: "btble_controller_get_lib_ver", cdecl.}
    proc btble_controller_sleep(maxSleepCycles: int32): int32
      {.importc: "btble_controller_sleep", cdecl.}
    when defined(bl808BleVendorQcc743):
      proc btble_controller_sleep_restore_c()
        {.importc: "btble_controller_sleep_restore", cdecl.}
    when defined(bl808BleVendorQcc743):
      proc bleblob_qcc_init_extra_heaps()
        {.importc: "bleblob_qcc_init_extra_heaps", cdecl.}
      proc bleblob_qcc_init_phyrf(): cint
        {.importc: "bleblob_qcc_init_phyrf", cdecl.}
    when defined(bl808BleVendorBl616Controller):
      proc bleblob_init_bl606p_phyrf()
        {.importc: "bleblob_init_bl606p_phyrf", cdecl.}
    var btbleTxPower: int8

    proc ble_controller_init*(taskPriority: uint8) =
      when defined(bl808BleVendorQcc743):
        discard bleblob_qcc_init_phyrf()
      when defined(bl808BleVendorBl616Controller):
        bleblob_init_bl606p_phyrf()
      btble_controller_init(taskPriority)
      when defined(bl808BleVendorQcc743):
        bleblob_qcc_init_extra_heaps()

    proc ble_controller_deinit*() =
      btble_controller_deinit()

    proc blecontroller_main*() =
      btblecontroller_main_c()

    proc ble_controller_get_lib_ver*(): cstring =
      btble_controller_get_lib_ver()

    proc ble_controller_sleep*(maxSleepCycles: int32): int32 =
      btble_controller_sleep(maxSleepCycles)

    proc ble_controller_wakeup() =
      when defined(bl808BleVendorQcc743):
        btble_controller_sleep_restore_c()
      else:
        discard

    proc ble_controller_set_tx_pwr*(bleTxPower: cint) =
      btbleTxPower = bleTxPower.int8

    proc ble_controller_get_tx_pwr*(): int8 =
      btbleTxPower
  else:
    proc ble_controller_init*(taskPriority: uint8) {.importc, cdecl.}
    proc ble_controller_deinit*() {.importc, cdecl.}
    proc blecontroller_main*() {.importc, cdecl.}
    proc ble_controller_get_lib_ver*(): cstring {.importc, cdecl.}
    proc ble_controller_sleep*(maxSleepCycles: int32): int32 {.importc, cdecl.}
    proc ble_controller_wakeup() {.importc, cdecl.}
    proc ble_controller_set_tx_pwr*(bleTxPower: cint) {.importc, cdecl.}
    proc ble_controller_get_tx_pwr*(): int8 {.importc, cdecl.}
  proc bt_onchiphci_interface_init*(cb: HciRecvCb): uint8 {.importc, cdecl.}
  proc bt_onchiphci_send*(pktType: uint8, destId: uint16,
                          pkt: ptr HciPktStruct): int8 {.importc, cdecl.}
  when defined(bl808BleVendorBtble):
    proc bflbble_init*() =
      discard

    proc bflbble_isr*() =
      discard

    proc bflbble_isr_clear*() =
      discard

    proc bflbble_reset*() =
      discard

    proc bflbble_sleep_check*(): bool =
      true
  else:
    proc bflbble_init*() {.importc, cdecl.}
    proc bflbble_isr*() {.importc, cdecl.}
    proc bflbble_isr_clear*() {.importc, cdecl.}
    proc bflbble_reset*() {.importc, cdecl.}
    proc bflbble_sleep_check*(): bool {.importc, cdecl.}
  proc bleblob_poll_for(iterations: uint32) {.importc, cdecl.}
  proc bleBlobDbgQueueSendCount*(): uint32
    {.importc: "bleblob_dbg_queue_send_count", cdecl.}
  proc bleBlobDbgQueueRecvCount*(): uint32
    {.importc: "bleblob_dbg_queue_recv_count", cdecl.}
  proc bleBlobDbgQueueNewCount*(): uint32
    {.importc: "bleblob_dbg_queue_new_count", cdecl.}
  proc bleBlobDbgQueueNewLastSize*(): uint32
    {.importc: "bleblob_dbg_queue_new_last_size", cdecl.}
  proc bleBlobDbgQueueNewLastMaxMsg*(): uint32
    {.importc: "bleblob_dbg_queue_new_last_max_msg", cdecl.}
  proc bleBlobDbgQueueNewLastStatus*(): uint32
    {.importc: "bleblob_dbg_queue_new_last_status", cdecl.}
  proc bleBlobDbgHciControllerCount*(): uint32
    {.importc: "bleblob_dbg_hci_controller_count", cdecl.}
  proc bleBlobDbgDmIrqEnabled*(): uint32
    {.importc: "bleblob_dbg_dm_irq_enabled", cdecl.}
  proc bleBlobDbgBleIrqEnabled*(): uint32
    {.importc: "bleblob_dbg_ble_irq_enabled", cdecl.}
  proc bleBlobDbgDmIrqCount*(): uint32
    {.importc: "bleblob_dbg_dm_irq_count", cdecl.}
  proc bleBlobDbgBleIrqCount*(): uint32
    {.importc: "bleblob_dbg_ble_irq_count", cdecl.}
  proc bleBlobDbgRwipScheduleCount*(): uint32
    {.importc: "bleblob_dbg_rwip_schedule_count", cdecl.}
  proc bleBlobDbgSampleTime*()
    {.importc: "bleblob_dbg_sample_time", cdecl.}
  proc bleBlobDbgTimeWord*(index: uint32): uint32
    {.importc: "bleblob_dbg_time_word", cdecl.}
  proc bleBlobDbgReg32*(address: uint32): uint32
    {.importc: "bleblob_dbg_reg32", cdecl.}
  when defined(bl808BleVendorCaptureLlcStart):
    var bleblob_llc_start_seen {.importc.}: uint32
    var bleblob_llc_start_header {.importc.}: array[4, uint32]
    var bleblob_llc_start_msg {.importc.}: array[64, uint8]
    var bleblob_llc_start_em {.importc.}: array[64, uint32]
    var bleblob_llc_start_rx {.importc.}: array[64, uint32]
    var bleblob_llc_start_tx {.importc.}: array[16, uint32]
    var bleblob_llc_start_regs {.importc.}: array[8, uint32]

  proc bleBlobDbgLlcStartSeen*(): uint32 =
    when defined(bl808BleVendorCaptureLlcStart):
      bleblob_llc_start_seen
    else:
      0'u32

  proc bleBlobDbgLlcStartHeader*(index: uint32): uint32 =
    when defined(bl808BleVendorCaptureLlcStart):
      if index < bleblob_llc_start_header.len.uint32:
        bleblob_llc_start_header[index.int]
      else:
        0'u32
    else:
      discard index
      0'u32

  proc bleBlobDbgLlcStartWord*(index: uint32): uint32 =
    when defined(bl808BleVendorCaptureLlcStart):
      let off = index * 4'u32
      if off + 3'u32 < bleblob_llc_start_msg.len.uint32:
        uint32(bleblob_llc_start_msg[off.int]) or
          (uint32(bleblob_llc_start_msg[(off + 1'u32).int]) shl 8) or
          (uint32(bleblob_llc_start_msg[(off + 2'u32).int]) shl 16) or
          (uint32(bleblob_llc_start_msg[(off + 3'u32).int]) shl 24)
      else:
        0'u32
    else:
      discard index
      0'u32

  proc bleBlobDbgLlcStartEmWord*(index: uint32): uint32 =
    when defined(bl808BleVendorCaptureLlcStart):
      if index < bleblob_llc_start_em.len.uint32:
        bleblob_llc_start_em[index.int]
      else:
        0'u32
    else:
      discard index
      0'u32

  proc bleBlobDbgLlcStartRxWord*(index: uint32): uint32 =
    when defined(bl808BleVendorCaptureLlcStart):
      if index < bleblob_llc_start_rx.len.uint32:
        bleblob_llc_start_rx[index.int]
      else:
        0'u32
    else:
      discard index
      0'u32

  proc bleBlobDbgLlcStartTxWord*(index: uint32): uint32 =
    when defined(bl808BleVendorCaptureLlcStart):
      if index < bleblob_llc_start_tx.len.uint32:
        bleblob_llc_start_tx[index.int]
      else:
        0'u32
    else:
      discard index
      0'u32

  proc bleBlobDbgLlcStartRegWord*(index: uint32): uint32 =
    when defined(bl808BleVendorCaptureLlcStart):
      if index < bleblob_llc_start_regs.len.uint32:
        bleblob_llc_start_regs[index.int]
      else:
        0'u32
    else:
      discard index
      0'u32
  proc prepareWirelessDomainC()
    {.importc: "bleblob_prepare_wireless_domain", cdecl.}
  proc restoreWirelessClocksC()
    {.importc: "bleblob_restore_wireless_clocks", cdecl.}
  proc restoreBleSleepStateC()
    {.importc: "bleblob_restore_ble_sleep_state", cdecl.}
  when not defined(bl808BleVendorBtble):
    var ble_dbg_assert_block* {.importc.}: uint32

  proc bleBlobPrepareWirelessDomain*() =
    prepareWirelessDomainC()

  proc bleBlobPoll*(iterations: uint32 = 16) =
    bleblob_poll_for(iterations)

  proc bleBlobAllowAssertReturn*() =
    when not defined(bl808BleVendorBtble):
      ble_dbg_assert_block = 0

  proc ble_controller_sleep_restore*() =
    when defined(bl808BleVendorBtble):
      ble_controller_wakeup()
      restoreBleSleepStateC()
      restoreWirelessClocksC()
    else:
      ble_controller_wakeup()

  proc bleBlobHciCommand*(opcode: uint16, params: ptr uint8,
                          paramLen: uint8): int8 =
    var pkt: HciPktStruct
    pkt.hciCmd.opcode = opcode
    pkt.hciCmd.params = params
    pkt.hciCmd.paramLen = paramLen
    restoreWirelessClocksC()
    let rc = bt_onchiphci_send(BtHciCmd, 0, addr pkt)
    bleBlobPoll(64)
    rc
