# Global firmware state include map.
#
# Keep these includes in the same order as the former monolithic file. This
# module is included by wifi_fw.nim, so these files still compile into the
# historical wifi firmware ABI anchor.

include global_state/storage
include global_state/c_runtime
include global_state/debug_exports
include global_state/trace_helpers
include global_state/forward_decls_base
include global_state/debug_rx_helpers
include global_state/forward_decls_mac
include global_state/rf_bl808_core
include global_state/rf_core_init_asserts
include global_state/late_forward_decls
include global_state/event_runtime_init
