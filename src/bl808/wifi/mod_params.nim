## Nim replacement for the small BL808 WiFi host-driver mod-params unit.
##
## The SDK C driver still owns `struct bl_hw`; this module only exports the
## global `bl_mod_params` object and writes the same HT capability fields as
## Bouffalo's bl_mod_params.c for the configured BL808 host layout.

import
  mod_params/state,
  mod_params/core

export
  state,
  core
