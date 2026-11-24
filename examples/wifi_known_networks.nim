## Selection for the HTTP manager's two configured Wi-Fi profiles.

type
  KnownWifiTarget* = enum
    wifiTargetNone, wifiTargetPrimary, wifiTargetFallback
  KnownWifiMatches* = set[KnownWifiTarget]

proc matchesKnownWifi*(bytes: openArray[uint8]; length: uint8;
                       channel, requiredChannel: uint8; name: string): bool =
  if name.len == 0 or length.int != name.len or length.int > bytes.len or
      (requiredChannel != 0 and channel != requiredChannel):
    return false
  for i in 0 ..< name.len:
    if bytes[i] != name[i].uint8: return false
  true

proc bootWifiTarget*(seen: KnownWifiMatches; allowFallback: bool): KnownWifiTarget =
  if allowFallback and wifiTargetFallback in seen: wifiTargetFallback
  elif wifiTargetPrimary in seen: wifiTargetPrimary
  else: wifiTargetNone

proc reconnectWifiTarget*(previous: KnownWifiTarget;
                          seen: KnownWifiMatches): KnownWifiTarget =
  if previous in seen: previous
  elif wifiTargetPrimary in seen: wifiTargetPrimary
  elif wifiTargetFallback in seen: wifiTargetFallback
  else: previous # Let the firmware retry its last configured target.
