## Shared WiFi firmware constants.
##
## Keep this facade stable for wifi_fw.nim and root-level re-exports while the
## ordinary HAL modules are being moved under src/bl808/wifi/.

include fw_constants/states
include fw_constants/status_codes
include fw_constants/config_ids
include fw_constants/limits_events
include fw_constants/tables
include fw_constants/rate_control
