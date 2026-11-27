## Nim implementation of the Bouffalo WiFi host IPC shim used by Nim firmware.
##
## The remaining SDK host driver still allocates and passes the C structs from
## ipc_host.h/ipc_shared.h. Keep this module at the C ABI boundary and access
## fields by the fixed BL808 M0 layout used by wifi.nim's CFG_TXDESC=4 build.

import ../mmio
when defined(bl808WifiSplitTxSlots):
  from std/bitops import firstSetBit, countSetBits

include ipc_host/layout
include ipc_host/callback_types
include ipc_host/debug_state

include ipc_host/host_interfaces
include ipc_host/accessors
include ipc_host/runtime
include ipc_host/list_helpers
include ipc_host/callbacks

when defined(bl808WifiSplitTxSlots):
  include ipc_host/tx_dma_pool
include ipc_host/init
include ipc_host/messages
include ipc_host/tx_shared
include ipc_host/irq
