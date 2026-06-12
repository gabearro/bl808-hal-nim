# ======================== BTBLE VENDOR ABI ALIASES ========================
# ---------------------------------------------------------------------------

proc btble_co_list_push_back*(list: ptr CoList,
                              node: ptr CoListNode) {.exportc, cdecl.} =
  ble_co_list_push_back(list, node)

proc btble_co_list_push_front*(list: ptr CoList,
                               node: ptr CoListNode) {.exportc, cdecl.} =
  ble_co_list_push_front(list, node)

proc btble_co_list_pop_front*(list: ptr CoList): ptr CoListNode
    {.exportc, cdecl.} =
  ble_co_list_pop_front(list)

proc btble_co_list_init*(list: ptr CoList) {.exportc, cdecl.} =
  ble_co_list_init(list)

proc btble_co_list_extract*(list: ptr CoList,
                            node: ptr CoListNode) {.exportc, cdecl.} =
  ble_co_list_extract(list, node)

proc btble_co_list_extract_after*(list: ptr CoList, prevNode: ptr CoListNode,
                                  node: ptr CoListNode) {.exportc, cdecl.} =
  ble_co_list_extract_after(list, prevNode, node)

proc btble_co_list_find*(list: ptr CoList, node: ptr CoListNode): bool
    {.exportc, cdecl.} =
  ble_co_list_find(list, node)

proc btble_co_list_insert_after*(list: ptr CoList,
                                 afterNode: ptr CoListNode,
                                 node: ptr CoListNode) {.exportc, cdecl.} =
  ble_co_list_insert_after(list, afterNode, node)

proc btble_co_list_insert_before*(list: ptr CoList,
                                  beforeNode: ptr CoListNode,
                                  node: ptr CoListNode) {.exportc, cdecl.} =
  ble_co_list_insert_before(list, beforeNode, node)

proc btble_co_list_merge*(dest: ptr CoList, src: ptr CoList)
    {.exportc, cdecl.} =
  ble_co_list_merge(dest, src)

proc btble_co_list_pool_init*(list: ptr CoList, pool: pointer,
                              eltSize: uint32, count: uint32,
                              initCb: pointer, lastCb: pointer)
    {.exportc, cdecl.} =
  ble_co_list_pool_init(list, pool, eltSize, count, initCb, lastCb)

proc btble_co_list_size*(list: ptr CoList): uint32 {.exportc, cdecl.} =
  ble_co_list_size(list)

proc btble_co_list_push_back_sublist*(list: ptr CoList,
                                      firstNode: ptr CoListNode,
                                      lastNode: ptr CoListNode)
    {.exportc, cdecl.} =
  if firstNode == nil:
    return
  if list.first == nil:
    list.first = firstNode
  else:
    list.last.next = firstNode
  list.last = lastNode
  if list.last != nil:
    list.last.next = nil

proc btble_co_list_extract_sublist*(list: ptr CoList,
                                    firstNode: ptr CoListNode,
                                    lastNode: ptr CoListNode)
    {.exportc, cdecl.} =
  if firstNode == nil:
    return
  var nodeBeforeSublist: ptr CoListNode = nil
  var sublistHeadSearch = list.first
  while sublistHeadSearch != nil and sublistHeadSearch != firstNode:
    nodeBeforeSublist = sublistHeadSearch
    sublistHeadSearch = sublistHeadSearch.next
  if sublistHeadSearch == nil:
    return
  let afterLast =
    if lastNode != nil: lastNode.next
    else: nil
  if nodeBeforeSublist == nil:
    list.first = afterLast
  else:
    nodeBeforeSublist.next = afterLast
  if list.last == lastNode:
    list.last = nodeBeforeSublist
  if lastNode != nil:
    lastNode.next = nil

proc btble_ke_event_callback_set*(eventId: uint8, cb: KeEventCallback)
    {.exportc, cdecl.} =
  ble_ke_event_callback_set(eventId, cb)

proc btble_ke_event_clear*(eventId: uint8) {.exportc, cdecl.} =
  ble_ke_event_clear(eventId)

proc btble_ke_event_flush*() {.exportc, cdecl.} =
  ble_ke_event_flush()

proc btble_ke_event_get*(eventId: uint8): bool {.exportc, cdecl.} =
  ble_ke_event_get(eventId)

proc btble_ke_event_get_all*(): uint32 {.exportc, cdecl.} =
  ble_ke_event_get_all()

proc btble_ke_event_init*() {.exportc, cdecl.} =
  ble_ke_event_init()

proc btble_ke_event_schedule*() {.exportc, cdecl.} =
  ble_ke_event_schedule()

proc btble_ke_event_set*(eventId: uint8) {.exportc, cdecl.} =
  ble_ke_event_set(eventId)

proc btble_ke_init*() {.exportc, cdecl.} =
  ble_ke_init()

proc btble_ke_flush*() {.exportc, cdecl.} =
  ble_ke_flush()

proc btble_ke_malloc*(size: uint32, mtype: uint32): pointer
    {.exportc, cdecl.} =
  when defined(bl808m0):
    bleCentralTraceCheckRawRa(0x0A00'u32)
  when defined(bl808m0) and bl808BleNimConnectionEnabled:
    if nim_llc_status == 0xC0010001'u32 and size == 0x8C'u32:
      discard mtype
      discard c_memset(addr nim_llc_env_storage[0], 0,
                       nim_llc_env_storage.len.csize_t)
      nim_llc_status = 0xC0010011'u32
      return cast[pointer](addr nim_llc_env_storage[0])
  result = ble_ke_malloc(size, mtype)
  when defined(bl808m0):
    bleCentralTraceCheckRawRa(0x0A01'u32)
proc btble_ke_free*(p: pointer) {.exportc, cdecl.} =
  ble_ke_free(p)

proc btble_ke_check_malloc*(): uint32 {.exportc, cdecl.} =
  ble_ke_check_malloc()

proc btble_ke_is_free*(p: pointer): bool {.exportc, cdecl.} =
  ble_ke_is_free(p)

proc btble_ke_mem_init*(mtype: uint8, heap: ptr uint8, size: uint16)
    {.exportc, cdecl.} =
  discard mtype
  ke_mem_heap = heap
  ke_mem_heap_end = addr cast[ptr UncheckedArray[uint8]](heap)[size.int]
  ble_ke_mem_init()

proc btble_ke_mem_is_empty*(): bool {.exportc, cdecl.} =
  ble_ke_mem_is_empty()

proc btble_ke_msg_alloc*(id: KeMsgId, destId: KeTaskId,
                         srcId: KeTaskId,
                         paramLen: uint16): pointer {.exportc, cdecl.} =
  when defined(bl808m0) and
      bl808BleNimConnectionEnabled:
    when defined(bl808BleBridgeDiag):
      nim_bridge_stage = 0x8000'u32 or uint32(id and 0x00FF'u16)
  ble_ke_msg_alloc(id, destId, srcId, paramLen)

proc btble_ke_msg_send*(param: pointer) {.exportc, cdecl.} =
  when defined(bl808m0) and
      bl808BleNimConnectionEnabled:
    when defined(bl808BleBridgeDiag):
      nim_bridge_stage = 0x8100'u32 or
        (cast[uint32](param) and 0x000000FF'u32)
  ble_ke_msg_send(param)

proc btble_ke_msg_send_basic*(id: KeMsgId, destId: KeTaskId,
                              srcId: KeTaskId) {.exportc, cdecl.} =
  when defined(bl808m0) and
      bl808BleNimConnectionEnabled:
    when defined(bl808BleBridgeDiag):
      nim_bridge_stage = 0x8200'u32 or uint32(id and 0x00FF'u16)
  ble_ke_msg_send_basic(id, destId, srcId)

proc btble_ke_msg_free*(msg: ptr KeMsgHeader) {.exportc, cdecl.} =
  ble_ke_msg_free(msg)

proc btble_ke_msg_dest_id_get*(param: pointer): KeTaskId {.exportc, cdecl.} =
  ble_ke_msg_dest_id_get(param)

proc btble_ke_msg_src_id_get*(param: pointer): KeTaskId {.exportc, cdecl.} =
  ble_ke_msg_src_id_get(param)

proc btble_ke_msg_in_queue*(param: pointer): bool {.exportc, cdecl.} =
  ble_ke_msg_in_queue(param)

proc btble_ke_msg_discard*(msgid: KeMsgId, destId: KeTaskId,
                           srcId: KeTaskId, param: pointer): int32
    {.exportc, cdecl.} =
  ble_ke_msg_discard(msgid, destId, srcId, param)

proc btble_ke_msg_save*(msgid: KeMsgId, destId: KeTaskId,
                        srcId: KeTaskId, param: pointer): int32
    {.exportc, cdecl.} =
  ble_ke_msg_save(msgid, destId, srcId, param)

proc btble_ke_msg_forward*(param: pointer, destId: KeTaskId)
    {.exportc, cdecl.} =
  ble_ke_msg_fobflbard(param, destId)

proc btble_ke_msg_forward_new_id*(param: pointer, id: KeMsgId,
                                  destId: KeTaskId) {.exportc, cdecl.} =
  ble_ke_msg_fobflbard_new_id(param, id, destId)

proc btble_ke_queue_extract*(queue: ptr CoList, cmp: QueueCmpFunc,
                             arg: pointer): ptr CoListNode {.exportc, cdecl.} =
  ble_ke_queue_extract(queue, cmp, arg)

proc btble_ke_queue_insert*(queue: ptr CoList, node: ptr CoListNode,
                            cmp: QueueCmpFunc) {.exportc, cdecl.} =
  ble_ke_queue_insert(queue, node, cmp)

proc btble_ke_sleep_check*(): bool {.exportc, cdecl.} =
  ble_ke_sleep_check()

proc btble_ke_state_set*(taskId: KeTaskId, state: uint8) {.exportc, cdecl.} =
  ble_ke_state_set(taskId, state)
proc btble_ke_state_get*(taskId: KeTaskId): uint8 {.exportc, cdecl.} =
  ble_ke_state_get(taskId)

proc btble_ke_task_check*(taskType: uint8): bool {.exportc, cdecl.} =
  ble_ke_task_check(taskType)

proc btble_ke_task_create*(taskType: uint8, desc: ptr KeTaskDesc)
    {.exportc, cdecl.} =
  ble_ke_task_create(taskType, desc)

proc btble_ke_task_delete*(taskType: uint8) {.exportc, cdecl.} =
  ble_ke_task_delete(taskType)

proc btble_ke_task_init*() {.exportc, cdecl.} =
  ble_ke_task_init()

proc btble_ke_task_msg_flush*(taskId: KeTaskId) {.exportc, cdecl.} =
  ble_ke_task_msg_flush(taskId)

proc btble_ke_timer_active*(id: uint16, task: uint16): bool
    {.exportc, cdecl.} =
  ble_ke_timer_active(id, task)

proc btble_ke_timer_clear*(id: uint16, task: uint16) {.exportc, cdecl.} =
  ble_ke_timer_clear(id, task)

proc btble_ke_timer_flush*() {.exportc, cdecl.} =
  while ke_timer_list.first != nil:
    let node = ble_co_list_pop_front(addr ke_timer_list)
    ble_ke_free(node)

proc btble_ke_timer_get*(id: uint16, task: uint16): uint32
    {.exportc, cdecl.} =
  var timerEntry = cast[ptr KeTimer](ke_timer_list.first)
  while timerEntry != nil:
    if timerEntry.id == id and timerEntry.task == task:
      return timerEntry.time
    timerEntry = timerEntry.next
  0

proc btble_ke_timer_set*(id: uint16, task: uint16, delay: uint32)
    {.exportc, cdecl.} =
  ble_ke_timer_set(id, task, delay)

proc btble_controller_init*(taskPriority: uint8) {.exportc, cdecl.} =
  ble_controller_init(taskPriority)
  resetNimControllerState()

proc btble_controller_deinit*() {.exportc, cdecl.} =
  ble_controller_deinit()

proc btblecontroller_main*() {.exportc, cdecl.} =
  blecontroller_main()

proc btble_controller_get_lib_ver*(): cstring {.exportc, cdecl.} =
  ble_controller_get_lib_ver()

proc btble_controller_sleep*(maxSleepCycles: int32): int32
    {.exportc, cdecl.} =
  ble_controller_sleep(maxSleepCycles)

proc btble_controller_remaining_mem*(): uint32 {.exportc, cdecl.} =
  0

proc ble_controller_reset*() {.exportc, cdecl.} =
  rwip_reset()

proc BTBLE_ROM_hook_init*() {.exportc, cdecl.} =
  BLE_ROM_hook_init()

proc dbg_platform_reset_complete*(status: uint32) {.exportc, cdecl.} =
  ble_dbg_platform_reset_complete(status)

proc bt_onchiphci_hanlde_rx_acl*(param: pointer, hostBufData: ptr uint8): uint8
    {.exportc: "bt_onchiphci_hanlde_rx_acl", cdecl.} =
  bt_onchiphci_handle_rx_acl(param, hostBufData)

proc hci_initialize*(initType: uint8) {.exportc, cdecl.} =
  hci_init(initType != 0)

proc hci_is_ext_host*(): bool {.exportc, cdecl.} =
  false

proc hci_build_acl_data*(handle: uint16, data: pointer, len: uint16): pointer
    {.exportc, cdecl.} =
  hci_build_acl_rx_data(handle, data, len)

proc ble_util_buf_init*() {.exportc, cdecl.} =
  em_buf_init()

proc ble_util_buf_acl_tx_alloc*(len: uint16): pointer {.exportc, cdecl.} =
  ble_ke_malloc(len.uint32, 0)

proc ble_util_buf_acl_tx_elt_get*(buf: pointer): pointer {.exportc, cdecl.} =
  buf

proc ble_util_buf_acl_tx_free*(buf: pointer) {.exportc, cdecl.} =
  when defined(bl808m0) and
      bl808BleNimConnectionEnabled:
    when defined(bl808BleBridgeDiag):
      nim_bridge_stage = 0x8300'u32 or
        (cast[uint32](buf) and 0x000000FF'u32)
  when defined(bl808m0) and bl808BleNimConnectionEnabled and
      bl808BleNimManualConnTx:
    let txBufferAddress = cast[uint32](buf)
    if txBufferAddress == NimAclTxEmOffset.uint32 or
        txBufferAddress == cast[uint32](addr nim_acl_empty_tx_buf[0]):
      nim_acl_empty_tx_pending = 0
      if nim_conn_started and nim_acl_empty_tx_queued != 0:
        nim_acl_empty_tx_queued = 0
        discard nimSendEmptyAclNow(activeNimConnectionHandle())
      return
  if buf != nil:
    ble_ke_free(buf)

proc ble_util_buf_adv_tx_alloc*(len: uint16): pointer {.exportc, cdecl.} =
  ble_ke_malloc(len.uint32, 0)

proc ble_util_buf_adv_tx_free*(buf: pointer) {.exportc, cdecl.} =
  if buf != nil:
    ble_ke_free(buf)

proc ble_util_buf_elt_rx_get*(idx: uint8): pointer {.exportc, cdecl.} =
  discard idx
  nil

proc ble_util_buf_llcp_tx_alloc*(len: uint16): pointer {.exportc, cdecl.} =
  let llcpTxBuffer = ble_ke_malloc(len.uint32, 0)
  when defined(bl808m0) and bl808BleNimConnectionEnabled:
    inc nim_llcp_alloc_count
    nim_llcp_alloc_last_len = len.uint32
    nim_llcp_alloc_last_ptr = cast[uint32](llcpTxBuffer)
    nim_llcp_alloc_last_emoff = 0
    nim_llcp_alloc_last_len_field = 0
    if llcpTxBuffer != nil and len >= 7'u16:
      let llcpTxElementBytes = cast[ptr UncheckedArray[uint8]](llcpTxBuffer)
      nim_llcp_alloc_last_emoff =
        uint32(llcpTxElementBytes[4]) or (uint32(llcpTxElementBytes[5]) shl 8)
      nim_llcp_alloc_last_len_field = llcpTxElementBytes[6].uint32
  llcpTxBuffer

proc ble_util_buf_llcp_tx_free*(buf: pointer) {.exportc, cdecl.} =
  when defined(bl808m0) and
      bl808BleNimConnectionEnabled:
    when defined(bl808BleBridgeDiag):
      nim_bridge_stage = 0x8400'u32 or
        (cast[uint32](buf) and 0x000000FF'u32)
  when defined(bl808m0) and bl808BleNimConnectionEnabled:
    let llcpTxBufferAddress = cast[uint32](buf)
    inc nim_llcp_free_count
    nim_llcp_free_last_raw = llcpTxBufferAddress
    if llcpTxBufferAddress == NimLlcpTxEmOffset.uint32 or
        llcpTxBufferAddress == cast[uint32](addr nim_llcp_tx_buf[0]):
      nim_llcp_tx_pending = 0
      inc nim_llcp_free_manual_count
      when bl808BleNimManualConnTx:
        serviceNimConnectionLlcpRxDescriptors()
        nimLlcpTrySendQueued()
        nimLlcpTrySendStartup(activeNimConnectionHandle())
      return
    if buf != nil:
      inc nim_llcp_free_heap_count
  if buf != nil:
    ble_ke_free(buf)

proc ble_util_buf_rx_alloc*(len: uint16): pointer {.exportc, cdecl.} =
  ble_ke_malloc(len.uint32, 0)

proc ble_util_buf_rx_free*(buf: pointer) {.exportc, cdecl.} =
  if buf == nil:
    return
  let rxBufferAddress = cast[uint32](buf)
  if rxBufferAddress < 0x00010000'u32:
    return
  when defined(bl808m0):
    if rxBufferAddress >= BTBLE_EM_BASE and
        rxBufferAddress < BTBLE_EM_BASE + 0x00010000'u32:
      return
  ble_ke_free(buf)

proc ble_util_nb_good_channels*(map: ptr uint8): uint8 {.exportc, cdecl.} =
  if map == nil:
    return 0
  let mapBytes = cast[ptr UncheckedArray[uint8]](map)
  var count: uint8 = 0
  for channelMapByteIndex in 0 ..< 5:
    let channelMapByte = mapBytes[channelMapByteIndex]
    for channelMapBitIndex in 0 ..< 8:
      if channelMapByteIndex * 8 + channelMapBitIndex < 37 and
          (channelMapByte and (1'u8 shl channelMapBitIndex)) != 0:
        inc count
  count

when not (defined(bl808m0) and
    (bl808BleNimConnectionEnabled or bl808BleNimPureCentral)):
  proc lld_read_clock*(): uint32 {.exportc, cdecl.} =
    result = currentBtbleTime()
  proc rwip_current_drift_get*(): uint32 {.exportc, cdecl.} =
    RwipDefaultMaxDriftPpm

  proc rwip_max_drift_get*(sca: uint8): uint32 {.exportc, cdecl.} =
    discard sca
    RwipDefaultMaxDriftPpm

  proc rwip_channel_assess_ble*(channel: uint8, rssi: int8)
      {.exportc, cdecl.} =
    discard channel
    discard rssi

  proc ble_util_pkt_dur_in_us*(length: uint16, rate: uint8): uint16
      {.exportc, cdecl.} =
    case rate
    of 0:
      uint16((uint32(length) + 10'u32) * 8'u32)
    of 1:
      uint16((uint32(length) + 11'u32) * 4'u32)
    of 2:
      uint16(uint32(length) * 64'u32 + 720'u32)
    else:
      uint16(uint32(length) * 16'u32 + 462'u32)

when not (defined(bl808m0) and
    bl808BleNimSchProgEnabled):
  proc rwip_time_get*(time: pointer) {.exportc, cdecl.} =
    if time == nil:
      return
    let rwipTimeWords = cast[ptr UncheckedArray[uint32]](time)
    rwipTimeWords[0] = currentBtbleTime()
    rwipTimeWords[1] = 0
    rwipTimeWords[2] = regRead((BLE_BASE + 0x9C4'u32).uint)

  proc rwip_prevent_sleep_set*(mask: uint16) {.exportc, cdecl.} =
    bflbip_prevent_sleep_mask = bflbip_prevent_sleep_mask or mask.uint32

  proc rwip_prevent_sleep_clear*(mask: uint16) {.exportc, cdecl.} =
    bflbip_prevent_sleep_mask = bflbip_prevent_sleep_mask and not mask.uint32

  proc rwip_sw_int_req*() {.exportc, cdecl.} =
    requestBtbleSwInterrupt()

proc rwip_prevent_sleep_get*(): uint32 {.exportc, cdecl.} =
  bflbip_prevent_sleep_mask

proc rwip_driver_init*(initType: uint8) {.exportc, cdecl.} =
  discard initType
  bflbip_init()

proc rwip_init*(initType: uint8) {.exportc, cdecl.} =
  bflbip_init()
  ble_ke_init()
  em_buf_init()
  hci_init(initType != 0)
  llc_init()
  lld_init(initType != 0)
  bleSettleAfterLldInit()
  llm_init()
  ecc_init()
  lld_sleep_init()
  bdaddr_init()
  resetNimControllerState()

proc rwipResetCore() =
  ble_ke_flush()
  hci_reset()
  bflbip_reset()
  bflbble_reset()
  ea_init()
  bflbip_prevent_sleep_mask = 0
  nim_btble_sw_pending = false
  resetNimControllerState()
  bleArmHciResetSettle()
  quiesceM0PolledBleClicSources()

proc rwip_reset*() {.exportc, cdecl.} =
  let irqState = btbleIrqSave()
  defer:
    btbleIrqRestore(irqState)
  rwipResetCore()
  when defined(bl808m0):
    nimEnableM0BleRuntimeIrqs(false)

proc rwip_isr*() {.exportc, cdecl.} =
  bflbble_isr()

proc rwip_schedule*() {.exportc, cdecl.} =
  discard bleControllerServiceNonblocking()

proc rwip_sleep*(): int32 {.exportc, cdecl.} =
  bflbip_sleep().int32

proc rwip_rand_init*(seed: uint32) {.exportc, cdecl.} =
  discard seed

proc rwip_sca_get*(): uint8 {.exportc, cdecl.} =
  0

proc rwip_wlcoex_set*(en: bool) {.exportc, cdecl.} =
  bflbip_wlcoex_set(en)

proc rwip_eif_get*(): pointer {.exportc, cdecl.} =
  bflbip_eif_get()

when not (defined(bl808m0)):
  proc rwip_timer_alarm_set*(targetCoarse: uint32, targetFine: uint16)
      {.exportc, cdecl.} =
    discard targetCoarse
    discard targetFine

when not (defined(bl808m0)):
  proc rwip_timer_arb_set*(targetCoarse: uint32, targetFine: uint16)
      {.exportc, cdecl.} =
    discard targetCoarse
    discard targetFine

proc rwip_timer_co_set*(target: uint32) {.exportc, cdecl.} =
  discard target

proc rwip_bt_time_to_bts*(time: pointer, bts: pointer) {.exportc, cdecl.} =
  if time != nil and bts != nil:
    discard c_memcpy(bts, time, 8)

proc rwip_bts_to_bt_time*(bts: pointer, time: pointer) {.exportc, cdecl.} =
  if bts != nil and time != nil:
    discard c_memcpy(time, bts, 8)

proc rwip_ch_ass_en_get*(): bool {.exportc, cdecl.} =
  false

proc rwip_ch_ass_en_set*(en: bool) {.exportc, cdecl.} =
  discard en

proc rwip_ch_assess_data_ble_get*(): pointer {.exportc, cdecl.} =
  nil

type
  BleAesResultCb = proc(status: uint8, result: ptr uint8, ctx: pointer)
    {.cdecl.}
  BleAesContinueCb = proc(op: pointer, result: ptr uint8): uint8 {.cdecl.}

  BleAesOpHeader = object
    next: pointer
    continueCb: pointer
    resultCb: pointer
    key: ptr uint8
    value: ptr uint8
    ctx: pointer

var nim_aes_last_result*: array[16, uint8]
var nim_aes_k2_last_result*: array[33, uint8]

proc bleAesDeliver(cb: pointer, ctx: pointer, status: uint8,
                   result: ptr uint8) =
  if cb != nil:
    cast[BleAesResultCb](cb)(status, result, ctx)

proc bleAesCompleteOp(op: pointer, status: uint8, result: ptr uint8) =
  if op == nil:
    return
  let aesOp = cast[ptr BleAesOpHeader](op)
  var callFinal = true
  if status == 0'u8 and aesOp.continueCb != nil:
    callFinal = cast[BleAesContinueCb](aesOp.continueCb)(op, result) != 0'u8
  if callFinal:
    bleAesDeliver(aesOp.resultCb, aesOp.ctx, status, result)
    ble_ke_free(op)

const
  SecEngBase = 0x20004000'u
  SecCtrlProtRead = SecEngBase + 0xF00'u
  TrngCtrl = SecEngBase + 0x200'u
  TrngData = SecEngBase + 0x208'u
  TrngCtrl3 = SecEngBase + 0x234'u
  TrngCtrlProt = SecEngBase + 0x2FC'u
  TrngBusy = 1'u32 shl 0
  TrngTrigger = 1'u32 shl 1
  TrngEnable = 1'u32 shl 2
  TrngDataClear = 1'u32 shl 3
  TrngIntClear = 1'u32 shl 9
  TrngIntMask = 1'u32 shl 11
  TrngRoscEnable = 1'u32 shl 31
  TrngGroupOwnerShift = 4
  TrngGroupOwnerMask = 0x03'u32
  TrngGroup0Owner = 0x01'u32
  TrngReleasedOwner = 0x03'u32
  TrngRequestGroup0 = 0x02'u32
  TrngReleaseAccess = 0x06'u32
  TrngTimeout = 100_000'u32

var
  nim_trng_wait_timeout_count* {.exportc.}: uint32
  nim_trng_wait_last_reg* {.exportc.}: uint32
  nim_trng_wait_last_mask* {.exportc.}: uint32

proc bleTrngNopDelay() {.inline.} =
  {.emit: """
    __asm__ volatile("nop");
    __asm__ volatile("nop");
    __asm__ volatile("nop");
    __asm__ volatile("nop");
  """.}

proc noteTrngWaitTimeout(reg, mask: uint32) {.inline.} =
  inc nim_trng_wait_timeout_count
  nim_trng_wait_last_reg = reg
  nim_trng_wait_last_mask = mask

proc bleTrngOwner(): uint32 {.inline.} =
  (regRead(SecCtrlProtRead) shr TrngGroupOwnerShift) and TrngGroupOwnerMask

proc bleRequestTrngGroup0(releaseWhenDone: var bool): bool =
  releaseWhenDone = false
  case bleTrngOwner()
  of TrngGroup0Owner:
    true
  of TrngReleasedOwner:
    regWrite(TrngCtrlProt, TrngRequestGroup0)
    fenceIo()
    if bleTrngOwner() == TrngGroup0Owner:
      releaseWhenDone = true
      true
    else:
      false
  else:
    false

proc bleReleaseTrngGroup0(releaseWhenDone: bool) =
  if releaseWhenDone:
    regWrite(TrngCtrlProt, TrngReleaseAccess)
    fenceIo()

proc bleTrngWaitIdle(): bool =
  var timeout = TrngTimeout
  while (regRead(TrngCtrl) and TrngBusy) != 0'u32:
    if timeout == 0'u32:
      noteTrngWaitTimeout(TrngCtrl.uint32, TrngBusy)
      return false
    dec timeout
  true

proc bleTrngClearInterrupt() =
  var trngCtrlWord = regRead(TrngCtrl) or TrngIntMask
  regWrite(TrngCtrl, trngCtrlWord or TrngIntClear)
  trngCtrlWord = regRead(TrngCtrl) or TrngIntMask
  regWrite(TrngCtrl, trngCtrlWord and not TrngIntClear)

proc bleTrngDisable() =
  regWrite(TrngCtrl, (regRead(TrngCtrl) and not TrngEnable) or TrngIntMask)
  bleTrngClearInterrupt()

proc bleTrngReadBlock(randomBlockOut: ptr uint8): bool =
  if randomBlockOut == nil:
    return false
  regWrite(TrngCtrl3, regRead(TrngCtrl3) or TrngRoscEnable)
  regWrite(TrngCtrl, regRead(TrngCtrl) or TrngEnable or TrngIntMask)
  bleTrngClearInterrupt()
  bleTrngNopDelay()
  if not bleTrngWaitIdle():
    bleTrngDisable()
    return false

  bleTrngClearInterrupt()
  regWrite(TrngCtrl, regRead(TrngCtrl) or TrngTrigger or TrngIntMask)
  bleTrngNopDelay()
  if not bleTrngWaitIdle():
    bleTrngDisable()
    return false

  let randomBlockBytes = cast[ptr UncheckedArray[uint8]](randomBlockOut)
  var nonZero = false
  for trngDataWordIndex in 0 ..< 8:
    let trngSampleWord = regRead(TrngData + uint(trngDataWordIndex * 4))
    if trngSampleWord != 0'u32:
      nonZero = true
    for sampleByteIndex in 0 ..< 4:
      randomBlockBytes[trngDataWordIndex * 4 + sampleByteIndex] =
        uint8((trngSampleWord shr (sampleByteIndex * 8)) and 0xFF'u32)

  regWrite(TrngCtrl, (regRead(TrngCtrl) and not TrngTrigger) or TrngIntMask)
  regWrite(TrngCtrl, regRead(TrngCtrl) or TrngDataClear or TrngIntMask)
  regWrite(TrngCtrl, (regRead(TrngCtrl) and not TrngDataClear) or TrngIntMask)
  bleTrngDisable()
  nonZero

proc bleFillRandomBytesUnlocked(randomOut: ptr uint8, byteCount: int): bool =
  if byteCount < 0:
    return false
  if byteCount == 0:
    return true
  if randomOut == nil:
    return false
  var releaseTrng = false
  if not bleRequestTrngGroup0(releaseTrng):
    return false
  let randomOutBytes = cast[ptr UncheckedArray[uint8]](randomOut)
  const
    BlockLen = 32
    MaxAttempts = 3
  var trngBlock: array[BlockLen, uint8]
  var randomOutputByteOffset = 0
  while randomOutputByteOffset < byteCount:
    var ok = false
    for attempt in 0 ..< MaxAttempts:
      discard attempt
      if bleTrngReadBlock(addr trngBlock[0]):
        ok = true
        break
    if not ok:
      bleReleaseTrngGroup0(releaseTrng)
      return false
    var blockIndex = 0
    while blockIndex < BlockLen and randomOutputByteOffset < byteCount:
      randomOutBytes[randomOutputByteOffset] = trngBlock[blockIndex]
      inc blockIndex
      inc randomOutputByteOffset
  bleReleaseTrngGroup0(releaseTrng)
  true

proc bleFillRandomBytes(randomOut: ptr uint8, byteCount: int): bool =
  let status = disableInterrupts()
  result = bleFillRandomBytesUnlocked(randomOut, byteCount)
  restoreInterrupts(status)

proc bleReadLe32(sourceBytes: ptr UncheckedArray[uint8], byteOffset: int): uint32 {.inline.} =
  uint32(sourceBytes[byteOffset]) or
    (uint32(sourceBytes[byteOffset + 1]) shl 8) or
    (uint32(sourceBytes[byteOffset + 2]) shl 16) or
    (uint32(sourceBytes[byteOffset + 3]) shl 24)

proc rwip_aes_encrypt*(input: ptr uint8, key: ptr uint8) {.exportc, cdecl.} =
  blecrypto.bleAesEncryptBlock(key, input, addr nim_aes_last_result[0])
  if input == nil or key == nil:
    return

  let status = disableInterrupts()
  bflbip_prevent_sleep_mask = bflbip_prevent_sleep_mask or 0x04'u32
  restoreInterrupts(status)

  copyBytes(BTBLE_EM_BASE + 0x100'u32, key, 16)
  let inputBlockBytes = cast[ptr UncheckedArray[uint8]](input)
  regWrite((BLE_BASE + 0x0B4'u32).uint, bleReadLe32(inputBlockBytes, 0))
  regWrite((BLE_BASE + 0x0B8'u32).uint, bleReadLe32(inputBlockBytes, 4))
  regWrite((BLE_BASE + 0x0BC'u32).uint, bleReadLe32(inputBlockBytes, 8))
  regWrite((BLE_BASE + 0x0C0'u32).uint, bleReadLe32(inputBlockBytes, 12))
  regWrite((BLE_BASE + 0x0C4'u32).uint, 64'u32)
  regWrite((BLE_BASE + BTBLE_INTACK_OFFSET).uint, BtbleIntAesDone)
  enableBtbleInterruptMaskBits(BtbleIntAesDone)
  regOr(BLE_BASE + 0x0B0'u32, 0x01'u32)

proc rwble_init*(initType: uint8) {.exportc, cdecl.} =
  discard initType
  bflbble_init()

proc rwble_isr*() {.exportc, cdecl.} =
  bflbble_isr()

when not (defined(bl808m0) and
    (bl808BleNimConnectionEnabled or bl808BleNimPureCentral)):
  proc lld_rxdesc_check*(requestedRxDescIndex: uint8): pointer {.exportc, cdecl.} =
    discard requestedRxDescIndex
    nil

  proc lld_rxdesc_free*(desc: pointer) {.exportc, cdecl.} =
    discard desc

  proc sch_arb_insert*(elt: pointer): uint8 {.exportc, cdecl.} =
    discard elt
    0

  proc sch_arb_remove*(elt: pointer): uint8 {.exportc, cdecl.} =
    discard elt
    0

  proc sch_slice_per_add*(sliceType: uint8, conhdl: uint8,
                          interval: uint32, anchor: uint32,
                          offset: uint16): uint8 {.exportc, cdecl.} =
    discard sliceType
    discard conhdl
    discard interval
    discard anchor
    discard offset
    0

  proc sch_slice_per_remove*(sliceType: uint8,
                             conhdl: uint8): uint8 {.exportc, cdecl.} =
    discard sliceType
    discard conhdl
    0

const
  LlcProcSlotCount = 9
  LlcAuthPayloadNearlyTimerId = 0x0102'u16
  LlcAuthPayloadRealTimerId = 0x0103'u16
  LlcAuthPayloadNearlyOpMsgId = 0x010C'u16
  LlcAuthPayloadExpiredMsgId = 0x1102'u16
  LlcProcLePing = 8'u8
  LlcEnvEncryptedFlag = 0x0020'u16
  LlcLlcpDisconnectedState = 3'u8

proc llcTaskId(conhdl: uint16): KeTaskId {.inline.} =
  KeTaskId((conhdl shl 8) or 1'u16)

proc llcEnvFor(conhdl: uint16): ptr LlcConEnv {.inline.} =
  if conhdl < LLC_CON_MAX.uint16:
    llc_env[conhdl]
  else:
    nil

proc llcEnvConnectionOpen(env: ptr LlcConEnv): bool {.inline.} =
  env != nil and
    ((llcConnectionRuntime(env).llcpStateFlags and 0x03'u8) !=
      LlcLlcpDisconnectedState)

proc llcEnvEncrypted(env: ptr LlcConEnv): bool {.inline.} =
  env != nil and
    (llcConnectionRuntime(env).linkFlags and LlcEnvEncryptedFlag) != 0'u16

proc llm_le_features_get*(features: pointer) {.exportc, cdecl.} =
  if features != nil:
    var f = llm_util_get_supp_features()
    discard c_memcpy(features, addr f, 8)

proc llcAuthPayloadNearMargin(env: ptr LlcConEnv, timeout: uint16): uint16 =
  let runtime = llcConnectionRuntime(env)
  let interval = uint32(runtime.connInterval)
  let latency = uint32(runtime.connLatency)
  let eventSpan = (latency + 1'u32) * interval
  if eventSpan == 0'u32:
    return 1'u16

  var marginTicks = eventSpan * 8'u32
  let timeoutTicks = uint32(timeout) * 16'u32
  let eventTicks = eventSpan * 2'u32
  if timeoutTicks < marginTicks:
    marginTicks = (timeoutTicks div eventTicks) * eventTicks

  var margin = marginTicks shr 4
  if margin == 0'u32:
    margin = 1'u32
  if margin > 0xFFFF'u32:
    0xFFFF'u16
  else:
    uint16(margin)

proc llcArmAuthPayloadTimers(conhdl: uint16, env: ptr LlcConEnv) =
  if not llcEnvEncrypted(env):
    return
  let task = llcTaskId(conhdl)
  let runtime = llcConnectionRuntime(env)
  btble_ke_timer_set(
    LlcAuthPayloadNearlyTimerId, task,
    uint32(runtime.authPayloadTimeout) * 2'u32)
  btble_ke_timer_set(
    LlcAuthPayloadRealTimerId, task,
    uint32(runtime.authPayloadRealTimeout) * 2'u32)

proc llc_le_ping_set*(conhdl: uint16, timeout: uint16): uint8
    {.exportc, cdecl.} =
  let env = llcEnvFor(conhdl)
  if env == nil:
    return HciStatusCommandDisallowed
  let margin = llcAuthPayloadNearMargin(env, timeout)
  if timeout <= margin:
    return HciStatusUnsupportedFeatureParam
  let runtime = llcConnectionRuntime(env)
  runtime.authPayloadRealTimeout = timeout - margin
  runtime.authPayloadTimeout = timeout
  llcArmAuthPayloadTimers(conhdl, env)
  HciStatusSuccess

proc phy_upd_proc_start*(conhdl: uint16) {.exportc, cdecl.} =
  discard conhdl

proc dl_upd_proc_start*(conhdl: uint16) {.exportc, cdecl.} =
  discard conhdl

when defined(bl808m0) and bl808BleNimConnectionEnabled and bl808BleNimLlcStart:
  proc nimLlcStart(conhdl: uint16, params: pointer): uint8
      {.exportc: "vendor_llc_start", cdecl.} =
    if params == nil or conhdl >= nim_llc_start_env_slots.len.uint16:
      return 0xFF'u8
    if nim_llc_start_env_slots[conhdl] != nil:
      return 0xFF'u8

    let env = addr nim_llc_start_env_storage[conhdl][0]
    let envView = cast[ptr NimLlcStartEnvView](env)
    let start = nimVendorLlcStartParams(params)
    discard c_memset(env, 0, nim_llc_start_env_storage[conhdl].len.csize_t)
    nim_llc_start_env_slots[conhdl] = env

    btble_ke_state_set(KeTaskId((conhdl shl 8) or 1'u16), 0'u8)
    btble_co_list_init(addr envView.pendingList)

    envView.connIntervalMin = start.connIntervalMin
    envView.connIntervalMax = start.connIntervalMax
    envView.connLatency = start.connLatency
    envView.peerRate = start.peerRate
    discard c_memcpy(cast[pointer](addr envView.peerFeatureSeed[0]),
                     cast[pointer](addr start.peerFeatureSeed[0]), 5)
    llm_le_features_get(cast[pointer](addr envView.leFeatures[0]))
    envView.leFeatures[0] = envView.leFeatures[0] and 0xFB'u8
    envView.leFeatures[3] = envView.leFeatures[3] and 0xFD'u8
    envView.supervisionTimeout = 27'u16

    let rateIdx =
      if start.phyRate < co_rate_to_phy.len.uint8: co_rate_to_phy[start.phyRate]
      else: co_rate_to_phy[0]
    envView.txRate = rateIdx
    envView.rxRate = rateIdx
    envView.eventCounter = 519'u16
    envView.schedulerWord = 0x429000FB'u32
    envView.txPacketTime = 27'u16
    envView.txOctets = 328'u16
    envView.rxOctets = 328'u16
    envView.maxTxTime = start.controllerDefaults.maxTxTime
    let maxRxTime =
      if rateIdx == 3'u8:
        let a = start.controllerDefaults.maxRxTime
        if a < 0x0A90'u16: a else: 0x0A90'u16
      else:
        start.controllerDefaults.maxRxTime
    envView.maxRxTime = maxRxTime
    envView.minEventSpacing = start.controllerDefaults.minEventSpacing
    envView.localSleepClockAccuracy = start.controllerDefaults.localSleepClockAccuracy
    envView.peerSleepClockAccuracy = start.controllerDefaults.peerSleepClockAccuracy
    var envFlags = envView.flags and 0xFFFE'u16
    if start.directAnchorMode == 0'u8:
      envFlags = envFlags or 1'u16
    envView.flags = envFlags
    envView.authPayloadTimeout = start.controllerDefaults.authPayloadTimeout
    envView.channelSelection = start.controllerDefaults.channelSelection
    envView.connEventLenMin = start.controllerDefaults.connEventLenMin
    envView.connEventLenMax = start.controllerDefaults.connEventLenMax

    var lldParams: array[48, uint8]
    let lld = nimLldConStartParams(addr lldParams[0])
    lld.accessAddress = start.accessAddress
    lld.crcInit = start.crcInit
    lld.transmitWindowSize = start.transmitWindowSize
    lld.windowOffset = start.windowOffset
    lld.interval = start.connIntervalMin
    lld.latency = start.connIntervalMax
    lld.supervisionTimeout = start.connLatency
    lld.channelMap = start.peerFeatureSeed
    lld.hopIncrement = start.hopSca
    lld.peerSleepClockAccuracy = start.peerRate
    lld.timingFine = start.timingFine
    lld.timingClock = start.timingClock
    lld.anchorClock = start.anchorClock
    lld.timingSelector = start.directAnchorMode
    lld.rate = start.phyRate
    lld.peerRxAddrType = start.peerRxAddrType

    result = nimLldConStart(conhdl, addr lldParams[0])
    discard llc_le_ping_set(conhdl, 3000'u16)
    phy_upd_proc_start(conhdl)
    dl_upd_proc_start(conhdl)
    when bl808BleNimManualConnTx and bl808BleNimLlcStartInitialLlcp:
      if result == 0'u8:
        discard nimLlcpSendInitialNow(conhdl)
    if result != 0'u8:
      nim_llc_start_env_slots[conhdl] = nil

proc llc_llcp_tx_check*(conhdl: uint16) {.exportc, cdecl.} =
  discard conhdl

proc llc_cmd_cmp_send*(conhdl: uint16, opcode: uint16, status: uint8)
    {.exportc, cdecl.} =
  llc_common_cmd_complete_send(conhdl, opcode, status)

proc llc_cmd_stat_send*(conhdl: uint16, opcode: uint16, status: uint8)
    {.exportc, cdecl.} =
  llc_common_cmd_status_send(conhdl, opcode, status)

proc llc_role_get*(conhdl: uint16): uint8 {.exportc, cdecl.} =
  discard conhdl
  0

type LlcProcErrCallback = proc(conhdl: uint16, status: uint8,
                               param: pointer) {.cdecl.}

type LlcProcEnvView {.packed.} = object
  errCallback: pointer
  procId: uint8
  state: uint8
  statePadding: uint8

static:
  doAssert offsetof(LlcProcEnvView, errCallback) == 0
  doAssert offsetof(LlcProcEnvView, procId) == 4
  doAssert offsetof(LlcProcEnvView, state) == 5
  doAssert offsetof(LlcProcEnvView, statePadding) == 6

var llc_proc_slots: array[LLC_CON_MAX, array[LlcProcSlotCount, pointer]]

template llcProcEnv(procEnv: pointer): ptr LlcProcEnvView =
  cast[ptr LlcProcEnvView](procEnv)

proc llcProcUpdateTaskState(conhdl: uint16, procId: uint8, setBit: bool) =
  if procId >= 8'u8:
    return
  let task = llcTaskId(conhdl)
  let mask = uint8(1'u16 shl procId)
  var state = btble_ke_state_get(task)
  if setBit:
    state = state or mask
  else:
    state = state and not mask
  btble_ke_state_set(task, state)

proc llcProcSlot(conhdl: uint16, procId: uint8): ptr pointer =
  if conhdl < LLC_CON_MAX.uint16 and procId < LlcProcSlotCount.uint8:
    addr llc_proc_slots[int(conhdl)][int(procId)]
  else:
    nil

proc llc_proc_get*(conhdl: uint16, procId: uint8): pointer
    {.exportc, cdecl.} =
  let llcProcedureSlot = llcProcSlot(conhdl, procId)
  if llcProcedureSlot == nil:
    nil
  else:
    llcProcedureSlot[]

proc llc_proc_state_get*(procEnv: pointer): uint8
    {.exportc, cdecl.} =
  if procEnv == nil:
    0
  else:
    llcProcEnv(procEnv).state

proc llc_proc_state_set*(procEnv: pointer, conhdl: uint16, state: uint8)
    {.exportc, cdecl.} =
  discard conhdl
  if procEnv != nil:
    llcProcEnv(procEnv).state = state

proc llc_proc_timer_pause_set*(conhdl: uint16, enable: bool)
    {.exportc, cdecl.} =
  discard conhdl
  discard enable

proc llc_proc_timer_set*(conhdl: uint16, procId: uint8, delay: uint32)
    {.exportc, cdecl.} =
  discard conhdl
  discard procId
  discard delay

proc llc_proc_unreg*(conhdl: uint16, procId: uint8) {.exportc, cdecl.} =
  if conhdl < LLC_CON_MAX.uint16 and procId < LlcProcSlotCount.uint8:
    llc_proc_slots[int(conhdl)][int(procId)] = nil
    llcProcUpdateTaskState(conhdl, procId, false)

proc llc_proc_reg*(conhdl: uint16, procId: uint8,
                   procEnv: pointer): uint32 {.exportc, cdecl.}

proc aes_alloc*(size: uint32, continueCb: pointer, cb: pointer,
                ctx: pointer): pointer {.exportc, cdecl.} =
  let allocSize =
    if size < sizeof(BleAesOpHeader).uint32:
      sizeof(BleAesOpHeader).uint32
    else:
      size
  result = ble_ke_malloc(allocSize, 0)
  if result == nil:
    return
  discard c_memset(result, 0, allocSize.csize_t)
  let aesOp = cast[ptr BleAesOpHeader](result)
  aesOp.continueCb = continueCb
  aesOp.resultCb = cb
  aesOp.ctx = ctx

proc aes_rand*(cb: pointer, ctx: pointer) {.exportc, cdecl.} =
  if not bleFillRandomBytes(addr nim_aes_last_result[0], 8):
    discard c_memset(addr nim_aes_last_result[0], 0, 8)
  discard c_memset(addr nim_aes_last_result[8], 0, 8)
  bleAesDeliver(cb, ctx, 0'u8, addr nim_aes_last_result[0])

proc aes_result_handler*(msgid: KeMsgId, destId: KeTaskId,
                         srcId: KeTaskId, param: pointer): int32
    {.exportc, cdecl.} =
  discard msgid
  discard destId
  discard srcId
  if param != nil:
    ble_ke_free(getMsgHeader(param))
  1

proc aes_shift_left_128*(dst: ptr uint8, src: ptr uint8) {.exportc, cdecl.} =
  if dst == nil or src == nil:
    return
  var carry = 0'u8
  for blockByteIndex in countdown(15, 0):
    let sourceByte = cast[ptr UncheckedArray[uint8]](src)[blockByteIndex]
    cast[ptr UncheckedArray[uint8]](dst)[blockByteIndex] = (sourceByte shl 1) or carry
    carry = (sourceByte shr 7) and 1

proc aes_xor_128*(dst: ptr uint8, a: ptr uint8, b: ptr uint8)
    {.exportc, cdecl.} =
  if dst == nil or a == nil or b == nil:
    return
  for blockByteIndex in 0 ..< 16:
    cast[ptr UncheckedArray[uint8]](dst)[blockByteIndex] =
      cast[ptr UncheckedArray[uint8]](a)[blockByteIndex] xor
      cast[ptr UncheckedArray[uint8]](b)[blockByteIndex]

proc bleAesValidBlockArgs(key: ptr uint8, value: ptr uint8): bool {.inline.} =
  key != nil and value != nil

proc bleAesCompleteDirect(cb: pointer, ctx: pointer, ok: bool,
                          result: ptr uint8) =
  bleAesDeliver(cb, ctx, if ok: 0'u8 else: 1'u8, result)

proc aes_start*(op: pointer, key: ptr uint8, value: ptr uint8)
    {.exportc, cdecl.} =
  let ok = bleAesValidBlockArgs(key, value)
  if op == nil:
    if ok:
      blecrypto.bleAesEncryptBlock(key, value, addr nim_aes_last_result[0])
    else:
      discard c_memset(addr nim_aes_last_result[0], 0, 16)
    return
  let aesOp = cast[ptr BleAesOpHeader](op)
  aesOp.key = key
  aesOp.value = value
  if ok:
    blecrypto.bleAesEncryptBlock(key, value, addr nim_aes_last_result[0])
  else:
    discard c_memset(addr nim_aes_last_result[0], 0, 16)
  bleAesCompleteOp(op, if ok: 0'u8 else: 1'u8, addr nim_aes_last_result[0])

proc btble_aes_init*(initType: uint8) {.exportc, cdecl.} =
  discard initType

proc btble_aes_encrypt*(key: ptr uint8, val: ptr uint8, copy: bool,
                        cb: pointer, ctx: pointer) {.exportc, cdecl.} =
  discard copy
  let ok = bleAesValidBlockArgs(key, val)
  if ok:
    blecrypto.bleAesEncryptBlock(key, val, addr nim_aes_last_result[0])
  else:
    discard c_memset(addr nim_aes_last_result[0], 0, 16)
  bleAesCompleteDirect(cb, ctx, ok, addr nim_aes_last_result[0])

type
  BleAesCcmCb = proc(status: uint8, ctx: pointer) {.cdecl.}

var nim_aes_f5_last_result*: array[32, uint8]

proc aes_cmac*(key: ptr uint8, msg: ptr uint8, msgLen: uint16,
               cb: pointer, ctx: pointer) {.exportc, cdecl.} =
  let ok = key != nil and (msg != nil or msgLen == 0'u16)
  if ok:
    blecrypto.bleAesCmac(key, msg, msgLen, addr nim_aes_last_result[0])
  else:
    discard c_memset(addr nim_aes_last_result[0], 0, 16)
  bleAesCompleteDirect(cb, ctx, ok, addr nim_aes_last_result[0])

proc aes_cmac_start*(op: pointer, key: ptr uint8, msg: ptr uint8,
                     msgLen: uint16): uint8 {.exportc, cdecl.} =
  let ok = op != nil and key != nil and (msg != nil or msgLen == 0'u16)
  if ok:
    blecrypto.bleAesCmac(key, msg, msgLen, addr nim_aes_last_result[0])
    bleAesCompleteOp(op, 0'u8, addr nim_aes_last_result[0])
    1'u8
  else:
    discard c_memset(addr nim_aes_last_result[0], 0, 16)
    if op != nil:
      bleAesCompleteOp(op, 1'u8, addr nim_aes_last_result[0])
    0'u8

proc aes_cmac_continue*(op: pointer, aesResult: ptr uint8): uint8
    {.exportc, cdecl.} =
  if op == nil or aesResult == nil:
    return 0'u8
  bleAesCompleteOp(op, 0'u8, aesResult)
  1'u8

proc aes_c1*(key: ptr uint8, r: ptr uint8, p1: ptr uint8, p2: ptr uint8,
             cb: pointer, ctx: pointer) {.exportc, cdecl.} =
  let ok = key != nil and r != nil and p1 != nil and p2 != nil
  if ok:
    blecrypto.bleAesC1(key, r, p1, p2, addr nim_aes_last_result[0])
  else:
    discard c_memset(addr nim_aes_last_result[0], 0, 16)
  bleAesCompleteDirect(cb, ctx, ok, addr nim_aes_last_result[0])

proc aes_s1*(msg: ptr uint8, msgLen: uint16, cb: pointer,
             ctx: pointer) {.exportc, cdecl.} =
  let ok = msg != nil or msgLen == 0'u16
  if ok:
    blecrypto.bleAesS1(msg, msgLen, addr nim_aes_last_result[0])
  else:
    discard c_memset(addr nim_aes_last_result[0], 0, 16)
  bleAesCompleteDirect(cb, ctx, ok, addr nim_aes_last_result[0])

proc aes_ccm*(key: ptr uint8, nonce: ptr uint8, input: ptr uint8,
              output: ptr uint8, msgLen: uint16, micLen: uint8,
              mode: uint8, mic: ptr uint8, aadLen: uint8,
              cb: pointer, ctx: pointer) {.exportc, cdecl.} =
  discard aadLen
  let encrypt = (mode and 1'u8) == 0'u8
  let ok = blecrypto.bleAesCcm(key, nonce, input, output, msgLen, mic, micLen,
                               encrypt)
  if cb != nil:
    cast[BleAesCcmCb](cb)(if ok: 0'u8 else: 1'u8, ctx)

proc aes_f4*(u: ptr uint8, v: ptr uint8, x: ptr uint8, z: uint8,
             cb: pointer, ctx: pointer) {.exportc, cdecl.} =
  let ok = u != nil and v != nil and x != nil
  if ok:
    blecrypto.bleAesF4(u, v, x, z, addr nim_aes_last_result[0])
  else:
    discard c_memset(addr nim_aes_last_result[0], 0, 16)
  bleAesCompleteDirect(cb, ctx, ok, addr nim_aes_last_result[0])

proc aes_f5*(w: ptr uint8, n1: ptr uint8, n2: ptr uint8, a1: ptr uint8,
             a2: ptr uint8, cb: pointer, ctx: pointer)
    {.exportc, cdecl.} =
  let ok = w != nil and n1 != nil and n2 != nil and a1 != nil and a2 != nil
  if ok:
    blecrypto.bleAesF5(w, n1, n2, a1, a2, addr nim_aes_f5_last_result[0])
  else:
    discard c_memset(addr nim_aes_f5_last_result[0], 0, 32)
  bleAesCompleteDirect(cb, ctx, ok, addr nim_aes_f5_last_result[0])

proc aes_f6*(w: ptr uint8, n1: ptr uint8, n2: ptr uint8, r: ptr uint8,
             iocap: ptr uint8, a1: ptr uint8, a2: ptr uint8,
             cb: pointer, ctx: pointer) {.exportc, cdecl.} =
  let ok = w != nil and n1 != nil and n2 != nil and r != nil and
    iocap != nil and a1 != nil and a2 != nil
  if ok:
    blecrypto.bleAesF6(w, n1, n2, r, iocap, a1, a2,
                       addr nim_aes_last_result[0])
  else:
    discard c_memset(addr nim_aes_last_result[0], 0, 16)
  bleAesCompleteDirect(cb, ctx, ok, addr nim_aes_last_result[0])

proc aes_g2*(u: ptr uint8, v: ptr uint8, x: ptr uint8, y: ptr uint8,
             cb: pointer, ctx: pointer) {.exportc, cdecl.} =
  let ok = u != nil and v != nil and x != nil and y != nil
  if ok:
    blecrypto.bleAesG2Raw(u, v, x, y, addr nim_aes_last_result[0])
  else:
    discard c_memset(addr nim_aes_last_result[0], 0, 16)
  bleAesCompleteDirect(cb, ctx, ok, addr nim_aes_last_result[0])

proc aes_h6*(w: ptr uint8, keyId: ptr uint8, cb: pointer,
             ctx: pointer) {.exportc, cdecl.} =
  let ok = w != nil and keyId != nil
  if ok:
    blecrypto.bleAesH6(w, keyId, addr nim_aes_last_result[0])
  else:
    discard c_memset(addr nim_aes_last_result[0], 0, 16)
  bleAesCompleteDirect(cb, ctx, ok, addr nim_aes_last_result[0])

proc aes_h7*(salt: ptr uint8, w: ptr uint8, cb: pointer,
             ctx: pointer) {.exportc, cdecl.} =
  let ok = salt != nil and w != nil
  if ok:
    blecrypto.bleAesH7(salt, w, addr nim_aes_last_result[0])
  else:
    discard c_memset(addr nim_aes_last_result[0], 0, 16)
  bleAesCompleteDirect(cb, ctx, ok, addr nim_aes_last_result[0])

proc aes_h8*(k: ptr uint8, s: ptr uint8, keyId: ptr uint8, cb: pointer,
             ctx: pointer) {.exportc, cdecl.} =
  let ok = k != nil and s != nil and keyId != nil
  if ok:
    blecrypto.bleAesH8(k, s, keyId, addr nim_aes_last_result[0])
  else:
    discard c_memset(addr nim_aes_last_result[0], 0, 16)
  bleAesCompleteDirect(cb, ctx, ok, addr nim_aes_last_result[0])

proc aes_h9*(k: ptr uint8, keyId: ptr uint8, cb: pointer,
             ctx: pointer) {.exportc, cdecl.} =
  let ok = k != nil and keyId != nil
  if ok:
    blecrypto.bleAesH9(k, keyId, addr nim_aes_last_result[0])
  else:
    discard c_memset(addr nim_aes_last_result[0], 0, 16)
  bleAesCompleteDirect(cb, ctx, ok, addr nim_aes_last_result[0])

proc aes_k1*(n: ptr uint8, salt: ptr uint8, p: ptr uint8, pLen: uint16,
             cb: pointer, ctx: pointer) {.exportc, cdecl.} =
  let ok = n != nil and salt != nil and (p != nil or pLen == 0'u16)
  if ok:
    blecrypto.bleAesK1(n, salt, p, pLen, addr nim_aes_last_result[0])
  else:
    discard c_memset(addr nim_aes_last_result[0], 0, 16)
  bleAesCompleteDirect(cb, ctx, ok, addr nim_aes_last_result[0])

proc aes_k2*(n: ptr uint8, p: ptr uint8, pLen: uint16, cb: pointer,
             ctx: pointer) {.exportc, cdecl.} =
  let ok = n != nil and (p != nil or pLen == 0'u16)
  if ok:
    blecrypto.bleAesK2(n, p, pLen, addr nim_aes_k2_last_result[0])
  else:
    discard c_memset(addr nim_aes_k2_last_result[0], 0, 33)
  bleAesCompleteDirect(cb, ctx, ok, addr nim_aes_k2_last_result[0])

proc aes_k3*(n: ptr uint8, cb: pointer, ctx: pointer) {.exportc, cdecl.} =
  discard c_memset(addr nim_aes_last_result[0], 0, nim_aes_last_result.len.csize_t)
  let ok = n != nil
  if ok:
    blecrypto.bleAesK3(n, addr nim_aes_last_result[8])
  bleAesCompleteDirect(cb, ctx, ok, addr nim_aes_last_result[8])

proc aes_k4*(n: ptr uint8, cb: pointer, ctx: pointer) {.exportc, cdecl.} =
  let ok = n != nil
  nim_aes_last_result[0] =
    if ok: blecrypto.bleAesK4(n) else: 0'u8
  bleAesCompleteDirect(cb, ctx, ok, addr nim_aes_last_result[0])

proc btble_dma_init*() {.exportc, cdecl.} =
  discard

proc btble_dma_copy*(dst: pointer, src: pointer, len: uint32)
    {.exportc, cdecl.} =
  if dst != nil and src != nil and len > 0:
    discard c_memcpy(dst, src, len.csize_t)

proc btble_dma_isr_handler*() {.exportc, cdecl.} =
  discard

proc co_nb_good_channels*(map: ptr uint8): uint8 {.exportc, cdecl.} =
  ble_util_nb_good_channels(map)

proc co_time_get*(): uint32 {.exportc, cdecl.} =
  currentBtbleTime()

proc co_time_init*() {.exportc, cdecl.} =
  discard

proc co_time_compensate*(time: uint32): uint32 {.exportc, cdecl.} =
  time

proc co_time_timer_init*() {.exportc, cdecl.} =
  discard

proc co_time_timer_set*(target: uint32) {.exportc, cdecl.} =
  discard target

proc co_time_timer_long_set*(target: uint32) {.exportc, cdecl.} =
  discard target

proc co_time_timer_periodic_set*(period: uint32) {.exportc, cdecl.} =
  discard period

proc co_time_timer_stop*() {.exportc, cdecl.} =
  discard

proc co_slot_to_duration*(slots: uint16): uint32 {.exportc, cdecl.} =
  uint32(slots) * 625'u32

proc co_util_pack*(outBuf: pointer, inBuf: pointer, fmt: cstring,
                   outLen: ptr uint16) {.exportc, cdecl.} =
  hci_util_pack(outBuf, inBuf, fmt, outLen)

proc co_util_unpack*(outBuf: pointer, inBuf: pointer, fmt: cstring,
                     outLen: ptr uint16) {.exportc, cdecl.} =
  hci_util_unpack(outBuf, inBuf, fmt, outLen)

proc flash_init*() {.exportc, cdecl.} =
  discard

proc flash_identify*(pid: ptr uint8): int32 {.exportc, cdecl.} =
  if pid != nil:
    let flashIdBytes = cast[ptr UncheckedArray[uint8]](pid)
    flashIdBytes[0] = 0
    flashIdBytes[1] = 0
    flashIdBytes[2] = 0
  0

proc flash_read*(address: uint32, data: ptr uint8, len: uint32): int32
    {.exportc, cdecl.} =
  discard address
  if data != nil:
    discard c_memset(data, 0xFF, len.csize_t)
  0

proc flash_write*(address: uint32, data: ptr uint8, len: uint32): int32
    {.exportc, cdecl.} =
  discard address
  discard data
  discard len
  0

proc flash_erase*(address: uint32, len: uint32): int32 {.exportc, cdecl.} =
  discard address
  discard len
  0

proc hci_ble_conhdl_register*(conhdl: uint16) {.exportc, cdecl.} =
  discard conhdl

proc hci_ble_conhdl_unregister*(conhdl: uint16) {.exportc, cdecl.} =
  discard conhdl

proc hci_msg_cmd_get_max_param_size*(opcode: uint16): uint16
    {.exportc, cdecl.} =
  discard opcode
  hci_cmd_get_max_param_size()

proc hci_msg_cmd_ll_dest_get*(opcode: uint16): KeTaskId {.exportc, cdecl.} =
  discard opcode
  0

proc hci_msg_cmd_reject_send*(opcode: uint16, status: uint8)
    {.exportc, cdecl.} =
  sendCmdComplete(opcode, status)

proc lld_con_current_tx_power_get*(conhdl: uint16): int8 {.exportc, cdecl.}
proc lld_con_rssi_get*(conhdl: uint16): int8 {.exportc, cdecl.}

proc sendHandleCmdComplete(opcode: uint16, status: uint8, handle: uint16) =
  var rsp = [status, uint8(handle and 0xFF), uint8((handle shr 8) and 0xFF)]
  sendCmdCompletePayload(opcode, addr rsp[0], rsp.len.uint8)

proc sendEncryptionChange(handle: uint16, status: uint8, enabled: uint8) =
  var evt: array[4, uint8]
  let body = cast[ptr HciEncryptionChangeEventView](addr evt[0])
  body.status = status
  body.handle = handle
  body.enabled = enabled
  sendHostEvent(HciEvtEncryptionChange, addr evt[0], evt.len.uint8)

proc sendRemoteVersionInfoComplete(handle: uint16, status: uint8) =
  var evt: array[8, uint8]
  let body = cast[ptr HciRemoteVersionInfoCompleteEventView](addr evt[0])
  body.status = status
  body.handle = handle
  body.version = 0x09'u8   # Bluetooth Core 5.0 HCI version
  body.companyId = 0x01BF'u16
  body.subversion = 0x0001'u16
  sendHostEvent(HciEvtRemoteVersionInfoComplete, addr evt[0], evt.len.uint8)

proc sendLeConnectionUpdateComplete(handle: uint16, status: uint8,
                                    params: ptr uint8) =
  var interval = 0'u16
  var latency = 0'u16
  var timeout = 0'u16
  if params != nil:
    let req = hciLeConnUpdateReq(params)
    interval = req.connIntervalMin
    latency = req.connLatency
    timeout = req.supervisionTimeout
  sendLeConnectionUpdateCompleteValues(handle, status, interval, latency,
                                       timeout)

proc sendLeConnectionUpdateCompleteValues(handle: uint16, status: uint8,
                                          interval, latency,
                                          timeout: uint16) =
  var evt: array[10, uint8]
  let body = cast[ptr HciLeConnectionUpdateCompleteEventView](addr evt[0])
  body.subevent = 0x03'u8
  body.status = status
  body.handle = handle
  body.interval = interval
  body.latency = latency
  body.timeout = timeout
  sendLeMetaPayload(addr evt[0], evt.len.uint8)

proc sendLeRemoteFeaturesComplete(handle: uint16, status: uint8) =
  var evt: array[12, uint8]
  let body = cast[ptr HciLeRemoteFeaturesCompleteEventView](addr evt[0])
  body.subevent = 0x04'u8
  body.status = status
  body.handle = handle
  let features = nimBleCurrentRemoteFeatures()
  for remoteFeatureByteIndex in 0 ..< 8:
    body.features[remoteFeatureByteIndex] =
      nimBleFeatureByte(features, remoteFeatureByteIndex)
  sendLeMetaPayload(addr evt[0], evt.len.uint8)

proc sendLePhyUpdateComplete(handle: uint16, status: uint8, params: ptr uint8) =
  discard params
  let txPhy = nimBleCurrentPhy()
  let rxPhy = nimBleCurrentPhy()
  var evt: array[6, uint8]
  let body = cast[ptr HciLePhyUpdateCompleteEventView](addr evt[0])
  body.subevent = 0x0C'u8
  body.status = status
  body.handle = handle
  body.txPhy = txPhy
  body.rxPhy = rxPhy
  sendLeMetaPayload(addr evt[0], evt.len.uint8)

proc sendLeEncryptComplete(opcode: uint16, params: ptr uint8,
                           paramLen: uint8): uint8 =
  var rsp: array[17, uint8]
  if params == nil or paramLen != 32'u8:
    rsp[0] = HciStatusInvalidParams
  else:
    let encryptParams = cast[ptr UncheckedArray[uint8]](params)
    rsp[0] = HciStatusSuccess
    blecrypto.bleAesEncryptBlock(cast[ptr uint8](addr encryptParams[0]),
                       cast[ptr uint8](addr encryptParams[16]),
                       addr rsp[1])
  sendCmdCompletePayload(opcode, addr rsp[0], rsp.len.uint8)
  rsp[0]

proc sendLeRandComplete(opcode: uint16, paramLen: uint8): uint8 =
  var rsp: array[9, uint8]
  if paramLen != 0'u8:
    rsp[0] = HciStatusInvalidParams
  elif bleFillRandomBytes(addr rsp[1], 8):
    rsp[0] = HciStatusSuccess
  else:
    rsp[0] = HciStatusHardwareFailure
  sendCmdCompletePayload(opcode, addr rsp[0], rsp.len.uint8)
  rsp[0]

proc sendReadBufferSizeComplete(opcode: uint16, paramLen: uint8): uint8 =
  result =
    if paramLen == 0'u8: HciStatusSuccess else: HciStatusInvalidParams
  var rsp: array[8, uint8]
  rsp[0] = result
  hciPutLe16(cast[ptr UncheckedArray[uint8]](addr rsp[0]), 1,
             NimBleLeMaxDataOctets)
  rsp[3] = 0'u8
  hciPutLe16(cast[ptr UncheckedArray[uint8]](addr rsp[0]), 4, 1'u16)
  hciPutLe16(cast[ptr UncheckedArray[uint8]](addr rsp[0]), 6, 0'u16)
  sendCmdCompletePayload(opcode, addr rsp[0], rsp.len.uint8)

proc sendLeReadBufferSizeComplete(opcode: uint16, paramLen: uint8): uint8 =
  result =
    if paramLen == 0'u8: HciStatusSuccess else: HciStatusInvalidParams
  var rsp: array[4, uint8]
  rsp[0] = result
  hciPutLe16(cast[ptr UncheckedArray[uint8]](addr rsp[0]), 1,
             NimBleLeMaxDataOctets)
  rsp[3] = 1'u8
  sendCmdCompletePayload(opcode, addr rsp[0], rsp.len.uint8)

proc sendLeReadLocalSupportedFeaturesComplete(opcode: uint16,
                                              paramLen: uint8): uint8 =
  result =
    if paramLen == 0'u8: HciStatusSuccess else: HciStatusInvalidParams
  var rsp: array[9, uint8]
  rsp[0] = result
  for localFeatureByteIndex in 0 ..< 8:
    rsp[localFeatureByteIndex + 1] =
      nimBleFeatureByte(NimBleConservativeLeFeatures, localFeatureByteIndex)
  sendCmdCompletePayload(opcode, addr rsp[0], rsp.len.uint8)

proc sendLeReadLocalP256Complete(opcode: uint16, paramLen: uint8): uint8 =
  bleP256Mark(0x00000200'u32)
  if paramLen != 0'u8:
    sendCmdStatus(opcode, HciStatusInvalidParams)
    bleP256Result(HciStatusInvalidParams.uint32)
    return HciStatusInvalidParams

  sendCmdStatus(opcode, HciStatusSuccess)
  bleP256Mark(0x00000210'u32)
  var evt: array[66, uint8]
  var secret: array[ECC_KEY_LEN, uint8]
  evt[0] = 0x08'u8
  discard c_memset(addr pka_result[0], 0, pka_result.len.csize_t)
  let secretOk = eccGenerateSecretKey(addr secret[0])
  bleP256Result(if secretOk: 1'u32 else: 0'u32)
  bleP256Mark(0x00000220'u32)
  var baseMultOk = false
  if secretOk:
    bleP256Mark(0x00000230'u32)
    baseMultOk = p256ControllerBaseMultLe(
      addr secret[0], addr pka_result[0],
      addr pka_result[ECC_KEY_LEN])
    bleP256Result(if baseMultOk: 3'u32 else: 2'u32)
    bleP256Mark(0x00000240'u32)
  if secretOk and baseMultOk:
    evt[1] = HciStatusSuccess
    discard c_memcpy(addr evt[2], addr pka_result[0], ECC_KEY_LEN.csize_t)
    discard c_memcpy(addr evt[2 + ECC_KEY_LEN],
                     addr pka_result[ECC_KEY_LEN], ECC_KEY_LEN.csize_t)
  else:
    evt[1] = HciStatusHardwareFailure
  bleP256Mark(0x00000250'u32)
  sendLeMetaPayload(addr evt[0], evt.len.uint8)
  bleP256Result(evt[1].uint32)
  bleP256Mark(0x00000260'u32)
  evt[1]

proc sendLeGenerateDhKeyComplete(opcode: uint16, params: ptr uint8,
                                 paramLen: uint8): uint8 =
  bleP256Mark(0x00000300'u32)
  if params == nil or paramLen != 64'u8:
    sendCmdStatus(opcode, HciStatusInvalidParams)
    bleP256Result(HciStatusInvalidParams.uint32)
    return HciStatusInvalidParams

  sendCmdStatus(opcode, HciStatusSuccess)
  bleP256Mark(0x00000310'u32)
  var evt: array[34, uint8]
  evt[0] = 0x09'u8
  discard c_memset(addr pka_result[0], 0, pka_result.len.csize_t)
  let peerPoint = cast[ptr EccPoint256](params)
  let peerY = addr peerPoint.y[0]
  if not bleP256IsValidScalarLe(addr ecc_private_key[0]):
    bleP256Mark(0x00000320'u32)
    evt[1] = HciStatusCommandDisallowed
  elif p256ControllerScalarMultLe(addr ecc_private_key[0], params, peerY,
                                  addr pka_result[0],
                                  addr pka_result[ECC_KEY_LEN]):
    bleP256Mark(0x00000330'u32)
    evt[1] = HciStatusSuccess
    discard c_memcpy(addr evt[2], addr pka_result[0], ECC_KEY_LEN.csize_t)
  else:
    bleP256Mark(0x00000340'u32)
    evt[1] = HciStatusInvalidParams
  bleP256Mark(0x00000350'u32)
  sendLeMetaPayload(addr evt[0], evt.len.uint8)
  bleP256Result(evt[1].uint32)
  bleP256Mark(0x00000360'u32)
  evt[1]

proc hci_rd_rssi_cmd_handler*(params: ptr uint8, opcode: uint16): uint32
    {.exportc, cdecl.} =
  let handle = hciConnHandle(params)
  let status = connParamStatus(params, handle)
  var rsp = [status, uint8(handle and 0xFF), uint8((handle shr 8) and 0xFF),
             cast[uint8](lld_con_rssi_get(handle))]
  sendCmdCompletePayload(opcode, addr rsp[0], rsp.len.uint8)
  0

proc hci_rd_tx_pwr_lvl_cmd_handler*(params: ptr uint8,
                                    opcode: uint16): uint32
    {.exportc, cdecl.} =
  let handle = hciConnHandle(params)
  let status = connParamStatus(params, handle)
  var rsp = [status, uint8(handle and 0xFF), uint8((handle shr 8) and 0xFF),
             cast[uint8](lld_con_current_tx_power_get(handle))]
  sendCmdCompletePayload(opcode, addr rsp[0], rsp.len.uint8)
  0

proc hci_disconnect_cmd_handler*(params: ptr uint8, opcode: uint16): uint32
    {.exportc, cdecl.} =
  let status = handleNimHciCommand(HciOpDisconnect, params, 3)
  sendCmdComplete(opcode, status)
  0

proc hci_le_con_upd_cmd_handler*(params: ptr uint8, opcode: uint16): uint32
    {.exportc, cdecl.} =
  discard sendLeConnectionUpdateCommand(opcode, params,
    sizeof(HciLeConnUpdateReqView).uint8)
  0

proc hci_le_en_enc_cmd_handler*(params: ptr uint8, opcode: uint16): uint32
    {.exportc, cdecl.} =
  discard sendLeEncryptComplete(opcode, params, 32'u8)
  0

proc hci_le_ltk_req_reply_cmd_handler*(params: ptr uint8,
                                       opcode: uint16): uint32
    {.exportc, cdecl.} =
  let handle = hciConnHandle(params)
  var status = connParamStatus(params, handle)
  if status == HciStatusSuccess:
    status = HciStatusCommandDisallowed
  sendHandleCmdComplete(opcode, status, handle)
  0

proc hci_le_ltk_req_neg_reply_cmd_handler*(params: ptr uint8,
                                           opcode: uint16): uint32
    {.exportc, cdecl.} =
  let handle = hciConnHandle(params)
  var status = connParamStatus(params, handle)
  if status == HciStatusSuccess:
    status = HciStatusCommandDisallowed
  sendHandleCmdComplete(opcode, status, handle)
  0

proc hci_le_rd_rem_feats_cmd_handler*(params: ptr uint8,
                                      opcode: uint16): uint32
    {.exportc, cdecl.} =
  discard sendLeReadRemoteFeaturesCommand(opcode, params, 2'u8)
  0

proc hci_le_rem_con_param_req_reply_cmd_handler*(params: ptr uint8,
                                                 opcode: uint16): uint32
    {.exportc, cdecl.} =
  let handle = hciConnHandle(params)
  var status = connParamStatus(params, handle)
  if status == HciStatusSuccess:
    status = HciStatusCommandDisallowed
  sendHandleCmdComplete(opcode, status, handle)
  0

proc hci_le_rem_con_param_req_neg_reply_cmd_handler*(params: ptr uint8,
                                                     opcode: uint16): uint32
    {.exportc, cdecl.} =
  let handle = hciConnHandle(params)
  var status = connParamStatus(params, handle)
  if status == HciStatusSuccess:
    status = HciStatusCommandDisallowed
  sendHandleCmdComplete(opcode, status, handle)
  0

proc hci_le_req_peer_sca_cmd_handler*(params: ptr uint8,
                                      opcode: uint16): uint32
    {.exportc, cdecl.} =
  let handle = hciConnHandle(params)
  let status = connParamStatus(params, handle)
  sendCmdComplete(opcode, status)
  if status == 0:
    var evt = [0x20'u8, status, uint8(handle and 0xFF),
               uint8((handle shr 8) and 0xFF), 0'u8]
    sendLeMetaPayload(addr evt[0], evt.len.uint8)
  0

proc hci_le_set_phy_cmd_handler*(params: ptr uint8, opcode: uint16): uint32
    {.exportc, cdecl.} =
  let handle = hciConnHandle(params)
  var status = connParamStatus(params, handle)
  if status == HciStatusSuccess:
    let req = hciLeSetPhyReq(params)
    if not nimBleRequestedPhySupported(req):
      status = HciStatusUnsupportedFeatureParam
  sendCmdComplete(opcode, status)
  if status == 0:
    nimBleSetCurrentPhy1M()
    sendLePhyUpdateComplete(handle, status, params)
  0

proc hci_le_rd_adv_ch_tx_pw_cmd_handler*(params: ptr uint8,
                                         opcode: uint16): uint32
    {.exportc, cdecl.} =
  discard params
  sendCmdComplete2(opcode, 0'u8, cast[uint8](ble_tx_pwr))
  0

proc hci_le_rd_chnl_map_cmd_handler*(params: ptr uint8,
                                     opcode: uint16): uint32
    {.exportc, cdecl.} =
  let handle = hciConnHandle(params)
  let status = connParamStatus(params, handle)
  var rsp = [status, uint8(handle and 0xFF), uint8((handle shr 8) and 0xFF),
             0xFF'u8, 0xFF, 0xFF, 0xFF, 0x1F]
  if status == HciStatusSuccess:
    nimBleCurrentChannelMap(cast[ptr UncheckedArray[uint8]](addr rsp[3]))
  sendCmdCompletePayload(opcode, addr rsp[0], rsp.len.uint8)
  0

proc hci_le_rd_phy_cmd_handler*(params: ptr uint8, opcode: uint16): uint32
    {.exportc, cdecl.} =
  let handle = hciConnHandle(params)
  let status = connParamStatus(params, handle)
  var rsp = [status, uint8(handle and 0xFF), uint8((handle shr 8) and 0xFF),
             nimBleCurrentPhy(), nimBleCurrentPhy()]
  sendCmdCompletePayload(opcode, addr rsp[0], rsp.len.uint8)
  0

proc hci_le_set_adv_data_cmd_handler*(params: ptr uint8,
                                      opcode: uint16): uint32
    {.exportc, cdecl.} =
  let status = handleNimHciCommand(HciOpLeSetAdvData, params, 32)
  sendCmdComplete(opcode, status)
  0

proc hci_le_set_adv_en_cmd_handler*(params: ptr uint8,
                                    opcode: uint16): uint32
    {.exportc, cdecl.} =
  let status = handleNimHciCommand(HciOpLeSetAdvEnable, params, 1)
  sendCmdComplete(opcode, status)
  0

proc hci_le_set_adv_param_cmd_handler*(params: ptr uint8,
                                       opcode: uint16): uint32
    {.exportc, cdecl.} =
  let status = handleNimHciCommand(HciOpLeSetAdvParams, params, 15)
  sendCmdComplete(opcode, status)
  0

proc hci_le_set_adv_set_rand_addr_cmd_handler*(params: ptr uint8,
                                               opcode: uint16): uint32
    {.exportc, cdecl.} =
  var status = 0x12'u8
  if params != nil:
    let req = hciLeSetAdvRandomAddrReq(params)
    for localAddressByteIndex in 0 ..< nim_local_addr.len:
      nim_local_addr[localAddressByteIndex] =
        req.randomAddress.bytes[localAddressByteIndex]
    nim_local_addr_valid = true
    status = 0'u8
  sendCmdComplete(opcode, status)
  0

proc hci_le_set_scan_rsp_data_cmd_handler*(params: ptr uint8,
                                           opcode: uint16): uint32
    {.exportc, cdecl.} =
  let status = handleNimHciCommand(HciOpLeSetScanRspData, params, 32)
  sendCmdComplete(opcode, status)
  0

proc hci_le_set_data_len_cmd_handler*(params: ptr uint8,
                                      opcode: uint16): uint32
    {.exportc, cdecl.} =
  let handle = hciConnHandle(params)
  let status = nimBleDataLengthStatus(params, handle)
  var rsp = [status, uint8(handle and 0xFF), uint8((handle shr 8) and 0xFF)]
  sendCmdCompletePayload(opcode, addr rsp[0], rsp.len.uint8)
  if status == HciStatusSuccess:
    sendLeDataLengthChange(handle)
  0

proc hci_rd_auth_payl_to_cmd_handler*(params: ptr uint8,
                                      opcode: uint16): uint32
    {.exportc, cdecl.} =
  let handle = hciConnHandle(params)
  let status = connParamStatus(params, handle)
  var rsp = [status, uint8(handle and 0xFF), uint8((handle shr 8) and 0xFF),
             uint8(nim_auth_payload_timeout and 0xFF),
             uint8((nim_auth_payload_timeout shr 8) and 0xFF)]
  sendCmdCompletePayload(opcode, addr rsp[0], rsp.len.uint8)
  0

proc hci_rd_rem_ver_info_cmd_handler*(params: ptr uint8,
                                      opcode: uint16): uint32
    {.exportc, cdecl.} =
  discard sendReadRemoteVersionInfoCommand(opcode, params, 2'u8)
  0

proc hci_vs_set_max_rx_size_and_time_cmd_handler*(params: ptr uint8,
                                                  opcode: uint16): uint32
    {.exportc, cdecl.} =
  discard params
  sendCmdComplete(opcode, 0'u8)
  0

proc hci_vs_set_pref_slave_evt_dur_cmd_handler*(params: ptr uint8,
                                                opcode: uint16): uint32
    {.exportc, cdecl.} =
  discard params
  sendCmdComplete(opcode, 0'u8)
  0

proc hci_vs_set_pref_slave_latency_cmd_handler*(params: ptr uint8,
                                                opcode: uint16): uint32
    {.exportc, cdecl.} =
  discard params
  sendCmdComplete(opcode, 0'u8)
  0

proc hci_wr_auth_payl_to_cmd_handler*(params: ptr uint8,
                                      opcode: uint16): uint32
    {.exportc, cdecl.} =
  let handle = hciConnHandle(params)
  var status = connParamStatus(params, handle)
  if status == HciStatusSuccess and params != nil:
    let timeout = hciWriteAuthPayloadTimeoutReq(params).timeout
    status = llc_le_ping_set(handle, timeout)
    if status == HciStatusSuccess:
      nim_auth_payload_timeout = timeout
  sendHandleCmdComplete(opcode, status, handle)
  0

proc hci_msg_task_dest_compute*(opcode: uint16): KeTaskId {.exportc, cdecl.} =
  discard opcode
  0

proc hci_tl_acl_tx_data_alloc*(pktType: uint8, handle: uint16,
                               len: uint16): pointer {.exportc, cdecl.} =
  discard pktType
  hci_acl_tx_data_alloc(handle, len)

proc hci_tl_acl_tx_data_received*(pktType: uint8, handle: uint16,
                                  data: pointer, len: uint16)
    {.exportc, cdecl.} =
  discard pktType
  hci_acl_tx_data_received(handle, data, len)

proc hci_tl_cmd_get_max_param_size*(): uint16 {.exportc, cdecl.} =
  hci_cmd_get_max_param_size()

proc hci_tl_cmd_received*(data: pointer, len: uint16) {.exportc, cdecl.} =
  hci_cmd_received(data, len)

proc nvds_init*(readCb: pointer, writeCb: pointer): uint8 {.exportc, cdecl.} =
  discard readCb
  discard writeCb
  0

proc nvds_get*(tag: uint8, length: ptr uint8, buf: ptr uint8): uint8
    {.exportc, cdecl.} =
  discard tag
  if length != nil:
    length[] = 0
  discard buf
  1

proc nvds_put*(tag: uint8, length: uint8, buf: ptr uint8): uint8
    {.exportc, cdecl.} =
  discard tag
  discard length
  discard buf
  0

proc nvds_del*(tag: uint8): uint8 {.exportc, cdecl.} =
  discard tag
  0

proc nvds_lock*(tag: uint8): uint8 {.exportc, cdecl.} =
  discard tag
  0

proc rf_txpwr_dbm2cs*(dbm: int8): uint8 {.exportc, cdecl.} =
  uint8((int32(dbm) shl 2) and 0xFC)

proc rf_txpwr_cs2dbm*(cs: uint8): int8 {.exportc, cdecl.} =
  int8(cs shr 2)

proc rw_main_task_post*(fn: pointer, arg: pointer): bool {.exportc, cdecl.} =
  bflb_main_task_post(fn, arg)

proc rw_main_task_post_from_fw*(fn: pointer, arg: pointer) {.exportc, cdecl.} =
  bflb_main_task_post_from_fw(fn, arg)

proc rw_main_task_post_from_isr*(fn: pointer, arg: pointer) {.exportc, cdecl.} =
  bflb_main_task_post_from_isr(fn, arg)

var nim_lld_aa_counter: uint32
when defined(bl808m0):
  var nim_lld_aa_gen_count* {.exportc.}: uint32
  var nim_lld_aa_last_seed* {.exportc.}: uint32
  var nim_lld_aa_last* {.exportc.}: uint32

proc lldAccessAddressValid(aa: uint32): bool =
  if aa == 0'u32 or aa == 0xFFFFFFFF'u32 or aa == 0x8E89BED6'u32:
    return false

  var transitions = 0
  var run = 1
  var last = aa and 1'u32
  for bit in 1 ..< 32:
    let accessAddressBit = (aa shr bit) and 1'u32
    if accessAddressBit == last:
      inc run
      if run > 6:
        return false
    else:
      inc transitions
      run = 1
      last = accessAddressBit
  transitions >= 2

proc lld_aa_gen*(outAddr: ptr uint8, seed: uint8) {.exportc, cdecl.} =
  if outAddr == nil:
    return
  inc nim_lld_aa_counter
  when defined(bl808m0):
    inc nim_lld_aa_gen_count
    nim_lld_aa_last_seed = seed.uint32
  var aa =
    currentBtbleTime() xor 0xD6BE898E'u32 xor
    (uint32(seed) * 0x9E3779B1'u32) xor
    (nim_lld_aa_counter * 0x45D9F3B'u32)
  var guard = 0
  while not lldAccessAddressValid(aa) and guard < 64:
    aa = aa * 1664525'u32 + 1013904223'u32 + uint32(guard)
    inc guard
  if not lldAccessAddressValid(aa):
    aa = 0xA77C2B91'u32 xor (uint32(seed) shl 8)
  let accessAddressBytes = cast[ptr UncheckedArray[uint8]](outAddr)
  accessAddressBytes[0] = uint8(aa and 0xFF)
  accessAddressBytes[1] = uint8((aa shr 8) and 0xFF)
  accessAddressBytes[2] = uint8((aa shr 16) and 0xFF)
  accessAddressBytes[3] = uint8((aa shr 24) and 0xFF)
  when defined(bl808m0):
    nim_lld_aa_last = aa

proc lld_ch_map_set*(chMap: ptr uint8) {.exportc, cdecl.} =
  var count: uint8 = 0
  let channelMapBytes =
    if chMap == nil:
      nil
    else:
      cast[ptr UncheckedArray[uint8]](chMap)
  for channel in 0 ..< 37:
    let enabled =
      if channelMapBytes == nil:
        true
      else:
        (channelMapBytes[channel shr 3] and
          (1'u8 shl uint8(channel and 0x07))) != 0'u8
    if enabled:
      lld_env[17 + int(count)] = uint8(channel)
      inc count
  if count == 0'u8:
    for channel in 0 ..< 37:
      lld_env[17 + channel] = uint8(channel)
    count = 37'u8
  lld_env[54] = count

proc lld_ch_idx_get*(): uint8 {.exportc, cdecl.} =
  let enabledChannelCount = lld_env[54]
  if enabledChannelCount == 0'u8:
    return uint8(currentBtbleTime() mod 37'u32)
  let enabledChannelMapIndex =
    int(currentBtbleTime() mod uint32(enabledChannelCount))
  lld_env[17 + enabledChannelMapIndex]

proc lld_con_current_tx_power_get*(conhdl: uint16): int8 {.exportc, cdecl.} =
  discard conhdl
  ble_tx_pwr

proc lld_con_rssi_get*(conhdl: uint16): int8 {.exportc, cdecl.} =
  discard conhdl
  0'i8

proc lld_con_init*(initType: uint8): uint32 {.exportc, cdecl.} =
  case initType
  of 2'u8, 3'u8:
    nim_conn_active = false
    nim_conn_handle = 0
    when defined(bl808m0) and bl808BleNimConnectionEnabled:
      nim_conn_started = false
      nim_connect_ind_pending = 0
      nim_acl_empty_tx_pending = 0
      nim_acl_empty_tx_queued = 0
      nim_acl_host_tx_pending = 0
      nim_llcp_tx_pending = 0
      nim_llcp_tx_queued = 0
      nim_llcp_tx_queue_head = 0
      nim_llcp_tx_queue_tail = 0
      nim_llcp_state.versionProcedureStarted = false
      nimLlcpClearFeatureExchangeState(clearDebug = true)
      nim_llcp_state.startupAttemptsLeft = 0
      nim_llcp_state.startupDelayServices = 0
      nimLlcpResetDataLengthState()
      when bl808BleNimPureConnection:
        discard c_memset(addr nim_conn_state, 0, sizeof(NimConnState).csize_t)
  else:
    discard
  0

proc lld_con_data_flow_set*(conhdl: uint16, enabled: uint8): uint32
    {.exportc, cdecl.} =
  when defined(bl808m0) and bl808BleNimConnectionEnabled and
      bl808BleNimPureConnection:
    if nim_conn_state.active and conhdl == nim_conn_state.handle:
      nim_conn_state.dataFlowEnabled = enabled != 0'u8
  else:
    discard conhdl
    discard enabled
  0

proc lld_con_event_counter_get*(conhdl: uint16): uint16 {.exportc, cdecl.} =
  when defined(bl808m0) and bl808BleNimConnectionEnabled and
      bl808BleNimPureConnection:
    if nim_conn_state.active and conhdl == nim_conn_state.handle:
      return nim_conn_state.eventCounter
  discard conhdl
  0'u16

proc lld_con_offset_get*(conhdl: uint16): uint32 {.exportc, cdecl.} =
  when defined(bl808m0) and bl808BleNimConnectionEnabled and
      bl808BleNimPureConnection:
    if nim_conn_state.active and conhdl == nim_conn_state.handle and
        nim_conn_state.intervalSlots != 0'u32:
      return nim_conn_state.nextAnchor mod nim_conn_state.intervalSlots
  discard conhdl
  0'u32

proc lld_con_time_get*(conhdl: uint16, counter: ptr uint16,
                       clock: ptr uint32, fine: ptr uint16): uint8
    {.exportc, cdecl.} =
  when defined(bl808m0) and bl808BleNimConnectionEnabled and
      bl808BleNimPureConnection:
    if nim_conn_state.active and conhdl == nim_conn_state.handle:
      if counter != nil:
        counter[] = nim_conn_state.eventCounter
      if clock != nil:
        clock[] = nim_conn_state.nextAnchor
      if fine != nil:
        fine[] = nim_conn_state.anchorFine
      return HciStatusSuccess
  else:
    discard counter
    discard clock
    discard fine
  discard conhdl
  HciStatusCommandDisallowed

proc lld_con_peer_sca_set*(conhdl: uint16, sca: uint8): uint32
    {.exportc, cdecl.} =
  let boundedSca = sca and 0x07'u8
  when defined(bl808m0) and bl808BleNimConnectionEnabled and
      bl808BleNimPureConnection:
    if nim_conn_state.active and conhdl == nim_conn_state.handle:
      nim_conn_state.peerSca = boundedSca
      nim_conn_state.peerDriftPpm =
        if boundedSca.int < co_sca2ppm.len:
          uint32(co_sca2ppm[boundedSca.int])
        else:
          0'u32
  else:
    discard conhdl
  0

proc lld_con_pref_slave_latency_set*(conhdl: uint16, latency: uint16): uint32
    {.exportc, cdecl.} =
  when defined(bl808m0) and bl808BleNimConnectionEnabled and
      bl808BleNimPureConnection:
    if nim_conn_state.active and conhdl == nim_conn_state.handle:
      nim_conn_state.preferredSlaveLatency = latency
  else:
    discard conhdl
    discard latency
  0

proc lld_con_pref_slave_evt_dur_set*(conhdl: uint16, duration: uint16): uint32
    {.exportc, cdecl.} =
  when defined(bl808m0) and bl808BleNimConnectionEnabled and
      bl808BleNimPureConnection:
    if nim_conn_state.active and conhdl == nim_conn_state.handle:
      nim_conn_state.preferredSlaveEventDuration = duration
  else:
    discard conhdl
    discard duration
  0

proc lld_con_ch_map_update*(conhdl: uint16, map: ptr uint8,
                            instant: uint16): uint8 {.exportc, cdecl.} =
  discard instant
  if map == nil:
    return HciStatusInvalidParams
  if conhdl >= LLC_CON_MAX.uint16:
    return HciStatusUnknownConnection
  llc_util_update_channel_map(conhdl, map)
  lld_ch_map_set(map)
  HciStatusSuccess

proc lld_ch_map_upd_cfm_handler*(msgid: KeMsgId, param: pointer,
                                 dest_id: KeTaskId,
                                 src_id: KeTaskId): uint32 {.exportc, cdecl.} =
  discard msgid
  discard param
  discard src_id
  let conhdl = uint16(dest_id shr 8)
  if conhdl < LLC_CON_MAX.uint16:
    llc_proc_unreg(conhdl, 6'u8)
  0

proc lld_con_data_len_update*(): uint32 {.exportc, cdecl.} =
  when defined(bl808m0) and bl808BleNimConnectionEnabled and
      bl808BleNimPureConnection:
    if nim_conn_state.active:
      nimConnProgramPacketDurations(nim_conn_state.handle)
  0

proc lld_white_list_add*(position: uint8, peerAddr: ptr BdAddr,
                         addrType: uint8): uint32 {.exportc, cdecl.} =
  if addrType == 0xFF'u8:
    return 0
  let whitelistPositionSlot = llmWlNormalizeSlot(position)
  if whitelistPositionSlot >= 0 and peerAddr != nil and
      (llmWlSlotAvailable(whitelistPositionSlot) or
       (llm_wl_type[whitelistPositionSlot] == addrType and
        co_bdaddr_compare(addr llm_wl[whitelistPositionSlot], peerAddr))):
    co_bdaddr_set(addr llm_wl[whitelistPositionSlot], peerAddr)
    llm_wl_type[whitelistPositionSlot] = addrType
  elif not llm_util_bl_add(peerAddr, addrType):
    return 1
  0

proc lld_white_list_rem*(position: uint8, peerAddr: ptr BdAddr,
                         addrType: uint8): uint32 {.exportc, cdecl.} =
  if addrType == 0xFF'u8:
    return 0
  let whitelistPositionSlot = llmWlNormalizeSlot(position)
  if whitelistPositionSlot >= 0 and
      llm_wl_type[whitelistPositionSlot] != 0xFF'u8:
    discard c_memset(addr llm_wl[whitelistPositionSlot], 0,
                     sizeof(BdAddr).csize_t)
    llm_wl_type[whitelistPositionSlot] = 0xFF'u8
  elif not llm_util_bl_rem(peerAddr, addrType):
    return 1
  0

template abiNoopHandler(name: untyped) =
  ## Export an unsupported controller ABI entry point as a no-op.
  proc name*(): uint32 {.exportc, cdecl.} =
    0

template abiLlcpHandler(name: untyped, opcode: untyped) =
  when defined(bl808m0) and bl808BleNimConnectionEnabled:
    when bl808BleNimManualConnTx:
      proc name*(conhdl: uint16,
                 pdu: ptr UncheckedArray[uint8],
                 rxHeader: uint16): uint32 {.exportc, cdecl.} =
        nimLlcpHandleConsumed(conhdl, pdu, rxHeader, opcode)
    else:
      abiNoopHandler(name)
  else:
    abiNoopHandler(name)

proc emi_init*() {.exportc, cdecl.} =
  discard

type
  CoDjobCallback = proc() {.cdecl.}

  CoDjob {.packed.} = object
    node: CoListNode
    cb: CoDjobCallback

const
  CoDjobQueueCount = 3
  CoDjobDrainLimit = 8'u32
  CoDjobEventIds = [0'u8, 3'u8, 6'u8]
  CoDjobIsrQueue = 2

var
  co_djob_queues: array[CoDjobQueueCount, CoList]
  nim_ble_codjob_yield_count* {.exportc.}: uint32
  nim_ble_codjob_yield_event* {.exportc.}: uint32

proc coDjobQueueIndex(eventId: uint8): int =
  for codJobQueueIndex in 0 ..< CoDjobEventIds.len:
    if CoDjobEventIds[codJobQueueIndex] == eventId:
      return codJobQueueIndex
  if eventId < CoDjobQueueCount.uint8:
    int(eventId)
  else:
    -1

proc coDjobEventId(deferredJobQueueIndex: int): uint8 =
  if deferredJobQueueIndex >= 0 and deferredJobQueueIndex < CoDjobEventIds.len:
    CoDjobEventIds[deferredJobQueueIndex]
  else:
    0'u8

proc coDjobPending(deferredJobQueueIndex: int): bool {.inline.} =
  let irq = disableInterrupts()
  result = co_djob_queues[deferredJobQueueIndex].first != nil
  restoreInterrupts(irq)

proc coDjobAnyPending(): bool =
  let irq = disableInterrupts()
  for queue in co_djob_queues:
    if queue.first != nil:
      result = true
      break
  restoreInterrupts(irq)

proc coDjobRun(eventId: uint8) {.cdecl.} =
  let deferredJobQueueIndex = coDjobQueueIndex(eventId)
  if deferredJobQueueIndex < 0:
    return
  var drained = 0'u32
  while drained < CoDjobDrainLimit:
    let irq = disableInterrupts()
    let node = ble_co_list_pop_front(addr co_djob_queues[deferredJobQueueIndex])
    restoreInterrupts(irq)
    if node == nil:
      return
    let job = cast[ptr CoDjob](node)
    let deferredJobCallback = job.cb
    job.node.next = nil
    if deferredJobCallback != nil:
      deferredJobCallback()
    inc drained

  if coDjobPending(deferredJobQueueIndex):
    inc nim_ble_codjob_yield_count
    nim_ble_codjob_yield_event = eventId.uint32
    ble_ke_event_set(coDjobEventId(deferredJobQueueIndex))

proc coDjobRegister(deferredJobQueueIndex: int, job: ptr CoDjob) =
  if deferredJobQueueIndex < 0 or
      deferredJobQueueIndex >= CoDjobQueueCount or job == nil:
    return
  let irq = disableInterrupts()
  if not ble_co_list_find(addr co_djob_queues[deferredJobQueueIndex],
                          addr job.node):
    let wasEmpty = co_djob_queues[deferredJobQueueIndex].first == nil
    ble_co_list_push_back(addr co_djob_queues[deferredJobQueueIndex],
                          addr job.node)
    restoreInterrupts(irq)
    if wasEmpty:
      ble_ke_event_set(coDjobEventId(deferredJobQueueIndex))
  else:
    restoreInterrupts(irq)

proc coDjobUnregister(deferredJobQueueIndex: int, job: ptr CoDjob) =
  if job == nil:
    return
  let irq = disableInterrupts()
  if deferredJobQueueIndex >= 0 and deferredJobQueueIndex < CoDjobQueueCount:
    ble_co_list_extract(addr co_djob_queues[deferredJobQueueIndex],
                        addr job.node)
  else:
    for queue in mitems(co_djob_queues):
      ble_co_list_extract(addr queue, addr job.node)
  job.node.next = nil
  restoreInterrupts(irq)

proc co_djob_init*(job: pointer, cb: pointer) {.exportc, cdecl.} =
  if job == nil:
    return
  let djob = cast[ptr CoDjob](job)
  djob.node.next = nil
  djob.cb = cast[CoDjobCallback](cb)

template hciCmdStatusDescView(desc: pointer): ptr HciCmdStatusDescView =
  cast[ptr HciCmdStatusDescView](desc)

template hciEventRouting(evt: pointer): ptr HciEventRoutingView =
  cast[ptr HciEventRoutingView](evt)

proc hci_msg_cmd_status_exp*(desc: pointer): uint8 {.exportc, cdecl.} =
  if desc == nil:
    return 1
  if hciCmdStatusDescView(desc).expectedStatusWord == 0'u32:
    1'u8
  else:
    0'u8

proc hci_msg_evt_get_hl_tl_dest*(evt: pointer): uint8 {.exportc, cdecl.} =
  if evt == nil:
    0
  else:
    hciEventRouting(evt).route and 0x03'u8

proc hci_msg_evt_host_lid_get*(evt: pointer): uint8 {.exportc, cdecl.} =
  if evt == nil:
    0
  else:
    hciEventRouting(evt).hostLid

proc led_init*() {.exportc, cdecl.} =
  discard

proc led_set_all*() {.exportc, cdecl.} =
  discard

proc syscntl_init*() {.exportc, cdecl.} =
  discard

proc llc_proc_init*(procEnv: pointer, procId: uint8, cb: pointer)
    {.exportc, cdecl.} =
  if procEnv == nil:
    return
  let env = llcProcEnv(procEnv)
  env.errCallback = cb
  env.procId = procId
  env.state = 0
  env.statePadding = 0

proc Add2SelfBigHex256*(dst, other: pointer) {.exportc, cdecl.} =
  bleBigHexAddSelf(dst, other)

proc AddBigHex256*(a, b, dst: pointer) {.exportc, cdecl.} =
  bleBigHexAdd(a, b, dst)

proc AddBigHexModP256*(a, b, dst: pointer) {.exportc, cdecl.} =
  bleBigHexAddModP256(a, b, dst)

proc AddP256*(value: pointer) {.exportc, cdecl.} =
  bleBigHexAddP256(value)

proc AddPdiv2_256*(value: pointer) {.exportc, cdecl.} =
  bleBigHexAddPdiv2(value)

proc GF_Jacobian_Point_Addition256*(a, b, dst: pointer) {.exportc, cdecl.} =
  bleP256JacobianAdd(a, b, dst)

proc GF_Jacobian_Point_Double256*(point, dst: pointer) {.exportc, cdecl.} =
  bleP256JacobianDouble(point, dst)

proc MultiplyBigHexByUint32_256*(a: pointer, k: uint32, dst: pointer)
    {.exportc, cdecl.} =
  bleBigHexMultiplyByU32ModP256(a, k, dst)

proc MultiplyBigHexModP256*(a, b, dst: pointer) {.exportc, cdecl.} =
  bleBigHexMultiplyModP256(a, b, dst)

proc MultiplyByU32ModP256*(k: uint32, dst: pointer) {.exportc, cdecl.} =
  bleBigHexP256TimesU32(k, dst)

proc SubtractBigHex256*(a, b, dst: pointer) {.exportc, cdecl.} =
  bleBigHexSubtract(a, b, dst)

proc SubtractBigHexMod256*(a, b, dst: pointer) {.exportc, cdecl.} =
  bleBigHexSubtractModP256(a, b, dst)

proc SubtractBigHexUint32_256*(a: pointer, k: uint32, dst: pointer)
    {.exportc, cdecl.} =
  bleBigHexSubtractU32(a, k, dst)

proc SubtractFromSelfBigHex256*(dst, other: pointer) {.exportc, cdecl.} =
  bleBigHexSubtractSelf(dst, other)

proc SubtractFromSelfBigHexSign256*(dst, other: pointer) {.exportc, cdecl.} =
  bleBigHexSubtractSelf(dst, other)
proc co_djob_initialize*(initType: uint8) {.exportc, cdecl.} =
  case initType
  of 1'u8:
    for codJobQueueIndex in 0 ..< CoDjobQueueCount:
      ble_ke_event_callback_set(CoDjobEventIds[codJobQueueIndex], coDjobRun)
      ble_co_list_init(addr co_djob_queues[codJobQueueIndex])
  of 2'u8, 3'u8:
    for queue in mitems(co_djob_queues):
      ble_co_list_init(addr queue)
  else:
    discard

proc co_djob_isr_reg*(job: pointer) {.exportc, cdecl.} =
  coDjobRegister(CoDjobIsrQueue, cast[ptr CoDjob](job))

proc co_djob_reg*(eventId: uint8, job: pointer) {.exportc, cdecl.} =
  coDjobRegister(coDjobQueueIndex(eventId), cast[ptr CoDjob](job))

proc co_djob_unreg*(eventId: uint8, job: pointer) {.exportc, cdecl.} =
  coDjobUnregister(coDjobQueueIndex(eventId), cast[ptr CoDjob](job))
when defined(bl808m0) and bl808BleNimConnectionEnabled and
    bl808BleNimManualConnTx:
  proc aclTaskHandle(destId, srcId: KeTaskId, handleFlags: uint16): uint16 =
    result = handleFlags and 0x0FFF'u16
    if result != 0'u16:
      return
    result = uint16(destId shr 8)
    if result != 0'u16:
      return
    result = uint16(srcId shr 8)

  template hciAclDataInd(param: pointer): ptr HciAclDataIndView =
    cast[ptr HciAclDataIndView](param)

  proc hci_acl_data_handler*(msgid: KeMsgId, param: pointer,
                             dest_id: KeTaskId, src_id: KeTaskId): uint32
      {.exportc, cdecl.} =
    discard msgid
    if param == nil:
      return 0
    let ind = hciAclDataInd(param)
    let handleFlags = ind.handleFlags
    let len = ind.length
    let handle = aclTaskHandle(dest_id, src_id, handleFlags)
    let data = cast[ptr uint8](ind.dataAddr.uint)
    let pbBcFlag = uint8((handleFlags shr 12) and 0x000F'u16)
    discard hciOwnedAclTxDataReceived(handle, pbBcFlag, data, len)
    0
else:
  abiNoopHandler(hci_acl_data_handler)
abiNoopHandler(hci_command_llc_handler)
abiNoopHandler(hci_command_llm_handler)
abiNoopHandler(hci_msg_cmd_cmp_pkupk)
abiNoopHandler(hci_msg_cmd_desc_get)
abiNoopHandler(hci_msg_cmd_pkupk)
abiNoopHandler(hci_msg_evt_desc_get)
abiNoopHandler(hci_msg_evt_pkupk)
abiNoopHandler(hci_msg_le_evt_desc_get)
abiLlcpHandler(ll_channel_map_ind_handler, LlcpChannelMapInd)
abiNoopHandler(ll_clk_acc_req_handler)
abiNoopHandler(ll_clk_acc_rsp_handler)
abiLlcpHandler(ll_connection_param_req_handler, LlcpConnectionParamReq)
abiLlcpHandler(ll_connection_param_rsp_handler, LlcpConnectionParamRsp)
abiLlcpHandler(ll_connection_update_ind_handler, LlcpConnectionUpdateInd)
abiLlcpHandler(ll_enc_req_handler, LlcpEncReq)
abiLlcpHandler(ll_enc_rsp_handler, LlcpEncRsp)
abiLlcpHandler(ll_feature_req_handler, LlcpFeatureReq)
abiLlcpHandler(ll_feature_rsp_handler, LlcpFeatureRsp)
abiLlcpHandler(ll_length_req_handler, LlcpLengthReq)
abiLlcpHandler(ll_length_rsp_handler, LlcpLengthRsp)
abiLlcpHandler(ll_min_used_channels_ind_handler, LlcpMinUsedChannelsInd)
abiLlcpHandler(ll_pause_enc_req_handler, LlcpPauseEncReq)
abiLlcpHandler(ll_pause_enc_rsp_handler, LlcpPauseEncRsp)
abiLlcpHandler(ll_phy_req_handler, LlcpPhyReq)
abiLlcpHandler(ll_phy_rsp_handler, LlcpPhyRsp)
abiLlcpHandler(ll_phy_update_ind_handler, LlcpPhyUpdateInd)
abiLlcpHandler(ll_ping_req_handler, LlcpPingReq)
abiLlcpHandler(ll_ping_rsp_handler, LlcpPingRsp)
abiLlcpHandler(ll_slave_feature_req_handler, LlcpSlaveFeatureReq)
abiLlcpHandler(ll_start_enc_req_handler, LlcpStartEncReq)
abiLlcpHandler(ll_start_enc_rsp_handler, LlcpStartEncRsp)
when defined(bl808m0) and bl808BleNimConnectionEnabled:
  when bl808BleNimManualConnTx:
    proc ll_terminate_ind_handler*(conhdl: uint16,
                                   pdu: ptr UncheckedArray[uint8],
                                   rxHeader: uint16): uint32 {.exportc, cdecl.} =
      nimLlcpHandleConsumed(conhdl, pdu, rxHeader, LlcpTerminateInd)
  else:
    proc ll_terminate_ind_handler*(): uint32 {.exportc, cdecl.} =
      noteNimPeripheralDisconnectedFrom(5'u32, NimLlcpDefaultReason)
      0
else:
  abiNoopHandler(ll_terminate_ind_handler)
when defined(bl808m0) and bl808BleNimConnectionEnabled:
  when bl808BleNimManualConnTx:
    proc ll_version_ind_handler*(conhdl: uint16,
                                 pdu: ptr UncheckedArray[uint8],
                                 rxHeader: uint16): uint32 {.exportc, cdecl.} =
      nimLlcpHandleConsumed(conhdl, pdu, rxHeader, LlcpVersionInd)
  else:
    abiNoopHandler(ll_version_ind_handler)
else:
  abiNoopHandler(ll_version_ind_handler)
proc llc_le_ping_proc_err_cb*(conhdl: uint16, status: uint8,
                              param: pointer) {.exportc, cdecl.} =
  discard param
  if status == 0'u8:
    llc_llcp_ping_req_pdu_send(conhdl)

proc llc_auth_payl_nearly_to_handler*(msgid: KeMsgId, param: pointer,
                                       dest_id: KeTaskId,
                                       src_id: KeTaskId): uint32
    {.exportc, cdecl.} =
  discard msgid
  discard param
  discard src_id
  let conhdl = uint16(dest_id shr 8)
  let env = llcEnvFor(conhdl)
  if not llcEnvConnectionOpen(env) or not llcEnvEncrypted(env):
    return 0

  let task = llcTaskId(conhdl)
  let procEnv = btble_ke_msg_alloc(
    LlcAuthPayloadNearlyOpMsgId, task, task, 8'u16)
  if procEnv != nil:
    llc_proc_init(procEnv, LlcProcLePing, cast[pointer](llc_le_ping_proc_err_cb))
    discard llc_proc_reg(conhdl, 0'u8, procEnv)
    llc_proc_state_set(procEnv, conhdl, 0'u8)
    when defined(bl808m0) and bl808BleNimConnectionEnabled and
        bl808BleNimManualConnTx:
      if nimBleLocalFeatureSupported(NimBleFeatureLePing):
        llc_llcp_ping_req_pdu_send(conhdl)
        llc_proc_state_set(procEnv, conhdl, 1'u8)
  0

proc llc_auth_payl_real_to_handler*(msgid: KeMsgId, param: pointer,
                                     dest_id: KeTaskId,
                                     src_id: KeTaskId): uint32
    {.exportc, cdecl.} =
  discard msgid
  discard param
  discard src_id
  let conhdl = uint16(dest_id shr 8)
  let env = llcEnvFor(conhdl)
  if not llcEnvConnectionOpen(env) or not llcEnvEncrypted(env):
    return 0

  var evt = [uint8(conhdl and 0x00FF'u16),
             uint8((conhdl shr 8) and 0x00FF'u16)]
  sendHostEvent(HciEvtAuthenticatedPayloadTimeoutExpired,
                addr evt[0], evt.len.uint8)
  llcArmAuthPayloadTimers(conhdl, env)
  0
proc llc_cleanup*(conhdl: uint16): uint32 {.exportc, cdecl.} =
  llc_stop(conhdl)
  0

proc llc_clk_acc_modify*(conhdl: uint16, sca: uint8): uint32
    {.exportc, cdecl.} =
  discard lld_con_peer_sca_set(conhdl, sca)
  0

abiNoopHandler(llc_con_move_cbk)
when defined(bl808m0) and bl808BleNimConnectionEnabled and
    bl808BleNimManualConnTx:
  proc llc_disconnect*(conhdl: uint16, reason: uint8): uint32
      {.exportc, cdecl.} =
    llc_llcp_terminate_ind_pdu_send(conhdl, reason)
    0
else:
  abiNoopHandler(llc_disconnect)
abiNoopHandler(llc_encrypt_ind_handler)
proc llc_init_term_proc*(conhdl: uint16, reason: uint8): uint32
    {.exportc, cdecl.} =
  llc_llcp_terminate_ind_pdu_send(conhdl, reason)
  0

proc llc_le_ping_restart*(conhdl: uint16): uint32 {.exportc, cdecl.} =
  let env = llcEnvFor(conhdl)
  llcArmAuthPayloadTimers(conhdl, env)
  0

when defined(bl808m0) and bl808BleNimConnectionEnabled and
    bl808BleNimManualConnTx:
  proc llc_ll_reject_ind_pdu_send*(conhdl: uint16, opcode: uint8,
                                   reason: uint8,
                                   procEnv: pointer): uint32
      {.exportc, cdecl.} =
    discard procEnv
    var pdu =
      if opcode <= LlcpRejectInd:
        nimLlcpBuildRejectInd(reason)
      else:
        nimLlcpBuildRejectExtInd(opcode, reason)
    discard nimLlcpQueuePdu(conhdl, pdu)
    0

  proc llc_llcp_send*(conhdl: uint16, pdu: pointer,
                      procEnv: pointer): uint32 {.exportc, cdecl.} =
    discard procEnv
    if pdu == nil:
      return 0
    let llcpPduBytes = cast[ptr UncheckedArray[uint8]](pdu)
    let len = nimLlcpWireLength(llcpPduBytes[0])
    if len != 0'u8:
      discard nimLlcpQueuePdu(conhdl, llcpPduBytes, len)
    0

  proc llc_llcp_state_set*(conhdl: uint16, stateKind: uint8,
                           state: uint8): uint32 {.exportc, cdecl.} =
    if conhdl < LLC_CON_MAX.uint16 and llc_env[conhdl] != nil:
      let runtime = llcConnectionRuntime(llc_env[conhdl])
      var flags = runtime.llcpStateFlags
      let bits = state and 0x03'u8
      case stateKind
      of 0'u8:
        flags = (flags and 0xFC'u8) or bits
      of 1'u8:
        flags = (flags and 0xF3'u8) or uint8(bits shl 2)
      of 2'u8:
        flags = (flags and 0xF0'u8) or bits or uint8(bits shl 2)
      else:
        discard
      runtime.llcpStateFlags = flags
    0
else:
  abiNoopHandler(llc_ll_reject_ind_pdu_send)
  abiNoopHandler(llc_llcp_send)
  abiNoopHandler(llc_llcp_state_set)

proc llcMsgConnectionHandle(dest_id, src_id: KeTaskId): uint16 =
  let fromDest = uint16(dest_id shr 8)
  if fromDest != 0'u16:
    fromDest
  else:
    uint16(src_id shr 8)

proc llc_op_ch_map_upd_ind_handler*(msgid: KeMsgId, param: pointer,
                                    dest_id: KeTaskId,
                                    src_id: KeTaskId): uint32
    {.exportc, cdecl.} =
  discard msgid
  discard param
  llc_llcp_ch_map_update_pdu_send(llcMsgConnectionHandle(dest_id, src_id))
  0

proc llc_op_clk_acc_ind_handler*(msgid: KeMsgId, param: pointer,
                                 dest_id: KeTaskId,
                                 src_id: KeTaskId): uint32
    {.exportc, cdecl.} =
  discard msgid
  discard param
  discard dest_id
  discard src_id
  0

proc llc_op_con_upd_ind_handler*(msgid: KeMsgId, param: pointer,
                                 dest_id: KeTaskId,
                                 src_id: KeTaskId): uint32
    {.exportc, cdecl.} =
  discard msgid
  discard param
  discard dest_id
  discard src_id
  0

when defined(bl808m0) and bl808BleNimConnectionEnabled:
  proc llc_op_disconnect_ind_handler*(): uint32 {.exportc, cdecl.} =
    noteNimPeripheralDisconnectedFrom(6'u32, NimLlcpDefaultReason)
    0
else:
  abiNoopHandler(llc_op_disconnect_ind_handler)
proc llc_op_dl_upd_ind_handler*(msgid: KeMsgId, param: pointer,
                                dest_id: KeTaskId,
                                src_id: KeTaskId): uint32
    {.exportc, cdecl.} =
  discard msgid
  discard param
  let conhdl = llcMsgConnectionHandle(dest_id, src_id)
  if conhdl == nim_conn_handle and nim_conn_active:
    sendLeDataLengthChange(conhdl)
  0

proc llc_op_encrypt_ind_handler*(msgid: KeMsgId, param: pointer,
                                 dest_id: KeTaskId,
                                 src_id: KeTaskId): uint32
    {.exportc, cdecl.} =
  discard msgid
  discard param
  let conhdl = llcMsgConnectionHandle(dest_id, src_id)
  llc_llcp_reject_ind_pdu_send(conhdl, 0x1A'u8)
  0

proc llc_op_feats_exch_ind_handler*(msgid: KeMsgId, param: pointer,
                                    dest_id: KeTaskId,
                                    src_id: KeTaskId): uint32
    {.exportc, cdecl.} =
  discard msgid
  discard param
  llc_llcp_feats_req_pdu_send(llcMsgConnectionHandle(dest_id, src_id))
  0

proc llc_op_le_ping_ind_handler*(msgid: KeMsgId, param: pointer,
                                 dest_id: KeTaskId,
                                 src_id: KeTaskId): uint32
    {.exportc, cdecl.} =
  discard msgid
  discard param
  llc_llcp_ping_req_pdu_send(llcMsgConnectionHandle(dest_id, src_id))
  0

proc llc_op_phy_upd_ind_handler*(msgid: KeMsgId, param: pointer,
                                 dest_id: KeTaskId,
                                 src_id: KeTaskId): uint32
    {.exportc, cdecl.} =
  discard msgid
  discard param
  discard dest_id
  discard src_id
  0

proc llc_op_ver_exch_ind_handler*(msgid: KeMsgId, param: pointer,
                                  dest_id: KeTaskId,
                                  src_id: KeTaskId): uint32
    {.exportc, cdecl.} =
  discard msgid
  discard param
  llc_llcp_version_ind_pdu_send(llcMsgConnectionHandle(dest_id, src_id))
  0

abiNoopHandler(llc_proc_collision_check)
proc llc_proc_err_ind*(conhdl: uint16, procId: uint8, status: uint8,
                       param: pointer): uint32 {.exportc, cdecl.} =
  let procEnv = llc_proc_get(conhdl, procId)
  if procEnv != nil:
    let llcProcedureErrorCallback = llcProcEnv(procEnv).errCallback
    if llcProcedureErrorCallback != nil:
      cast[LlcProcErrCallback](llcProcedureErrorCallback)(conhdl, status, param)
  0

proc llc_proc_id_get*(conhdl: uint16, procId: uint8): uint8
    {.exportc, cdecl.} =
  let env = llc_proc_get(conhdl, procId)
  if env == nil:
    0
  else:
    llcProcEnv(env).procId

proc llc_proc_id_set*(conhdl: uint16, procId: uint8,
                      newProcId: uint8): uint32 {.exportc, cdecl.} =
  let env = llc_proc_get(conhdl, procId)
  if env != nil:
    llcProcEnv(env).procId = newProcId
    if newProcId < LlcProcSlotCount.uint8 and newProcId != procId:
      llc_proc_slots[int(conhdl)][int(newProcId)] = env
      llc_proc_slots[int(conhdl)][int(procId)] = nil
  0

proc llc_proc_reg*(conhdl: uint16, procId: uint8,
                   procEnv: pointer): uint32 {.exportc, cdecl.} =
  let llcProcedureSlot = llcProcSlot(conhdl, procId)
  if llcProcedureSlot != nil:
    llcProcedureSlot[] = procEnv
    if procEnv != nil:
      llcProcEnv(procEnv).procId = procId
    llcProcUpdateTaskState(conhdl, procId, procEnv != nil)
  0
when defined(bl808m0) and bl808BleNimConnectionEnabled:
  proc llc_stopped_ind_handler*(): uint32 {.exportc, cdecl.} =
    noteNimPeripheralDisconnectedFrom(7'u32, NimLlcpDefaultReason)
    0
else:
  abiNoopHandler(llc_stopped_ind_handler)
when defined(bl808m0) and bl808BleNimConnectionEnabled and
    bl808BleNimManualConnTx:
  template lldAclRxInd(param: pointer): ptr LldAclRxIndView =
    cast[ptr LldAclRxIndView](param)

  proc lld_acl_rx_ind_handler*(msgid: KeMsgId, param: pointer,
                               dest_id: KeTaskId, src_id: KeTaskId): uint32
      {.exportc, cdecl.} =
    discard msgid
    if param == nil:
      return 0
    let ind = lldAclRxInd(param)
    let bufRef = ind.bufRef
    let len = ind.length
    let llid = ind.llidFlags and 0x03'u8
    let handle = aclTaskHandle(dest_id, src_id, 0'u16)
    if len > 0'u16 and len <= NimBleLeMaxDataOctets and
        (llid == NimDataLlIdStart or
         llid == NimDataLlIdContinuation) and
        sendHostAclData(handle, llid, bufRef, uint8(len)):
      inc nim_acl_rx_count
    else:
      inc nim_acl_rx_drop_count
    ble_util_buf_rx_free(cast[pointer](bufRef.uint))
    0

  proc lld_acl_tx_cfm_handler*(msgid: KeMsgId, param: pointer,
                               dest_id: KeTaskId, src_id: KeTaskId): uint32
      {.exportc, cdecl.} =
    discard msgid
    discard param
    sendNumberOfCompletedPackets(aclTaskHandle(dest_id, src_id, 0'u16), 1'u16)
    0
else:
  abiNoopHandler(lld_acl_rx_ind_handler)
  abiNoopHandler(lld_acl_tx_cfm_handler)

proc updateNimLegacyAdvPayload(data: pointer, length: uint16,
                               emOffset: uint16, scanRsp: bool) =
  let advPayloadCopyLen = min(length.int, 31)
  let source = cast[uint](data)
  let sourceIsRam = data != nil and source >= 0x20000000'u and source < 0x30000000'u
  let sourceIsBtbleEm =
    data != nil and source >= BTBLE_EM_BASE.uint and
    source < (BTBLE_EM_BASE + 0x8000'u32).uint
  let advPayloadBytes = cast[ptr UncheckedArray[uint8]](data)
  if scanRsp:
    nim_scan_rsp_data_len = advPayloadCopyLen.uint8
  else:
    nim_adv_data_len = advPayloadCopyLen.uint8
  for payloadOffset in 0 ..< advPayloadCopyLen:
    let advertisingPayloadByte =
      if sourceIsRam:
        advPayloadBytes[payloadOffset]
      elif sourceIsBtbleEm:
        read8(uint32(source) + payloadOffset.uint32)
      elif emOffset != 0'u16:
        read8(BTBLE_EM_BASE + emOffset.uint32 + payloadOffset.uint32)
      else:
        0'u8
    if scanRsp:
      nim_scan_rsp_data[payloadOffset] = advertisingPayloadByte
    else:
      nim_adv_data[payloadOffset] = advertisingPayloadByte
  if nim_adv_enabled:
    programBtbleLegacyAdv(nim_adv_data_len)

proc lld_adv_end_ind_handler*(msgid: KeMsgId, param: pointer,
                              dest_id: KeTaskId,
                              src_id: KeTaskId): uint32
    {.exportc, cdecl.} =
  discard msgid
  discard param
  discard dest_id
  discard src_id
  if nim_conn_active:
    nim_adv_enabled = false
  0

proc lld_adv_scan_rsp_data_update*(data: pointer, length: uint16,
                                   emOffset: uint16): uint32
    {.exportc, cdecl.} =
  updateNimLegacyAdvPayload(data, length, emOffset, true)
  0

abiNoopHandler(lld_calc_aux_rx)
when not (defined(bl808m0) and bl808BleNimConnectionEnabled and
          bl808BleNimManualConnTx):
  abiNoopHandler(lld_con_data_tx)
abiNoopHandler(lld_con_enc_key_load)
when not (defined(bl808m0) and bl808BleNimConnectionEnabled and
          bl808BleNimManualConnTx):
  abiNoopHandler(lld_con_llcp_tx)
abiNoopHandler(lld_con_offset_upd_ind_handler)
abiNoopHandler(lld_con_param_upd_cfm_handler)
abiNoopHandler(lld_con_param_update)
abiNoopHandler(lld_con_phys_update)
abiNoopHandler(lld_con_rx_enc)
abiNoopHandler(lld_con_tx_enc)
abiNoopHandler(lld_con_tx_len_update_for_intv)
abiNoopHandler(lld_con_tx_len_update_for_rate)
when defined(bl808m0) and bl808BleNimConnectionEnabled:
  proc lld_disc_ind_handler*(): uint32 {.exportc, cdecl.} =
    noteNimPeripheralDisconnectedFrom(8'u32, NimLlcpDefaultReason)
    0
else:
  abiNoopHandler(lld_disc_ind_handler)
when defined(bl808m0) and bl808BleNimConnectionEnabled and
    bl808BleNimManualConnTx:
  proc lld_llcp_rx_ind_handler*(msgid: KeMsgId, param: pointer,
                                dest_id: KeTaskId,
                                src_id: KeTaskId): uint32
      {.exportc, cdecl.} =
    discard msgid
    discard param
    discard dest_id
    discard src_id
    serviceNimConnectionLlcpRxDescriptors()
    0

  proc lld_llcp_tx_cfm_handler*(msgid: KeMsgId, param: pointer,
                                dest_id: KeTaskId,
                                src_id: KeTaskId): uint32
      {.exportc, cdecl.} =
    discard msgid
    discard param
    let conhdl = aclTaskHandle(dest_id, src_id, 0'u16)
    when bl808BleNimPureConnection:
      nimConnCompleteManualTx()
    else:
      if nim_llcp_tx_pending != 0'u32:
        nim_llcp_tx_pending = 0
        inc nim_llcp_free_manual_count
      nimLlcpTrySendQueued()
      nimLlcpTrySendStartup(conhdl)
    0
else:
  abiNoopHandler(lld_llcp_rx_ind_handler)
  abiNoopHandler(lld_llcp_tx_cfm_handler)
abiNoopHandler(lld_per_adv_list_add)
abiNoopHandler(lld_per_adv_list_rem)
abiNoopHandler(lld_phy_upd_cfm_handler)
when defined(bl808m0):
  proc lld_ral_search*(peerAddr: pointer, addrType: uint8): uint8
      {.exportc, cdecl.} =
    discard peerAddr
    discard addrType
    0xFF'u8
else:
  abiNoopHandler(lld_ral_search)
abiNoopHandler(lld_rpa_renew)
when not (defined(bl808m0) and bl808BleNimConnectionEnabled):
  abiNoopHandler(lld_rx_timing_compute)
when not (defined(bl808m0) and
    (bl808BleNimConnectionEnabled or bl808BleNimPureCentral)):
  abiNoopHandler(lld_rxdesc_buf_ready)
abiNoopHandler(lld_scan_req_ind_handler)
when not defined(bl808m0):
  abiNoopHandler(sch_alarm_clear)
  abiNoopHandler(sch_alarm_init)
  abiNoopHandler(sch_alarm_set)
  abiNoopHandler(sch_alarm_timer_isr)
when not (defined(bl808m0)):
  abiNoopHandler(sch_arb_event_start_isr)
  abiNoopHandler(sch_arb_init)
  abiNoopHandler(sch_arb_sw_isr)
when not (defined(bl808m0)):
  abiNoopHandler(sch_plan_chk)
  abiNoopHandler(sch_plan_init)
  abiNoopHandler(sch_plan_req)
  abiNoopHandler(sch_plan_set)
  abiNoopHandler(sch_plan_shift)
when not (defined(bl808m0) and
    bl808BleNimSchProgEnabled):
  abiNoopHandler(sch_prog_end_isr)
  abiNoopHandler(sch_prog_fifo_isr)
  abiNoopHandler(sch_prog_init)
  abiNoopHandler(sch_prog_push)
  abiNoopHandler(sch_prog_rx_isr)
  abiNoopHandler(sch_prog_skip_isr)
  abiNoopHandler(sch_prog_tx_isr)
when not defined(bl808m0):
  abiNoopHandler(sch_slice_bg_add)
  abiNoopHandler(sch_slice_bg_remove)
  abiNoopHandler(sch_slice_compute)
  abiNoopHandler(sch_slice_fg_add)
  abiNoopHandler(sch_slice_fg_remove)
abiNoopHandler(sch_slice_init)
proc specialModP256*(value: pointer) {.exportc, cdecl.} =
  bleBigHexSpecialModP256(value)
