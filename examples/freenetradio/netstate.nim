## What the rest of the radio needs to know about the network (upstream:
## `stack.is_link_up()` / `is_config_up()` and `display::set_ip` /
## `set_link`). The network task writes it; everyone else reads.
## "Link" is the Wi-Fi association (upstream: the Ethernet link).

type
  NetState* = object
    linkUp*: bool               ## associated with the access point
    hasIp*: bool                ## DHCP has given us an address
    ip*: array[4, uint8]
    gateway*: array[4, uint8]

var net*: NetState

proc configUp*(): bool {.inline.} = net.linkUp and net.hasIp
