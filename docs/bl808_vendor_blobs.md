# BL808 Vendor Blobs

This file records the provenance for vendor archives that are used as hardware
validation references or temporary bridges while the native Nim paths are being
corrected.

## WiFi

- Local path: `src/bl808/libwifi_fw.a`
- Reference path: `tools/ref/libwifi_bl808.a`
- SDK source: `bouffalolab/bl_iot_sdk`
- Verified source commit: `b773b3f4bf6154125304a328c72bf2aa7168a715`
  (`[BL808] [APP] add bl808_demo_event support wifi`, 2023-04-21)
- Source path: `components/network/wifi/lib/libwifi.a`
- SHA-256: `6458808ea976de70c0d9f218645efe61ba6e56c9d33fca697abb36a41efe91e7`
- The source archive at this commit and both local copies are byte-identical.
  This is a BL808 reference, not the later `wifi6` archive in `bouffalo_sdk`.

### Pure Nim TX Policy

The default firmware copies the station's complete rate, retry, and RF power
policy into each host TX buffer, matching the vendor allocator.

`-d:bl808WifiBootstrapRetryWorkaround` opts into the earlier bench workaround:
fixed retry rates and power for EAPOL and all IPv4/ARP traffic. It is not limited
to DHCP or the period immediately after association. This is a diagnostic
override, not the vendor-parity configuration. The existing
`bl808WifiKeepEapolRcPrimary` and `bl808WifiForceEapolPrimaryLegacy` options only
modify this explicitly enabled workaround; the latter takes precedence.

Authentication and association requests keep the internal-frame allocator's
rate policy and TPC-selected power by default. Their earlier fixed rate/power
and retry-limit workaround is available with
`-d:bl808WifiMgmtRetryWorkaround`. The `bl808WifiMgmtOfdmFirst`,
`bl808WifiMgmtLegacyFirst`, and `bl808WifiKeepMgmtRcPrimary` options only adjust
that explicit workaround, in that precedence order. The separate
`bl808WifiForceTxPwr20`, `bl808WifiForceTxPwr30`, and `bl808WifiForceTxPwr70`
diagnostic options still override management TX power independently.

### Station RX Configuration

Authentication and association frame construction preserve the installed MAC
registers and RX filter by default. VIF setup and scan start/finish own that
configuration; sending a frame does not restore scan-only receive flags.

`-d:bl808WifiAuthPromiscRx` enables the previous broad RX filter for these
builders. `-d:bl808WifiAuthHwWorkaround` enables the previous pre-authentication
MAC/address register reprogramming. Both are diagnostic overrides; enabling
both reproduces the former MAC/RX behavior.

### Power Table Adapter

The WiFi SDK's `trpc_update_power` and `trpc_power_get` interfaces use a packed
24-byte table (three 8-byte rate groups). The newer RF backend stores those
groups in 10-byte rows. The Nim adapter packs/unpacks these groups without
changing RF padding or the remaining rate families. RF channel-width config
reloads use a separate internal operation, not the WiFi table-pointer API.
The outer 38-byte WiFi table adds 14 channel offsets after the rate groups.

### PHY Interrupt Ownership

The selected RF backend's `phy_mdm_isr` is a no-op. `phy_rc_isr` reads the
modem status at `0x24C0B41C` and acknowledges it at `0x24C0B420`. Channel
setup retains its separate pulse at `0x24C00888`; the modem interrupt must
not acknowledge RC status or initiate a channel-change pulse.

The older SDK PHY differs: its modem handler logs only, while its RC handler
also has a legacy pulse. Those older RC side effects are not transferred to
the selected backend's modem handler.

### PHY Capability Fields

The selected RF backend reads modem-version bit 22 for VHT and bit 21 for HE.
VHT is also available when the bandwidth field at bits 25:24 is nonzero.
LDPC TX/RX use bits 26/27, beamformee/beamformer use bits 28/29, and MU-MIMO
RX/TX use bits 30/31. Bandwidth bits must not stand in for LDPC support.
Station TX policy enables LDPC only when both the local TX capability and the
peer's HT LDPC capability are present.

`phy_get_antenna_set` uses the TX-chain count at bits 7:4, not the RX count at
bits 3:0, and returns the low byte of the resulting chain mask.
`phy_set_group_id_info` reads an 8-byte membership bitmap and 16-byte user
position array as little-endian byte sequences without requiring word alignment.

### RF Power Replay

The selected RF backend packs live WLAN/BZ power rows before replaying the
matching calibration records. Low-power compensation uses the vendor's coarse
row selection and residual adjustment, including its asymmetric rounding and
saturation. Calibration selection follows the live WLAN index table rather
than its default values.

Runtime low-power compensation replays only WLAN fields; BZ target-power
changes replay only BZ fields. Both preserve live unowned register bits and
publish power fields before calibration fields in vendor store order. Runtime
WB03 replay checks completeness only for the selected domain. Full
initialization and restore retain the existing whole-bank path.

The existing WB03/40 MHz restore fallback remains enabled unless complete
calibration replay is explicitly selected and the required records are present.
That fallback still uses its fixed register baseline; these corrections do not
establish full calibration parity or physical radio readiness.

## BLE

- Local controller path: `src/bl808/libbtblecontroller_bl808_ble1m0s1bredr0.a`
- Local RF path: `src/bl808/librf_bl808.a`
- SDK source: `bouffalolab/bouffalo_sdk`
- Controller source commit: `a05d70b0`
- Controller source path:
  `components/wireless/bluetooth/btblecontroller/lib/libbtblecontroller_bl808_ble1m0s1bredr0.a`
- Controller SHA-256: `802780e9e6ad158ae124012415e1af97514ac14738ee103e91783d81a26b427a`
- The BL808 controller archive was removed from the SDK in commit `7e7b5642`.
- RF source path:
  `drivers/soc/bl616/rf/lib/librf.a` from the same `bl808_fw` SDK branch
- RF SHA-256: `5808ffe3bfdcf8c7f1b0f46b2e287fa6d99130c7a1a385ccb8ab7fb538b9d864`
