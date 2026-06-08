## BLE Controller reimplementation for BL808 (replaces libblecontroller_bl602_m1s1.a)
##
## Reimplemented from the binary blob disassembly. All 465 exported symbols
## are provided with {.exportc, cdecl.} pragmas.
##
## Module map:
##   co_list / co_bdaddr   -- linked list and BD address utilities
##   ke_*                  -- kernel: events, messages, timers, tasks, memory
##   ea_*                  -- event arbiter / scheduler
##   em_buf_*              -- exchange memory buffer management
##   hci_*                 -- HCI command/event interface
##   llc_*                 -- link layer control
##   lld_*                 -- link layer driver hardware
##   llm_*                 -- link layer manager (adv, scan, connection)
##   bflbble_* / bflbip_*  -- platform integration
##   ecc_*                 -- ECC crypto

import mmio
import core
import irq
import blep256
import blebighex
from blerfdata import nil
from blecrypto import nil

include blecontroller/feature_config
include blecontroller/constants_interrupts
include blecontroller/registers_wireless_rf
include blecontroller/types_state
include blecontroller/runtime_scheduler
include blecontroller/kernel_core
include blecontroller/hci_llc_lld
include blecontroller/platform_api
include blecontroller/abi_aliases_tail
