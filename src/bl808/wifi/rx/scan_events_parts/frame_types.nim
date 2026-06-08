proc isBeacon(fc: uint16): bool {.inline.} =
  (fc and (Ieee80211FctlFtype or Ieee80211FctlStype)) == Ieee80211StypeBeacon

proc isProbeResp(fc: uint16): bool {.inline.} =
  (fc and (Ieee80211FctlFtype or Ieee80211FctlStype)) == Ieee80211StypeProbeResp
