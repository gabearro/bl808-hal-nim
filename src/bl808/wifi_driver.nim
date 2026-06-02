## Nim replacement for the SDK WiFi driver glue in bl60x_wifi_driver/wifi.c.
##
## This module owns the netif init and TX forwarding ABI used by the remaining
## SDK WiFi manager/supplicant scaffolding.

when defined(bl808m0) and defined(bl808WifiNimFw):
  {.passC: "-Ibuild/bl_iot_sdk_b773b3f/components/network/wifi_manager/bl60x_wifi_driver".}
  {.passC: "-Ibuild/bl_iot_sdk_b773b3f/components/network/wifi_manager/bl60x_wifi_driver/include".}
  {.passC: "-Ibuild/bl_iot_sdk_b773b3f/components/network/lwip/src/include".}
  {.passC: "-Ibuild/bl_iot_sdk_b773b3f/components/network/lwip/lwip-port".}
  {.passC: "-Ibuild/bl_iot_sdk_b773b3f/components/network/lwip/lwip-port/config".}

  const
    ErrOk = 0'i8
    ErrIf = -12'i8
    WifiMtuSize = 1514'u16
    EtharpHwaddrLen = 6'u8
    NetifFlagBroadcast = 0x02'u8
    NetifFlagEtharp = 0x08'u8
    NetifFlagIgmp = 0x20'u8
    OpTaskGetCurrentTaskOff = 68'u
    OpTaskNotifyOff = 76'u

  type
    ErrT = int8

    Pbuf {.importc: "struct pbuf", header: "<lwip/pbuf.h>".} = object
      next*: ptr Pbuf
      payload*: pointer
      tot_len*: uint16
      len*: uint16

    Ip4Addr {.importc: "ip4_addr_t", header: "<lwip/ip4_addr.h>".} = object
      addr32* {.importc: "addr".}: uint32

    IpAddr {.importc: "ip_addr_t", header: "<lwip/ip_addr.h>".} = object
      addr32* {.importc: "addr".}: uint32

    Netif {.importc: "struct netif", header: "<lwip/netif.h>".} = object
      ip_addr* {.importc: "ip_addr".}: IpAddr
      hostname*: cstring
      mtu*: uint16
      hwaddr_len*: uint8
      flags*: uint8
      output*: NetifOutputFn
      linkoutput*: NetifLinkoutputFn
      status_callback*: NetifStatusCallbackFn

    NetifOutputFn = proc(netif: ptr Netif; p: ptr Pbuf; ipaddr: ptr Ip4Addr): ErrT {.cdecl.}
    NetifLinkoutputFn = proc(netif: ptr Netif; p: ptr Pbuf): ErrT {.cdecl.}
    NetifStatusCallbackFn = proc(netif: ptr Netif) {.cdecl.}
    BlTxCallback = proc(cbArg: pointer; txOk: bool) {.cdecl.}
    TaskGetCurrentTaskProc = proc(): pointer {.cdecl.}
    TaskNotifyProc = proc(task: pointer) {.cdecl.}

    BlTxCfm {.importc: "struct bl_tx_cfm", header: "bl_tx.h".} = object
      cb*: BlTxCallback
      cb_arg* {.importc: "cb_arg".}: pointer

    BlOpsFuncs {.importc: "bl_ops_funcs_t",
                 header: "bl_os_adapter/bl_os_adapter.h".} = object

    WifiConfC {.importc: "wifi_conf_t", header: "include/wifi_mgmr_ext.h".} = object
      country_code* {.importc: "country_code".}: array[3, cchar]

    WifiMgmr {.importc: "wifi_mgmr_t", header: "wifi_mgmr.h".} = object
      country_code* {.importc: "country_code".}: array[3, cchar]
      channel_nums* {.importc: "channel_nums".}: cint
      hostname* {.importc: "hostname".}: array[32, cchar]

  var
    taskHandleOutput: pointer
    bl606a0StaHw: pointer
    wifiMgmr {.importc: "wifiMgmr", header: "wifi_mgmr.h".}: WifiMgmr
    g_bl_ops_funcs {.importc, header: "bl_os_adapter/bl_os_adapter.h".}: BlOpsFuncs

  proc etharp_output(netif: ptr Netif; p: ptr Pbuf; ipaddr: ptr Ip4Addr): ErrT
    {.importc, cdecl, header: "<netif/etharp.h>".}
  proc netif_set_status_callback(netif: ptr Netif; cb: NetifStatusCallbackFn)
    {.importc, cdecl, header: "<lwip/netif.h>".}
  proc bl_output(blHw: pointer; isSta: cint; p: ptr Pbuf; customCfm: ptr BlTxCfm): ErrT
    {.importc, cdecl, header: "bl_tx.h".}
  proc bl_main_rtthread_start(blHw: ptr pointer): cint
    {.importc, cdecl, header: "bl_main.h".}
  proc bl_msg_update_channel_cfg(countryCode: cstring)
    {.importc, cdecl, header: "bl_msg_tx.h".}
  proc bl_msg_get_channel_nums(): cint
    {.importc, cdecl, header: "bl_msg_tx.h".}
  proc bl_wifi_clock_enable(): cint {.importc, cdecl.}
  proc bl_wifi_mac_addr_get(mac: ptr uint8): cint {.importc, cdecl.}
  proc arch_delay_us(us: uint32) {.importc, cdecl.}
  proc wifi_mgmr_sta_netif_get(): ptr Netif {.importc, cdecl.}
  proc wifi_mgmr_api_ip_update(): cint {.importc, cdecl.}
  proc wifi_mgmr_api_ip_got(): cint {.importc, cdecl.}
  when defined(bl808WifiNimDriverTrace):
    proc c_printf(fmt: cstring): cint
      {.importc: "printf", header: "<stdio.h>", cdecl, varargs, discardable.}

    proc trace(msg: cstring) {.inline.} =
      c_printf("[WIFI-DRIVER] %s\r\n", msg)
  else:
    template trace(msg: cstring) = discard

  proc opPtr(off: uint): pointer {.inline.} =
    cast[ptr pointer](cast[uint](addr g_bl_ops_funcs) + off)[]

  proc blOsTaskNotify(task: pointer) {.inline.} =
    let fn = cast[TaskNotifyProc](opPtr(OpTaskNotifyOff))
    if fn != nil:
      fn(task)

  proc blOsTaskGetCurrentTask(): pointer {.inline.} =
    let fn = cast[TaskGetCurrentTaskProc](opPtr(OpTaskGetCurrentTaskOff))
    if fn == nil: nil else: fn()

  proc blTxNotify(cbArg: pointer; txOk: bool) {.cdecl.} =
    discard cbArg
    discard txOk
    if taskHandleOutput != nil:
      blOsTaskNotify(taskHandleOutput)

  proc wifiTx(netif: ptr Netif; p: ptr Pbuf): ErrT {.cdecl.} =
    trace("wifiTx")
    if p == nil:
      trace("wifiTx nil")
      return ErrIf
    if p.tot_len > WifiMtuSize:
      trace("wifiTx mtu")
      return ErrIf
    if taskHandleOutput == nil:
      taskHandleOutput = blOsTaskGetCurrentTask()

    var customCfm = BlTxCfm(cb: blTxNotify, cb_arg: nil)
    let isSta = if netif == wifi_mgmr_sta_netif_get(): 1.cint else: 0.cint
    bl_output(bl606a0StaHw, isSta, p, addr customCfm)

  proc bl_wifi_eth_tx*(p: ptr Pbuf; isSta: bool; customCfm: ptr BlTxCfm): cint
    {.exportc, cdecl.} =
    {.emit: """
    extern volatile unsigned int nimfw_dbg_eth_tx_eapol;
    extern volatile unsigned int nimfw_dbg_eth_tx_ret;
    nimfw_dbg_eth_tx_eapol++;
    """.}
    trace("bl_wifi_eth_tx")
    let rc = bl_output(bl606a0StaHw, (if isSta: 1.cint else: 0.cint), p, customCfm)
    {.emit: ["nimfw_dbg_eth_tx_ret = (unsigned int)", rc, ";"].}
    if rc == ErrOk:
      arch_delay_us(1000)
      0
    else:
      -1

  proc netifStatusCallback(netif: ptr Netif) {.cdecl.} =
    if netif == nil or netif.ip_addr.addr32 == 0'u32:
      trace("status ip update")
      discard wifi_mgmr_api_ip_update()
    else:
      trace("status ip got")
      discard wifi_mgmr_api_ip_got()

  proc bl606a0_wifi_netif_init*(netif: ptr Netif): ErrT {.exportc, cdecl.} =
    trace("netif init")
    if netif == nil:
      return ErrIf
    netif.hostname = cast[cstring](addr wifiMgmr.hostname[0])
    netif.hwaddr_len = EtharpHwaddrLen
    netif.mtu = 1500'u16
    netif.flags = NetifFlagBroadcast or NetifFlagEtharp or NetifFlagIgmp
    netif.output = etharp_output
    netif.linkoutput = wifiTx
    netif_set_status_callback(netif, netifStatusCallback)
    ErrOk

  proc clearHostname() =
    for i in 0 ..< wifiMgmr.hostname.len:
      wifiMgmr.hostname[i] = 0.cchar

  proc putHostnameChar(pos: var int; ch: char) =
    if pos < wifiMgmr.hostname.len - 1:
      wifiMgmr.hostname[pos] = ch.cchar
      inc pos

  proc putHostnameHex(pos: var int; value: uint8) =
    const hex = "0123456789abcdef"
    putHostnameChar(pos, hex[int((value shr 4) and 0x0f'u8)])
    putHostnameChar(pos, hex[int(value and 0x0f'u8)])

  proc setHostname(mac: ptr uint8) =
    clearHostname()
    var pos = 0
    for ch in "Bouffalolab_BL808-":
      putHostnameChar(pos, ch)
    putHostnameHex(pos, cast[ptr UncheckedArray[uint8]](mac)[3])
    putHostnameHex(pos, cast[ptr UncheckedArray[uint8]](mac)[4])
    putHostnameHex(pos, cast[ptr UncheckedArray[uint8]](mac)[5])

  proc bl606a0_wifi_init*(conf: ptr WifiConfC): cint {.exportc, cdecl.} =
    trace("wifi init")
    var mac: array[6, uint8]
    discard bl_wifi_mac_addr_get(addr mac[0])
    setHostname(addr mac[0])

    if conf != nil:
      bl_msg_update_channel_cfg(cast[cstring](addr conf.country_code[0]))
      wifiMgmr.country_code[0] = conf.country_code[0]
      wifiMgmr.country_code[1] = conf.country_code[1]
    else:
      bl_msg_update_channel_cfg("US")
      wifiMgmr.country_code[0] = 'U'.cchar
      wifiMgmr.country_code[1] = 'S'.cchar
    wifiMgmr.country_code[2] = 0.cchar

    discard bl_wifi_clock_enable()
    bl606a0StaHw = nil
    result = bl_main_rtthread_start(addr bl606a0StaHw)
    wifiMgmr.channel_nums = bl_msg_get_channel_nums()
