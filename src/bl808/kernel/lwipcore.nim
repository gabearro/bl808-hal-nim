## lwIP core compilation and Nim bindings.
##
## Compiles the lwIP C sources and provides type-safe Nim wrappers
## for the raw API (NO_SYS=1 mode).
##
## Usage:
##   import bl808/kernel/lwipcore
##   lwipInit()
##   # ... set up netif, start DHCP, etc.

# Iter 2.A.0 step 4 follow-up: clock provides kernel_read_tick_ms which
# sys_arch.c (compiled below) calls from sys_now(). Without this import
# nothing pulls clock.nim into the link, so kernel_read_tick_ms is
# unresolved as soon as anything references sys_now (e.g. lwIP timer
# callbacks reachable from ethernet_input).
import ./clock

# =============================================================================
# C compilation
# =============================================================================

# Include paths and sources. WiFi firmware images must use the SDK lwIP tree
# because the WiFi headers put the SDK lwIP include directory first; compiling
# the vendored lwIP C files against those headers mixes incompatible versions.
when defined(bl808WifiNimFw):
  const LwipRoot = "build/bl_iot_sdk_b773b3f/components/network/lwip"
  when defined(bl808WifiRealLwip):
    when defined(bl808WifiRealLwipTcp):
      {.passC: "-Isrc/bl808/kernel/lwip_wifi_http".}
      {.passC: "-include src/bl808/kernel/lwip_wifi_http/lwipopts.h".}
      {.passC: "-Ibuild/bl_iot_sdk_b773b3f/components/os/freertos_e907/include".}
      {.passC: "-Ibuild/bl_iot_sdk_b773b3f/components/os/freertos_e907/portable/GCC/RISC-V".}
    else:
      {.passC: "-Isrc/bl808/kernel/lwip_wifi_smoke".}
  {.passC: "-Ibuild/bl_iot_sdk_b773b3f/components/network/lwip/src/include".}
  {.passC: "-Ibuild/bl_iot_sdk_b773b3f/components/network/lwip/lwip-port".}
  {.passC: "-Ibuild/bl_iot_sdk_b773b3f/components/network/lwip/lwip-port/arch".}
  {.passC: "-Ibuild/bl_iot_sdk_b773b3f/components/network/lwip/lwip-port/config".}
  {.passC: "-Ibuild/bl_iot_sdk_b773b3f/components/network/lwip/lwip-port/FreeRTOS".}
else:
  const LwipRoot = "vendor/lwip"
  {.passC: "-I vendor/lwip/src/include".}
  {.passC: "-I src/bl808/kernel".}        # for lwipopts.h

# Core files
{.compile: LwipRoot & "/src/core/init.c".}
{.compile: LwipRoot & "/src/core/def.c".}
{.compile: LwipRoot & "/src/core/mem.c".}
{.compile: LwipRoot & "/src/core/memp.c".}
{.compile: LwipRoot & "/src/core/pbuf.c".}
{.compile: LwipRoot & "/src/core/netif.c".}
{.compile: LwipRoot & "/src/core/ip.c".}
{.compile: LwipRoot & "/src/core/raw.c".}
when defined(bl808WifiRealLwipTcp):
  {.compile: "src/bl808/kernel/lwip_wifi_http/tcp_enabled.c".}
  {.compile: "src/bl808/kernel/lwip_wifi_http/tcp_in_enabled.c".}
  {.compile: "src/bl808/kernel/lwip_wifi_http/tcp_out_enabled.c".}
elif not defined(bl808WifiRealLwip):
  {.compile: LwipRoot & "/src/core/tcp.c".}
  {.compile: LwipRoot & "/src/core/tcp_in.c".}
  {.compile: LwipRoot & "/src/core/tcp_out.c".}
{.compile: LwipRoot & "/src/core/udp.c".}
{.compile: LwipRoot & "/src/core/inet_chksum.c".}
when defined(bl808WifiRealLwip):
  {.compile: "src/bl808/kernel/lwip_wifi_smoke/timeouts.c".}
else:
  {.compile: LwipRoot & "/src/core/timeouts.c".}
when not defined(bl808WifiRealLwip):
  {.compile: LwipRoot & "/src/core/dns.c".}
{.compile: LwipRoot & "/src/core/sys.c".}
when not defined(bl808WifiRealLwip):
  {.compile: LwipRoot & "/src/core/stats.c".}

# IPv4
when not defined(bl808WifiNimFw):
  {.compile: LwipRoot & "/src/core/ipv4/acd.c".}
{.compile: LwipRoot & "/src/core/ipv4/etharp.c".}
{.compile: LwipRoot & "/src/core/ipv4/ip4.c".}
{.compile: LwipRoot & "/src/core/ipv4/ip4_addr.c".}
{.compile: LwipRoot & "/src/core/ipv4/ip4_frag.c".}
{.compile: LwipRoot & "/src/core/ipv4/icmp.c".}
{.compile: LwipRoot & "/src/core/ipv4/dhcp.c".}

# Netif
{.compile: LwipRoot & "/src/netif/ethernet.c".}

# Arch
{.compile: "src/bl808/kernel/sys_arch.c".}

# =============================================================================
# Fundamental types
# =============================================================================

type
  ErrT* = int8
    ## lwIP error type.

  IpAddr* {.importc: "ip4_addr_t", header: "lwip/ip4_addr.h".} = object
    ## IPv4 address.
    address* {.importc: "addr".}: uint32

  Pbuf* {.importc: "struct pbuf", header: "lwip/pbuf.h", incompleteStruct.} = object
    ## Packet buffer (opaque — access via lwIP functions).

  Netif* {.importc: "struct netif", header: "lwip/netif.h", incompleteStruct.} = object
    ## Network interface (opaque — fields set via lwIP functions).

  PbufLayer* = distinct cint
  PbufType* = distinct cint

var
  pbufTransport* {.importc: "PBUF_TRANSPORT", header: "lwip/pbuf.h", nodecl.}: PbufLayer
  pbufIp* {.importc: "PBUF_IP", header: "lwip/pbuf.h", nodecl.}: PbufLayer
  pbufLink* {.importc: "PBUF_LINK", header: "lwip/pbuf.h", nodecl.}: PbufLayer
  pbufRaw* {.importc: "PBUF_RAW", header: "lwip/pbuf.h", nodecl.}: PbufLayer
  pbufRam* {.importc: "PBUF_RAM", header: "lwip/pbuf.h", nodecl.}: PbufType
  pbufPool* {.importc: "PBUF_POOL", header: "lwip/pbuf.h", nodecl.}: PbufType

const
  ErrOk*: ErrT = 0
  ErrMem*: ErrT = -1
  ErrBuf*: ErrT = -2
  ErrTimeout*: ErrT = -3
  ErrRte*: ErrT = -4
  ErrAbrt*: ErrT = -6
  ErrConn*: ErrT = -11

  NetifFlagBroadcast* = 0x02'u8
  NetifFlagEtharp* = 0x08'u8
  NetifFlagLinkUp* = 0x04'u8
  NetifFlagUp* = 0x01'u8

# =============================================================================
# Callback types
# =============================================================================

type
  NetifInitFn* = proc(netif: ptr Netif): ErrT {.cdecl.}
  NetifInputFn* = proc(p: ptr Pbuf, inp: ptr Netif): ErrT {.cdecl.}
  NetifLinkOutputFn* = proc(netif: ptr Netif, p: ptr Pbuf): ErrT {.cdecl.}
  NetifOutputFn* = proc(netif: ptr Netif, p: ptr Pbuf,
                         ipaddr: ptr IpAddr): ErrT {.cdecl.}
  NetifStatusCb* = proc(netif: ptr Netif) {.cdecl.}

# =============================================================================
# Init
# =============================================================================

proc lwipInit*() {.importc: "lwip_init", header: "lwip/init.h".}
  ## Initialize lwIP. Call once at startup.

proc sysCheckTimeouts*() {.importc: "sys_check_timeouts",
                            header: "lwip/timeouts.h".}
  ## Process expired lwIP timers. Call periodically (~10-50ms).

# =============================================================================
# Pbuf
# =============================================================================

proc pbufAlloc*(layer: PbufLayer, length: uint16,
                kind: PbufType): ptr Pbuf {.importc: "pbuf_alloc",
                                            header: "lwip/pbuf.h".}

proc pbufFree*(p: ptr Pbuf): uint8 {.importc: "pbuf_free",
                                      header: "lwip/pbuf.h".}

proc pbufTake*(buf: ptr Pbuf, data: pointer, len: uint16): ErrT
  {.importc: "pbuf_take", header: "lwip/pbuf.h".}

proc pbufCopyPartial*(p: ptr Pbuf, buf: pointer, len: uint16,
                      offset: uint16): uint16
  {.importc: "pbuf_copy_partial", header: "lwip/pbuf.h".}

proc pbufPayload*(p: ptr Pbuf): pointer =
  {.emit: "result = `p`->payload;".}

proc pbufTotLen*(p: ptr Pbuf): uint16 =
  {.emit: "result = `p`->tot_len;".}

proc pbufLen*(p: ptr Pbuf): uint16 =
  {.emit: "result = `p`->len;".}

proc pbufNext*(p: ptr Pbuf): ptr Pbuf =
  {.emit: "result = `p`->next;".}

# =============================================================================
# Netif
# =============================================================================

proc netifAdd*(netif: ptr Netif, ipaddr, netmask, gw: ptr IpAddr,
               state: pointer, init: NetifInitFn,
               input: NetifInputFn): ptr Netif
  {.importc: "netif_add", header: "lwip/netif.h".}

proc netifSetDefault*(netif: ptr Netif)
  {.importc: "netif_set_default", header: "lwip/netif.h".}

proc netifSetUp*(netif: ptr Netif)
  {.importc: "netif_set_up", header: "lwip/netif.h".}

proc netifSetLinkUp*(netif: ptr Netif)
  {.importc: "netif_set_link_up", header: "lwip/netif.h".}

proc netifSetAddr*(netif: ptr Netif, ipaddr, netmask, gw: ptr IpAddr)
  {.importc: "netif_set_addr", header: "lwip/netif.h".}

proc netifSetStatusCallback*(netif: ptr Netif, cb: NetifStatusCb)
  {.importc: "netif_set_status_callback", header: "lwip/netif.h".}

proc netifSetHwaddr*(netif: ptr Netif, mac: array[6, uint8]) =
  ## Set the MAC address on a netif.
  let macPtr = unsafeAddr mac[0]
  {.emit: """
  {
    int i;
    for (i = 0; i < 6; i++) ((unsigned char*)(`netif`->hwaddr))[i] = ((unsigned char*)`macPtr`)[i];
    `netif`->hwaddr_len = 6;
  }
  """.}

proc netifSetMtu*(netif: ptr Netif, mtu: uint16) =
  {.emit: "`netif`->mtu = `mtu`;".}

proc netifSetFlags*(netif: ptr Netif, flags: uint8) =
  {.emit: "`netif`->flags = `flags`;".}

proc netifSetLinkOutput*(netif: ptr Netif, fn: NetifLinkOutputFn) =
  {.emit: "`netif`->linkoutput = (netif_linkoutput_fn)`fn`;".}

proc netifSetOutput*(netif: ptr Netif, fn: NetifOutputFn) =
  {.emit: "`netif`->output = (netif_output_fn)`fn`;".}

proc netifSetName*(netif: ptr Netif, a, b: char) =
  {.emit: "`netif`->name[0] = `a`; `netif`->name[1] = `b`;".}

# =============================================================================
# Ethernet / ARP
# =============================================================================

proc ethernetInput*(p: ptr Pbuf, netif: ptr Netif): ErrT
  {.importc: "ethernet_input", header: "netif/ethernet.h", cdecl.}

proc etharpOutput*(netif: ptr Netif, q: ptr Pbuf,
                    ipaddr: ptr IpAddr): ErrT
  {.importc: "etharp_output", header: "lwip/etharp.h", cdecl.}

proc etharpGratuitous*(netif: ptr Netif): ErrT =
  ## Announce the current IPv4 address on Ethernet-style netifs.
  ## lwIP exposes this as a macro, so call etharp_request with netif_ip4_addr.
  {.emit: "`result` = etharp_request(`netif`, netif_ip4_addr(`netif`));".}

# =============================================================================
# DHCP
# =============================================================================

proc dhcpStart*(netif: ptr Netif): ErrT
  {.importc: "dhcp_start", header: "lwip/dhcp.h".}

proc dhcpStop*(netif: ptr Netif)
  {.importc: "dhcp_stop", header: "lwip/dhcp.h".}

# =============================================================================
# Raw API
# =============================================================================

type
  RawPcb* {.importc: "struct raw_pcb", header: "lwip/raw.h",
             incompleteStruct.} = object

  RawRecvFn* = proc(arg: pointer, pcb: ptr RawPcb, p: ptr Pbuf,
                    address: ptr IpAddr): uint8 {.cdecl.}

proc rawNew*(proto: uint8): ptr RawPcb
  {.importc: "raw_new", header: "lwip/raw.h".}

proc rawRecv*(pcb: ptr RawPcb, recv: RawRecvFn, arg: pointer)
  {.importc: "raw_recv", header: "lwip/raw.h".}

proc rawSendto*(pcb: ptr RawPcb, p: ptr Pbuf, dst: ptr IpAddr): ErrT
  {.importc: "raw_sendto", header: "lwip/raw.h".}

proc rawRemove*(pcb: ptr RawPcb)
  {.importc: "raw_remove", header: "lwip/raw.h".}

# =============================================================================
# IP address helpers
# =============================================================================

proc ipAddrSet*(a: var IpAddr, val: uint32) {.inline.} =
  a.address = val

proc ip4Addr*(a, b, c, d: uint8): IpAddr =
  IpAddr(address: a.uint32 or (b.uint32 shl 8) or
                  (c.uint32 shl 16) or (d.uint32 shl 24))

proc ipAddrAny*(): IpAddr = IpAddr(address: 0)

# =============================================================================
# TCP raw API
# =============================================================================

type
  TcpPcb* {.importc: "struct tcp_pcb", header: "lwip/tcp.h",
             incompleteStruct.} = object

  TcpRecvFn* = proc(arg: pointer, tpcb: ptr TcpPcb, p: ptr Pbuf,
                      err: ErrT): ErrT {.cdecl.}
  TcpAcceptFn* = proc(arg: pointer, newpcb: ptr TcpPcb,
                        err: ErrT): ErrT {.cdecl.}
  TcpSentFn* = proc(arg: pointer, tpcb: ptr TcpPcb,
                      len: uint16): ErrT {.cdecl.}
  TcpErrFn* = proc(arg: pointer, err: ErrT) {.cdecl.}

proc tcpNew*(): ptr TcpPcb
  {.importc: "tcp_new", header: "lwip/tcp.h".}

proc tcpBind*(pcb: ptr TcpPcb, ipaddr: ptr IpAddr,
               port: uint16): ErrT
  {.importc: "tcp_bind", header: "lwip/tcp.h".}

proc tcpListen*(pcb: ptr TcpPcb): ptr TcpPcb
  {.importc: "tcp_listen", header: "lwip/tcp.h".}

proc tcpAccept*(pcb: ptr TcpPcb, accept: TcpAcceptFn)
  {.importc: "tcp_accept", header: "lwip/tcp.h".}

proc tcpRecv*(pcb: ptr TcpPcb, recv: TcpRecvFn)
  {.importc: "tcp_recv", header: "lwip/tcp.h".}

proc tcpSent*(pcb: ptr TcpPcb, sent: TcpSentFn)
  {.importc: "tcp_sent", header: "lwip/tcp.h".}

proc tcpErr*(pcb: ptr TcpPcb, err: TcpErrFn)
  {.importc: "tcp_err", header: "lwip/tcp.h".}

proc tcpArg*(pcb: ptr TcpPcb, arg: pointer)
  {.importc: "tcp_arg", header: "lwip/tcp.h".}

proc tcpWrite*(pcb: ptr TcpPcb, data: pointer, len: uint16,
                apiflags: uint8): ErrT
  {.importc: "tcp_write", header: "lwip/tcp.h".}

proc tcpOutput*(pcb: ptr TcpPcb): ErrT
  {.importc: "tcp_output", header: "lwip/tcp.h".}

proc tcpRecved*(pcb: ptr TcpPcb, len: uint16)
  {.importc: "tcp_recved", header: "lwip/tcp.h".}

proc tcpClose*(pcb: ptr TcpPcb): ErrT
  {.importc: "tcp_close", header: "lwip/tcp.h".}

proc tcpAbort*(pcb: ptr TcpPcb)
  {.importc: "tcp_abort", header: "lwip/tcp.h".}

const
  TcpWriteFlagCopy* = 0x01'u8
  TcpWriteFlagMore* = 0x02'u8

# =============================================================================
# UDP raw API
# =============================================================================

type
  UdpPcb* {.importc: "struct udp_pcb", header: "lwip/udp.h",
             incompleteStruct.} = object

  UdpRecvFn* = proc(arg: pointer, pcb: ptr UdpPcb, p: ptr Pbuf,
                      remoteAddr: ptr IpAddr, port: uint16) {.cdecl.}

proc udpNew*(): ptr UdpPcb
  {.importc: "udp_new", header: "lwip/udp.h".}

proc udpBind*(pcb: ptr UdpPcb, ipaddr: ptr IpAddr,
               port: uint16): ErrT
  {.importc: "udp_bind", header: "lwip/udp.h".}

proc udpRecv*(pcb: ptr UdpPcb, recv: UdpRecvFn, arg: pointer) =
  {.emit: "udp_recv(`pcb`, (udp_recv_fn)`recv`, `arg`);".}

proc udpSendto*(pcb: ptr UdpPcb, p: ptr Pbuf,
                 dst: ptr IpAddr, port: uint16): ErrT
  {.importc: "udp_sendto", header: "lwip/udp.h".}

proc udpRemove*(pcb: ptr UdpPcb)
  {.importc: "udp_remove", header: "lwip/udp.h".}
