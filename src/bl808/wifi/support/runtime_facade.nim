## Vendor runtime facade exports used by WiFi manager and WPA code.

include runtime_facade_parts/events
include runtime_facade_parts/power_management
include runtime_facade_parts/time
include runtime_facade_parts/random
when defined(bl808WifiRealLwip):
  include runtime_facade_parts/dhcp_xid
  include runtime_facade_parts/dhcp_retry
include runtime_facade_parts/heap
include runtime_facade_parts/task
include runtime_facade_parts/asserts
