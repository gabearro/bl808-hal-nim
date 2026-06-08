## Nim replacement for the BL808 WiFi HOSAL forwarding wrapper.
##
## Platform-specific callbacks still live behind `g_wifi_hosal_funcs`; this
## module removes the SDK C forwarding translation unit from Nim firmware builds.

import hosal/dispatch

export dispatch
