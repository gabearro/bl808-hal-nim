# Vendor firmware provenance

The BL808 SDKs provide pinned network build inputs and several comparison
archives. The [native Wi-Fi guide](wifi.md) describes the code that runs in
the standard FreeNetRadio build.

## Wi-Fi application build inputs

The Wi-Fi application and lwIP build expect the Bouffalo IoT SDK at
`build/bl_iot_sdk_b773b3f`. If the directory is absent:

```sh
mkdir -p build
git clone https://github.com/bouffalolab/bl_iot_sdk.git build/bl_iot_sdk_b773b3f
git -C build/bl_iot_sdk_b773b3f checkout --detach \
  b773b3f4bf6154125304a328c72bf2aa7168a715
git -C build/bl_iot_sdk_b773b3f apply "$PWD/tools/bl808_lwip_dhcp_policy.patch"
git -C build/bl_iot_sdk_b773b3f apply "$PWD/tools/bl808_wifi_wpa_key_result.patch"
```

The repository uses its lwIP sources and WPA supplicant together with local
adapters and overlays.
[lwIP build](../src/bl808/kernel/lwipcore.nim) ·
[Wi-Fi SDK configuration](../src/bl808/wifi/facade_parts/sdk_build_config_parts/).

Apply the DHCP policy and WPA key-result patches once per clean checkout.
The standard FreeNetRadio build checks for both changes at compile time.
The other trace patches in [tools](../tools/) support focused diagnostics.

## Reference archives

| Artifact | Provenance |
| --- | --- |
| [libwifi_fw.a](../src/bl808/libwifi_fw.a) and [libwifi_bl808.a](../tools/ref/libwifi_bl808.a) | Byte-identical to `components/network/wifi/lib/libwifi.a` at IoT SDK commit `b773b3f4`. SHA-256 `6458808ea976de70c0d9f218645efe61ba6e56c9d33fca697abb36a41efe91e7`. |
| `libbl606p_phyrf.a` | The companion RF archive selected by the pinned Bouffalo [BL808 demo build](https://github.com/bouffalolab/bl_iot_sdk/blob/b773b3f4bf6154125304a328c72bf2aa7168a715/customer_app/bl808/bl808_demo_event/Makefile). Its Git blob is `a9935b475d2198000ae7b67d141f00767176a81a`. |
| [librf_bl808.a](../src/bl808/librf_bl808.a) | The BL616-derived legacy RF reference from the `bl808_fw` SDK branch. SHA-256 `5808ffe3bfdcf8c7f1b0f46b2e287fa6d99130c7a1a385ccb8ab7fb538b9d864`. |
| [BL808 BLE controller archive](../src/bl808/libbtblecontroller_bl808_ble1m0s1bredr0.a) | `bouffalolab/bouffalo_sdk` commit `a05d70b0`. SHA-256 `802780e9e6ad158ae124012415e1af97514ac14738ee103e91783d81a26b427a`. |

For RF link provenance, build the native scan test, then pass the real
demo RF archive and the same harness work directory:

```sh
.venv/bin/python tools/hw_validate.py --test m0_wifi_nimfw_scan_hal_test --build-only
python3 tools/validate_rf_symbol_provenance.py \
  --bl808-demo-rf-archive "$BL808_DEMO_RF_ARCHIVE" \
  --hw-validation-test m0_wifi_nimfw_scan_hal_test \
  --hw-validation-work-dir build/hw-validation
```

The tool checks selected archive and ELF symbols. Device behavior requires
the corresponding hardware test. See the
[prior provenance and experiment notes](https://github.com/gabearro/bl808-hal-nim/blob/eb932dddbb56ac5131b3d398e5463f18008fc639/docs/bl808_vendor_blobs.md)
for disassembly offsets and individual bench results.
