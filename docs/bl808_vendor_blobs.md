# BL808 Vendor Blobs

This file records the provenance for vendor archives that are used as hardware
validation references or temporary bridges while the native Nim paths are being
corrected.

## WiFi

- Local path: `src/bl808/libwifi_fw.a`
- Reference path: `tools/ref/libwifi_bl808.a`
- SHA-256: `6458808ea976de70c0d9f218645efe61ba6e56c9d33fca697abb36a41efe91e7`

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
