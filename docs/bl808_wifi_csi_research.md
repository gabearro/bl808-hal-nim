# BL808 Wi-Fi CSI Research Handoff

## Where We Left Off

The target is a BL808 M0 software interface that returns the complex Wi-Fi
channel estimate `H[k]` for each received OFDM packet and ties the estimate to
that packet. Finding the interface means establishing the trigger, the ready
event, the coefficient address or DMA destination, and the word format. The
source search targets the C driver that programs this modem and its register
definitions.

- **RivieraWaves driver.** The original BL808 PHY/RF C remains unlocated.
  The M1s archives identify eight BL808 WLAN register headers and preserve
  152 named accessors. SiFlower's published PHY C matches eight programmed
  values in the M1s initialization. ListenAI's compiled PHY matches the
  selected BL808 archive's two channel calculations. The published BL602
  radio-controller header matches 28 BL808 accessors by offset and mask.
  [Public builds of `phy.c`](#public-builds-of-phyc) ·
  [Register and value comparison](#driver-values-across-candidate-sdks)
- **Direct readout.** BL808 and QCC743 share several modem registers down to the
  bit masks, and an archived BL808 hardware read decodes as Karst using the
  shared configuration layout. QCC743 headers and Beken Karst code agree on
  the direct-read candidates `0x24C008F8` and `0x24C00064` at the BL808 base.
  BL808 decode, readiness, and coefficient storage remain unverified.
- **DMA.** QCC743 and several Bouffalo BL616 variants ship a CSI driver that
  uses a dedicated controller at `0x24C70000` and writes into host-allocated
  buffers. The investigated BL808/M1s archives yielded no identifiable use of
  either CSI interface. Their PHY tables and Linux M0 Wi-Fi image are accounted
  for. A separate modem firmware image or loader remains unsubstantiated.
- **Coefficient window.** Beken reads at modem base `+0x9000`. An archived
  BL808 dump in BLE mode matches the first 32 words of the loaded LDPC table
  at that offset. Its ownership during a Wi-Fi capture remains open.
- **Raw RF samples.** The older Sipeed RF header and M1s diagnostic agree
  field for field on the RF SRAM capture controls. A November 2026 bench run
  captured changing I/Q words from BL808 OCRAM at `0x22028000` on both
  taps, with fresh completion and no stray writes. Channel-6 traffic later
  produced legacy short and long training fields. Two independent captures
  yielded 52-tone provisional channel estimates whose normalized magnitude
  correlation was `0.936`. The absolute sample clock, orientation, and
  physical channel response still lack a known RF reference.

The raw RF path now produces packet-aligned provisional CSI, but the
software snapshot decoder produced only 2–18 records/s across the 15
one-second sound-control runs. That cadence cannot resolve 300 or 330 Hz.
The next CSI architecture gate is a hardware packet trigger or CSI DMA
readout with gain-consistent packet timestamps. A live forced-RF test of the
candidate direct modem control/status pair returned zero control readback,
zero status, and an unchanged coefficient-window hash. A normal-MAC data-frame
test is needed before ruling that path out.

## Source of the Current Wi-Fi Build

The BL808 M0 scan test builds the Wi-Fi stack and host-side PHY control from
this repository. A fresh build of `m0_wifi_nimfw_scan_hal_test` links
`phy_init` at `0x58033BBA`, `rfc_config_channel` at `0x580339FA`, and
`rxl_cntrl_evt` at `0x5803A5B6` from the generated
`@pbl808@swifi_fw.nim.c.o`. The link map contains zero references to
`libwifi_fw.a`, `libwifi_bl808.a`, or `librf_bl808.a`. The M0 facade
requires `-d:bl808WifiNimFw`. This gives us editable source on both sides
of the host RX event and PHY initialization path.
[Firmware entry point](../src/bl808/wifi_fw.nim) ·
[PHY initialization and channel control][local-phy] ·
[RX event handler][local-rx] · [M0 facade](../src/bl808/wifi.nim)

### Original vendor C and the modem implementation

| Component | Source evidence |
| --- | --- |
| E907 Wi-Fi MAC firmware reference | Both local Wi-Fi archive copies match the archive in the April 21, 2023 Bouffalo BL808 demo commit `b773b3f4`. All 70 members retain C translation-unit paths in DWARF. For example, `rxl_cntrl.o` names `components/network/wifi/ip/lmac/src/rx/rxl/rxl_cntrl.c`. Every one of those paths is absent from the pinned SDK tree. The SDK build marks the component library-only and links `-lwifi`. [Exact archive][bl-pinned-wifi] · [SDK make fragment][bl-pinned-wifi-mk] |
| E907 PHY/RF control reference | `src/bl808/librf_bl808.a` matches `drivers/soc/bl616/rf/lib/librf.a` byte for byte at `a05d70b0` and at historical `bl808_fw` tip `1b76ad75`. The package publishes the archive, CMake file, `wl_api.h`, and `wl_config.h`. Its 14 objects have no DWARF compilation units. The member `phy.c.o` defines `phy_init` and `phy_get_version`. [Pinned RF build recipe][bl-pinned-rf-mk] · [Exact archive bytes][bl-pinned-rf] |
| Earlier BL606P PHY/RF references | Bouffalo `b773b3f4` and Sipeed `bf7e689` ship distinct older `libbl606p_phyrf.a` builds. Both identify `components/platform/soc/bl606p/bl606p_phyrf/phy/phy.c` in DWARF. All 14 translation-unit paths in each archive are absent from its corresponding SDK commit. The Sipeed Wi-Fi archive likewise names 71 C translation units absent from its tree. [Bouffalo PHY/RF package][bl-early-rf] · [Sipeed archive][m1s-rf-archive] |
| On-chip Wi-Fi baseband | The inspected source and archives show E907 register programming, AGC table loading, and PHY control. A separate modem executable, load protocol, and its integration into BL808 remain unverified. Ceva documented both hardwired and programmable options for its Wi-Fi IP family. [Ceva's Wi-Fi IP announcement][ceva-rw-options] · [BL808 reference manual][bl-rm] |

The source search used the archive's exact DWARF paths and the selected RF
member basenames across public Git history. It covered 127 reachable commits
in Bouffalo `bl_iot_sdk`, 752 in `bouffalo_sdk` including both explicitly
fetched 2023 RF commits, 66 in Bouffalo's driver mirror, and both Sipeed
lineages (92 commits). The official Gitee `bl_iot_sdk` mirror's 77 commits
are contained in the GitHub history. The 638-commit SoCXin snapshot carries
the same RF archive blob. The original BL808 C translation units and modem
register package remain unavailable in the checked trees. The current
Bouffalo OpenVela manifest documents precompiled distribution for its
wireless and PHY/RF components.
[Bouffalo SDK][bl-sdk] · [Driver mirror][bl-drivers] ·
[Historical Sipeed tree][m1s-phy-history] · [Bouffalo Gitee mirror][bl-gitee] ·
[SoCXin snapshot][socxin-sdk-rf] · [OpenVela packaging policy][bl-vela-policy]

The build can be reproduced without a board. The link map and the archive
inventory from this pass are under `build/hw-validation-wifi-source/`.

```sh
.venv/bin/python tools/hw_validate.py --test m0_wifi_nimfw_scan_hal_test \
  --jtag-flash --build-only --work-dir build/hw-validation-wifi-source
```

## RivieraWaves Karst Driver Source Search

The target is the original RivieraWaves-derived C that runs on the E907
and programs the BL808 Wi-Fi PHY. The primary files are `phy.c`, its
`reg/bl808/wlan` register headers, and any capture routines or lower-MAC
RX hooks that consume channel estimates. The older PHY/RF archive gives
the concrete translation-unit path
`components/platform/soc/bl606p/bl606p_phyrf/phy/phy.c`.
Ceva describes the C software and the modem as distinct IP deliverables.
[M1s PHY/RF archive][m1s-rf-archive] · [Ceva Sense integration webinar][ceva-rw-sense]

### Public builds of `phy.c`

The public `bouffalo_sdk-drivers` snapshot at `1f406cee` has three useful
comparators for the pinned BL808 `phy.c.o`. OpenVela's porting document
identifies this driver mirror as the source of its precompiled PHY/RF
library. The mirror's 66 reachable commits and the OpenVela vendor
repository's 374 reachable commits yielded no tracked matching `phy.c`.
The mirror supplies archives and interface headers for these parts.
[OpenVela driver integration][vela-phy-port] · [Driver mirror][bl-drivers]

| Archive member | Verified comparison with the pinned BL808 `phy.c.o` |
| --- | --- |
| `libbl616_phyrf.a:phy.o` | 25 of 31 common function sections have byte-identical instruction bodies, including `phy_get_version`, `phy_get_rf_gain_idx`, and `phy_set_group_id_info`. Both `rxgain` data sections match, including bytes `0E 13 1A 20 26 2D 32 39 3F`. `phy_init`, `phy_set_channel`, and `rc2_config_rxgain` differ. `phy_hw_set_channel` stores the same inverse carrier and frequency ratio at `0x24C0084C` and `0x24C008EC`. Its `phy_init` writes `0x120` at `0x24C0C838`, where the pinned BL808 build writes `0x40`. |
| `libbl616cl_phyrf.a:phy.c.obj` | DWARF names `drivers/soc/bl616cl/phyrf/phy/phy.c` and generated headers under `reg/wlan11`. `phy_get_version` is byte-identical and reads `0x24C00000` and `0x24C0003C`. `phy_hw_set_channel` writes the same two frequency calculations at the same absolute addresses. Its gain bytes are `02 08 0F 16 1C 29 2F 34 34`. |
| `libbl618dg_phyrf.a:phy.c.obj` | DWARF names `drivers/soc/bl618dg/phyrf/phy/phy.c` and generated headers under `reg/wlan_p1`. The version reads use the same absolute addresses. `mdm_set_channel` writes the same two calculations at `+0x5E/+0x70` of the routine. This build adds separate 2.4 GHz and 5 GHz gain routines. |

All three channel paths therefore give `0x6CAE` and `0x8000` at 2412 MHz
HT20. These are compiled driver comparisons. The byte counts use raw ELF
section contents before relocation. Section hashes and sizes are in
`build/hw-validation-wifi-source/phy-translation-unit-comparison.tsv`.
A name-only match in Tuya's SDK, `components/bk_wifi/src/phy.c`, contains
two CLI wrappers that call `do_evm` and `do_rx_sensitivity`.
[BL616 archive][bl616-phy-archive] · [BL616CL archive][bl616cl-phy-archive] ·
[BL618DG archive][bl618dg-phy-archive] · [Tuya PHY wrappers][tuya-phy-wrappers]

The 18 public forks of the M1s SDK exposed 23 branch/tag refs. Seven
distinct tips added 100 commits outside the two previously checked SDK
lineages. The 192-commit combined history contains no tracked `phy.c`,
`phy_karst*.c`, `phy_custom_rf.c`, `phy_bl602.c`, or matching modem register
header. The earliest independent fork (`28e6cf28`) and the RT-Thread Wi-Fi
branch (`f6d69aaa`) were included. Web searches for `rc2_config_rxgain`,
`phy_config_rxgain`, and `NX_MDM_VER` with PHY routine names yielded no new
implementation.
[M1s fork list][m1s-forks] · [Early preserved fork][m1s-fork-early] ·
[RT-Thread Wi-Fi fork][m1s-fork-rtthread]

The fork sweep also enumerated 98 `bl_iot_sdk` forks, 175 `bouffalo_sdk`
forks, and two driver mirror forks. GitHub returned refs for 270 and
reported five repositories unavailable. Deduplicating against the upstream
histories left 66 `bl_iot_sdk` tips with 242 additional commits and 110
`bouffalo_sdk` tips with 598 additional commits. The only tracked `phy.c`
hits in those additional histories belonged to Apache NimBLE. The two
driver mirror forks added no tips. Checking all 83 advertised public pull
request heads across the SDK and M1s repositories added 58 more commits.
Those commits yielded no matching Wi-Fi implementation or modem header.
Ref and path inventories are in `build/hw-validation-wifi-source/`.
[IoT SDK forks][bl-iot-forks] · [MCU SDK forks][bl-sdk-forks] ·
[Driver mirror forks][bl-driver-forks]

### Downloadable PHY and Wi-Fi archives

The web search used the exact SDK-relative `phy.c` path, archive and object
names, companion filenames such as `agcmem.c`, `ldpcmem.c`, `phy_hal.c`, and
`phyrf_utils.c`, and register fingerprints. Searches included English and
Chinese archive terms. The RT-Thread port and the separate YoC component
packages are downloadable bundles with relevant compiled files.

| Package | Verified contents |
| --- | --- |
| [RT-Thread WLAN tarball][rtthread-wlan-tar] at `6e479190` | The 595-entry tarball contains `platform/soc/bl606p/bl606p_phyrf/lib/libbl606p_phyrf.a` and `network/wifi/lib/libwifi.a`. Their SHA-256 values match both M1s archives. The first includes `phy.o`, `agcmem.o`, `ldpcmem.o`, `phy_hal.o`, and `phyrf_utils.o`. The second includes `rxl_cntrl.o`. The tarball contains `phy.h`. It has no `phy.c`, `rxl_cntrl.c`, or `reg_mdm_cfg.h`. |
| [YoC BL606P PHY ZIP][yocop-phy-zip] at `v8.1.0` | The integrity-checked ZIP contains `bl606p_phyrf/libphyrf.a` and RF parameter headers. The nine public tags publish four distinct `libphyrf.a` blobs, introduced at `v2.1.0`, `v2.1.1`, `v7.6.0`, and `v7.7.0`. All four have a `phy.o` with source-level DWARF. The tagged trees carry no matching C or generated WLAN header. |
| [YoC BL606P firmware package][yocop-wifi] | `v8.1.0` publishes `bl606p_firmware/libfirmware.a`, containing `rxl_cntrl.o` and `rxl_hwdesc.o`. DWARF names `components/bl606p_firmware/bl606p_firmware/ip/lmac/src/rx/rxl/rxl_cntrl.c` under `bl606_open_back`. The package supplies `bl_phy_api.h`. Its nine reachable commits yield no matching PHY or lower-MAC C. |
| [PineVoice BL606P package][pinevoice-phy] at `305dd9a` | Two `libbl606p_phyrf.a` builds for toolchains V2.6.1 and V2.4. `phy.o` in both has no DWARF. The V2.6.1 `phy_get_version` reads `0x24C00000` and stores zero for the second output, like the older M1s build. The package supplies `rfparam.c` and an install manifest listing `bl606p_phyrf/phy/*` and `reg/bl808/wlan/*`. The 41 reachable commits contain neither the `phy.c` body nor a `reg_mdm_cfg.h` file. [Zephyr blob manifest][zephyr-phy-blobs] |
| [Arduino BL616CL dependency tarball][arduino-phy-bundle] at `v0.12.0` | The 1,401-entry tarball contains `phy.h` and `libbl616cl_phyrf.a`. All 15 common code and initialized-data sections in its stripped `phy.c.obj` match the earlier debug-bearing BL616CL comparison. The tarball has no `phy.c`, preprocessed PHY source, or generated modem config header. |

The older YoC builds add another exact source suffix to search,
`components/bl606p_phyrf/bl606p_phyrf/phy/phy.c`. The `v2.1.0` DWARF
places it under `yoc_open/int`. The later builds name the `bl606_open`
source tree. `libphyrf.a` in the `v8.1.0` ZIP matches `v7.7.0` exactly.
Its `phy.o` shares 110 generated WLAN accessor names with M1s `phy.o`,
including all 20 `reg_mdm_cfg.h` names in that object. Its `mdm_reset`
writes `0x1111` and then zero to `0x24C00888`, matching M1s. Its
`agc_config+0x408/+0x426/+0x444` writes `0x100` at the same three RC2
threshold offsets `+0xC838/+0xC83C/+0xC840` where M1s writes `0x40`.
[YoC PHY component][yocop-phy] · [YoC component manifest][yocop-manifest] ·
[M1s PHY/RF archive][m1s-rf-archive]

Software Heritage independently preserved 45 distinct snapshots across
the M1s and two vendor SDK origins. Four archived tips added 11 commits
outside the previously checked histories. The archived `bl808` tip
`ccc9f709` has the same PHY/RF library blob as `b773b3f4`, with the original
`components/platform/soc/bl606p/bl606p_phyrf/phy/phy.c` path in DWARF.
The archived tip publishes the library and interface headers. Inspection
of the additional history yielded no matching source or generated modem
header. The snapshot inventory is in
`build/hw-validation-wifi-source/phy-swh-snapshot-refs.tsv`.
[Archived branch snapshot][swh-iot-archive] · [Archived SDK revision][swh-iot-tip]

Ai-Thinker's public M6X SDK mirror at `d444b4c4` provides a separate
`librf.a:phy.c.obj` whose nine `rxgain` bytes and two version register
addresses match the pinned BL808 build. No matching implementation or
modem config header appears in its 551 reachable commits. The Zephyr HAL
at `18c998da` pins the PineVoice archives for BL808. Its 47 reachable
commits and the 98 commits of the older split vendor components repository
yielded no matching `phy.c`. The direct M1s SDK tarball download timed out.
Its Git tree and the download of the smaller RT-Thread bundle independently
identify the same compiled M1s libraries.
[Ai-Thinker SDK mirror][aipi-m6x-phy] · [Zephyr blob manifest][zephyr-phy-blobs] ·
[Split components repository][bl-iot-components]

### YoC dependency and release history

The documented LongYuan installation resolves component versions through
the YoC manifest. The published `yoctools` 2.0.40 implementation downloads
the selected Git revision. Its ZIP downloader is in an inactive branch.
For example, `sdk_chip_bl606p_e907` at `v7.5.2` selects `drv_wifi_bl606p`,
`bl606p_firmware`, and `bl606p_phyrf` at `v2.1.0`. The corresponding
`v8.1.0` SDK selects the three `v8.1.0` components. This traces the
installer to the component trees already available for direct inspection.
[LongYuan SDK][yocop-longyuan] · [YoC installer distribution][yocop-tools] ·
[E907 SDK dependency list][yocop-chip-sdk]

The early `drv_wifi_bl606p` tag `v2.1.0` also bundles its own `libs/libphyrf.a`.
It is distinct from the four archives in the standalone PHY component.
Its 12 objects include a debug-bearing `phy.o` built from
`ali_bl_606/components/bl606p_phyrf/bl606p_phyrf/phy/phy.c`. The object
reads `0x24C00000` for `phy_get_version`, returns zero for the second word,
and pulses `0x1111` at `0x24C00888`. Its `agc_config+0x36E/+0x38C/+0x3AA`
writes `0x40` to the same three RC2 reference fields as M1s. The bundled
archive disappears from the Wi-Fi driver tree in `v2.1.1`.
[Early YoC Wi-Fi driver archive][yocop-early-wifi-phy] ·
[M1s PHY/RF archive][m1s-rf-archive]

The consolidated XuanTie `open-yoc` release branches carry byte-identical
copies of the standalone component libraries. `v7.6.0` uses the
`v7.6.0` component blob. `v7.7.0` through `v8.0.0` use the unchanged
`v7.7.0` blob. The combined search covered 74 reachable commits across
seven other YoC SDK, chip, board, and Wi-Fi dependency repositories,
35 original `open-yoc` commits, and 9 more from six divergent fork tips.
Of 27 listed forks, 23 exposed refs. The checked histories yielded no
matching `phy.c` or generated WLAN header. Zephyr's public `bflb_rf.c`
wraps `rfc_init` and its CMake selects the PineVoice library for the real
implementation. A public Sourcegraph pass including archived and forked
repositories found this wrapper and the known SDK headers and archive.
[XuanTie release component][xuantie-yoc-phy] · [Open-YoC forks][xuantie-yoc-forks] ·
[Zephyr RF wrapper][zephyr-rf-wrapper]

The PineVoice V2.6.1 `phy.o` shares 24 of 29 raw code and data sections
with each of the three earlier standalone YoC builds, including
`phy_init`, `phy_config_rxgain`, and `mdm_reset`. Its `agc_config` differs
and writes `0x100` to the three reference fields, matching the values
in the later YoC build. The comparison is on ELF contents before
relocation. The dependency search and section hashes are in
`yoc-phy-dependency-search.tsv` and `pinevoice-yoc-phy-comparison.tsv`
under `build/hw-validation-wifi-source/`.
[PineVoice BL606P package][pinevoice-phy] · [YoC PHY component][yocop-phy]

### XuanTie offline SDK downloads

XuanTie's resource catalog lists four LongYuan offline SDK ZIPs. The
v2.1.1 entry is labeled `sdk_v2.1.1` and shows 171.71 MB. The catalog
also lists v2.1.0 (156.14 MB), v7.7.0 (522.23 MB), and v7.8.0
(599.53 MB). A board evaluation records extracting v2.1.1 and building
the Wi-Fi provisioning project under
`longyuan_v2.1.1/solutions/wifi_ble_provisioning_demo/`. The v2.1.1
download button opens XuanTie's sign-in dialog. The ZIP's PHY contents
remain unverified. Searches for the catalog ID, extracted directory,
offline package names, and Chinese mirror terms yielded no accessible
copy. The Wayback availability API returned no snapshot for the old
catalog URL.
[XuanTie offline SDK catalog][xrvm-longyuan-offline] ·
[Board evaluation][longyuan-board-evaluation]

The tagged Gitee SDK includes a separate 25 MB `.lakebook` archive.
Its tar inventory contains 39 JSON files. The document metadata
identifies the August 2022 v2.1.1 release and explicitly lists the
offline download alongside the Gitee installer. The tar inventory has
no SDK or firmware files.
[LongYuan v2.1.1 documentation archive][yocop-longyuan-lakebook]

The corresponding public Wi-Fi provisioning and Bluetooth audio demos
both select `sdk_chip_bl606p_e907` v7.6.1. Its manifest selects the
v2.1.1 PHY, Wi-Fi firmware, and driver packages already inspected.
The two demo histories contain 18 commits in total and no matching
PHY sources, modem headers, libraries, or SDK archives.
[Wi-Fi provisioning manifest][yocop-longyuan-wifi-demo] ·
[Bluetooth audio manifest][yocop-longyuan-bt-demo] ·
[E907 v7.6.1 dependencies][yocop-chip-sdk-v761]

### CDK board and example packages

XuanTie's publishing guide documents a separate CDK route that can
serve component ZIPs from OCC. The official board quick-start walks
through the CDK example installer and the Gitee-based YoC installer.
The live BL606P-DVK resource table lists five hardware documents. The
chip table lists two manuals. The LongYuan application page links to the
same four offline SDK ZIPs listed above.
[CDK component publishing guide][yoc-cdk-publishing] ·
[Official board quick-start][xrvm-bl606p-quickstart] ·
[Board resources][xrvm-bl606p-board] · [Chip resources][xrvm-bl606p-chip] ·
[LongYuan application page][xrvm-longyuan-platform]

The CDK board evaluation identifies the exact downloaded component
`__workspace_pack__/bl606p_evb_e907/v7.6.2/`. Its corresponding
55-entry public Gitee ZIP passed the archive integrity check. The archive
includes board support C, an embedded C906 payload, and two debug-bearing
RV32 executables, `boot.elf` and `bootmini.elf`. The two ELF blob IDs
match the same files in the consolidated `open-yoc` tree. The ZIP lacks
`phy.c`, `reg_mdm_cfg.h`, and a PHY or Wi-Fi library. The ELFs contain
clock support symbols such as `Clock_Get_WIFI_PLL_Output`. Their symbols,
source strings, and disassembly yielded no target driver routines or
references to the modem base or nearby register pages. Three later
`boot.elf` builds in the consolidated releases gave the same result.
The raw payload in `include/c906_fw.h` includes the string
`helloworld c906` and yielded no immediate references to the modem.
[Board evaluation][longyuan-board-evaluation] · [Exact board ZIP][yocop-cdk-board-zip]

The official smart-speaker walkthrough installs `sdk_longyuan` and
builds `smart_speaker_v2` with `package_bl606p_mind.yaml`. The v2.1.1
manifest again resolves to the public E907 SDK v7.6.1. The two 2022
smart-speaker ELF files, `c906fdv_fw_mind.elf` and
`c906fdv_fw_mind_xiaoyou.elf`, and two later builds in `open-yoc` are
RV64 speech and IPC images with DWARF. Across those four images the
search found no target PHY translation units, functions, or immediate
references to the modem. The same comparison detects the driver
symbols and modem addresses in the pinned BL808 `phy.c.o`. The hashes
and checks for all nine ELFs and the BL808 object are in
`build/hw-validation-wifi-source/cdk-board-speaker-image-check.tsv`.
[Official speaker walkthrough][xrvm-bl606p-speaker] ·
[Speaker manifest][yocop-cdk-speaker-manifest] ·
[Early speaker binaries][yocop-cdk-speaker-binaries] ·
[Consolidated speaker firmware][xuantie-cdk-speaker-elf]

The related F133-A voice-panel listing offers a separate 33 MB source
download. Its button opens the XuanTie sign-in dialog. The contents and
any relationship to the target modem remain unverified.
[F133-A solution resources][xrvm-f133-panel]

### Repackaged SDK histories

Ten repackaged GitHub SDK and firmware projects covered 996 distinct
commits. Their branches and tags yielded no matching PHY C, generated
modem headers, or offline SDK archive. None published release assets.
The PineVoice repack includes both known BL606P PHY libraries with
identical Git blob IDs. The file and blob inventory is in
`build/hw-validation-wifi-source/wifi_phy_repacked_history.tsv`.
[PineVoice repack][pinevoice-repack-phy]

One repack preserves a distinct July 2024 BL616 PHY/RF library
(Git blob `dda05328`). Its `phy.o` has no DWARF and shares 32 of 36
raw code and initialized-data sections with the previously checked
BL616 archive. It reads both version words at the same addresses as
the pinned BL808 build and has the same nine `rxgain` bytes. Its channel
routine performs both matching frequency calculations and writes the
fields at `0x24C0084C` and `0x24C008EC`. Reset goes through
`crm_mdm_reset`, pulsing `0x11` at `0x24940018`, compared with M1s
pulsing `0x1111` at `0x24C00888`.
[Early BL616 PHY/RF archive][bl616-early-repack] ·
[BL616 driver archive][bl616-phy-archive] ·
[M1s PHY/RF archive][m1s-rf-archive]

Another filename hit, `phy_custom_rf.c`, came from a report on the
ZT9612 USB Wi-Fi adapter. The tracked history and release metadata
provide neither that file nor the vendor firmware that names it.
[ZT9612 firmware distribution note][zt9612-fw-note]

### Exact BL808 header paths recovered from DWARF

The M1s and Bouffalo BL606P PHY/RF objects declare inlined accessors under
`components/platform/soc/bl606p/bl606p_phyrf/reg/bl808/wlan/`. The observed
headers are `reg_mdm_cfg.h`, `reg_mdm_stat.h`, `reg_mdmdsss_cfg.h`,
`reg_macbypass.h`, `reg_mac_core.h`, `reg_bl_rc2.h`, `reg_rc.h`, and
`reg_riu.h`. The full member lists were checked. The 14-member M1s and
April 2023 Bouffalo archives each preserve 152 distinct declarations
across the eight headers. The 13-member August 2023 Linux demo archive
preserves 115 declarations across seven headers. The additional `reg_mac_core.h`
declaration comes from `phyrf_utils.o` and names the low word of MAC
monotonic counter 2. Of the 23 modem configuration accessors in the two
larger archives, 15 appear by the same name in the QCC743 header. The three
DWARF inventories yielded no declarations named for CSI readout or
channel-estimate memory. The full generated headers remain missing from
the searched SDKs. [Sipeed PHY/RF archive][m1s-rf-archive] ·
[April PHY/RF package][bl-early-rf] · [August PHY/RF archive][bl-linux-rf] ·
[QCC743 WLAN register source][qcc-config]

One concrete result is `SWRESET` at BL808 modem `+0x888`. The M1s
`phy.o:mdm_reset` calls the inlined `mdm_swreset_set` to write `0x1111`,
then zero. The `cli.o:cmd_rx_start_at` instructions and their inlined
accessor names independently identify modem reset at bit 0, DSP reset
at bit 8, and AGC reset at bit 12. The bit names match the older Beken
header, whose `SWRESET` offset is `+0x894`. The M1s RX diagnostic pulses
those reset bits, then configures MAC bypass. The sequence provides
evidence of a separately resettable signal-processing block. Its
instruction memory and software interface remain unsubstantiated.
[M1s PHY/RF archive][m1s-rf-archive] ·
[Older Beken register header][bk-old-mdm]

### Search fingerprints from the modem initialization

The function offsets below are from `phy.o:phy_init` in the pinned M1s
PHY/RF archive. The inlined DWARF names identify fields and the RV32
instructions establish the offsets, masks, and values.

| Modem offset | BL808 archive evidence | Public register comparison |
| --- | --- | --- |
| `+0x818` | `mdm_cfgsmoothforce_setf` clears bit 18 at `phy_init+0x92`. `mdm_smoothctrl_set` writes `0x01880C06` at `+0x200`. | QCC743 `SMOOTHCTRL` has the same offset and reset word. The older Beken header defines `CFGSMOOTHFORCE` at bit 18. |
| `+0x830` | `mdm_smoothsnrthrhigh_setf` and `mdm_smoothsnrthrmid_setf` write `0x1B` to bits 15:8 and `0x0F` to bits 7:0 at `phy_init+0xA4/+0xBA`. | QCC743 `SMOOTHSNRTHR` has the same offset, field widths and reset values (`0x00001B0F`). |
| `+0x874` | `mdm_rcclkforce_setf` sets bit 27 at `phy_init+0xDA`. `mdm_agcmemclkforce_setf` sets and clears bit 29 at `+0x162/+0x194` around the AGC table copy to `0x24C0A000`. | The older Beken header has `AGCMEMCLKFORCE` at bit 29 of its `+0x87C` register. The BL616 header exposes `mdm_rcclkforce_setf` through a clock-control alias. |

[M1s PHY/RF archive][m1s-rf-archive] · [QCC743 generated header][qcc-config] ·
[Older Beken register header][bk-old-mdm] · [BL616 clock header][bl616-crm]

### Related public implementations

| Lead | Result |
| --- | --- |
| [QCC743 generated register source][qcc-config] | Defines `CSIRDCTL` and `CSIRDSTAT` and matches multiple BL808 accesses. The CSI definitions are gated by `RW_NX_CSI`. BL808 per-packet behavior requires independent confirmation. |
| [ListenAI ARCS-Mini SDK][listen-sdk] | Tracked modem and clock headers and C for the RF layer. Its `phy_custom_rf.o` independently reproduces BL808's channel-divider and frequency-ratio calculations. The compiled LMAC also exposes the RivieraWaves `rxl_cntrl.c` path. |
| [ESWIN ECR6600 SDK Wi-Fi archive][eswin-wifi] | The Andes NDS32 `phy_custom_rf.o` also implements the BL808 inverse-carrier calculation and the two-word modem version read. DWARF names the PHY C and generated header. The inspected trees provide the object code. |
| [Beken BK7236 archive][bk-lib], [Tuya T3][tuya-t3-csi], [Tuya T5AI][tuya-t5-csi], and [Samsung TizenRT BK7239N][tizen-bk-wifi] | All supply compiled Karst-family objects. T3's `phy_karst_bk7236.c.obj` reads coefficients at `0x49809000`. T5AI and TizenRT contain a separate CSI object whose debug source suffix is `ip_ax/macsw/ip/lmac/src/csi/csi.c`. Emulating T5AI's copy routine confirmed the same first read address and 48 or 52 exported words for formats 0 or 2. The inspected trees yielded object code for these paths. |
| [SiFlower SFAX8 PHY code][sfax8-phy] and [SF19A2890 Linux driver][sfwifi-mdm] | The SFAX8 Aetnensis source reproduces eight programmed values from the M1s BL808 PHY. Its generated `reg_mdm_cfg.h` contains all 23 modem configuration accessors named in the M1s DWARF. The SF19A2890 LMAC directory carries the build configuration. |
| [AIC8800 embedded SDK][aic-embedded] and [Linux source][aic-rwnx] | The embedded SDK carries a generated RIU header with all 55 M1s RIU accessor names, plus a CSI callback example backed by a supplied LMAC image. The Linux code names Karst and provides host ABI context. [AIC license announcement][ceva-aic] |
| [GigaDevice GD32VW55x SDK][gd32-sdk] | Its Wi-Fi archive contains `rxl_cntrl.o` with the `rxl_cntrl_evt` entry point and the original `rxl_cntrl.c` path in strings. `hal_phy.o:phy_get_version` returns the constants `0x50A24111` and `0x01020000`. The first word would select RF mode 2 under the QCC layout. The 31 reachable SDK commits ship object code for the lower MAC and PHY, with no tracked matching PHY C or modem header. |

A device-independent pass searched for `RivieraWaves Sense`, `phy_karst.c`,
`reg_mdm_cfg.h`, `reg_mdm_stat.h`, `rxl_cntrl.c`, `CSIRDCTL`, `CSIRDSTAT`,
`mdm_cfgsmoothforce_setf`, `mdm_rcclkforce_setf`, `0x01880C06`, and
`0x00001B0F`, without device or chip-vendor names in the queries. The exact
`reg_mdm_stat.h` lookup led to AIC's host driver, which quotes the modem
feature fields. The clock-accessor search found two SDK clock headers.
The broader RivieraWaves SDK search led to the independently packaged
GD32 lower MAC and PHY. The searches missed the verified QCC header.
The original BL808 Karst implementation and exact channel-estimate map
remain open. The indexed queries, declaration inventory, and T5AI emulation
log are under `build/hw-validation-wifi-source/`. Exact searches for
`phy_custom_rf.c` found a report that names the file in ZT9612 firmware
metadata. That repository publishes a Linux host driver. The same PHY
filename appears independently in ListenAI's archive DWARF.
[AIC Linux patch][aic] · [BL616 clock header][bl616-crm] · [GD32 SDK][gd32-sdk]
· [ZT9612 report][zt-phy-name]

### Additional filename and accessor indexes

Web queries used `mdm_txctrl3_pack`,
`mdm_tbe_count_adjust_20_setf`, `mdm_rxtdctrl1_set`, the RC2 and RIU
accessors, the `agcmem.c` and `ldpcmem.c` companion files, and the
programmed words `0x01880C06` and `0x02D00438`. They produced no new
matching implementation. GitHub's commit-message search returned zero
for `reg_mdm_cfg.h`, `reg_bl_rc2.h`, `phy_custom_rf.c`, and
`phy_karst.c`. Four subsequent searches returned HTTP 403. Sourcegraph's
six new global queries returned zero with shard limits reported. Its
Linux control query succeeded. The grep.app requests returned HTTP 429.
These reports limit what each index can establish about public source.
[GitHub commit query scope][github-commit-search-scope]

Common Crawl's URL index returned no captures for the LongYuan
catalog URL in December 2023 or for the board URL in April 2024.
Other samples of the legacy and migrated URLs timed out or returned
HTTP 503. These observations establish no archive contents.
[Common Crawl URL index][common-crawl-index]

### Winner Micro WLAN SDK archives

Ceva's January 2022 announcement identifies a RivieraWaves Wi-Fi 6
license for a future Winner Micro generation. The public W80x and W600
SDK archives expose an older PHY interface, `tls_wl_bbp_init` in
`tls_wl_phy.c`. The official W80x `libmacsw.a` has DWARF for that
translation unit, including the baseband base `0x40001000` and
MAC base `0x40001400`. The C-SKY W80x repack's DWARF names
`V1.00.04/src/wlan/driver/tls_wl_phy.c`. It has all 20 initialization
words byte for byte with the official W80x archive. Two OpenHarmony
archive revisions contain the same table. The later OpenHarmony
`tls_wl_phy.o` also matches the repack's object byte for byte.
[Ceva license announcement][ceva-winner-license] ·
[W80x official SDK][winner-sdk-phy] · [W80x repacked archive][winner-repack-phy]

The ARM W600 SDK v3.2.0 and v3.4.0 libraries have identical 20-word
tables, sharing 14 words in the same positions as W80x. Disassembly
of v3.4.0 shows stores to `0x40000A00` through `0x40000A4C`.
The W80x and W600 tables begin with `0x50400800` and `0x58405000`,
respectively. Neither contains the BL808 initialization fingerprints
`0x01880C06`, `0x00001B0F`, or `0x02D00438`. BL808's modem
configuration reads `0x24C00000`. Its initialization uses
`+0x818`, `+0x830`, and `+0x898` for those values. The word
comparison is in
`build/hw-validation-wifi-source/winner-phy-init-table.tsv`.
[W600 v3.2.0 archive][winner-w600-320] · [W600 v3.4.0 archive][winner-w600-340]

Across 9 reachable commits in the official W80x SDK, 5 in the
W80x repack, 39 in the W600 SDK, and 151 in the OpenHarmony W800
port, the checked histories publish library objects and interface
code. They yielded no tracked `tls_wl_phy.c` or RivieraWaves modem
configuration header. The historical W600 `tools/library.zip`
contains five Python bytecode files for the gzip tool.
[OpenHarmony W800 port][openharmony-w800-phy] · [W600 tools archive][winner-w600-tools-zip]

### ListenAI ARCS driver code and archive

The official ARCS-Mini repository at `76ce8f9b` and the mirror at `66568d04`
share the same `wifi_mdmcfg_reg.h`, `wifi_crm_reg.h`, and `ilp32/libplf.a`
Git blobs. The SDK builds the RF layer from sources such as `rf_drv.c`
and links the PHY software as `libplf.a`. `phy_custom_rf.o` calls the
tracked `rf_drv.c:ls_rf_set_channel`, which dispatches to the RF backend.
DWARF identifies the PHY source as
`wifi/macsw/plf/refip/src/driver/phy/phy_custom_rf.c` and its generated
header as `build/reg/virtex7/riscv32/custom_rf/reg_mdm_cfg.h` relative to
`plf/refip/src`. `liblmacdp.a:rxl_cntrl.o` names
`wifi/macsw/ip/lmac/src/rx/rxl/rxl_cntrl.c`. These archived translation
units and the internal generated header remain absent from the 55
reachable official commits and 244 mirror commits examined.
[ListenAI SDK instructions][listen-docs] · [Wi-Fi link recipe][listen-wifi-build] ·
[RF channel wrapper][listen-rf] · [PHY archive][listen-plf]

`phy_custom_rf.o:phy_get_version+0x0C/+0x14` reads ARCS modem base
`0x4B800000` and `+0x3C`. The SDK's generated header defines the CSI pair
at `+0x064` and `+0x8F8`, with all six field masks equal to QCC743's.
The 14 inspected Wi-Fi platform, module and MAC archives across the two
ABIs yielded no CSI-specific symbols or statically identifiable accesses
to `0x4B800064` or `0x4B8008F8`. The scan recovered the version read and
normal modem configuration as positive controls. The log is
`build/hw-validation-wifi-source/listenai-modem-mmio.txt`.
[ARCS modem header][listen-mdm] · [ARCS modem base][listen-base]

### Published SiFlower and Beken driver C

SiFlower publishes the Aetnensis PHY C and generated headers in the
SFAX8 factory test tree. The modem configuration and status wrappers both
locate their block at Wi-Fi base `+0x00100000`. For register comparisons,
use the offsets in the `MDM_*_ADDR` expressions. The configuration header's
`MDM_*_OFFSET` macros are relative to its configuration sub-block, which
starts at modem `+0x800`.
[SFAX8 factory tree][sfax8] · [SFAX8 PHY C][sfax8-phy] · [Generated header][sfax8-mdm]

The M1s `phy.o:phy_init` instructions and the SFAX8 C agree on the
following values. The first six rows come from the SFAX8 20 MHz branch of
`phy_hw_set_channel`. The last two come from `phy_hw_init`. A host-side
check compiled the published accessors and the actual calls against a
mock register array and verified all eight offsets and values.

| Register and offset | Programmed value | M1s store offset in `phy_init` |
| --- | --- | --- |
| `TXCTRL0 +0x838` | `0x000000B4` | `+0x1AA` |
| `TXCTRL1 +0x88C` | `0x00001C13` | `+0x1B4` |
| `TBECTRL0 +0x858` | Low byte `0x00` | `+0x1D2` |
| `TXCTRL3 +0x898` | `0x02D00438` | `+0x1C0` |
| `DCESTIMCTRL +0x81C` | `0x00000F0F` | `+0x1DC` |
| `RXTDCTRL1 +0x834` | Bits 31:24 set to `0x06` | `+0x1F4` |
| `SMOOTHCTRL +0x818` | Clears bit 18 | `+0x92` |
| `CLKGATEFCTRL0 +0x874` | Sets bit 27 | `+0xDA` |

The SFAX8 headers declare 113 of the 152 named M1s accessors, including
all 23 for modem configuration and all 55 for RIU. Its
`mdm_dcestimctrl_pack` has the same five parameter names and order as the
M1s DWARF, including `delaysynctd20`. QCC743's version has four
parameters. The SFAX8 code pulses only bit 0 at `SWRESET +0x888` and its
status header declares `NXVERSION=0x0EC32111` at reset. The M1s object
pulses `0x1111` at that offset and the archived BL808 board word is
`0x0C822111`. These are concrete differences between the integrations.
[M1s PHY/RF archive][m1s-rf-archive] · [SFAX8 PHY C][sfax8-phy] ·
[SFAX8 modem config][sfax8-mdm] · [SFAX8 modem status][sfax8-stat]

SFAX8 and both BL808 PHY archive generations load 512 AGC words at modem
`+0xA000`. The three table byte sequences have distinct SHA-256 digests.
The older Beken Trident C supplies four distinct 512-word AGC tables across
its chip and build branches. Its `phy_get_version` reads the first modem
word and puts zero in the second output, matching the older M1s reporting
convention. Its channel setup writes the RF channel field from
`center1_freq - 2400`. The comparison, including the table digests, is in
`build/hw-validation-wifi-source/driver-c-source-comparison.tsv`.
[SFAX8 AGC loader][sfax8-agc-loader] · [Older Beken Trident code][bk-trident]

The OpenCam RT-Thread SDK contributes three Trident
AGC arrays selected by the host `phy_trident.c`.
The BK7252 camera port's AGC table matches the BK7231
array byte for byte. The other two SDK profiles can
branch to a header with a zero branch count at the
point where BK7231 has one outgoing branch. The
comparison gives a concrete way to test how an
external event resumes an otherwise parked state.
[Related Trident tables](bl808_agc_microcode.md#addressed-states-with-no-stored-branches)

### ESWIN and AIC embedded SDKs

Ceva identifies ECR6600 as a licensee implementation of its 1×1 Wi-Fi 6
IP. The public ECR6600 SDK snapshot at `b8c9f789` and the OpenECR6600
port at `9ce4dd3c` contain the same `libs/libps_wifi.a` Git blob.
GNU Binutils 2.40, configured for `nds32le-elf`, resolves its NDS32
instructions and DWARF relocations. The compilation-unit paths are
`PS/wifi/ecr6600/plf/refip/driver/phy/phy_custom_rf.c` and
`PS/wifi/ecr6600/ip/lmac/src/rx/rxl/rxl_cntrl.c`. The PHY debug line table
also identifies `ecr6600/plf/refip/compiler/custom_rf/reg_mdm_cfg.h`.
The history of the two inspected SDK trees carries the archive. The
source units and internal generated header remain unlocated.
[Ceva license announcement][ceva-eswin] · [ESWIN archive][eswin-wifi] ·
[OpenECR6600 archive][eswin-open-wifi]

In `phy_custom_rf.o`, `phy_get_version+0x14/+0x26` calls
`hal_reg_pl_rd` on `0x00700000` and `0x0070003C`. In
`mdm_set_channel`, `+0x1A2/+0x1A6` divides `0x04000000` by the
center frequency, and `+0x20A..+0x212` replaces bits 14:0 of
`0x0070084C`. It therefore computes `0x6CAE` on channel 1 at 2412 MHz,
matching the selected BL808 archive. The ESWIN path also includes
power-save clock restoration and additional channel logic. No
`+0x8EC` ratio store was identified in this ESWIN routine.
[ESWIN archive][eswin-wifi] · [BL808 PHY archive][bl-pinned-rf]

The ESWIN archive's `hal_rf_6600.o` also supplies a
479-word AGC program with the classic RIU branch layout.
Two SDK versions patch that program for the revision
selected by `efuse_ft[26]`. The patches isolate several
state-header bits and the low byte of selector `22`.
Both loaders copy words `000` through `1DE`.
[ESWIN AGC loaders and revision comparisons](bl808_agc_microcode.md#eswin-revision-dependent-agc-images)

The AIC8800 embedded Gitee SDK at `06164fca` and the VSF port at
`cec53600` share a `reg_riu.h` blob. It declares all 55 named M1s RIU
accessors. Its `RWNXAGCCNTL` is at `0x4033B390`, the same modem-relative
`+0xB390` that M1s uses at `0x24C0B390`. The AIC
`AGCFSMRESET` mask is `0x00001000`, matching the M1s set/clear around
the AGC copy at `phy_init+0x148/+0x1A2`. The SDK histories supply
the RIU header and the tested host-side archives. They yielded no
tracked matching PHY C or `reg_mdm_cfg.h`.
[AIC embedded SDK][aic-embedded] · [AIC RIU header][aic-riu] ·
[M1s PHY/RF archive][m1s-rf-archive]

The same AIC SDK publishes `fhost_wifi_csi.c` and prebuilt TX/RX LMAC
images. The C receives an LLTF report containing a timestamp and four
arrays of 51 signed 16-bit values for primary and secondary I/Q.
`libwifi_sta.a:fhost_rx.o:fhost_rx_csi_cb` reads a length at record
`+0x14` and dispatches the payload at `+0x50`. The RX image writes the
report magic `0x41435349` at file offset `0x18680`. Separately, its
`0xDE0..0xDF8` routine copies `0x53C` bytes from RAM `0x00190DB0`
into modem `+0x9000`. That particular access is a write into the
modem window. The AIC coefficient acquisition sequence and the identity
of the copied table remain unverified.
[AIC CSI callback C][aic-csi-c] · [AIC RX image and build inputs][aic-csi-target]

The RX and TX LMAC binaries also embed an identical 2 KiB AGC program.
The RX loader copies it from RAM `0x001905B0` to modem AGC memory at
`0x4033A000` and sets `AGCRAM_READY`. The array shares branch encodings
and entry sequences with BL808 and SF19A28. Its final word is zero.
[AIC AGC extraction and comparisons](bl808_agc_microcode.md#aic8800-images-recovered-from-firmware-loaders)

### Published RC2 register accessors

Sipeed's historical SDK tracks `bl602_phy_rf/reg/reg_bl_rc2.h`, with 134
inline C accessors at the BL602 base `0x44C00000`. PINE64's copy has the same
accessor code and adds a copyright preamble. The header shares 30 of the 37
names declared in the BL808 `reg/bl808/wlan/reg_bl_rc2.h` DWARF. Comparing
the C with `phy.o` and `cli.o` in the M1s archive confirmed all 30 relative
offsets and 28 masks. The M1s instructions use base `0x24C00000`.
[Historical SDK header][m1s-bl602-rc2] · [PINE64 header][bl602-rc2] ·
[M1s PHY/RF archive][m1s-rf-archive]

| Modem offset | Mask in the published C and M1s instructions | Value written by the BL808 archives |
| --- | --- | --- |
| `+0xC040`, `+0xC044` | VGA max/min `0x01F00000` and `0x000F8000`. LNA max/min `0x0000FF00` and `0x000000FF`. | M1s `agc_config+0x368..+0x38A` sets VGA max/min to 12 and 3, and LNA max/min to 8 and 0. |
| `+0xC080`, `+0xC084`, `+0xC088` | Nine byte fields for LNA gain entries 0 through 8. | At zero gain offset, M1s computes `0x1D160F08`, `0x36302A23`, and low byte `0x3C`. The pinned archive computes `0x201A130E`, `0x39322D26`, and low byte `0x3F`. Both preserve the upper three bytes at `+0xC088`. |
| `+0xC80C` | DSSS digital gain `0xFF000000`. | M1s `phy_init+0x104` writes field value `0x97`. Pinned `phy_init+0x42A` writes `0xA8`. |
| `+0xC830` | Event 4 operands and combiner `0xFC000000`, `0x03F00000`, `0x000FC000`, and `0x00001C00`. | Both archives program field values 63, 1, 54, and 5. |
| `+0xC838`, `+0xC83C`, `+0xC840` | Bit 31 enable at all three. OFDM, DSSS, and continued DSSS threshold masks `0x0007FFFF`, `0x000FFFFF`, and `0x003FFFFF`. | Both archives set the three enable bits. M1s programs thresholds `0x40`, `0x40`, and `0x40` at `agc_config+0x3EC/+0x40C/+0x42C`. The pinned archive programs `0x40`, `0x40`, and `0x36` at `phy_init+0x82C/+0x84E/+0x870`. |

The two mask differences are the getter and setter for `TXHBF20COEFFSEL`
at `+0xC218`. The BL602 C limits the field to `0x0000FFFF`. The M1s
`cli.o:tx_start` uses the full word when it reads the register at `+0x22`
and writes the replacement at `+0x45E`. Three accessors for the LNA index,
LNA gain, and maximum gain are absent from the published header. M1s DWARF
and stores place them at `+0xC850` (masks `0xFF000000` and `0x00FF0000`)
and `+0xC85C` (mask `0x00FF0000`). The four other missing names are the
full-width PHY and RIU diagnostic outputs at `+0xC918`, `+0xC91C`,
`+0xC920`, and `+0xC924`, read by `cli.o:cmd_diag_read`. The diagnostic
words have no verified CSI interpretation.
[Historical SDK header][m1s-bl602-rc2] · [M1s PHY/RF archive][m1s-rf-archive] ·
[Pinned PHY/RF archive][bl-pinned-rf]

The public C supplies register accessors. The tuning values above came from
the compiled BL808 routines, including the gain-table calculation at zero
offset. The comparison exercised the archived AGC and gain instructions
with four synthetic input words and checked the remaining accesses directly
in disassembly. The per-accessor evidence is in
`build/hw-validation-wifi-source/rc2-source-comparison.tsv`. The apparent
`phy_bl602.c` match in PINE64 is a reconstruction from DWARF with trap stubs
for `agc_config` and `phy_config_rxgain`. Exact symbol and numeric-mask web
queries without device or vendor names yielded no additional source.
[PINE64 reconstruction commit][bl602-dwarf-recovery] ·
[PINE64 PHY stubs][bl602-phy-stubs]

### Vendor download catalog and publications

- Bouffalo's public catalog returned no BL808 rows in the Document or
  Firmware listings. The Tool listing likewise returned no rows under
  the BL808 SDK and RF Testing Tool filters. The BL606P document results
  were manufacturing and DevCube tool guides. PINE64's BL808 MCU SDK
  link redirects to the current Bouffalo Git repository. An independently
  retained SDK fork at `63794163` had 469 reachable commits and no
  matching BL808 WLAN header or Karst implementation paths. The
  independent RT-Thread WLAN port at `6e479190` carries byte-identical
  copies of both Sipeed archives, with the common PHY/RF declarations.
  [Bouffalo Document catalog][bl-dev-docs] · [Firmware catalog][bl-dev-firmware] ·
  [Tool catalog][bl-dev-tools] · [PINE64 downloads][pine-ox64] ·
  [January 2023 SDK fork][arm000-mcu] · [RT-Thread WLAN port][rtthread-wlan-port]
- The Sipeed M1s and M1s Dock download catalog contains 51 files across
  31 subdirectories. Its chip material includes the public BL808
  data sheets and revision 1.0 reference manuals. The catalog lists
  factory and demo binaries and the November 2022 Linux image bundle.
  That bundle contains M0 and D0 low-load images, a combined Linux image
  and flashing instructions. Its 37,968-byte M0 image yielded no WLAN
  version strings or candidate MMIO accesses. The listing contains no
  BL808 modem source package. The full file
  inventory is `build/hw-validation-wifi-source/sipeed-m1s-downloads.tsv`.
  [Sipeed M1s download catalog][m1s-downloads] · [November Linux bundle][m1s-linux-zip]
- Bouffalo's published sensing patent application CN113156220A discusses
  beamforming and wireless channel measurement. CN116150584A from its
  Shanghai organization describes processing per-subcarrier CSI amplitudes
  across consecutive packets. The chip and register sequence remain
  unspecified. Bouffalo's separate UVM
  patent describes register tables with offsets, field widths and access
  modes as inputs to verification models. Its example is an I²C block.
  [Radio-wave sensing][bl-patent-sensing] · [CSI amplitude processing][bl-patent-csi] ·
  [UVM register generation][bl-patent-reg]

The precise vendor request is the matching BL808 `phy.c` and PHY/RF
driver package, its `reg/bl808/wlan` generated headers, and any associated
CSI readout or lower-MAC RX source and programming guide. Identify the
target with the archived `HDMCONFIG=0x0C822111`, modem base `0x24C00000`,
and the `librf.a` revision `a05d70b0` or the historical BL606P PHY/RF
package at `b773b3f4`. [Bouffalo Lab technical support][bl-support] ·
[Ceva licensing contact][ceva-contact]

## BL808 and M1s Evidence

### Artifacts and symbols

| Artifact | Provenance | SHA-256 |
| --- | --- | --- |
| `src/bl808/libwifi_fw.a`, `tools/ref/libwifi_bl808.a` | [Bouffalo `bl_iot_sdk` BL808 archive][bl-pinned-wifi] | `6458808ea976de70c0d9f218645efe61ba6e56c9d33fca697abb36a41efe91e7` |
| `src/bl808/librf_bl808.a` | [Bouffalo RF reference bytes][bl-pinned-rf] and [local vendor archive provenance](bl808_vendor_blobs.md#ble) | `5808ffe3bfdcf8c7f1b0f46b2e287fa6d99130c7a1a385ccb8ab7fb538b9d864` |
| M1s `components/network/wifi/lib/libwifi.a` | [Sipeed M1s SDK at `bf7e689`](https://github.com/sipeed/M1s_BL808_SDK/blob/bf7e689cf49d57dd529e2492e5264ef602ed5b3c/components/network/wifi/lib/libwifi.a) | `90c1f966e3789c9946c13a766108c2ba4afa4e96e12771cdaec1ba3f6a245d1d` |
| M1s `components/platform/soc/bl606p/bl606p_phyrf/lib/libbl606p_phyrf.a` | [Separate M1s PHY/RF archive at `bf7e689`](https://github.com/sipeed/M1s_BL808_SDK/blob/bf7e689cf49d57dd529e2492e5264ef602ed5b3c/components/platform/soc/bl606p/bl606p_phyrf/lib/libbl606p_phyrf.a) | `7fd993e1a3ca5d316eb474b27cf6d67280cd187230abbc972216dcc0cfa9bc8d` |

The M1s SDK was available locally under `build/vendor-cache/M1s_BL808_SDK` at
`bf7e689cf49d57dd529e2492e5264ef602ed5b3c`. The read-only diff of defined
external symbol names found exactly six M1s Wi-Fi names missing from the pinned
BL808 Wi-Fi archive: `bl_sleep_check`, `chan_scan_terminate`,
`mac_payload_offset`, `sta_table_add_entry`, `sta_table_get_sta_info`, and
`wifi_ps_operations`. None is a CSI API. Matching symbol names across builds do
not imply matching implementations.

The separate M1s PHY/RF archive adds the interesting symbols: `cmd_sram_rx`,
`cmd_sram_rx_addr`, `ldpc_config`, `ldpcmem`, `agc_config`, `mdm_reset`,
`phy_cli_register`, `phy_macbyp_rx_print_status_at`, `rf_pri_rxiq`,
`cmd_rc_adc_dc_meas`, and `cmd_rc_adc_pwr_meas`. These are absent as defined
externals from our selected RF archive. Some are calibration or diagnostic
entry points, not paths to per-packet channel estimates. BSP filenames such as
`bl808_csi.h` and `csi_reg.h` in camera paths refer to the camera serial interface;
T-Head `csi_core.h` and `csi_dsp` are also unrelated to Wi-Fi CSI.

### Extended archive and firmware audit

- The `bl_iot_sdk` checkout at `edcf613f` contains the historical `bl808`
  branch and 127 commits across its local refs. The history of the two
  `libwifi.a` paths and the BL606P PHY/RF archive yielded 16 distinct Git blobs
  at the recorded change commits. This includes the Linux demo's separate
  `components/network/bl808_wifi/lib/libwifi.a` and the pinned archive, which
  also matches the `bl808` branch tip byte for byte. The other Wi-Fi archives
  include builds for related hardware.
  [Bouffalo history][bl-iot] · [Linux demo Wi-Fi archive][bl-linux-wifi]
- Symbol inspection and a constant-effective-address pass over executable
  RV32 code found no identifiable use of `0x24C00064`, `0x24C008F8`, or the
  QCC CSI DMA range `0x24C70000`–`0x24C700FF` in those 16 blobs, the M1s
  pair, or the selected BL808 RF and BLE-controller archives. The scan
  follows register constants through common immediate arithmetic into load
  and store operands. It recovered the BL808 version access, M1s LDPC
  address construction, and the known QCC ISR access to `0x24C70004` as
  positive controls. Indirect pointers, ROM callees, branch-dependent
  register values, and hardware-internal movements remain outside this
  check.
- Bouffalo's Linux Wi-Fi package documents the protocol stack executing on
  the E907 M0 and exposing virtual Ethernet to Linux via shared memory and
  IPC. The M1s Linux SDK and OpenBouffalo lowload sources describe the
  M0/D0 host images. These names account for the common BL808 “Wi-Fi firmware”
  and “lowload” search hits. The searched PHY init paths establish table
  uploads and modem reset/configuration. A separate modem CPU image,
  execute address, and download protocol remain unsubstantiated.
  [Bouffalo XRAM driver][bl-xram] · [M1s Linux SDK][m1s-linux] ·
  [M0 lowload source][bl-lowload] · [BL808 reference manual][bl-rm]
- The public BL808C 1.0.8.8 BootROM dump and the SDK's E907 ROM API
  definitions supplied no evidence of a CSI entry point, an access to the
  candidate CSI addresses, or a separate modem image loader. The boot ROM
  check covers one published chip revision and statically identifiable
  addresses. Dump SHA-256
  `da0eb77d3b082384a856fb25f24f11c33e01e30685ca679db7f97e9c98f87856`.
  [OpenBouffalo boot ROM dump][bl-bootrom] · [M1s E907 ROM API table][m1s-rom-api]
- Both published M1s Dock E907 factory images, `firmware_20221212.bin` and
  `firmware_20230227.bin`, contain Wi-Fi and RF code. The same
  constant-effective-address pass recovered modem `+0x9000` setup and
  accesses to the RF SRAM registers. In the February image, for example,
  file offsets `0x51CAE`–`0x51CC6` read RF `+0x23C/+0x240/+0x244` into
  saved state and `0x51DF2`–`0x51E0A` restore them. That sequence matches
  the M1s calibration save/restore functions. No CSI control/status or DMA
  access was identified in either factory image. These are stripped
  images, so this is limited to the statically identifiable accesses and
  embedded strings. [December E907 image][m1s-factory-dec] ·
  [February E907 image][m1s-factory-feb] · [M1s RF archive][m1s-rf-archive]
- Both BL808 v0.56 manufacturing images distributed with RT-Thread contain
  the `sram_rx` diagnostics. In each image the RF SRAM save sequence at
  file offsets `0x5C42E`–`0x5C446` and restore sequence at
  `0x5C572`–`0x5C58A` use the same three RF registers as the M1s code.
  The modem scan also recovers reset writes to `0x24C00888`. It yielded
  zero candidate CSI control/status or DMA accesses in these images.
  [RT-Thread manufacturing images][rtthread-mfg]
- Five Bouffalo PyPI programmer releases yielded 16 manufacturing images
  including the autoboot variants. The BL606P images include v0.42 and
  v0.44, and both chips have builds v0.56, v0.57 and v0.59. The BL808
  v0.56 programmer image matches the RT-Thread image after its 4 KiB
  prefix. Every image yielded modem reset writes, LDPC memory references,
  and RF SRAM controls. The constant-address scan returned no candidate
  CSI control/status or DMA accesses. Inventory and scan logs are under
  `build/hw-validation-wifi-source/`.
  [Programmer 1.7.5][iot-tool-175] · [1.8.0][iot-tool-180] ·
  [1.8.3][iot-tool-183] · [1.8.7][iot-tool-187] · [1.10.0][iot-tool-1100]
- PINE64's original Ox64 `bl808_demo_event.bin` includes Wi-Fi version
  strings, modem reset, LDPC memory setup and RF SRAM register accesses.
  `whole_flash_data.bin` is a separate UART demo release. The static scan
  yielded zero candidate CSI control/status or DMA accesses in both
  images. The modem reset and RF SRAM accesses provide positive controls
  in the first image. [PINE64 release links][pine-ox64]

### Modem RAM, interrupts, and raw samples

- BL808's [Wi-Fi PHY implementation](../src/bl808/wifi/fw/global_state/rf_bl808_core.nim)
  uses modem base `0x24C00000`. Its Wi-Fi `copyAgcMemory()` reproduces the
  `phy_init` copy of the 512-word AGC state machine image to `0x24C0A000`.
  The pinned BL808 low-power path copies 240 words and stops inside
  `S0EC`. The official BL616 archives copy 384 words and cover every
  active record in their image. The BL808 suffix retained after a
  low-power reload remains unmeasured. [Low-power copy and branch dependencies](bl808_agc_microcode.md#low-power-loader-boundary)
- `0x24C09000` is an LDPC destination in the M1s PHY/RF `ldpc_config` and the
  BL808 BLE PHY memory loader. The first 32 words at that address in
  `build/hw-validation-no-conn-rf-retune-central/logs/m0_ble_nim_controller_pure_central_hal_test.m0.openocd.clean.log`
  at lines 734–739 match `BleLdpcMem` word for word. The selected Wi-Fi
  `phy`/`lp_phy` objects omit that load. Ownership in an active Wi-Fi readout
  remains unresolved. [BLE PHY memory loader][bl-ble-loader] · [LDPC table][bl-ldpc]
- In the selected RF backend, `phy_mdm_isr` is a no-op and `phy_rc_isr` reads
  `0x24C0B41C` and acknowledges through `0x24C0B420`. The earlier SDK's modem
  handler logs only; its RC handler has different legacy side effects. Do not
  infer that those interrupts are CSI events. The channel-setup pulse at
  `0x24C00888` is separate. See [PHY interrupt ownership](bl808_vendor_blobs.md#phy-interrupt-ownership).
- Current BL808 capability checks expose HE, VHT, bandwidth, LDPC, beamforming,
  and MU-MIMO fields. None of those is a verified host CSI capability bit. An
  OFDM receiver can estimate the channel internally without offering software
  access to its estimates.

### AGC state machine disassembly

The [AGC microcode guide](bl808_agc_microcode.md) has a section-by-section
walkthrough, every state's incoming and outgoing branches, and the
annotated listing of every word in the current Wi-Fi program.
Its [ISA encoding reference](bl808_agc_microcode.md#recovered-isa-encoding)
gives the packing formulas for headers and branches. The disassembler
has a one-word lookup and a byte-for-byte reconstruction check.
The [semantic evidence](bl808_agc_microcode.md#semantic-evidence-and-remaining-measurements)
records the BL808 diagnostic readout path and the observations needed to
assign the remaining hardware predicates and actions.
The [public decoder-source audit](bl808_agc_microcode.md#public-decoder-source-audit)
records which checked driver, register, and emulator sources specify
field positions but leave the Boolean and output semantics open.
The [MPW-to-full-mask comparison](bl808_agc_microcode.md#extension-selector-and-payload)
isolates the extension byte from its payload. The
[VCD correlator](../tools/trace_agc_fetch.py) identifies the words seen on
the sampled AGC RAM bus.

The SiFlower diagnostic maps distinguish host RAM access,
the full AGC RAM address, and the CCA FSM value. AX3000
`genvcd` emits all banks at the same VCD scope and uses a
fixed 2,083 ps conversion period. The correlator's
`--address-id` option selects one same-name vector.
[Diagnostic banks](bl808_agc_microcode.md#observable-signals-and-the-bl808-diagnostic-route) ·
[VCD clock and bus selection](bl808_agc_microcode.md#correlating-a-diagnostic-capture-with-the-disassembly)

DA16200 and AX3000 independently show why the lower AGC
header cannot be read directly as a contiguous CCA state
number unless the decoder accepts codes outside the
eleven receive-state mask positions. The paired BL618DG
band images expose the same problem. Single-bit variants
of BL808 state `S00D` give distinct predictions for the
contiguous slice and the six unsigned bit arrangements
that cover all eleven codes.
[CCA masks and header probes](bl808_agc_microcode.md#receive-state-cca-masks-and-the-header-controls)

BL616, BL616CL, and AIC records give codes above 10 in
all six of those unsigned arrangements. Across 202 distinct
control words, every shared four-bit mapping that stays in
range requires inversion. All 12 mappings that also use all
eleven codes in the original five-image set predict that
header bit 2 drives the high CCA bit with inverted polarity.
A verified two-path BL808 probe
changes one predecessor control bit and holds the successor
header fixed. A stable CCA code difference at that successor
would establish a dependence beyond the current header.
[Extended CCA comparison](bl808_agc_microcode.md#testing-the-cca-header-projections-against-more-images) ·
[Common-successor probe](bl808_agc_microcode.md#checking-the-cca-code-at-a-common-successor)

The ListenAI ARCS platform archive provides a separate
front-end divider, PHY divider, and logic analyzer clock
selection. Its factory test archive reads back the first-sample
and write indices through the analyzer
register block. This supplies an independent capture
implementation for comparing clock metadata and timed AGC
states. A controlled BL808 RAM chain has now measured 0.1 µs
per AGC count under the current board clocks.
[Clock controls](bl808_agc_microcode.md#separate-front-end-phy-and-analyzer-clock-controls) ·
[ARCS analyzer capture](bl808_agc_microcode.md#listenai-arcs-logic-analyzer-capture)

SiFlower's MAC diagnostic bank `04` exposes `tick1us_p`
alongside the RIU address and timeout banks. Nine synthetic
captures verified that scaling the matched count-12, 16,
and 32 waits against this pulse cancels the exporter clock
assumption and fixed capture latency. BL808 snapshots show
different slot cycle counts with the same MAC clock field.
The MAC diagnostic pulse still needs a BL808 measurement;
the state-timer unit is now measured independently.
[Timer calibration](bl808_agc_microcode.md#calibrating-the-timer-against-a-mac-diagnostic-pulse)

SiFlower's 60 and 120 MHz PHY timing recipes share
one AGC image. The older M1s BL808 driver and archived
register captures match the 60 MHz recipe values.
The pinned BL808 driver changes the FE and DAC
selectors while writing the same transmit start delay
at 20 and 40 MHz. These comparisons identify which
PHY timing values to read alongside an AGC trace. The
AGC tick still needs calibration.
[Width-dependent PHY timing](bl808_agc_microcode.md#phy-timing-registers-across-channel-widths)

The timer-width comparison covers 10 distinct official
normal-use AGC programs. Every active timer with bit 26
set belongs to the same retry operation, and a BL616CL
release removes its expiry edge while retaining that bit.
A BL808 RAM timing sweep now shows that bit 26 does not add
2,048 counts: 500, 1,000, and 2,000 count states last about
50, 100, and 200 µs with that bit either clear or set.
The bit's other effect remains unknown.
[Timer bit 26](bl808_agc_microcode.md#bit-26-in-the-timer-count-field) ·
[RF and modem clocks](bl808_agc_microcode.md#separate-front-end-phy-and-analyzer-clock-controls)

The compact BL616CL low-power image keeps the
timer enabled at `S043` while a constant operand
disables its expiry branch under the C1 model.
That separates observing the timer signal from
observing a state change. Matched BL808 and
BL616CL probe words test bit 26 at two counts
to distinguish a high count bit from a change
to the timer scale or a separate control. The BL808
timing sweep now excludes the high-count-bit reading;
the BL616CL measurement remains open.
[Stationary timer observation](bl808_agc_microcode.md#observing-expiry-while-the-state-stays-active)

The QCC743 and BL616 analyzer drivers have identical capture
routines. They temporarily change and restore `0x24900074`,
the same address the M1s BL808 CLI uses to select PHY
diagnostics. Their analyzer base `0x24E00000` and the QCC743 ID
`656E6562` give a specific BL808 readback candidate. The two
SiFlower diagnostic maps also give exact lane positions for
SFD, AGC lock, signal-field validity, and the AGC RAM
address in one bank. These observations can distinguish the
candidate inputs for the long receive waits.
[QCC743 analyzer](bl808_agc_microcode.md#qcc743-analyzer-and-the-bl808-diagnostic-selector) ·
[SFD and receive indications](bl808_agc_microcode.md#separate-sfd-and-receive-indications)

The compiled DSSS precompensation setter anchors
two register layouts. The pinned BL808 driver
writes `PRECOMP=2D` at `0x24C00324`, and the
M1s BL808 driver writes that field at `0x24C03024`.
The neighboring SFD and receive-error controls
need readback at the corresponding base before
using them to interpret a trace. Valid and
invalid PLCP CRC and MAC FCS cases give separate
tests for `P1F` and `P23`.
[DSSS register comparison](bl808_agc_microcode.md#dsss-control-addresses-in-the-archived-drivers) ·
[SFD and header validation test](bl808_agc_microcode.md#separating-sfd-detection-header-validation-and-receive-end)

At the shared diagnostic offsets, the QCC743 header
defines different selector fields from the DA16200
legacy layout. The M1s BL808 CLI also writes a second
selector pair at `0x24900078` beyond the defined QCC743
fields. This gives a targeted BL808 mux readback to
resolve before applying the SiFlower lane names to a
trace.
[Diagnostic selector layouts](bl808_agc_microcode.md#diagnostic-selector-layouts-at-the-shared-offsets)

M1s BL808 `wifi_main` calls the same diagnostic initializer as
the BL616 and QCC743 archives. It writes `8000000C` to
`0x24900068`. M1s also supplies a named diagnostic trigger
that pulses `0x24900070`. Both addresses are verified in the
BL808 compiler output. A timed AGC capture still requires
verification of the analyzer and its RAM on BL808.
[BL808 configuration and trigger evidence](bl808_agc_microcode.md#qcc743-analyzer-and-the-bl808-diagnostic-selector)

The [ESWIN channel driver and fuse patch](bl808_agc_microcode.md#eswin-revision-dependent-agc-images)
link the `C1(01,0F,3F) → S00B` event to DSSS receive
enablement and isolate header bit 8 in its acquisition
sequence. The [separate RF width control](bl808_agc_microcode.md#eswin-channel-width-and-header-bit-8)
leaves that bit's exact hardware output open. The
[ESWIN debug readback](bl808_agc_microcode.md#correlating-a-diagnostic-capture-with-the-disassembly)
can identify the loaded program while the FSM is in reset.
The [SiFlower bridge profile](bl808_agc_microcode.md#sf19a28-bridge-configuration)
isolates header bit 9 in the retry loop and shows the
same board tuning applied to extension selectors
`0E` and `0F`.
Three AX3000 low-band files also isolate header bit 3
before the common receive return, with the extension
and outgoing branch held fixed.
[Header bit 3 comparison](bl808_agc_microcode.md#bit-3-before-the-common-receive-return)

The RC2 packet detector shares its mode, count threshold, and
window fields across the published BL602 header and the pinned
BL808 driver. The Wi-Fi and low-power drivers set mode 2, while
the archived BLE capture shows mode 0 with the same threshold
and window. Separate RF status bits expose raw and latched
packet detection for comparison with an AGC branch trace.
[RC2 detector fields](bl808_agc_microcode.md#packet-detection-configuration-and-readback) ·
[RF status bits and readbacks](bl808_agc_microcode.md#readouts-for-gain-power-and-cca)

The BL602 header and BL618DG PHY archive agree on the ADC power
input field at `0x24C0C834[1:0]`. The pinned BL808 Wi-Fi and
low-power drivers write code `1`. The later BL618DG initialization
write leaves the field at code `2`, which also appears in the
BL808 vendor BLE readback. BL618DG DWARF names separate detector
module and reference-level update controls. The ADC source codes
and the corresponding microcode predicate IDs remain open.
[ADC power and reference controls](bl808_agc_microcode.md#reference-level-update-controls-and-adc-power-input) ·
[Packet detector module select](bl808_agc_microcode.md#packet-detection-configuration-and-readback)

The AX3000 SDK packages the standard AGC images. The DFS
comparison image remains in the source tree. Its branch to
word `1D6` retains the address of a valid count-40 state in
the standard 20 MHz image after the DFS build moves that
state to `1D7`. Both published AX3000 load paths preserve
the input words through AGC reset release.
[AX3000 branch comparison](bl808_agc_microcode.md#repeated-branch-addresses-in-ax3000-high-band-images) ·
[AX3000 upload and reload](bl808_agc_microcode.md#ax3000-kernel-upload-and-firmware-reload)

The BL808 and M1s images change bits 1 and 9 in the selector-`21`
setup word before the same seven-way decision. BL618DG keeps
`21000101` in both band images and removes the high-byte result
routes in the 5 GHz image. The disassembler now labels the
stage code and both result fields on each BL808 selector-`29`
word. [Receive decision comparison](bl808_agc_microcode.md#selector-21-and-the-third-selections-result-fields)

`agcmem` programs the modem's automatic gain control state machine. This
block manages receive gain during acquisition and responds to detector
events. The older BL808 PHY pulses the same AGC FSM reset bit that the AIC
RIU header names. The BL808 RC2 initialization sets LNA/VGA gain limits and
OFDM/DSSS detection thresholds. In the related SFAX8 driver, EVT2 is
associated with disappearance detection and clearing EVT3 disables DSSS
detection. The exact event assignment on BL808 remains unverified.
[M1s PHY/RF archive][m1s-rf-archive] · [AIC RIU header][aic-riu] ·
[SFAX8 PHY C][sfax8-phy]

OpenCam and TuyaOpen Trident drivers use both
`P1D` and `P3F` in their named DSSS event.
The matching fallback program then tests
`P1D` on its own. These older programs use a
different two-bit combiner field; their event
behavior cannot be read directly from the measured
BL808 three-bit RAM table.
[Trident DSSS event and fallback](bl808_agc_microcode.md#trident-variants-separate-dsss-event-inputs)

The pinned RF archive and the Nim port differ in two AGC event fields.
The archived normal initializer writes combiner 2 at `0x24C0B384`,
where the port writes 6. The archived low-power initializer writes
operand `01` in bits 19:14 of `0x24C0B388`, where the port writes
`2A`. The archived `bba_set_pd_dsss` independently corroborates the
constant operands by choosing between `01` and `00` to enable and
disable the DSSS event condition.
[Archived event recipes](bl808_agc_microcode.md#entry-stubs-and-external-events) ·
[DSSS gate](bl808_agc_microcode.md#host-controlled-detector-gates)

The archived vendor BLE OpenOCD log and the BLE initializer
agree on RC2 EVT4 word `FCF0440D` at `0x24C0C830`.
It targets the count-50 DSSS-associated entry at `S00D`.
The BLE loader's RAM image matches the
older M1s archive byte for byte. The pinned Wi-Fi program
retains the same entry header and relocates its timer
destination from `S106` to `S142`. The normal Wi-Fi
runtime target at `0x24C0C830` remains unmeasured.
[BLE and Wi-Fi entry comparison](bl808_agc_microcode.md#entry-stubs-and-external-events)

Two historical Nim Wi-Fi captures confirm the RIU event targets
`S002`, `S005`, `S008`, and `S00B`. The lwIP and scan
captures read back combiner 2 and combiner 6 respectively at
`+B384` with identical operands and target. The normal Nim
initializer explicitly writes combiner 6. An archived debugger
patch restored combiner 2 alongside 12 other modem writes and
the scan returned five results. That run gives no isolated
combiner outcome. A separate readback at the AGC copy
breakpoint matches the first 64 archive words.
[Wi-Fi event and RAM captures](bl808_agc_microcode.md#wi-fi-event-register-and-ram-readback)

Both BL618DG band programs use `C6(14,00,37)` on
predicate page 1 before a count-6 fallback into the
ADC-power gain selection. The middle input is held
at zero. Combined with the AX3000 branch where that
input is held at one, the two cases constrain C6 under
the inferred branch priority. The truth table remains open.
[Combiner 6 branch comparison](bl808_agc_microcode.md#combiner-6-on-the-second-predicate-page)

In the same BL618DG images, page-1 operands `27` through
`32` each qualify a group of gain choices and then
select a specific gain-setting word. Replaying the
compiled PHY driver confirmed the independently writable
threshold fields. Varying only threshold 3 and comparing
the `P2A` and `P2B` destinations tests an ADC-power
bin boundary. Swapping the two branch words tests
whether the predicates can be true together.
[Gain predicate and register comparison](bl808_agc_microcode.md#isolating-one-gain-threshold)

The normal and low-power BL618DG PHY drivers agree on
the RF lookup entries and LNA bounds. Indices 8 and 9
share both physical gain codes and calibration values,
so gain readback alone cannot identify which index
`10009921` applies. Indices 1 and 2 have different LNA
codes, and the gain ladders supply matched bit-4
variants with the same timer and destination.
[Gain-table dispatch](bl808_agc_microcode.md#what-selects-the-short-gain-ladder) · [Selector 10 gain fields](bl808_agc_microcode.md#distinguishing-the-two-gain-nibbles-in-selector-10)

The AX3000 DFS C6 state has a single coded incoming branch
that tests `P2B`. Its entry and C6 states have identical
lower controls and no extensions. Holding `P2B` high
and observing both outcomes with different `P26` values
would constrain C6 rows `100` and `101` to differ.
[DFS C6 entry comparison](bl808_agc_microcode.md#an-isolated-c6-entry-in-the-ax3000-dfs-image)

Both AX3000 FMAC channel-mode sequences preserve
`DSSSONLY`, including the high-band radar-enabled
path. Three standard low-band arrays and the archived
DFS array use `C6(2B,00,26)` ahead of a timer fallback.
If `P26` follows `DSSSONLY` and both routes execute
with that bit clear, C6 rows `000` and `100` differ.
That condition eliminates `A & (B | C)` and leaves
`A & (B | !C)` among 64 possible tables. The branch
trials isolate those rows with single-word changes.
The CPU writes and encodings were verified offline.
[Fixed-mode constraints and test words](bl808_agc_microcode.md#c6-with-the-dsss-only-input-clear)

BL618DG 5 GHz can reach the C6 destination directly
through a page-0 `P09` precheck. AIC uses C6 as the
first branch of a two-exit OFDM/DSSS decision with no
timer. The BL808 event register can test all eight
rows with constant operands and the stock RAM image.
The register words and control runs are documented
for when hardware is available.
[C6 entry paths](bl808_agc_microcode.md#c6-path-entry-in-bl618dg-and-aic) ·
[Constant-input C6 event test](bl808_agc_microcode.md#constant-input-c6-event-test) ·
[Constant-input C6 RAM test](bl808_agc_microcode.md#constant-input-c6-ram-branch-test)

The D80N RF-test firmware clears `DSSSONLY` after its
startup channel call, and its channel helper sets `OFDMONLY`
for band 1. Its AGC program preserves the two branches at
`S097`, with a second `22800000` action added on the retry
path. Under the proposed predicate mapping, a band-1 trace
with `DSSSONLY` clear would isolate `C6(P1B,P1C,0)` at that
state. The AX3000 low-band comparison identifies a separate
way to distinguish its C6 and timer paths by the emitted actions.
[D80N mode and retry](bl808_agc_microcode.md#aic-d80n-detector-mode-and-the-c6-retry) ·
[AX3000 C6 action paths](bl808_agc_microcode.md#combiner-6-before-a-timer-fallback)

The AX3000 DFS image adds `C3(15,1A,00)` at four
receive states. Two have no timer and the same competing
predicates, giving a way to test the first two C3 inputs
with the third clear. The sole BL808 C3 word uses
`C3(00,00,02)`. A verified single-word image variant
substitutes C0 with the same timer operand and destination.
[C3 restart and timer comparisons](bl808_agc_microcode.md#combiner-3-restarts-with-its-third-input-clear)

The published Karst PHY object confirms the AX3000
receive-path mask rule. Both initialization and wakeup
select mask 3 when `NSS=2`, and mask 1 otherwise, on
the code path that programs `ACTIVEANT` and `COMBPATHSEL`.
The AX3000 40 MHz image yields fixed-state variants that
separate per-branch path reduction from third-input
inversion. Their predicted outcomes differ only when
the two selected paths see different predicate values.
The recorded single-path BL808 configuration cannot
distinguish those outcomes.
[Receive-path mask and branch comparison](bl808_agc_microcode.md#receive-path-selection-and-combination)

Historical BL808 readbacks match three related RIU
registers with documented 50 ns DC-compensation units.
The AGC header timebase remains open. Three stock
qualifier states use the same branch and controls
with counts 12, 16, and 32, giving a direct
comparison that can cancel fixed trace latency.
The pinned BL808 driver selects centered
DC-compensation type 3 at 20 MHz and type 0
on its wider path while reusing the AGC words.
Hold this setting fixed when comparing effects
of individual extension payloads.
[Receive timing and matched states](bl808_agc_microcode.md#state-timer-and-50-ns-receive-controls) ·
[Width-dependent DC compensation](bl808_agc_microcode.md#centered-dc-compensation-across-channel-widths)

BL618DG's gain dispatch independently supports C4 negating
its third input when the first two are zero. The inference
uses first-match priority and assumes that both gain paths
execute. AX3000 also splits the combined BL808 return into
individual uses of `P25` and `P11`. Together the
comparisons support the candidate `P25 | !P11` for all
four BL808 C4 branches.
[C4 polarity](bl808_agc_microcode.md#combiner-4-polarity-in-the-gain-dispatch) ·
[Separate return tests](bl808_agc_microcode.md#separate-return-tests-for-p25-and-p11)

Related band images isolate `P03` as a gain-path selector and
`P09` as a branch input and event veto. BL616CL uses both
polarities of `P10` to choose whether to repeat the initial
gain setup. The SiFlower debug names for these three selectors
depend on an unverified relationship between debug bit order
and operand numbering.
[The complete low-operand candidate table](bl808_agc_microcode.md#complete-diagnostic-order-candidate-map-for-low-operands)
records the proposed `P02` through `P11` mapping to RIU bank-`01`
bits 0 through 15, with each BL808 use count and a separate constraint.
`P02` has additional timer-flag corroboration; the other names are
not yet confirmed physical assignments.
[Isolated predicate tests](bl808_agc_microcode.md#isolated-tests-of-the-diagnostic-order-candidates)

PineVoice can advance the acquisition check on `P1B`
without `P1C`, then uses both for the first `03` result.
The BL618DG 5 GHz signal-detection entry can reach a
late decision that selects `03` for both inputs and
`01` for either. A BL808 diagnostic image can expose
the individual branches through distinct destinations
with the same state controls and extension actions.
[Receive-result predicate comparison](bl808_agc_microcode.md#separate-checks-of-the-receive-result-predicates)

The AX3000 low-band 20 and 40 MHz programs use the same
seven receive-result branches after target relocation.
At fixed width, the pinned BL808 driver can distinguish
the lower and upper primary using `PSSELECT` at
`0x24C0B080` and `PRIMARYIND` at `0x24C00850`.
The current Nim channel setter writes the latter value to
`0x24C00848`, the transmit SFO control address in the
related SDK. This affects how a sideband trace should be
configured and interpreted.
[Primary-channel controls](bl808_agc_microcode.md#isolating-primary-channel-controls)

The pinned PHY programs the per-MCS `ACI20MARG`
table at `0x24C0B340–0x24C0B348`. Replay confirms
three zero words at 20 MHz and `02040507 00000001
00000000` at 40 MHz. The archived vendor Wi-Fi
readback matches the zero setting. A future trace
can vary one MCS field at fixed width and compare
the `P1B/P1C` exits with ACI and SIGNAL-valid lanes
to test when those predicates can assert.
[ACI register evidence](bl808_agc_microcode.md#per-mcs-adjacent-channel-interference-margins) ·
[Predicate timing comparison](bl808_agc_microcode.md#timing-the-receive-predicates-against-aci-detection)

The OFDM plateau-fall timeout is at
`0x24C00870[23:12]` and reads 500 in the archived
BL808 dumps. The SiFlower diagnostic map exposes
plateau fall, plateau timeout, and AGC state expiry
as separate signals. The pinned 20 MHz channel code
preserves the timeout and sets bit 24. The current Nim
mask also clears the time-domain frequency-offset
compensation and fine-estimation enables identified
by the related headers. Both settings matter when
interpreting an OFDM receive trace.
[Plateau timeout and driver replay](bl808_agc_microcode.md#ofdm-plateau-fall-timeout-and-the-state-timer)

The SiFlower driver sets `RXTDCTRL1[0]` to keep RF on
across a brief MAC receive-request drop after an error.
M1s sets the same bit at `0x24C00834`, and archived BL808
scans contain both bit values. Hold it fixed when comparing
the `P24/P25` returns, and capture MAC receive request and
error alongside the AGC address to distinguish a restart
from a programmed return.
[Reset-mode driver and readback comparison](bl808_agc_microcode.md#receive-request-drops-and-agc-reset-mode)

The pinned BL808 microcode gives `P23` and `P24`
distinct destinations at `S0EC`. M1s sends both
to the same destination. Both BL618DG bands
also test `P24` downstream of the `P23` exit.
M1s reads separate MAC bypass counters for
receive end, receive error, and bad frames.
These report the receive outcome alongside a
trace of the branch destination.
[P24 branch comparison](bl808_agc_microcode.md#p24-before-and-after-the-signal-field-wait) ·
[MAC bypass counters](bl808_agc_microcode.md#mac-bypass-receive-end-and-error-readouts)

Both stored BL808 branches to `S0FC` test `P25` alone.
SiFlower's MPIF decoder exposes ordinary receive end and
receive-end timing on separate lanes. Capturing both alongside
the AGC-facing timing lane distinguishes which pulse tracks
the `S0FC` transition.
[P25 observation points and capture lanes](bl808_agc_microcode.md#distinguishing-receive-end-from-receive-end-timing-on-p25)

The original AX3000 high-band programs test `P0B` before
and after a count-50 wait. Standard v3 substitutes `P2D`,
while the DFS image uses both selectors around that wait.
BL618DG separately uses `P0C` to advance before timer
expiry. A matched SF16A18 receive path uses `P0D` in the
same position where BL618DG uses `P0C` and adds a timeout.
The four-way BL808 `S073` diagnostic image predicts a
distinct first destination for each `P0B/P0C` combination.
Archived BL808 readbacks give plateau index 3 and
plateau delta 2 dB. The RIU map exposes separate
controls for the plateau and ADC disappearance,
so a controlled trace can correlate each branch
with the detector that triggered it.
[Related receive paths](bl808_agc_microcode.md#power-stability-and-correlator-predicate-tests) ·
[Plateau and disappearance controls](bl808_agc_microcode.md#power-plateau-and-disappearance-controls) ·
[BL808 diagnostic branch encodings](bl808_agc_microcode.md#separating-p0b-and-p0c-on-bl808)

The archived BL808 Wi-Fi dumps and QCC743 driver
writes identify separate upward and downward in-band
power gap controls. They can be varied independently
while comparing `IdPow` with the isolated `P10` edges.
QCC743 also removes `P39` from the normal `+B384`
recipe and retains it in low-power mode. The physical
predicate assignments still need a trace.
[In-band power gap controls](bl808_agc_microcode.md#in-band-power-gap-controls-for-the-p10-test) ·
[Normal and low-power event operands](bl808_agc_microcode.md#detector-operands-shared-by-host-events-and-ram-branches)

The BL618DG driver sets the ADC floor to `9E` and
the in-band floor to `9C`. All selector-`22`
words in its band programs match the in-band code.
Trident preserves the same low byte in its BCD
forms of selectors `22` and `23` and publishes
the same signed in-band floor. This favors −100 dBm
as the local in-band floor in the seven BL808 words.
The state-local effect on BL808 remains unmeasured.
[Power floor field comparison](bl808_agc_microcode.md#separating-the-in-band-and-adc-power-floors)

The Trident profiles use both `20` and `28` in
the selector-`22` middle byte under one host
detector configuration. A one-byte BL808 comparison
at word `0EA` can test whether this setting changes
a power comparator's gap or its assertion timing.
[Middle-byte and host detector comparison](bl808_agc_microcode.md#middle-byte-changes-with-fixed-host-detector-settings)

Matched normal-use images isolate two settings in selector
`3E`. BL616CL sets bit 0 on the first qualifier route
compared with BL616. BL618DG sets bit 16 on the four-count
setup for the second result decision compared with BL808,
M1s, and BL616CL. Both BL618DG band images use that
setting. The exact one-bit comparisons are documented
for the BL808 states at `S066` and `S0A2`.
[Selector 3E field comparisons](bl808_agc_microcode.md#isolating-selector-3e-bits-0-and-16)

The AX3000 v3 high-band width pair changes
`3D000303` to `3D000202` in three otherwise
matching setup records. CPU replay of both
FMAC builds shows the same host-programmed
centered DC type, 3, at 20 and 40 MHz.
The adjacent selector `3F` has a candidate link
to `DELDCSTABLECC[1]` at `+B37C`. Eight checked
BL808 variants separate that bit, payload bit 8,
and the following `1F` setup. Their physical
effects remain unmeasured.
[Host compensation and selector 3D](bl808_agc_microcode.md#separating-setup-commands-from-host-dc-compensation) ·
[Selector 3F and isolation variants](bl808_agc_microcode.md#selector-3f-and-the-dc-stability-setting)

The BL618DG factory 2.4 GHz receive test temporarily
changes selector `44` from `44002C01` to `44002001`.
It also programs two LNA settings, `LNA_BM_HG` and
`LNA_BM_LG`, and the receive mixer setting `RMXGM_BM`.
The normal channel
driver identifies the test's gate as `CFG_BAND_5G` at
`0x24C0C864[31]`. This yields a controlled way to
separate the selector setting, RF tuning, and band
selection. The selector's physical effect and the band
bit's availability on BL808 remain unverified.
[Factory receive patch](bl808_agc_microcode.md#selector-44-in-the-factory-receive-test) ·
[Band flag in the PHY](bl808_agc_microcode.md#blagcfsmreg-initialization)

BL616CL factory receive diagnostics name the guarded
setup an 802.11b DSSS threshold override. Three releases
run that setup by clearing bit 10 of the selector-`44`
word and applying separate RF writes. Five later releases
retain the diagnostic and perform only the RF writes.
This makes `44[15:8]` a DSSS threshold candidate for
BL808 word `03F`. The v2.3.17 and v2.3.18 normal images
vary that payload while the two named RC2 DSSS thresholds
both keep code `40`. The exact detector and scale remain open.
[DSSS threshold evidence](bl808_agc_microcode.md#driver-diagnostic-for-the-80211b-dsss-threshold) ·
[RC2 threshold comparison](bl808_agc_microcode.md#agc-payload-and-the-rc2-dsss-thresholds)

Full driver replay confirms that the early factory
start and stop commands both write `44002001`, even
though stop changes the two RF fields back to 3.
Versions 2.3.33 and .34 keep the stock AGC program
and instead restore detector events on receive start.
Their direct EVT4 route can reach the first parameter
decision without fetching selector `44`. A threshold
comparison needs to establish when the modified
state executes and hold the RF and event settings fixed.
[Factory start and stop replay](bl808_agc_microcode.md#receive-test-start-and-stop-across-the-threshold-revision) ·
[Event paths](bl808_agc_microcode.md#receive-test-event-route-in-bl616cl)

Current BL618DG channel code also changes two full
RIU words at `+B1B8/+B1BC` across bands. BL616CL
and QCC743 initialization use the same 2.4 GHz
values. The earlier BL618DG channel routine uses
the same band flag and byte-identical programs.
This gives a way to keep the added driver settings
fixed when testing AGC header bit 14.
[Band-related register writes](bl808_agc_microcode.md#other-band-settings-alongside-cfg_band_5g)

The normal BL808 initializer sets `GPSTATUS=1` and
then clears it through `bba_init`. The low-power
initializer writes 1 and changes the signal-detection
combiner and operands separately. BL618DG initializes
the field to 1 while retaining the normal event recipe.
These differences clarify which controls a test must
hold fixed when checking the `P2A` veto.
[Driver status writes](bl808_agc_microcode.md#when-the-driver-changes-gpstatus)

The BL808 startup gain profiles support active-high
`P26 = DSSSONLY` and `P27 = OFDMONLY`. Three AIC images
use `P27` high to bypass DSSS setup and `P27` low to
qualify another DSSS-associated wait. Both PineVoice
archives corroborate the startup mapping with indices
8, 7, and 6 for mixed, DSSS-only, and OFDM-only profiles.
The earlier BL616
OFDM-only host ceiling is 5, while the corresponding
startup extension carries an index of 4. The evidence
leaves the physical predicate wiring and the effective
gain limit unverified.
[Startup gain profiles](bl808_agc_microcode.md#matching-the-startup-branch-to-host-gain-modes) ·
[Mode predicate comparisons](bl808_agc_microcode.md#uses-of-the-mode-predicates-after-startup)

The BL808 RF lookup table maps startup gain index 8
to LNA code 7 and mixer code 3. Archived Wi-Fi snapshots
show that pair in the hardware gain readback at
`0x2000104C` and also show the index-0 pair `(0, 1)`.
This gives a physical readout for testing the index byte
of selector `10`. The snapshots carry no AGC state address.
[RF hardware codes and selector-10 test](bl808_agc_microcode.md#rf-hardware-codes-for-the-startup-gain-index)

The vendor BLE capture also links the RC2 LNA index
0 to nominal gain code `05` and the RF hardware
pair `(0, 1)`. The same capture reports RC2 RBB
index 6, whose programmed stage codes `(1, 3)`
differ from the RF hardware codes `(0, 0)`.
The reads are sequential. Use both RC2 and RF
readouts with a state timestamp when interpreting
a change in applied gain.
[RC2 and RF gain readbacks](bl808_agc_microcode.md#comparing-the-rc2-and-rf-gain-readbacks)

BL618DG uses the same 5 GHz `0C424201` extension
while programming detector gain maximum `42` or `40`
by channel group. BL616CL versions 2.3.34 and 2.3.35
both program the two RIU gain maxima to `4B` while
the index-7 `0C` middle byte changes from `3C` to `30`.
Two matched Trident and SiFlower decisions distinguish
the modern `P04` gain-maximum candidate and `P05`
saturation candidate by their separate branches.
The modern gain-limit source and predicate wiring
remain unverified.
[Gain-limit comparison](bl808_agc_microcode.md#receive-gain-limits-in-selector-0c) ·
[Matched predicate tests](bl808_agc_microcode.md#separating-the-gain-maximum-and-saturation-candidates)

Five original-to-v3 AX3000 image pairs clear bit 6
of their matched `0C` setup action in both bands
and across channel widths. The local state header,
branch condition, and next setup action agree. A
single-bit BL808 variant at word `019` isolates the
same setting. The effect on the receiver gain
target or applied gain remains unmeasured.
[Selector 0C bit 6](bl808_agc_microcode.md#selector-0c-payload-bit-6-across-ax3000-revisions)

Seven AIC images give `P06` and `P07` separate branches
with matched timing and distinct gain words. The SFAX8
factory driver documents separate threshold fields for the
up and down crossing detectors. Replaying the BL808, M1s,
and YoC initializers confirms that the crossing thresholds
vary while the local `C2(05,06,37)` test stays fixed.
Verified BL808 variants isolate each of those three inputs.
Their physical mappings still need a trace.
[AIC crossing branches](bl808_agc_microcode.md#separating-p06-and-p07-in-the-detector-driven-gain-choice) ·
[BL808 saturation comparison](bl808_agc_microcode.md#crossing-thresholds-on-the-bl808-saturation-path)

The SFAX8 factory `phy_aetnensis.c` loads `0C004201` and programs
radio-controller gain limits `45` and `07` separately.
The SF19A28 band images keep the same `0C` word and
change only the low byte of the matched `14` state.
Sixteen verified BL808 variants isolate the three
`14` bytes at `S01B` with the startup gain profile fixed.
Synthetic trace replay recovers gain target, applied
gain, and I/Q estimator activity together. The physical
effect of each payload byte remains unverified.
[Receive gain limits](bl808_agc_microcode.md#receive-gain-limits-in-selector-0c) ·
[Startup selector `14` comparisons](bl808_agc_microcode.md#isolating-the-selector-14-bytes-from-the-startup-gain-profile)

The SFAX8 factory RF tests independently check the
applied gain index at radio pointers `0801` and `0001`
for 2.4 and 5 GHz. Each RF table tops out at index
`3F`, below the selector-`0C` code `42` and the
host maximum `45`. A direct index interpretation
requires clamping or translation. The driver also
exposes a separate `GetRxGain` read path for
comparing AGC target and applied RF gain.
[SFAX8 physical gain indices](bl808_agc_microcode.md#physical-gain-indices-in-the-sfax8-rf-driver)

Matched startup and receive records isolate the upper
payload byte of extension selector `1F`. M1s and three
earlier YoC releases also isolate its bit 0 on the
signal-detection route while retaining the same local
wait and jump sequence. The hardware destinations of
the changed fields remain open.
[Selector 1F comparisons](bl808_agc_microcode.md#selector-1f-in-acquisition-and-receive-setup)

The BL808 entry action `60000000` also occurs inside
AX3000 receive gain adjustment and BL618DG ADC-power
gain selection. Those paths separate the shared
`60` action from the words that encode the selected
gain. Trident's startup and retry paths independently
corroborate the acquisition setup role of `01000000`.
[Acquisition entry actions](bl808_agc_microcode.md#acquisition-entry-actions-01-5b-and-60)

Selector `40` uses `40000001` at a timed setup step
across the reference images. AX3000 also uses it on a
route back to the gain-limit record. Selector `44`
remains `44002401` in two BL616CL releases with identical
AGC RAM and different host ADC peak-voltage settings.
The physical outputs of both selectors remain open.
[Selector 40 setup](bl808_agc_microcode.md#selector-40-and-its-timed-setup-step) ·
[Selector 44 comparison](bl808_agc_microcode.md#receive-setup-words-0d-and-44)

Both ESWIN loaders replace their sole `40000001`
with `44001406` on the eFuse-selected revision,
while preserving the four-count wait and its next
state. Cold-copy replay verifies the exact word at
`0x0070A06C`. If selector `44` were a literal write
to `+B390`, that payload would assert the FSM
reset bit. This constrains the proposed register
alignment for setup commands. The actual outputs
of the two extensions remain unmeasured.
[ESWIN substitution and BL808 test variants](bl808_agc_microcode.md#selector-44-in-the-eswin-four-count-setup)

Two AX3000 images issue `29010002` on their
DSSS-associated paths before any `P1D/P1E` decision.
The high payload byte can therefore be set directly.
The two images also preserve the seven final decision
conditions and result words while changing their order.
BL808 trials now isolate the selected byte and the
low-byte stage code with the outgoing branch held fixed.
[Selector 21 and branch order](bl808_agc_microcode.md#selector-21-and-the-third-selections-result-fields) ·
[Selector 29 DSSS setup and trials](bl808_agc_microcode.md#high-payload-byte-on-dsss-associated-paths)

The original AX3000 images exercise all four combinations
of state-header bits 0 and 2. BL808 only uses the two
equal settings. The Beken Trident signal-detection and
saturation paths provide matched bit-0 setup records.
The BL808 `S00D` trial holds the timer and successor fixed
while testing both bits against the `AgcFsmInit` lane.
Matched AIC and AX3000 return states also
isolate bits 8 and 9 with the extension and branch words
held fixed.
[Header bits 0 and 2](bl808_agc_microcode.md#state-bits-0-and-2-in-the-reference-images) ·
[BL808 header-bit trace](bl808_agc_microcode.md#separating-bl808-header-bits-0-and-2-in-a-trace) ·
[Isolated return states](bl808_agc_microcode.md#return-states-that-isolate-bits-8-and-9)

The QCC743 default and `4wlan` images isolate header
bit 11 at the qualifier exit `S08C`. Both preserve the
encoded branches and the driver's CCA mask and
`BLAGCFSMREG` settings. At the first parameter decision,
they change bits 11 and 5 together with bit 6 clear.
The corresponding BL808 decision enables separate trials
for the two bits. Their physical effects remain open.
[Bit 11 and bit 5 comparisons](bl808_agc_microcode.md#bit-11-at-the-qualifier-exit)

The two BL618DG band programs have 59 matched states
that set header bit 14 only in 5 GHz while preserving
the extension and branches. The channel setter also
changes `BLAGCFSMREG[31]` by band. The two controls
have yet to be isolated in hardware.
[BL618DG bit-14 comparison](bl808_agc_microcode.md#bit-14-in-the-two-bl618dg-band-programs)

The three receive-state CCA masks now match register
headers from SiFlower and Beken and archived BL808
register dumps. All 27 related SDK archives clear two
primary mask bits that are set in the saved BL808 dumps.
The low header slice `[14:11]` fits the eleven mask
positions in BL808 and BL618DG 2.4 GHz. Several equivalent
5 GHz states use values above 10 in that slice.
The `S00D` trace can test BL808's mapping by observing
the CCA state and primary output separately.
[CCA masks and header comparison](bl808_agc_microcode.md#receive-state-cca-masks-and-the-header-controls)

The QCC743, BL616, and BL616CL initializers also use
`AAAA0301` for the CCA source enables at `0x24C0B3B0`,
compared with `AAAA0377` in the archived BL808 captures.
The difference clears the three ramp-up CCA enables
and two of the three energy CCA enables. The `S00D` test
holds this register fixed while probing the lower header
bits and their effect on the receive-state CCA lane.
[CCA source-enable comparison](bl808_agc_microcode.md#cca-source-enables-in-the-comparison-drivers)

All 62 observed `32000100` actions use header bit 12
set. AIC retains the DSSS-associated wait with
`32010100` and bit 12 clear. The four BL808 test
images separate the header bit from the payload bit.
The archived BL808 dumps also keep saturation and
disappearance CCA enabled at `0x24C0B3AC`. The
SiFlower maps give separate lanes for those events,
receive-state CCA, and PHY-to-MAC CCA when testing
the header and extension effects.
[Bit 12 and selector 32](bl808_agc_microcode.md#bit-12-through-the-dsss-receive-waits) ·
[CCA event controls and diagnostics](bl808_agc_microcode.md#saturation-and-disappearance-inputs-to-cca)

In the archived images, page-0 `P1F` consistently advances
the long receive wait. BL618DG's 5 GHz program omits those
waits and retains the `P23` decision on the route from
signal detection. Both older Trident builds use `1C` in
the corresponding long wait and proceed to a final `22`
test without the later `P23` wait. Both Karst images
preserve the 1,500-count timeout budget on a route
that waits 50 counts before testing `P1F` for 1,450
counts. The next wait still uses 600 counts. The
receive comparison uses packet lengths that move
the on-air end by 80 µs while keeping the L-SIG
timing fixed.
[Receive wait comparison](bl808_agc_microcode.md#distinct-uses-of-p1f-and-p23) ·
[Karst timer split](bl808_agc_microcode.md#splitting-the-first-receive-timeout-across-two-states)

The related BL616CL CRM debug symbols identify the two masks
used by BL808's width-dependent `crm_clk_set` as front-end
and DAC clock selectors. The sequencer timer on the current
BL808 board is measured at 10 MHz.
[Clock-control comparison](bl808_agc_microcode.md#clock-controls-around-the-agc-loader)

The related BL616 and BL616CL drivers have a combined packet
detector setter for `GPSTATUS[7:4]` and the DSSS event's middle
operand. In the BL616 mainline archive, `P36` gates a
selector-`0E` gain setting in RAM and serves as a veto in
the host's RC2 event 4 under the inferred combiner rules.
YoC tests `P3F` alone before a DSSS-associated long wait, and
three AX3000 images test `P2A` alone before a choice between
extensions `60` and `5F`. These give observation points
for the three predicates. Their physical input assignments
remain open.
[Detector operands in RAM and host events](bl808_agc_microcode.md#detector-operands-shared-by-host-events-and-ram-branches)

In the pinned BL808 `bba_pd_loop`, the two
compensation updates on either side of RSSI code
−90 keep gain profile 0 and `GPSTATUS=0`. Only the
DSSS event operand differs. The related QCC743
drivers update both gates at RSSI boundaries that
depend on bandwidth. The separate OFDM and DSSS
setters give direct controls for a trace with gain
and RSSI compensation held fixed.
[Same-state boundary replay](bl808_agc_microcode.md#rssi-boundaries-with-the-same-bba-gain-state)

The YoC v7.7.0 change inserts that `P3F` check into an
earlier DSSS-associated route that went straight to the
wait sequence. The revision also adds a second
selector-`44` word, `44002D01`. Every stored path
from the entry stubs to the new `P3F` check passes
through that word. The detector effect still needs
an isolated payload comparison.
The revision changes RC2 EVT4 from
`C5(3F,01,36)` to `C7(3F,32,2D)`. BL618DG adds
three separately decoded RC2 events and programs a
named 10-bit event mask. Its two set mask bits correspond
to the two event slots omitted by its initializer.
[YoC PHY revision comparison](bl808_agc_microcode.md#detector-operands-shared-by-host-events-and-ram-branches) ·
[Selector 44 on the P3F route](bl808_agc_microcode.md#selector-44-before-the-yoc-p3f-decision) ·
[BL618DG event decoding](bl808_agc_microcode.md#branch-bit-9-and-predicate-pages)

Six AIC profiles use `P3F` before a DSSS wait and
`P11` on the later return path. Each issues
`5A010000` at the `P3F` decision, and the reachable
graphs omit selector `44`. The BL808 event words below
test whether the two predicate inputs can differ at
the same time.
[AIC route and BL808 event comparison](bl808_agc_microcode.md#p3f-and-p11-in-the-same-aic-receive-program)

YoC DWARF identifies three BL808-compatible RC2 reference
thresholds at `0x24C0C838`, `0x24C0C83C`, and `0x24C0C840`
for OFDM, DSSS, and continuous DSSS respectively. Each has
an independent bit-31 enable. The pinned low-power
initializer disables the continuous-DSSS threshold and
keeps the DSSS threshold enabled. Compact BL616CL also
clears the continuous threshold enable, and its uploaded
program keeps the exact BL808 `P25 | !P11` return word.
The pinned BL808 low-power copy ends before its four uses
of that word, so the retained suffix matters when comparing
normal and low-power behavior.
[Threshold names, masks, and programmed values](bl808_agc_microcode.md#reference-level-detector-thresholds) ·
[Program residency and P11](bl808_agc_microcode.md#continuous-dsss-threshold-enable-at-the-p11-return)

The BL618DG band programs help separate selector `32`'s
payload bits. The 2.4 GHz image uses bit 8 before two
DSSS-associated waits. The 5 GHz image omits those routes
and retains the separate bit-0 setup. AIC also retains
bit 8 when `P1F` advances its matching wait and clears
it on the fallback. Related programs identify where
selectors `34` and `6E` participate in detection restart
and late receive setup.
[Selector `32` evidence](bl808_agc_microcode.md#selector-32-payload-bits-in-receive-setup) ·
[Selector `34` evidence](bl808_agc_microcode.md#selector-34-in-signal-detection-and-return-paths) ·
[Selector `6E` evidence](bl808_agc_microcode.md#selector-6e-before-the-late-receive-decision)

Both SF19A28 band programs and two ESWIN releases use
`P2F` after a count-20 delay to select `34000001` and
the detection restart. Three AX3000 low-band programs
also use its complement to skip the `P2C` and `P2B`
tests and apply `0EE8E607`. The exact input remains
unresolved. The BL808 comparison isolates bit 0 in
word `146` while preserving the state and its successor.
[Selector `34` bit 0](bl808_agc_microcode.md#selector-34-in-signal-detection-and-return-paths) ·
[P2F decision and BL808 probe](bl808_agc_microcode.md#p2f-gates-the-two-step-late-receive-decision)

YoC v7.7.0 adds a page-0 `P2B` branch that conditionally
issues `A0000001` before the common receive setup. The
same revision lowers the upper in-band power threshold
from −80 to −92 dBm and enables both power threshold
adjustments at `+C82C`. Emulated driver replay confirms
those stores in v7.7.0 and v8.1.0. These give specific
controls to vary when testing the `P2B` input and `A0`
action. Their hardware mapping remains open.
[P2B and threshold adjustment](bl808_agc_microcode.md#page-0-p2b-and-in-band-power-threshold-adjustment)

Both PineVoice toolchain archives retain the conditional
`A0000001` branch while their baseband initializer clears
both `+C82C` threshold-adjustment enables. The YoC driver
can also clear both enables in its DSSS-only profile
without changing AGC RAM. Its `bba_set_pd_rssi` writes
only the lower threshold at `+B3C0[15:8]`, giving a
separate control for the `P2B` comparison. Actual `P2B`
behavior with the adjustment enables clear remains open.
[Runtime profile comparison](bl808_agc_microcode.md#runtime-adjustment-settings-with-the-same-agc-branch)

BL616CL v2.3.29 adds a late `P2B` branch that
raises two selector-`0E` codes by two. The same
release adds an upper ADC threshold write of `F2`
at `0x24C0B3C4[23:16]` in gain profile 4.
Compiled replay across ten releases verifies that
switching away from profile 4 preserves that threshold
and that the calls leave AGC RAM fixed. The ADC and
in-band thresholds can therefore be tested separately.
The predicate input and the physical effect of the
two selector bytes remain open.
[Late-gain revision and ADC threshold](bl808_agc_microcode.md#adc-threshold-in-the-same-late-gain-revision)

Pinned BL808 `phy_init` writes the Wi-Fi comparator
thresholds −93 and −80 dBm, matching the archived
readbacks. `lp_phy_init` later sets both thresholds to
−85 dBm for its DSSS-only profile and has a disappearance
event that tests `P18` and `P19`. Six AX3000 programs
also test `P18` after a selector-`23` extension and
again after the short wait expires. Repacked 20 MHz
variants isolate the upper `23` payload byte from the
state header change in the 40 MHz image. The two
predicates still lack physical signal assignments.
[BL808 threshold writes](bl808_agc_microcode.md#in-band-power-gap-controls-for-the-p10-test) ·
[AX3000 P18 sampling](bl808_agc_microcode.md#p18-before-and-after-the-short-selector-23-wait)

The two YoC v2.1.0 packages supply different disappearance
conditions. The bundled Wi-Fi driver uses `C2(19,00,0E)`,
the standalone PHY adds `P18`, and pinned BL808 low power
uses `C2(19,18,00)`. Four initializer replays confirm the
operand stores and preserved target. With `P19` and `P18`
high and `P0E` clear, the C2 candidates predict different
event outcomes. BL618DG also has a separate `P18` event
that shares the disappearance destination with the RIU recipe.
[Disappearance event comparison](bl808_agc_microcode.md#p18-and-p19-in-the-disappearance-event)

AX3000 uses `P0E` in RAM only in three low-band images.
Its independent branch and the C6 branch have identical
successor actions in the stock image. Verified word
variants give each branch a distinct first action and can
substitute `P0F` for `P0E` without changing the target.
The AX3000 mode switch writes `RXDSSSEN`, `OFDMONLY`,
and the external event word separately. The SiFlower
`BarkerCCDiff` and `BarkerACDiff` lanes remain candidate
signals for the two predicates.
[P0E and P0F branch comparison](bl808_agc_microcode.md#separating-p0e-from-p0f-in-ax3000-ram)

Both BL808 `60` extensions enter `S059`, which issues
the fixed gain word `10000231`. The verified count-50
comparisons substitute `5B` at the same states and
preserve the gain word and destination. AX3000 low-band
programs issue `5A` and `5F` in consecutive count-2
states before `23`. A synthetic SDK trace confirms that
the fetch decoder can correlate gain target, gain update,
and radio-controller programming done with the extension
fetches. A separate pair of AX3000 routes issues `60` or
`5F`, then the same `42` action, then different gain words.
Verified variants change the initial action and the later
gain word independently. The physical actions remain open.
[BL808 selector `60` comparison](bl808_agc_microcode.md#isolating-the-bl808-60-action-from-the-following-gain-word) ·
[AX3000 `5A` and `5F` sequence](bl808_agc_microcode.md#consecutive-selector-5a-and-5f-actions-in-ax3000) ·
[AX3000 `60` and `5F` comparison](bl808_agc_microcode.md#comparing-ax3000-60-and-5f-before-a-common-42-word)

Eight related programs use page-0 `P28` to choose
between a `23` threshold word and a timed `0E` gain
word before the same receive setup. A later `P28`
test selects `42000001` on the route to `P2F` or a
return to gain setup. The BL808 image keeps the
common receive setup and omits the `P28` tests and
selector `42`. The SFAX8 comparison isolates bit 0
of `42` and can invert each `P28` branch separately.
[Page-0 `P28` decisions and selector `42`](bl808_agc_microcode.md#the-42-payload-and-the-two-page-0-p28-decisions)

The AX3000 v3 band images isolate bit 4 of selector `41` at
a matched count-1500 wait. The header and branch conditions
hold constant while the payload changes from `00000F` to
`00001F`. BL618DG uses the same selector with payload bit 16
alone before a gain-selection path. These comparisons narrow
the payload fields. Their hardware destinations remain open.
[Selector `41` evidence](bl808_agc_microcode.md#selector-41-at-retry-and-receive-waits)

The 2 KiB image contains little-endian 32-bit words. A state begins with
a header, then one extension word if header bit 28 is set, then the
number of transition words given by header bits 31:29. Each transition's
low nine bits name a destination **word index**. On BL808, state index
`i` corresponds to `0x24C0A000 + 4*i`. A decoded image ends with zero
padding before a separate final word at `0x1FF`. Both BL808 images store
`0xC0088D03` there. An archived Wi-Fi scan reads
`RFMODE=2` and `AGCRAMMODE=2` in the same dump. Those
values select clock-forced upload and skip the host BIST
step under the full-mask SiFlower driver's rules. Any
autonomous hardware use of the final word remains open.
[Final word and captured load mode](bl808_agc_microcode.md#signature-checks-in-later-loaders)

The annotated listing has been checked address by address against
the extracted image. Its 350 program words and final word match
the binary, and the intervening 161 words are zero padding.
[Verified word listing](bl808_agc_microcode.md#complete-annotated-listing)

In the explicit branch graph, `S000` plus the five archived external
event destinations reach 109 of the 114 BL808 states. The remaining
five are the `S053 → S056`, `S078 → S07B`, and `S102` entry islands;
each rejoins the main graph. No archived event target points at those
three heads. A separate entry mechanism would be needed to give
their extension words a normal Wi-Fi runtime effect.
[Entry reachability](bl808_agc_microcode.md#entry-stubs-and-external-events)

Enumerating the candidate branch truth tables with free predicate
inputs makes 152 of 153 branch slots locally selectable under
first-match priority; the one exception duplicates its predecessor
and has the same destination. Last-match priority leaves only 138
slots selectable and collapses several multiway result decisions,
reducing the known-root graph to 74 states. This strongly favors
first-match priority but remains a static model, not a hardware trace.
[Priority comparison](bl808_agc_microcode.md#inferred-transition-conditions)

A separate cross-program check deduplicated 12 source-derived AGC
images using the BL808-style layout. In all 1,576 state records,
header bit 27 is set exactly when an outgoing branch uses operand
`02` (653 timer states, 923 without). This strengthens the timer
encoding assignment; its clock period and physical expiry timing
remain unmeasured. Trident and AIC programs also show timer-enabled
states with no outgoing `02` test, so the equivalence is not
universal across sequencer programs.
[Timer invariant](bl808_agc_microcode.md#state-timer-independent-of-the-branch-operand)

Three public Amlogic W2/W2L arrays decode with the same record
layout and share 25 distinct extension values with the BL808 image.
The W2 program supplies additional C2, C4, and C6 branch contexts.
Two W2 source revisions isolate state-header bits 9 and 10 while
retaining the same final word. They narrow the remaining ISA tests;
none records a branch outcome or extension output.
[Amlogic combiner contexts](bl808_agc_microcode.md#amlogic-w2-and-w2l-combiner-contexts) ·
[W2 state-bit comparison](bl808_agc_microcode.md#independent-adjustments-of-bits-9-and-10) ·
[W2 trailer comparison](bl808_agc_microcode.md#amlogic-source-revisions-with-unchanged-trailers)

The W2 October 2023 and January 2024 compiled AGC arrays isolate
a new branch recipe. The 80-count state replaces one timer branch
with `C2(P21,P22,timer)` and `C7(timer,P21,P22)` leading to two
existing states with different selector-`22` payloads. If the
measured BL808 RAM tables apply to W2, these branches partition all
four `P21/P22` cases at timer expiry. A separate older 2,048-byte binary confirms that the
timer-only recipe predates the October array; it is not the image
uploaded by the inspected current loader. No source records the
branch outcome.
[W2 timer-route comparison](bl808_agc_microcode.md#w2-driver-revision-splits-a-timer-route-with-c2-and-c7)

Another public PHY/RF SDK names `phy.c`, `phy_lp.c`, `agcmem.c`, and
`agcmem_lp.c` in its build file but omits those source files from its
published tree. Its compiled archive supplies a new 512-word AGC
image: 123 states, 91 extensions, 177 branches, and the same
`C0088D03` final word as BL808. All targets resolve to headers, and
header bit 27 matches use of operand `02` in every state. Its loader
copies all 512 words. This independently reinforces the record and
timer encoding; it supplies no decoder or measured predicate output.
The v2.4.0 release has nine PHY/RF archive variants. Every variant,
including the two named low-power demos, contains the same 512-word
`agcmem.c.o` payload and identical eight-threshold/nine-gain tables.
None supplies a member named `agcmem_lp.c.o`. Thus the
release does not provide a second, reduced low-power program for a
controlled AGC comparison; the final linked images were not inspected.
[IPRO6 source lead and image comparison](bl808_agc_microcode.md#a-compiled-phy-with-named-but-unpublished-source-files)

An [AGC-object metadata audit](bl808_agc_microcode.md#public-decoder-source-audit)
found DWARF in nine of 48 extracted array objects. Each of those nine
declares one 512-word array at C source line 3 and no function. The
checked build manifests name PHY source paths that their public
branches omit. These observations focus the remaining source search
on a PHY implementation with action definitions, a generator, or the
referenced modem manual rather than on another copy of `agcmem.c`.

The same image has nine `P27..P2F` branches to otherwise identical
states whose selector-`10` high payload nibble sweeps 0–8. The compiled
host PHY has eight ADC-power gain thresholds and nine nominal/RF gain
entries. This strongly associates that nibble with a gain index in
the IPRO6 program. BL808's four startup choices vary the *other*
selector-`10` nibble, so the full payload byte cannot be assumed to
be a single shared index. No public source names either nibble's
hardware destination or the BL808 predicate inputs.
[IPRO6 gain ladder comparison](bl808_agc_microcode.md#a-nine-way-gain-choice-separates-two-selector-10-nibbles)

Vendor CPU replay confirms that the full BL808 upload
writes the supplied trailer and the low-power upload
preserves the seeded suffix through reset release in the
model. A Wi-Fi suffix and a BLE suffix both retain
`C0088D03` but give different words at `0F1`
and `129`. Hardware retention across modem reset and
any autonomous check of the trailer remain unverified.
[Full and partial upload replay](bl808_agc_microcode.md#replay-of-full-and-partial-uploads-with-different-ram-contents)

`C0088D03` also equals IEEE CRC-32 of the eight
ASCII digits `00000000`. This matches the text
representation of the preceding zero word in the
BL808 table. The loader copies the stored value.
Related SiFlower images also have zero at `1FE`
and carry different trailers. The checksum match
is a clue to how the BL808-family value may have
been generated. Its hardware use remains open.
[ASCII zero checksum and controls](bl808_agc_microcode.md#ascii-zero-checksum-candidate)

The older Trident format has stronger trailer evidence. A Beken
BK7238 source revision changes word `1FF` from `150C0811`
to `160C0F0E`; the revised driver's event edits are dated
`20221215`. The new word's first three binary bytes read
year 22, month 12, day 15, an exact match. Its final byte
`0E` plausibly records hour 14 but has no independent label.
This supports date metadata for that legacy program, while
BL808's `C0088D03` still has an unknown format and use.
[Legacy trailer comparison](bl808_agc_microcode.md#trident-build-date-candidate)

The shipped SF16A18 MPW modules start hardware BIST and
check its match bit after loading the stock image ending
in `0C02A8D6`. Replay confirms that they release the
AGC FSM on success, mismatch, and timeout. The stored
result controls whether platform startup continues. The
SF16A18 full-mask module compares the entire load with
the file through `memcmp`. Its readback failure message
still says `bist timeout`. A trailer test on the MPW
modem needs the hardware match bit and reported signature.
[Shipped self-test and readback paths](bl808_agc_microcode.md#shipped-sf16a18-self-test-and-readback-paths)

With a 511-word firmware file, replay of both MPW modules
left word `1FF` at its initial RAM value and still invoked
BIST. The host accepted or rejected the result according to
the supplied hardware match bit. Replay of the later SF19A28
module also left that word intact and compared only the
511 supplied words. Its shipped firmware contains 512 words.
These checks narrow the loaders' behavior without measuring
whether hardware reads the final word.
[MPW loader replay](bl808_agc_microcode.md#shipped-sf16a18-self-test-and-readback-paths) ·
[FMAC loader replay](bl808_agc_microcode.md#siflower-restart-and-the-final-word)

The later SF19A28 module uses its full-length
readback on both startup and watchdog recovery.
In MIPS replay the host accepts a changed final
word when the copied bytes agree with the file
and reports a persistent mismatch at that word
after 100 comparisons. The host check establishes
copy integrity. The sequencer's use of the final
word remains unmeasured.
[SiFlower reload and trailer replay](bl808_agc_microcode.md#siflower-restart-and-the-final-word)

The November 2021 through August 2022 BL602 images
share the same 512 words, including `C0088D03`. The
October 2022 and November 2024 loaders keep the
trailer in the source array and stop their uploads
at word `13F`, beyond every decoded state. In 240
host replays of the BL602 and pinned BL808 load
slices, the full copies accepted four trailer
values through reset release. The short copies
preserved the destination trailer. The hardware's
own use of the final word remains unmeasured.
[BL602 loader comparison](bl808_agc_microcode.md#later-bl602-phy-uploads-only-the-first-320-words) ·
[Trailer replay](bl808_agc_microcode.md#trailer-access-through-reset-release)

The public `bl60x-wifimon` `phy.c` provides a
BL602 receive-only PHY setup and a 512-word AGC
loader. Its table matches the August SDK array
except for `44002001 → 44002C01` at word `01E`.
It still copies `C0088D03` to `1FF`. This gives
another comparison for selector `44`. The ADC peak
code, upper ADC and in-band comparator thresholds,
and the VGA ceiling match the August SDK.
[Monitor PHY source](https://github.com/stschake/bl60x-wifimon/blob/6ecdac63fa8b552d78e48c75d0a6653282d23423/phy.c#L367-L452) ·
[Selector 44 comparison](bl808_agc_microcode.md#receive-setup-words-0d-and-44)

The DA16200 lower-MAC archives retain debug
references to `phy.c`, `phy_da16200.c`, and
generated modem headers. The compiled RIU
definitions match SFAX8's four external event
reset words. The AGC RAM image uses a distinct
branch layout with operands starting at bits
25, 18, and 12. Its channel setter provides two
verifiable AGC profiles. It splits one 100-count
wait into two 50-count waits, sets bit 27 on the
new wait, and replaces its branch operand `01`
with `02` while preserving the destination.
Host replay confirms the exact writes. The
hardware timebase remains unmeasured.
[DA16200 loader, decoder comparison, and channel edits](bl808_agc_microcode.md#da16200-channel-dependent-agc-edits)

Nine DA16200 and DA16600 prebuilt images link the
same AGC table and preserve `14011D0D` across
their different flash-image CRCs. The linked
platform startup calls the same 512-word upload.
In 192 CPU replays, bit 20 of `0x60C03390` gated
the start of the copy. Once that bit was supplied,
the loader wrote each tested trailer and released
reset without a post-copy read. This locates both
the flash integrity check and the AGC write gate
outside the sequencer's execution. The hardware
meaning of BL808 `1FF` remains unresolved.
[Prebuilt images, flash checks, and loader replay](bl808_agc_microcode.md#agc-and-flash-image-validation-in-da16200-and-da16600)

The replay also separates the channel-dependent
`10` and `0E` extension settings from the host gain
limits and spur frequency. All three packages use
identical AGC words per channel despite different
`RWNXAGCGAINRANGE` values. Within the spur group,
the host writes a different `spur_frq` value per
channel and keeps the same AGC words.
[DA16200 package controls and RF writes](bl808_agc_microcode.md#package-settings-that-vary-independently-of-the-agc-words)

The AIC8800DC normal-mode SDIO and USB drivers
publish the same 512-word AGC array as the CSI
and RF-test binaries. Its startup state `S020`
has a single live coded exit on `P29` under the
inferred combiner rules. The BL602 and YoC images
use the same input number in a count-20 wait with
different destinations for `P29` and expiry. A
BL808 diagnostic at `S0BC` gives the low-`P29`
case its own address while preserving the stock
result under the model. The signal itself still
needs a hardware observation.
[AIC source and binary comparison](bl808_agc_microcode.md#aic8800-images-recovered-from-firmware-loaders) ·
[Single-input checks and BL808 diagnostic](bl808_agc_microcode.md#single-input-p29-checks)

The distributed power-save firmware contains dedicated
AGC tables. BL616CL fits its complete 66-state program
into the same 240-word transfer used by the BL808
low-power driver. BL616 uses 384 words and BL618DG
uses 512. The BL616 power-save PHY archive also pairs
DSSS-only and OFDM-only register settings with LNA
ceilings of 6 and 4, respectively, matching its
one-hot `P26` and `P27` startup routes.
[Low-power images and linked loaders](bl808_agc_microcode.md#dedicated-low-power-agc-programs) ·
[Mode and detector gate settings](bl808_agc_microcode.md#mode-flags-and-detector-gates-in-low-power-firmware)

The compact BL616CL program uses `P1D` alone
to leave either of its first two acquisition waits
for the DSSS setup and subsequent `P1F` and `P23`
decisions. This route bypasses the retained
`21` setup and stage-2 `29` result words. The
signal source behind `P1D` remains unverified.
[Compact DSSS acquisition path](bl808_agc_microcode.md#dsss-acquisition-in-the-compact-bl616cl-program)

The BL616CL v2.3.34 receive-test driver programs
`C0(17,00,00)` as the complete signal-detection
condition for entry `S008`. This isolates the
positive role of `P17` from the other operands
used by the normal BL808 driver. The physical
source of `P17` remains open.
[Receive-test event recipe](bl808_agc_microcode.md#receive-test-event-route-in-bl616cl)

Both BL618DG band programs also use page-0 `P17` to
return to the driver's signal-detection entry. The
branch isolates that operand when `P1B` and the earlier
conditions are clear. The older Trident operand `17`
has the same branch role as BL808's alternate qualifier
operand `1A`.
The AIC D80 DFS code can omit modern `P17` through
a separate option, while its receive delay and gain
limit change in either setting of that option.
[BL618DG RAM branch](bl808_agc_microcode.md#page-0-predicate-17-in-bl618dg-receive-re-entry) ·
[Trident numbering](bl808_agc_microcode.md#predicate-numbers-in-the-older-trident-encoding) ·
[AIC detector option](bl808_agc_microcode.md#detection-input-controlled-by-aic-dfs-mode)

Thumb replay of the D80 PCIe and USB binaries confirms
that bit 4 removes `P17` and bit 5 independently
changes two RF gain-control fields. DFS disable leaves
the bit-5 change at `0x4033C044[11:8]` in place and
restores the event operand according to the current
bit-4 value. Use the two bit-4 settings while holding
DFS active and bit 5 clear to isolate the `P17` input.
[Independent DFS options and replay](bl808_agc_microcode.md#separate-dfs-options-for-the-p17-input-and-gain-controls)

The BL808 vendor PHY clears the forced AGC memory clock
before releasing reset in both normal and low-power
initialization. The normal Nim PHY releases reset first.
Its immediate post-copy readback occurs before either
operation. The archived BL808 Wi-Fi and BLE control words
also have the AIC ROM-mode and RAM-ready bit positions
clear.
[RAM readiness and reset release](bl808_agc_microcode.md#ram-readiness-and-reset-release)

The published AIC D80N U02 and U02C initialization
images stage the same 512-word AGC table in SRAM.
The D80N RF-test image copies the identical table to AGC RAM,
including both nonzero trailer words outside the state graph.
It sets `AGCRAM_READY` and releases reset with no explicit CPU
check of either trailer word in that routine. The normal-boot
ROM path and any hardware interpretation of the trailer remain open.
[D80N RF-test copy](bl808_agc_microcode.md#d80n-rf-test-firmware-writes-both-trailer-words-to-agc-ram)

Compared with the D80 RF-test table, D80N changes one byte of
selector `0F` in a DSSS setup state with the same branch and
timed successor.
[D80N table comparison](bl808_agc_microcode.md#d80n-initialization-stages-the-same-table-on-two-silicon-revisions)

The D80N table uses `P2D` to select the middle
byte of a `0E` word with the same successor.
It also removes the first `P37` decision in a
two-stage return and keeps the second. Both
comparisons identify the inputs' control-flow
roles while leaving the signal sources open.
[D80N predicate paths](bl808_agc_microcode.md#d80n-predicate-changes-in-receive-setup-and-return)

| Transition bits | Field using the public RIU event layout |
| --- | --- |
| 31:26, 25:20, 19:14 | Event operands `OP1`, `OP2`, `OP3` |
| 13, 12:10 | Path combiner and operand combiner |
| 9 | [`PGSEL` in BL618DG event-register setters](bl808_agc_microcode.md#branch-bit-9-and-predicate-pages). Clear in every pinned BL808 transition. |
| 8:0 | Destination state word index |

The destination field lands on a decoded state start for every BL808
transition. The public RIU event registers independently use the same
nine-bit target field and their first four reset targets, `0x002`, `0x005`,
`0x008`, and `0x00B`, are state starts in both BL808 images.
[SFAX8 RIU event layout][sfax8-riu-events] · [AIC RIU header][aic-riu]

| Archived image | States | Transitions | Extension words | First padding word |
| --- | ---: | ---: | ---: | --- |
| Current BL808 Wi-Fi | 114 | 153 | 83 | `0x15E` |
| Older M1s BL808 | 96 | 127 | 67 | `0x122` |

The current image matches the Nim Wi-Fi array byte for byte. The M1s image
matches the Nim BLE table after adding its zero padding and final word.
Three additional BL606P archive images from PineVoice and YOC also decode
with every destination on a state boundary. Five of six tested SiFlower
images pass the same check. In the SF-AX3000 v3 high-band 20 MHz image, words
`0x101` and `0x105` both decode to `0x1A6`, which is inside another state.
The decoder flags this case.
[Pinned BL808 RF archive][bl-pinned-rf] · [M1s PHY/RF archive][m1s-rf-archive] ·
[PineVoice archive tree][pinevoice-repack-phy] · [YOC archive][yocop-phy-zip] ·
[SFAX8 image][sfax8-agc-image] · [SiFlower AX3000 images][sf-ax3000-agc-images]

The Beken and TizenRT Karst PHY archives supply three further complete
programs that use the same branch format. Comparing them isolates a
new timer-controlled retry on operand `31` and a tuning change specific
to the branch on operand `05`. The oldest two images isolate a
single extension-byte change and a different final word.
[Karst image comparison](bl808_agc_microcode.md#beken-karst-images-recovered-from-phy-objects) ·
[One-word trailer comparison](bl808_agc_microcode.md#a-one-word-karst-trailer-comparison)

Two BL616CL Wi-Fi releases differ by a single program
bit and both copy `C0088D03` to the final RAM word.
A CRC covering that bit with the same parameters would
change. The QCC743 default and manufacturing archives
also load the BL616 image with that word. QCC743's
low-power loader releases reset after copying only
384 words. These comparisons constrain the trailer's
role. Autonomous handling on BL808 remains unverified.
[BL616CL single-bit comparison](bl808_agc_microcode.md#bl616cl-loads-the-same-final-word-after-a-single-bit-program-change) ·
[QCC743 upload bounds](bl808_agc_microcode.md#qcc743-normal-and-low-power-copy-bounds)

In the current BL808 image, state `0x000` routes to `0x00F`. State
`0x00F` has four transitions through three-state chains. All four chains
rejoin at `0x039`. The older M1s image uses a single transition from
`0x00F`. This exposes a real control-flow change between revisions.

```text
00F -> 030 -> 033 -> 036 -> 039
    -> 01E -> 021 -> 024 -> 039
    -> 027 -> 02A -> 02D -> 039
    -> 015 -> 018 -> 01B -> 039
```

The strongest clue to timed behavior is header bit 27. Across every state
in both BL808 images and SFAX8, it is set exactly when at least one outgoing
transition uses operand value `2`. Header bits 26:15 are zero for all other
states. With bit 27 set, bits 25:15 encode values such as 1, 50, 100,
600 and 1500. In the current image, state `0x00D` encodes 50 and has
only the operand-`2` transition to `0x142`. This supports interpreting
bit 27 as timer enable and operand `2` as timer expiration.
Related BL616 images retain bit 26 even with the timer disabled.
BL808 state `0x04C` has count 50 in bits 25:15; the direct
timing sweep rules out treating bit 26 as a high count bit.
PineVoice's retry head retains bit 26 and returns on expiry
without issuing the BL616 retry action. A controlled comparison
at the BL808 timer-only entry `S00D` can still check whether
timer enable delays a constant-true branch. The separate RAM
chain already measured the tick and bit 26.
A parked-state BL808 probe then read RIU bank `01[0]` directly:
it turned on after about 100 µs with a 1,000-count timer and
after about 200 µs with a 2,000-count timer, while a disabled-timer
control stayed clear. The AGC fetch address remained parked.
This validates the observable timer-expiry flag independently of
the timer branch timing.
[Timer bit 26 comparison](bl808_agc_microcode.md#bit-26-in-the-timer-count-field) ·
[Controlled timer test](bl808_agc_microcode.md#a-controlled-timer-test-at-s00d) ·
[Parked-state timeout capture](bl808_agc_microcode.md#observing-expiry-while-the-state-stays-active) ·
[Pinned BL808 RF archive][bl-pinned-rf] ·
[M1s PHY/RF archive][m1s-rf-archive] · [SFAX8 image][sfax8-agc-image]

The Beken Trident driver's `RF_DOWN_ENABLE` switch adds
legacy operand `07` to the count-10 expiry branch at
word `01C`. SF16A18 uses `0D` at the same point in a
matched gain-setting sequence. The DSSS-associated
path also advances past the same receive adjustment
on `07` in Trident or `0D | 20` in SF16A18.
These are comparisons of branch roles. A trace can
distinguish radio programming completion from
correlator activity and compare the `P0D` and `P20`
exits after an identical BL808 adjustment.
[AliOS Trident PHY][alios-trident] ·
[RF-down qualifier comparison](bl808_agc_microcode.md#rf-down-qualifier-across-decoder-revisions)

A controlled Beken BK7231N source comparison found two 512-word AGC
arrays that differ only at `132: 8400013F → 84000163`. The newer
`phy_trident.c` comments that word “for rx sens”. It redirects
legacy operand `21` from a state issuing `61020202` to the same
state as operand `20`, which issues `41000000`. This is direct
source evidence for the intended receive-sensitivity routing
change, but it does not name the physical input or prove a
selector mapping to BL808.
[Commented branch and decoded context](bl808_agc_microcode.md#predicate-numbers-in-the-older-trident-encoding)

An exact-symbol GitHub search for `agc_ram_parameter` on
2026-11-21 returned 44 indexed files. The 37 driver-source hits
contained only four distinct first 512-word profiles; six other hits
were linker maps and one was a RAM emulator. The array comments
provide the receive-sensitivity note above and a broader
input-power/packet-error-rate tuning note, but no predicate decoder
or extension-action definitions. This is an audit of indexed files
with that symbol, not a claim about unpublished driver source.
[Source audit and limits](bl808_agc_microcode.md#public-decoder-source-audit)

The Beken SDK 3.0.62 history gives another control-word comparison.
After accounting for two insertions and relocated branch targets,
the BK7238 program changes one aligned state header
`0000139F → 0000339F` (bit 13) and two aligned legacy
selector-`14` actions `14EAED03 → 14EAED43` (low payload
bit 6). Legacy selector `14` is binary selector `0E` in the
later format. The source comments “for large signal” beside
relocated external-event targets, but the revision also changes
host settings, so it does not identify either bit's hardware
output. Its ATE-conditioned write remains at index `02E` after
the affected state moves to `02F`; that write is not a clean
bit-13 experiment.
[Matched-source comparison](bl808_agc_microcode.md#isolating-lower-state-controls) ·
[Selector-0E comparison](bl808_agc_microcode.md#selector-0e-and-0f-choices)

Across 33 related image entries, every ordinary-page
`P20` condition that can change with that input follows
a `0E`, `0F`, or `0C` extension. Both BL618DG bands
hold `P20` common while `P05` selects the continuation.
Three AX3000 low-band images take distinct routes for
`P20`, `P0D`, and timer expiry from the same gain
state. The pinned BL808 expiry path issues
`4100000F` on both sides of a six-count `3D030303`
step. Related images set and clear `33[0]` around the
same step or around a wait without any `3D` action.
The related diagnostic maps expose gain update
and RF programming completion on separate lanes.
The SFAX8 factory RF read gives a way to stimulate
the RF controller separately when checking those
lanes. BL808's physical inputs remain unverified.
The BL618DG watchdog handler also establishes that
the host sign-extends the seven-bit ADC power result.
[P20 branch evidence](bl808_agc_microcode.md#p20-after-gain-related-setup) ·
[Separate exits](bl808_agc_microcode.md#separate-exits-for-p20-p0d-and-expiry) ·
[Six-count receive step](bl808_agc_microcode.md#actions-on-either-side-of-the-six-count-receive-step) ·
[RF read and diagnostic lanes](bl808_agc_microcode.md#rf-controller-observations-for-distinguishing-the-exits) ·
[ADC and watchdog readouts](bl808_agc_microcode.md#readouts-for-gain-power-and-cca)

Extract and decode the original archive member with the read-only
[AGC disassembler](../tools/disasm_agc.py) from the repo root.

```sh
agc_tmp=$(mktemp -d)
riscv64-unknown-elf-ar p src/bl808/librf_bl808.a agcmem.c.o > "$agc_tmp/agcmem.o"
riscv64-unknown-elf-objcopy --dump-section ".rodata.agcmem=$agc_tmp/agcmem.bin" \
  "$agc_tmp/agcmem.o" "$agc_tmp/agcmem-copy.o"
python3 tools/disasm_agc.py "$agc_tmp/agcmem.bin"
```

Pass `--annotate` for the per-word program roles, `--word 0x05A`
for an individual word, or `--dot` for the control-flow graph in
Graphviz format. The branch-priority analysis records which
destinations can distinguish first- and last-match behavior.
The tool
expects the contiguous BL808 layout. It reports a nonzero exit status for
invalid records or destinations that miss a decoded state boundary.
[Branch priority and observable destinations](bl808_agc_microcode.md#branch-priority-and-observable-destinations)

Two BL808 RAM runs now establish first-eligible-slot ordering
for simultaneous constant-true branches with page and path bits
clear. The two-slot test swaps target order and C0/C1 true words;
the seven-slot test exercises every adjacent pair with controls
for every slot. All 27 cases reached one marker, and the image
was restored after each run. This resolves the earlier static
ranking ambiguity for the tested RAM branch domain. Host event
priority and predicates that change mid-decision remain open.
[Hardware priority traces](bl808_agc_microcode.md#branch-slot-priority-on-bl808)

The earlier BL808/PineVoice startup comparison narrowed C5 and C7.
The hardware sweep now confirms C5=`A & B & !C` and
C7=`A & !B & !C`. A separate four-word reorder of the startup
branch list remains useful for measuring branch priority, which the
combiner sweep does not settle.
[Startup comparison and trial words](bl808_agc_microcode.md#c5-and-c7-across-the-startup-programs)

The earlier Amlogic/AX3000/BL618DG comparisons left many C6 tables
possible. The BL808 RAM sweep now selects `54`; their conditional
route interpretations need re-evaluation under that measured table.
[Cross-image C6 comparison](bl808_agc_microcode.md#amlogic-w2-and-w2l-combiner-contexts)
The BL808 RAM combiner is now measured in all 64 constant-input
cases. Two hardware traces, with 50-count and 500-count marker waits,
agree on C0–C7 masks `FE 80 A8 EA FD 40 54 10`, where mask bit
`4A+2B+C` gives the branch result. In particular, C2 is
`(A | B) & C`, not the earlier majority hypothesis, and C6 is
`(A | B) & !C`. All repeated controls passed and every case reached
exactly one marker. This verifies the RAM decoder with page and path
bits clear; the external event decoder still needs its own check.
[Hardware trace and truth table](bl808_agc_microcode.md#all-eight-ram-combiner-truth-tables-in-one-capture)

The separate constant-input event word `04005805` tests C6 row
`101`, which is false in the measured RAM table. Event behavior
has not yet been checked against that result.

An archived BL602 PHY reconstruction writes the paired
`E7750800`/`64038800` C2 event recipe seen in the six BL808
C2 logs. The C6 logs change both event words, so those logs
cannot isolate C6. [Event-recipe comparison](bl808_agc_microcode.md#constant-input-c6-event-test)

The combiner bench image and its trace analyzer are in
[`examples/m0_agc_combiner_probe.nim`](../examples/m0_agc_combiner_probe.nim)
and [`tools/analyze_agc_combiner.py`](../tools/analyze_agc_combiner.py).
Both hardware runs completed and restored the stock image.
[Combiner truth-table capture](bl808_agc_microcode.md#all-eight-ram-combiner-truth-tables-in-one-capture)

Additional BL808 RAM probes varied the branch path bit 13 and
page bit 9. For all 64 constant-input C0/C1 combinations, the
truth masks remained `FE` and `80` under all four settings; two
runs with different dwell times agree. Timer operand `02` also
transferred at the programmed 100 or 200 µs deadline under all
four settings, while timer-disabled controls stayed parked.
The board's single selected receive path and these shared inputs
do not reveal how the path bit reduces different per-path signals
or how page 1 maps other physical predicates.
[BL808 path/page captures](bl808_agc_microcode.md#branch-bit-9-and-predicate-pages)

A separate parked-state probe now gives header bit 2 a measured
output effect. With bit 0 and bit 26 independently toggled,
RIU bank `02[14]` was high exactly when header bit 2 was set
in every sampled phase/bin group, both with the state timer
enabled and disabled. Published RIU maps name that output
`AGCDelayLineEn`. Bank `02[15]`, named `AgcFsmInit` or
`agcfsmctrl[0]`, stayed low in these CPU-polled windows;
bit 0 and bit 26 remain unassigned.
[BL808 state-control trace](bl808_agc_microcode.md#separating-bl808-header-bits-0-and-2-in-a-trace)

A subsequent one-bit sweep of all 15 lower header positions at
control bases `0000` and `000F` found two reproducible output
relationships. Header bit 2 also tracks RIU bank `05[4]`, named
`AGCOFDMFEEn_aligned` in both published diagnostic maps. Header
bit 3 tracks RIU bank `02[13]`, named `InBd20PowEstEn`. No other
tested bit changed those persistent high control lanes or the
bank-5 receive-event lanes in the parked state; the bank-3 gain
diagnostic stayed `3F40`. These names remain related-chip
interpretations of measured BL808 diagnostic bits.
[Lower-header-bit hardware sweeps](bl808_agc_microcode.md#one-bit-sweep-of-the-lower-state-controls)

An isolated sweep of all 11 distinct selector-`29` payload words
showed no direct change in the sampled idle gain diagnostic or RIU
bank-2 bits 13–15. Clearing external EVT2 kept every trial in its
parked state; an unmasked control read `3D7A9408` at EVT2 and
sometimes fetched its `S008` target. The extension's physical
output remains unresolved, and a test after its normal setup
sequence or a known receive signal is still needed.
[Selector-29 hardware control](bl808_agc_microcode.md#isolated-selector-29-output-probe-on-bl808)

An event-isolated BL808 sweep of all 64 predicate codes, repeated
for all four combinations of branch page and path bits, found the
same immediate-true set: `01 03 08 0F 10 21 2A 2C 2E 37 38 39 3A`.
Code `02` took its true branch only at the 1,000-count timer
deadline; every other code took the timer fallback. The parked
RIU bank-1 value was `0002`. This is a fixed-condition truth
vector, not physical naming. Forcing RX alone gave the same
results. Varying the readback-verified RC2 `REGMINGAIN4SAT`
value from `00` through `FF` left both `P03` and the candidate
bank-1 bit 1 high, so their numeric correspondence remains open.
The analogous readback-verified `REGMAXGAIN` byte sweep at the same
RC2 address left `P04` false and candidate bank-1 bit 2 low while
the applied gain remained `3F40`; it likewise does not identify the
physical input. [All-code BL808 predicate and gain-limit sweeps](bl808_agc_microcode.md#all-64-predicate-ids-in-an-idle-bl808-state)

With header bits 3 and 10 both set, an event-isolated factorial run
observed RIU bank `01[9]` in all eight combinations of bits 0–2;
neither bit alone produced it. Both related diagnostic maps name
that lane `PowerStable`. A fresh all-code branch sweep found `P1A`
newly true, but `P0B` stayed false even while the lane appeared
during its source-state observation. Thus the simple candidate
`P0B = PowerStable` is contradicted on this board; `P1A` is a
stronger candidate, still requiring an independent signal change.
[BL808 bit-10 interaction and predicate controls](bl808_agc_microcode.md#one-bit-sweep-of-the-lower-state-controls)

### RF SRAM receive capture

The archival Sipeed `rf_reg.h` at `0ba0c5b` is byte-identical to the
OpenBouffalo copy. Its RF SRAM definitions match both the instructions
and DWARF of `cli.o:cmd_sram_rx` in the M1s PHY/RF archive. The current M1s
BL808 BSP defines `RF_BASE=0x20001000`. The data path stays in the RF block
and M0 OCRAM. [Archival RF header][m1s-rf-reg] · [BL808 BSP RF base][m1s-rf-base] ·
[M1s RF SDK archive][m1s-rf-archive]

| BL808 RF address | Vendor field | Observed diagnostic behavior |
| --- | --- | --- |
| `0x20001220` | `RF_RX_TEST_SEL`, bits 10:9 | Takes the low two bits of `dump_sel`, which defaults to zero. |
| `0x2000123C` | `LINK_MODE`, bits 17:16, and `SWAP`, bit 18 | Clears both fields. DWARF defines mode 0 as independent, mode 1 as ADC triggers DAC, and mode 2 as DAC triggers ADC. |
| `0x20001240` | ADC done, enable, loop, and status clear at bits 0–3. Done count at bits 31:16. | Clears loop mode, enables ADC capture, polls done with a bounded wait, disables, then pulses status clear. |
| `0x20001244` | ADC start index at bits 31:16 and end index at bits 15:0 | Programs start `0x2000` and end `0x2000 + samp_num`. Default `samp_num` is `0x400`, so the programmed word is `0x20002400`. |
| `0x20001248` | 32-bit `RF_SRAM_ADC_STS` | Defined in the header. The checked `cmd_sram_rx` polls `ADC_DONE` instead. |

`cmd_sram_rx_addr` reports `0x22028000`. `cmd_dpd_lpbk_run` independently
uses RX start index `0x2000` and prints the same destination. That matches a
four-byte index into OCRAM from `0x22020000` for this configuration. The
reported destination aliases `0x62028000` in the Wi-Fi linker's general RAM
region. Reserve the backing allocation before testing and verify end-index
semantics. The diagnostic starts capture directly and prints its completion
message even if its polling loop times out. A hardware test needs the done
bit or count and a changing buffer, followed by validation of the tap,
sample rate, packing, and preamble timing. [BL808 memory map][bl-rm] ·
[Wi-Fi linker layout][bl-wifi-linker] · [M1s RF SDK archive][m1s-rf-archive]

#### Opt-in raw snapshot and offline estimator

On 2026-11-21, `m0_wifi_csi_snapshot_ram_probe` ran through the hardware
harness using `--jtag-load --no-jtag-reset` and the dedicated
`bl808_m0_wifi_csi_ram.ld` linker. The RAM image keeps code and writable
state above `0x22030000` and reserves the dump destination. The diagnostic
build uses `bl808WifiDebugContinuePhyAssert` because this board reports
`HDMVERSION=0x00010001` and the archived PHY checks for version 32; this
is a controlled bypass of that one startup assertion.

Both tap 1 and tap 0 returned `CSI1 status=0`, `probe_status=0`, 4,000
changed words at stride 1, no stray or extra writes, and `ctrl_done=0x00010003`.
The returned words and UART FNV32 checksums were independently checked:

| Tap | Nominal source rate from BL618 comparison | Unique words | FNV32 | Saved raw frame |
| --- | ---: | ---: | --- | --- |
| 1 | 40 MS/s | 172/4000 | `89321191` | [`tap1` log](../build/hw-validation/captures/bl808_rf_sram_tap1_2026-11-21.csi1.log) |
| 0 | 80 MS/s | 197/4000 | `A96B7545` | [`tap0` log](../build/hw-validation/captures/bl808_rf_sram_tap0_2026-11-21.csi1.log) |

The tap-1 words include `00370008` and `0037FFF8`. Interpreting their
halves as signed 16-bit values gives changing candidate I/Q samples; the
captured tap-1 ranges were I 24..83 and Q -40..24. Tap 0 had different
ranges, I 6..23 and Q -10..7. This confirms a live RF SRAM sample dump,
not the BL618 sample clock or I/Q orientation. The offline estimator found
no short training repetition in this packet-free capture, so it is not a
CSI result. A known CW signal and known OFDM packets are still needed to
validate spectrum direction, sample rate, and channel estimates.

The [RF capture image](../build/hw-validation/captures/bl808_rf_sram_capture_2026-11-21.png)
shows the first 512 candidate I/Q words, all 4,000 words as a density plot,
and an averaged relative spectrum for each tap. Its axes now use sample
index and cycles per sample; the BL618 rates above are not applied to
the image. Regenerate it with
`tools/plot_rf_capture.py` and the two saved CSI1 logs.

Channel-6 UDP traffic later yielded two 8,000-word tap-1 frames with a
legacy 16-sample short-training repetition and two long-training symbols.
Using the provisional 40-to-20 MS/s decimation and low-halfword-I ordering,
the offline decoder found LTF template scores `0.7542` and `0.7546`, repeat
scores `0.8323` and `0.8178`, and all 52 occupied OFDM tones. The two
normalized tone-magnitude vectors correlated at `0.936`. This is strong
evidence of packet I/Q and a repeatable relative channel estimate, though
the absolute clock and ordering remain hypotheses until checked with a known
RF tone. [First raw frame](../build/hw-validation/captures/bl808_rf_sram_hotspot_ch6_search64_udp1k_2026-11-21.csi1.log) ·
[Second raw frame](../build/hw-validation/captures/bl808_rf_sram_hotspot_ch6_stfsearch64_udp1k_2026-11-21.csi1.log) ·
[Estimator](../tools/wifi_csi_estimate.py)

The raw halfwords show a tap-dependent scale or format change. Tap 0's
upper/lower means are `14.024/-1.163` with standard deviations
`2.502/2.574`; tap 1's are `54.481/-4.895` with deviations
`9.050/9.621`. Every tap-1 lower value is a multiple of four, and
3,971 of 4,000 upper values are `3 mod 4`. After dividing tap 1 by
four, mapping the upper as `round((x+1)/4)` and the lower as `x/4`,
the tap histograms differ from tap 0 by total-variation distances
`0.062` (upper) and `0.047`
(lower). Narrow peaks at `0.1328`, `0.1543`, `0.3008`, and `0.4668`
cycles/sample align across taps. Because the captures were separate
and no known tone was supplied, this does not determine sample rate,
I/Q order, ADC width, or whether a peak came from RF input or internal
clock coupling. Both raw frames lacked a detectable OFDM short
training repetition in the offline estimator.

A later [8,000-word tap-1 capture](../build/hw-validation/captures/bl808_rf_sram_tap1_8000_2026-11-21.csi1.log)
also returned `status=0`, 8,000 changed words at stride one, no stray
or extra writes, and FNV32 `3EC70B79` (independently checked). Its
SHA-256 is `6e79867a7c0fcc7dd12daea38bcb060cc57c882ee0e43146fd313caf579957d9`.
The diagnostic reserves 8,192 words at `0x22028000`; its guard leaves
8,128 as the largest requested capture. Hardware is verified through
8,000 words, not yet at the last 128 positions.

The RAM-loaded [cadence probe](../examples/m0_wifi_csi_cadence.nim)
re-triggered 16 captures in succession at each of three lengths. Every
capture returned status zero, the requested number of changed words,
and no stray writes. The median end-to-end time per call, using the
board's 1 MHz `mtime`, was 6,403 µs for 256 words, 7,479 µs for 4,000,
and 8,629 µs for 8,000. The [256-word](../build/hw-validation/captures/bl808_rf_sram_cadence_256_2026-11-21.uart.log),
[4,000-word](../build/hw-validation/captures/bl808_rf_sram_cadence_4000_2026-11-21.uart.log),
and [8,000-word](../build/hw-validation/captures/bl808_rf_sram_cadence_8000_2026-11-21.uart.log)
traces preserve every duration. The current routine poisons and checks
the entire 8,192-word window on every call; these durations do not
isolate the hardware dump engine. They rule out an 8 kHz snapshot
cadence for this fully validating routine.

The same probe's `CsiFastMode=1` path poisons and verifies only the
requested words. Sixteen successive captures at each tested setting
all completed with every requested word changed. The measured interval
from enable through fresh done, using the 1 MHz `mtime`, was:

| Tap | Words | Engine duration | Whole fast loop iteration | Evidence |
| --- | ---: | ---: | ---: | --- |
| 1 | 256 | 7–8 µs | median 305 µs | [UART trace](../build/hw-validation/captures/bl808_rf_sram_fast_cadence_256_2026-11-21.uart.log) |
| 1 | 4,000 | 100–101 µs | median 4,354 µs | [UART trace](../build/hw-validation/captures/bl808_rf_sram_fast_cadence_4000_tap1_2026-11-21.uart.log) |
| 0 | 4,000 | 100–101 µs | median 4,354 µs | [UART trace](../build/hw-validation/captures/bl808_rf_sram_fast_cadence_4000_tap0_2026-11-21.uart.log) |
| 1 | 8,000 | 200–201 µs | median 8,704 µs | [UART trace](../build/hw-validation/captures/bl808_rf_sram_fast_cadence_8000_tap1_2026-11-21.uart.log) |

The near-linear engine durations imply about 40 million *dumped words*
per second for both tested tap settings. This is evidence about the RF
SRAM writer and does not establish the upstream RF sample rate or analog
bandwidth. In particular, the earlier 80/40 MS/s tap-rate assumption
cannot be used to label the spectrum. The fast mode does not scan the
64-word guard; its `stray=FFFFFFFF` field means unmeasured, not zero.

An independent check of the saved raw words found the same narrow peaks
at `0.13281`, `0.15430`, `0.30078`, and `0.46680` cycles per dumped word
in both 4,000-word taps and the later 8,000-word tap-1 capture. The
512-bin averaged log-power spectra of the separate tap-0 and tap-1
captures correlate at `0.949` across bins (`0.964` for tap 0 versus the
8,000-word tap 1). Applying the unverified 80/40 MS/s labels would place
the same normalized peak at twice the frequency on tap 0. The present
evidence supports a common dumped-word cadence and similar spectral
content, but does not distinguish clock coupling from an on-air signal
or establish the analog sample clock. A known offset tone with the radio
retuned is needed for that distinction.

The signed-halfword check independently reproduced tap 0 ranges
`I=6..23`, `Q=-10..7`, means `14.024/-1.163`, and tap 1 ranges
`I=24..83`, `Q=-40..24`, means `54.481/-4.895`. In the 4,000-word
tap-1 frame, all lower halfwords are divisible by four and `3,971`
upper halfwords are `3 mod 4`; the other `29` upper values are `24`,
`28`, or `32`. In the 8,000-word frame, all lower values are divisible
by four and `7,917` upper values are `3 mod 4`. This is strong evidence
of a tap-dependent quantization or packing transform, not a basis to
assign an ADC bit width. The captured amplitudes occupy only a small
part of the code range, so 10-, 12-, and 16-bit source widths remain
compatible. Upper-halfword signedness is also untested because every
captured upper value is positive.

With `CsiTimedMode=1`, `CaptureCount=64`, and `CsiWords=256`, the probe
scheduled 64 starts at 125 µs intervals on the 1 MHz `mtime`. Every
start offset was exactly `125 * index` µs at that timer's resolution;
all 64 fresh-done statuses were zero and four poisoned, spaced-out
word positions changed on each capture. The four-word hashes were all
distinct. The engine took 7–8 µs per capture. The
[timed UART trace](../build/hw-validation/captures/bl808_rf_sram_timed_cadence_256_8khz_2026-11-21.uart.log)
is SHA-256 `8c9ec79d108f38362ca543f56f80461e739b67a422893c1fcd5ba3496ef24072`.
This proves 8 kHz timed re-triggering of short snapshots; it does not
prove continuous sample phase between snapshots, RF audio demodulation,
or a sustained host transfer path. The timed probe checks four word
positions per frame, not the whole buffer or guard.

The plot displays only the first 512 words of each waveform, but the
saved frames contain 4,000 words each and a later tap-1 frame contains
8,000. At the observed 40-million-word/s *writer* cadence those lengths
would span 100 and 200 µs if each word represents one successive RF
sample; this remains conditional on validating the sample clock and
word meaning. The reserved destination is 8,192 words, and the current
guard limits requests to 8,128. The 8 kHz test scheduled 256-word
snapshots every 125 µs, leaving large gaps even under that conditional
sample-rate interpretation. Capturing all 256 words at 8 kHz would
produce 8.192 MB/s before framing, far above the current 230,400-baud
UART path. On-device reduction may support a sampled power/envelope
experiment, but continuous-phase demodulation and sustained raw RF
streaming are not established.

Reproduce without changing flash:

```sh
.venv/bin/python tools/hw_validate.py --test m0_wifi_csi_snapshot_ram_probe \
  --jtag-load --no-jtag-reset --uart /dev/cu.usbmodem13401
.venv/bin/python tools/hw_validate.py --test m0_wifi_csi_snapshot_ram_probe \
  --jtag-load --no-jtag-reset --nim-define CsiTap=0 \
  --uart /dev/cu.usbmodem13401
.venv/bin/python tools/hw_validate.py --test m0_wifi_csi_cadence \
  --jtag-load --no-jtag-reset --nim-define CsiWords=256 \
  --nim-define CsiTimedMode=1 --nim-define CaptureCount=64 \
  --uart /dev/cu.usbmodem13401
```

Use the currently detected runtime UART path when repeating these commands.

The experimental `m0_wifi_csi_snapshot` image is separate from normal Wi-Fi
RX. Its linker profile places writable state, heap, and stack in uncached WRAM
(`0x22030000..0x22050000`) and reserves `0x22028000..0x22030000` for the RF
dump. The normal Wi-Fi linker uses the cached alias of that OCRAM as live RAM;
running the dump against a normal Wi-Fi image would corrupt it. The snapshot
reads the uncached OCRAM view directly and uses the existing Nim `rfc_init`,
`phySetChannel`/`phy_set_channel`, and `rfc_rf_fsm_force` paths. It restores
the RF gain, ADC, dump, and force controls it changes.

The first capture is only 256 samples. It clears and checks the done bit and
poisons the whole reserved window. It accepts a fresh done only if at least
75% of sample slots changed in a consistent 1-, 2-, 4-, or 8-word stride,
with at most four other changed words. A full capture uses that observed
stride to bound the count and leaves at least 64 words of guard before WRAM.
A changed word just after the expected span is reported as `probe_end_extra`
or `end_extra`; this tests BL808 end-index exclusivity. `CSI1 BEGIN`,
sequential `CSI1 WORD` lines, and `CSI1 END` preserve all raw memory words,
including strided poison gaps, with a 32-bit FNV checksum. Failures and timeouts stop and clear the
engine, restore registers, and emit no valid CSI frame.

The I/Q decoder currently assumes the [BL618 SDR sample's measured
layout](https://github.com/will-tm/zephyr/tree/cb430c75aed7d4316d81844efacf1e2bdd97b3e6/samples/boards/bflb/bl61x_sdr):
upper signed 16-bit halfword I, lower Q, tap 1 at 40 MS/s. These are **not
yet BL808 measurements**. `tools/wifi_csi_estimate.py` accepts rate,
I/Q-order, and sample-bit-width overrides. It low-pass decimates to 20 MS/s, detects the repeated
legacy short training field, estimates coarse and fine carrier offset,
aligns the two long training symbols, FFTs them, and divides the 52 active
tones by the [IEEE 802.11a long-training sequence](https://s3-us-west-1.amazonaws.com/ptab-filings%2FIPR2023-01143%2F1014).
Its JSON contains raw words, metadata, quality scores, CFO, and complex
`H[k]`. Absolute amplitude is not calibrated to transmitter power or gain.

Build and offline check without a board:

```sh
.venv/bin/python tools/hw_validate.py --test m0_wifi_csi_snapshot \
  --jtag-flash --build-only --work-dir build/hw-validation-wifi-csi
PYTHONPATH=tools python3 -m unittest tools.test_wifi_csi_estimate -v
```

When the board is available, rerun `--list` and `--preflight` with the actual
runtime UART port, inspect the flash plan, and run this explicit manifest
test with `--jtag-flash --uart <port>` and a separate work directory. It is
excluded from the automatic smoke tier. Use repeated controlled legacy OFDM
packets on a known 20 MHz channel, with BLE inactive; the default is 2412 MHz.
Feed the captured UART log to `tools/wifi_csi_estimate.py --output csi.json`.

Remaining hardware gates, in order:

1. Identify the BL808 board and PHY version; confirm RF calibration, RX force,
   and restoration of the pre-capture RF controls.
2. Check the probe's fresh done transition/count, changed-slot stride,
   `probe_end_extra`, and untouched guard/WRAM. Compare uncached OCRAM with
   a cache-invalidated cached-alias read before trusting that alias.
3. Validate tap clocks, I/Q order, sign extension, and width with a known CW
   frequency on either side of center. The BL618 format is only a hypothesis.
4. Capture repeated known legacy OFDM packets, verify the raw preamble and
   LTF timing, and compare 52-tone estimates across stable captures. Retain
   the UART logs and JSON. A packet-free snapshot is not a CSI result.

Packet pairing during normal Wi-Fi RX and the direct modem candidates at
`0x24C008F8` and `0x24C00064` remain separate hardware investigations.

#### Audio-rate vibration using Wi-Fi packets

If no separate CW transmitter is available, a laptop can provide
both the audio playback and intermittent Wi-Fi illumination by
generating sustained, controlled packet traffic while its speaker
vibrates. Published wireless-vibrometry work demonstrates both
reflection from a loudspeaker and modulation of a Wi-Fi transmitter
co-located with one. It extracts an audio-rate signal from changes
in received strength as well as studying phase. This is a physical
precedent, not a BL808 result.
[Wireless vibrometry paper](https://xyzhang.ucsd.edu/papers/TWei_MobiCom15_Vibrometry.pdf)

The initial 8 kHz retrigger test recorded only sparse, unpaired RF power.
Later channel-6 captures did contain Wi-Fi short and long training fields,
so a packet-aligned LTF measurement became possible. Speech requires many
reliable, gain-consistent channel observations per second. A line must move
from 300 to 330 Hz with the played tone in every repeat before counting it
as acoustic evidence. This condition has not yet been met.

At 8,000 measurements/s, a packed 16-bit magnitude stream would be
16 kB/s, while a packed pair of 16-bit I/Q coefficients would be
32 kB/s before framing. The latter exceeds the present 230,400-baud
UART's roughly 23 kB/s payload ceiling. Buffering a short run in
RAM or reducing the output rate is needed for complex samples; text
hex lines cost substantially more. Packet detection is now possible;
achieving an audio-rate *decoded packet* stream is the remaining gate.

The laptop was moved from channel 36 (5 GHz) to the personal hotspot on
channel 6 (2.4 GHz, 20 MHz), verified by macOS before and after the
experiment. The RAM-loaded BL808 receiver was retuned to `2437 MHz`.
An [8,000-word channel-6 frame](../build/hw-validation/captures/bl808_rf_sram_hotspot_ch6_8000_2026-11-21.csi1.log)
passed the capture integrity checks but had no detectable legacy short
training repetition. A single 200 µs frame can easily miss traffic.

The [timed cadence diagnostic](../examples/m0_wifi_csi_cadence.nim) now has
optional `CsiFrequencyMhz` and `CsiPowerMode` build parameters. In power
mode it captures 256 words every 125 µs and computes an uncalibrated
energy sum from 16 spaced candidate I/Q words, centered at the idle
tap-1 means. It checks four poisoned positions for fresh data, not every
power sample. This is RF activity evidence, not decoded packets, RSSI,
or CSI. Processing all 256 words caused ~409 µs between starts; the
16-word version met every 125 µs start in the recorded runs. A 512-frame
idle run had 16 frames above five times its median power; bounded local
UDP traffic to the hotspot gateway raised that count to 79/512.
[Idle trace](../build/hw-validation/captures/bl808_rf_sram_hotspot_ch6_power16_idle_2026-11-21.uart.log) ·
[Traffic trace](../build/hw-validation/captures/bl808_rf_sram_hotspot_ch6_power16_udp_2026-11-21.uart.log)

For the sound check, the Mac sent roughly 1,000 local 1,200-byte UDP
packets/s to the hotspot gateway while the board captured 1,024 frames
over 128 ms. The silent control sent 28,946 packets during its 29 s
generator run. The repeated tone run sent 34,948 during 35 s; QuickTime
played a generated 300 Hz tone through the selected, unmuted MacBook Pro
speakers, and the output route was checked both before and after the RF
capture while playback was active. The earlier tone run is excluded
because the user observed Bluetooth audio switching. Both valid traces
had zero failed or late frames. The silent and verified-speaker traces
had respectively 165 and 174 frames above ten times their own median
power. [Silent trace](../build/hw-validation/captures/bl808_rf_sram_hotspot_ch6_power16_udp1k_silent_2026-11-21.uart.log) ·
[Speaker trace](../build/hw-validation/captures/bl808_rf_sram_hotspot_ch6_power16_udp1k_speaker300_2026-11-21.uart.log) ·
[Reference WAV](../build/hw-validation/captures/300hz_reference_45s.wav)

The reproducible [trace analyzer](../tools/analyze_rf_audio_trace.py)
uses a Hann window on log power, checks the 285–315 Hz bins against
200–400 Hz, and separately bins the eight RF frames per 1 ms packet
interval. In the frame-level view, the near-300 Hz peak was 3.51 times
the band median in **silence** (strongest of 26 bins) and 2.03 times
in the **speaker** run (third of 26). The packet-bin view gave 2.03
versus 1.99 times. Thus the 300 Hz component did not appear specifically
with the speaker. This experiment detected increased RF activity from
local Wi-Fi traffic but **did not recover the audible tone or speech**.
The 128 ms records and sparse, unpaired packet energy measurements are
insufficient to infer a sound channel; packet preamble detection and
gain-tagged, packet-aligned CSI or magnitude measurements remain the
next gate. The first 500-packet/s tone comparison was also unsuitable
for 300 Hz because its packet-rate Nyquist limit was 250 Hz.

Reproduce the power trace through the hardware harness, with the
current UART port and Wi-Fi channel checked again:

```sh
.venv/bin/python tools/hw_validate.py --test m0_wifi_csi_cadence \
  --jtag-load --no-jtag-reset --nim-define CsiFrequencyMhz=2437 \
  --nim-define CsiWords=256 --nim-define CsiTimedMode=1 \
  --nim-define CsiPowerMode=1 --nim-define CsiPowerSamples=16 \
  --nim-define CaptureCount=1024 --uart /dev/cu.usbmodem13401
python3 tools/analyze_rf_audio_trace.py <silent-uart-log> <speaker-uart-log>
```

##### Longer controls and packet CSI cadence, 2026-11-21

A separate [7,200-frame RF power diagnostic](../examples/m0_wifi_audio_power_trace.nim)
captured 0.9 s at 8 kHz with no failed or late starts in silence, a 300 Hz
speaker run, and a 330 Hz speaker run. The 300 Hz run had a suggestive
near-303 Hz power peak, but the 330 Hz control's strongest peaks remained
near 233 Hz rather than moving to 330 Hz. Rapid receiver gain changes and
unpaired traffic made the power peak unsuitable as an acoustic detection.
[Silent trace](../build/hw-validation/captures/bl808_rf_audio_ch6_7200_silent_2026-11-21.uart.log) ·
[300 Hz trace](../build/hw-validation/captures/bl808_rf_audio_ch6_7200_tone300_2026-11-21.uart.log) ·
[330 Hz trace](../build/hw-validation/captures/bl808_rf_audio_ch6_7200_tone330_2026-11-21.uart.log)

The [packet CSI trace](../examples/m0_wifi_packet_csi_trace.nim) now records
one timestamp, four LTF DFT magnitude-squared values at tones `−16`, `−8`,
`+8`, `+16`, and RIU bank-3 gain tags before and after each accepted packet.
Acceptance requires short-training repetition, a sparse legacy LTF template
match in both symbols, and LTF repetition. This is packet-aligned channel
amplitude data, with provisional I/Q order and clock, not a phase-coherent
complex channel. The on-chip sparse template still needs broader packet
validation against retained full raw frames. It buffers the records during
one second and prints them after the RF run, so UART output does not set the
capture cadence. The RF SRAM engine itself takes at most about 202 µs for
8,000 words; software packet processing took as much as 26.5 ms in the final
implementation. The first unoptimized implementation took 140 ms.

Five one-second hardware runs were completed for each condition while the
Mac sent about 1,000 local UDP packets/s to the channel-6 hotspot. QuickTime
played the 300 and 330 Hz WAVs through the selected MacBook Pro Speakers;
the output route was checked before and after each five-run set. The 330 Hz
set ended with output volume at 44%, whereas it began at 100%, so its
amplitude is not a controlled comparison. The decoded packet cadence fails
the tone test independently of that volume change:

| Condition | Decoded packets in each 1 s run | Median packet-gap range | Largest per-run 95th-percentile gap |
| --- | --- | --- | --- |
| Silence | 6, 7, 8, 18, 8 | 42–179 ms | 397 ms |
| 300 Hz | 7, 15, 2, 11, 4 | 58–162 ms | 291 ms |
| 330 Hz | 4, 5, 10, 10, 11 | 43–347 ms | 376 ms |

The 15 runs yielded 126 accepted records in about 15 s, or 8.4 decoded
packets/s overall; individual runs ranged from 2.0 to 17.8/s. Only 45 of
126 records had the same before/after gain tag. These irregular records
cannot resolve either 300 or 330 Hz, and **no tone line is counted as
recovered**. The host's 1,000 UDP sends/s are not evidence that the
receiver decoded 1,000 Wi-Fi packets/s. The measured ceiling belongs to
this RF SRAM snapshot and software decoder path; a hardware packet trigger
or direct CSI DMA is needed before an audio or speech claim is testable.
[All 15 audited runs](../build/hw-validation/captures/bl808_packet_csi_ch6_5x_each_2026-11-21.json) ·
[Cadence analyzer](../tools/analyze_wifi_packet_csi_trace.py) ·
[Example packet log](../build/hw-validation/captures/bl808_packet_csi_ch6_tone330_r5_2026-11-21.uart.log)

The packet recorder was built and run through `tools/hw_validate.py` with
`--test m0_wifi_packet_csi_trace --jtag-load --no-jtag-reset` and the current
UART. The harness dry-run passed; the UART-anchor harness tests passed
`52/52`. All 15 run logs contain the start/config/end markers and
`failure=0`. The analyzer rejects missing markers, bad probe stride,
nonmonotone timestamps, and mismatched record counts. A future sound test
must achieve roughly 1,000 gain-consistent packet CSI records/s with
millisecond-scale gaps and then show the tone line moving in all five
repeats of each condition.

##### Measuring receiver gain during the training symbols

The AGC disassembly identifies gain selection and application as separate
events. The related SiFlower RIU dictionary labels the low and high bytes
of bank 03 `AGCGainTgt0` and `RFGain0dB` respectively. On the BL808 packet
recorder this makes `0x24C0C924[31:24]` a candidate applied RF gain readout.
The BL808 RF register at `0x2000104C` independently reports the applied
LNA, mixer and two receive baseband stage codes. Previous snapshots match
several hardware codes to the RF lookup tables. The RC2 total gain byte
and RIU primary 20 MHz digital gain are additional candidates to check
against the actual SRAM tap. The instructions and register names do not
establish the conversion to dB at tap 1 or whether that tap includes the
RIU digital gain. [AGC gain readouts](bl808_agc_microcode.md#readouts-for-gain-power-and-cca) ·
[Applied RF gain codes](bl808_agc_microcode.md#rf-hardware-codes-for-the-startup-gain-index)

In the 15 archived runs, 81 of 126 records changed gain tags between
capture start and end. Of the 45 matching pairs, 39 were `0x3F` and six
were `0x02`. These reads bracket an approximately 200 µs dump, whereas
the two LTF symbols used by the estimator occupy 6.4 µs. The logs cannot
show the gain actually applied during that interval, even for equal
endpoint tags. The old analyzer's `stable_gain_packets` count measures
endpoint agreement only.

For a short calibration run, load the recorder with
`--nim-define CsiLtfGainTrace=1`. This polls four gain readouts during each
dump and emits one extra `RF PACKET TRACE LTF GAIN` row for each accepted
packet. The row contains the packet index, estimated start and end of the
two LTF symbols in µs, number of gain samples spanning an extra 2 µs on
each side, first and last sample times, largest adjacent-read gap, and
a bitmask of fields that stayed equal in the samples. The last four words
are the first raw RIU bank 03 (`0x24C0C924`), RF gain (`0x2000104C`),
RC2 status (`0x24C0C908`) and RIU digital gain (`0x24C0B210`) reads.
Mask bits 0–3 track the applied RIU byte, the four analog stage codes,
the RC2 total gain byte and primary 20 MHz digital gain in that order.
A sample count of zero means the reads failed to bracket the guarded
window. The time alignment uses the measured approximately 40 raw
words/µs and software timestamps, so sub-poll gain changes or an
unmeasured dump trigger delay can still invalidate a record. The diagnostic
stops at 64 packets to fit the RAM linker layout and adds polling work.
Use it to measure gain behavior before enabling any correction.

The first RAM load lost JTAG debug access after resume and produced no UART
marker. That run was stopped, so it supplies no LTF gain measurements.
The 64-packet build and analyzer were checked on the host.

Calibrate with the speaker silent, fixed geometry, and repeated legacy
OFDM packets from one identified transmitter at a fixed power. A Wi-Fi
transmitter can supply the training symbols. Alternate two or more
documented receive gain settings, check the applied RF codes, and exclude
clipped symbols and gain transitions within the LTF window. Measure the
change in median LTF bin power in dB between states and compare it with
the candidate fields. This distinguishes the scale and sign of the RF
gain field and whether the digital gain is present at the tap. Use
held-out silent packets to check that the correction removes the gain
step and check each bin for residual gain-dependent response. A test
with unlabelled frames from several transmitters cannot isolate
receiver gain from their different channels and transmit powers.

The trace's four `mag_*` values are already squared magnitudes. For an
applied gain difference `delta_db` relative to a calibrated reference
state, correct bin power with `P * 10**(-delta_db/10)`, or subtract
`delta_db` from `10*log10(P)`. For complex I/Q or CSI amplitudes the
factor is `10**(-delta_db/20)`. The calibration depends on the tap.
Validate direct CSI separately before applying a raw-tap correction there,
since a direct estimator may already account for gain. Correcting gain
does not increase the observed packet cadence. Keep the five-repeat
speaker criterion and cadence gate before interpreting spectra.

## Cross-Chip CSI Evidence

### BL808 register-map anchors

The archived `build/hw-validation/wifi_rf_rxcal_breakpoints.gdb.log` at line
149 records `0x0C822111` at `0x24C00000`. Under the QCC743 `HDMCONFIG` layout
this gives `RFMODE=2` (Karst in the AIC definitions), `NRX=NTX=NSS=1`,
`NSTS=2`, and `CHBW=0`. The HE and VHT bits are clear. The numeric fields here
come from the raw word. The following line of the old GDB script prints a
different derived tuple. The selected RF archive's `phy_get_version` reads
a second word at `+0x3C`, matching the location of QCC's `HDMVERSION`.
The archived configuration word alone leaves the BL808 modem revision
unresolved.
[BL808 PHY implementation][local-phy] · [QCC HDMCONFIG and HDMVERSION][qcc-config] ·
[RivieraWaves-derived mode constants][aic]

The earlier M1s and April 2023 Bouffalo PHY/RF archives report the raw
configuration word from `+0x0` in the first output and write zero to the
second output. Their complete 14-byte `phy_get_version` function appears
at Ox64 demo file offset `0x59762` and in both M1s E907 factory images.
The Bouffalo forum log has the corresponding output pattern
`version_phy_1=0C822111` and `version_phy_2=00000000`. This printing
convention leaves the actual `+0x3C` content unresolved.
[Bouffalo PHY/RF package][bl-early-rf] ·
[PINE64 demo release][pine-ox64] · [Bouffalo forum log][bl808-wifi-log]

The selected vendor `phy_init+0x1A/+0x1C` reads `+0x3C` for its clock-count
check. The current Nim `phyInitValidateClock` reads `+0x0` via
`modemVersionReg()`. This explains the existing UART diagnostic that logs
`version=0x0C822111 clk=0x0000010E` in
`build/hw-validation-wifi-apm-start-country-names-scan-device-20260610/logs/m0_wifi_nimfw_scan_hal_test.primary.uart.log`
at line 82. That scan completed. For CSI work, record both raw registers and
use `+0x3C` for the modem revision. [Nim PHY implementation][local-phy]

### Driver values across candidate SDKs

The BL808 baseline combines the archived board read and writes recovered
from the pinned PHY/RF objects. Reset words in the public headers describe
their own integration. ARCS exposes offsets and field masks in its modem
header. The driver objects also allow a comparison of the actual values
calculated for the same inputs.

| Field or operation | Verified BL808 evidence | Candidate comparison |
| --- | --- | --- |
| `HDMCONFIG +0x000` | Board read `0x0C822111`. Field masks give RF mode `2`, one TX and RX chain, `NSS=1`, `NSTS=2` and 20 MHz. | QCC743 and ARCS have the same field masks. QCC743's declared reset is `0x00220000`. |
| `HDMVERSION +0x03C` | Selected `phy_get_version` reads this offset. The live BL808 word remains unknown. | ARCS `phy_get_version` reads the same relative offset. QCC743 declares `0x01020000` as its reset value. |
| `MDMCONF +0x800`, `RXMODE +0x820`, `TXMODE +0x824` | BL808 driver masks use `0xF00/0xF0/0xF` for `MDMCONF`, `0x70/0x7000/0x03000000` for RX streams and bandwidth, and `0x700000/0x03000000` for TX chains and bandwidth. | QCC743 and ARCS match all eight offset-and-mask pairs. Older Beken's `+0x800` and `+0x820` are `RXMODES` and `FECTRL0`. |
| `SMOOTHCTRL +0x818` | M1s writes `0x01880C06`. | QCC743 declares that exact reset word. Older Beken declares `0x018C0C06`, a difference of `0x00040000` at `CFGSMOOTHFORCE`. ARCS defines the same offset and the QCC743 smoothing fields. |
| `DCESTIMCTRL +0x81C` and `SMOOTHSNRTHR +0x830` | M1s writes `0x00000F0F` at `phy_init+0x1DC` and the two smoothing thresholds `0x1B0F` at `+0xA4/+0xBA`. | QCC743 and older Beken both declare `0x00001B0F` for the SNR thresholds. The `DCESTIMCTRL` reset words are `0x02000A0F` and `0x8000110F`, respectively. ARCS agrees with QCC743 on both offsets and fields. |
| Channel setup at `+0x84C` and `+0x8EC` | Selected `phy.c.o:mdm_set_channel.constprop.0+0x46/+0x5E` writes `0x04000000 / center_mhz` into bits 14:0 at `+0x84C` and `(center_mhz << 15) / primary_mhz` at `+0x8EC`. HT20 channel 1 computes `0x6CAE` and `0x8000`, respectively. | ARCS `phy_custom_rf.o:mdm_set_channel.isra.0+0x8A/+0x96` implements both calculations at the same offsets. ESWIN `mdm_set_channel+0x212` matches the first. The QCC743 and ARCS headers name the registers `RXFOESTCTRL` and `RXCFOBIASEST`. |
| PHY clocks `+0x874` and reset `+0x888` | M1s uses clock-force bits 27 and 29 at `+0x874` and pulses reset word `0x1111` at `+0x888`. | ARCS puts the matching two clock fields in CRM `+0x010`. Its `crm_mdm_reset+0x14/+0x42` pulses `0x111` at CRM `+0x018` with a different reset-bit map. Older Beken labels modem `+0x874` `TDFOCTRL2` and puts `SWRESET` at `+0x894`. |
| RC2 AGC and LNA fields | M1s and the pinned build use the same LNA table byte layout and AGC threshold masks. The pinned build sets the continued DSSS threshold to `0x36`, where M1s sets `0x40`. | The [published BL602 header](#published-rc2-register-accessors) matches 30 M1s offsets and 28 masks at a different base. |
| CSI status `+0x064` and control `+0x8F8` | BL808 implementation and live values remain unverified. | QCC743 and ARCS match all six field masks. BK7236 explicitly writes `3` to control and tests bit 0 of status. |

The ARCS object matches the two channel arithmetic operations. The
[published SFAX8 driver C](#published-siflower-and-beken-driver-c) is the
closest source-level match for the older BL808 initialization values.
For each new driver candidate, trace `phy_get_version`, `phy_init`, and
`mdm_set_channel` against the pinned BL808 objects. Compare modem-relative
offsets and masks, then compare literal writes and values calculated from
identical channel inputs. For the exact BL808 source claim, verify the
absolute register bases, clock and reset sequence, and archive provenance.
The numeric extraction of 13 common named offsets, 31 field masks, and
four test frequency pairs is in
`build/hw-validation-wifi-source/driver-register-comparison.tsv`.
[BL808 PHY archive][bl-pinned-rf] · [M1s PHY/RF archive][m1s-rf-archive] ·
[QCC modem header][qcc-config] · [ARCS modem header][listen-mdm] ·
[ARCS clock header][listen-crm] · [Older Beken header][bk-old-mdm]

### QCC743 register definitions and actual driver

The [QCC743 generated WLAN register directory][qcc-reg] contains a public
definition of the CSI register pair. Its `reg_mdm_cfg.h` matches the BL808 modem base and
reports `RFMODE` reset value `2`. [RivieraWaves-derived AIC definitions][aic]
label PHY mode `2` as Karst. This is a family clue, not evidence of the exact
BL808/QCC743 hardware configuration or that either shares a complete register map.

| QCC743 register | Relative offset | QCC743 address | Documented fields |
| --- | ---: | ---: | --- |
| [`CSIRDCTL`][qcc-control] | `+0x08F8` | `0x24C008F8` | bit 1 `CSI_RDENABLE`, bit 0 `CSI_RDREQUEST`; software read/write |
| [`CSIRDSTAT`][qcc-status] | `+0x0064` | `0x24C00064` | bit 0 ready, bit 1 error, bits 7:4 format, bits 10:8 bandwidth; software read-only |

Both register definitions are gated by [`RW_NX_CSI`][qcc-guard], which the
header defaults to `0` unless already defined. That default controls C header
visibility; it neither enables/disables hardware nor proves that a particular
firmware build uses these registers. QCC743 is a newer Wi-Fi 6 implementation.

The tracked [QCC `csidma_cmd.h`][qcc-cli] declares CSI DMA start, stop, ready,
and debug commands, plus optional FTM commands. The [official Bouffalo Wi-Fi 6
CLI][bl-wifi6-cli] exposes these under `CFG_CSIDMA_CLI`, with FTM separately gated
by `CSIDMA_FTM_ENABLE`. Copies of the header also turned up in public searches
of `zxf1023818103/bouffalo_sdk` (`components/wireless/wifi6/include/csidma_cmd.h`)
and `cwierzbicki00/qcom`. These are Wi-Fi 6 SDK leads, not BL808 support claims.

The [QCC MAC archive][qcc-lib] contains real implementations, not just
declarations. Its GNU archive symbol index identifies:

| Object | CSI-related symbols |
| --- | --- |
| `csidma.c.o` | `csidma_start`, `csidma_stop`, `csidma_buffer_ready`, `rxl_csidma_int_handler`, `csidma_enable_debug` |
| `csidma_cli.c.o` | `cmd_csidma_start`, `cmd_csidma_stop`, `cmd_csidma_ready`, `cmd_csidma_debug`, `csidma_cli_handler` |
| `intc.c.o` | `csidma_intc_register` |

DWARF in `csidma.c.o` identifies the driver source as
`components/wireless/qcc74x_macsw/plf/refip/src/driver/csidma/csidma.c`. The
tracked tree contains the declaration and binary. Disassembly and DWARF macro
records recover the driver-facing interface:

| Operation | QCC743 `csidma.c.o` |
| --- | --- |
| Start | `csidma_start+0x112` writes the payload pointer to slot `n` at `0x24C70020 + 0x20*n`. It writes the sender filter at slot `+0x4/+0x8`, the trigger interval in milliseconds at `+0xC`, and CSI mode (bits 5:4) and timestamp mode (bits 9:8) at `+0x10`. At `+0x170` it calls the helper that sets ready bit 0 in that same register. For the first active slot, stores at `+0x194/+0x19C` set controller enable bit 0 at `0x24C70000` and IRQ enable bit 2 at `0x24C70004`. |
| IRQ | `rxl_csidma_int_handler+0x08/+0x10` reads IRQ control and extracts the completed slot from bits 6:4. At `+0x124` it reads the slot timestamp at slot `+0x14`, stores it in the record, and calls the registered callback at `+0x132`. The valid-slot path acknowledges through IRQ bit 1 at `+0x14E`. The CLI installs `rxl_csidma_int_handler` through `intc.c.o:csidma_intc_register+0x04`, at low-level handler table index 42. |
| Storage | The ELF places six `0x80C`-byte software records in `csi_bufs` in `.wifi_ram`. Each record has a timestamp at `+0x38` and 2,000 bytes of DMA storage at `+0x3C`. The linked firmware supplies the RAM address. The storage size is the buffer capacity. |
| Re-arm | Return `CSIDMA_BUF_READY` (`1`) from the callback for immediate re-arm or `CSIDMA_BUF_KEEP` (`0`) to hold the buffer for consumption. `csidma_buffer_ready+0x06` invokes the same helper for valid slots. The helper sets slot `+0x10` bit 0 at `+0x12`. |
| Stop | `csidma_stop+0x52` clears the software active flag, then `+0x8C..+0xA8` zeroes the payload pointer, sender filter and interval and clears the timestamp-mode bits. On the last active slot, `+0xCE/+0xD6/+0xDC` disable the IRQ, acknowledge pending completion and disable the controller. |
| Decode | `csidata.c.o:csi_gen_report+0x104` stores `nsc=52`. At `+0x10E..+0x120` it chooses a coefficient input base of payload `+0x1C` or `+0x194` depending on decoded stream information. The loop at `+0x13A..+0x156` fills 52 pairs using bits 12:0 and 28:16, shifting each lane left three into an `int16_t`. DWARF sizes the matrix as `int16_t[2][120][2]`. The actual hardware write length is unknown. |

The interrupt archive names index 42 `INTC_DMA_CSIDMA`.
`intc.c.o:interrupt0_handler+0x5E` reads the interrupt index from
`0x24910040` and dispatches through the table at `+0x68/+0x6E`.
The QCC743 WFA linker script places `.wifi_ram` in `.wifibss` within
`ram_wifi`. With `wifi_main` defined, this region begins at `0x23011800`.
The exact `csi_bufs` address depends on the linked image.
[QCC MAC archive][qcc-lib] · [QCC743 WFA linker layout][qcc-wfa-linker]

In the examined driver, capture, completion, and payload delivery go through
the dedicated CSI DMA block. The optional FTM branch accesses timing and PLL
registers. There are no software accesses in `csidma.c.o` to `0x24C008F8`,
`0x24C00064`, or `0x24C09000`. Whether the DMA hardware uses any of the
direct-read logic internally is unknown.
The pinned mirror archive SHA-256 is
`ce2689f63dff54edb1fb6f83c8cd82ecb35acabe1f0634d5d5dca9a69385023f`.
CodeLinaro releases at `8befa431` and `964374a8` have the same
`.text.csidma_start` bytes. [QCC MAC archive][qcc-lib] · [CodeLinaro SDK][qcc-official]

The CodeLinaro tree at `964374a8` also exposes `csidma_capture_start` and a
Python collector for hostless, NCP, and RCP reports. The compiled capture
wrapper registers the same interrupt handler and calls `csidma_start`. The
collector assembles complex numbers from signed I/Q
pairs and labels a 52-tone report as `-26..-1, +1..+26`. It preserves
timestamp, peer MAC, RX format, RSSI, and stream count. This supplies a
public example of the packet-to-estimate contract the BL808 effort needs.
[QCC capture API][qcc-capture-api] · [QCC host collector][qcc-collector]

Bouffalo's Wi-Fi 6 SDK at `ad2a37b8` contains `csidma.c.o` in the BL616
default, bridge and coexistence archives and in the BL616D and BL616L default
archives. All five have identical `.text.csidma_start` bytes and use
`0x24C70000`. This establishes a Bouffalo software implementation on the
BL616 lineage. The repeated code across the five builds counts as one
implementation for the register comparison. [Bouffalo MAC archives][bl-mac-archives]

### Beken BK7236 Karst direct readout

The [BK7236 `libwifi_csi.a`][bk-lib] was checked at commit
`650e754e12fe1e43c37ce2316a973668b033fd48`. Its `phy_karst_bk7236.c.obj` is
ARM code and retains DWARF for
`/armino/properties/modules/wifi/ip_ax/macsw/plf/refip/src/driver/phy/phy_karst_bk7236.c`,
built under `/armino/build/properties_libs/bk7236`. Observations from the object:

1. `csi_info_get_enable+0x0E` writes `3` to `0x498008F8`, setting the two bits
   named by the QCC reference.
2. `print_csi_report_info+0x2A` reads `0x49800064` and tests bit 0. Subsequent
   reads extract format bits 7:4 and bandwidth bits 10:8. It filters by format
   and configuration before reading coefficients and clears the control word
   on cleanup. The relative offsets and field positions agree with QCC743.
3. `csi_info_read` accesses the coefficient window at `0x49809000` (literal at
   function offset `0xE4`). This is BK7236-specific evidence. Adding `+0x9000`
   to the BL808 modem base reaches the BL808 LDPC-loading window discussed above.

The Beken sequence forces the PHY bus clock and uses both the TX and RX paths.
`csi_info_report_setup` sets bit 8 at `0x49850010`. Its inlined DWARF name is
`crm_phyahbclkforce_setf`. The arm call in `txl_cntrl.c.obj:txl_transmit_trigger`
requires the CSI start flag, a TX data frame, bit 23 in `tx_hd.statinfo`,
and a nonzero descriptor field. Bouffalo's MACSW header names the matching
status bit `FRAME_SUCCESSFUL_TX_BIT`. `rxl_cntrl_evt+0x14A` runs on an RX
data frame and passes its format and descriptor metadata into the readout.
The report helper checks the ready bit, requires matching format and
20 MHz bandwidth, copies selected 32-bit words, and clears the control word.
A timer covers the request lifetime. A test patterned on this path needs a
successful outbound data packet and an inbound data packet within the arming
window. The BL808 clock-force bit and trigger remain unverified.
The BK7234 and BK7258 CSI archives have byte-identical `.text.csi_info_read`
to BK7236 and use the same enable/status offsets.
[Beken SDK archives][bk-archives] · [Bouffalo TX status definitions][bl-tx-status]

### BL808 direct-read control check (2026-11-21)

#### Flash-boot control before further CSI tests

The unmodified `m0_hello_nim_test.nim` was flashed through the same JTAG
flash/reset-capture harness path as the direct CSI scan probe. The flash stub
verified boot2, both partition tables, and the small firmware image, but UART
printed no `Hello from Nim!` during that capture. The FTDI nSRST pulse also
failed to make the stock hello image print. After a physical board reset, a
JTAG snapshot put the M0 PC at `0x58000E72`, which disassembles to the hello
program's final WFI loop. Thus flash boot did run; the short startup message
had finished before the subsequent UART capture began.

The RAM UART anchor answered ping and JEDEC ID `0x1860EF` when JTAG used
`--no-jtag-reset`. The harness UART-anchor flash path had an unconditional
`reset halt` despite that flag; it now honors the flag. The anchor then
verified the hello image in flash, but its old reboot routine pulsed
`GLB_SWRST_CFG2[5]` and remained in its final wait loop. A trial pulse of
bit 2 did not produce UART output. The [BL808 reset table][bl-rm] identifies
bit 0 as software power-on reset of M0, while bit 2 is a system reset that
does not include the M0 CPU in that table. Both the RAM C anchor and persistent
Nim anchor now pulse bit 0. The corrected anchor built and its harness tests
passed. After the physical reset restored UART and JTAG access, the harness
loaded the corrected RAM anchor, verified the stock hello image in flash,
sent the UART reboot command, and captured `Hello from Nim!`; the
`m0_hello_nim_test` run passed. The software reboot path is now hardware
validated. This clears the flash-boot control gate for the normal-firmware
CSI data probe. The read-only and forced-RF observations below are separate
from that probe.

When that Wi-Fi probe later stalled and the M0 JTAG scan returned IDCODE 0,
the FTDI nSRST helper reported a successful pulse but did not restore the
TAP. The [Ox64 schematic][ox64-schematic] shows the five-pin J6 connection
has four JTAG signals plus ground and no nSRST connection. Cycling the
switchable upstream USB hub port `0-1` port 3 with `uhubctl` disconnected
and re-enumerated the UART and JTAG adapters. The harness then passed M0
OpenOCD preflight again. In this bench setup, this is a verified host-side
recovery route even when the flashed firmware no longer runs the UART anchor.
With JTAG restored, `--uart-anchor-reboot --no-jtag-reset` loaded the RAM
anchor, read JEDEC `0x1860EF`, and issued the M0-inclusive reboot without
flashing. The `--uart-anchor-existing --no-jtag` reboot form also succeeded
after a RAM anchor probe. In both cases a later JTAG read found the stock
hello image in its final WFI loop at `0x58000E72`.

#### CRM and candidate CSI DMA address check

The Beken `crm_phyahbclkforce_setf` write is at Beken base `0x49850010`.
Adding the same offset to the BL808 modem base was a proposed experiment,
not a verified BL808 register mapping. Harness JTAG reads on the running
stock hello image found `0x24C50000 = 0x0C822111` and
`0x24C5003C = 0x00010001`, exactly matching `0x24C00000` and
`0x24C0003C`. The `+0x10` through `+0x20` reads also matched word for word.
This is evidence of a mirrored modem decode at `0x24C50000`; writing bit 8
at `0x24C50010` would not be a justified clock-force experiment.

The local PHY port uses CRM base `0x24940000`, copied from a BL616 CRM
object: `crm_init()` modifies `+0x10` bit 27, `crm_clk_set()` modifies
`+0x08`, and `crm_mdm_reset()` pulses `+0x18`. A JTAG read while the flashed
Wi-Fi probe was halted returned `0xDEAD5555` at each word from
`0x24940008` through `0x24940018`. That pattern does not validate this
CRM window on BL808, so no clock-force write was made there. The
[ARCS CRM header][listen-crm] also omits bit 8 in its `+0x10` force field.
The Beken PHY AHB bit cannot be transferred to BL808 by offset alone.
The pinned BL808/M1s `phy_init` does use documented force bits 27 and 29
at modem `0x24C00874`; an opt-in RAM probe can use bit 29 as a same-block
writable control while retrying the candidate direct CSI register.

The first attempted run with that opt-in clock probe did not reach the clock
or CSI writes. After rebooting into the known-good flashed hello image, a
fresh `--jtag-load` of `m0_wifi_packet_csi_trace` timed out at
`RF PACKET TRACE START`. Its stage log reached `F403` but not `F404`,
placing the stall inside `runRfPriFullCalRestoreBaseline`. JTAG showed the
M0 in the `sampleMtimeUs`/`rawDelay` loop, with no trap, and read
`0x24C00874 = 0`. This run cannot determine whether the modem clock-force
bit changes CSI control readback; RF initialization must advance beyond
`F404` before that test has meaning.

Read-only JTAG probes of the QCC CSI DMA candidate `0x24C70000` returned
`0` at `+0x00`, `0x70` at `+0x04`, and repeated `0xB02FFA10` at several
neighboring offsets. This is neither a clean all-zero absence result nor
evidence that the candidate block implements CSI DMA. No DMA write has been
attempted.

An opt-in check in `m0_wifi_packet_csi_trace` accessed the candidate pair on
live hardware through `tools/hw_validate.py`. After `rfc_init` and
`phySetChannel`, before forcing the RF receive state, the probe wrote `2`
(enable) and then `3` (enable plus request) to `0x24C008F8`. Both immediate
readbacks were `0`. A second write of `3` after RF receive forcing also read
back `0`. During 1,140 raw capture attempts with four decoded packet
candidates, the status at `0x24C00064` stayed `0`, and the hash of 52 words
starting at `0x24C09000` stayed `F38E81E8`. The modem bus was live:
`HDMCONFIG=0x0C822111`, version `0x00010001`, and clock control at `+0x874`
was `0x08000000`. The UART evidence is in
`build/hw-validation/captures/bl808_direct_csi_pre_force_readback_2026-11-21.uart.log`.

These observations make the QCC743/Beken control address a weak BL808 candidate.
They do not rule out a write-only control, a missing PHY bus-clock prerequisite,
or a path that works only under the normal MAC. The raw capture probe used
forced RF receive and did not perform the Beken-style successful outbound
data-frame arm. A prior 1-second run had 13 packet candidates and the same
zero control/status readbacks and unchanged coefficient-window hash.

The first normal-firmware probe also had a test-design error: it scanned only
management frames and restored the control word before connection and data
traffic. Its firmware produced no UART output in the current flash run, so it
gave no direct-read result. A reset-and-attach harness run timed out after
30 seconds without a UART banner; the failure snapshot still showed live
`HDMCONFIG=0x0C822111`, version `0x00010001`, CSI status `0`, and CSI control
`0`. This does not establish that the probe reached its control write. The data
probe now keeps the control active through connection and three outbound
keepalive data frames, records inbound data-frame counts, requires at least
one inbound data frame, and dumps/restores the control afterward. After the
UART-anchor reboot was fixed, this data probe was flashed and launched. It
printed `=== BL808 WiFi HAL Test ===`, then stalled in backend initialization
before `DIRECT CSI PROBE ARMED`; the harness timed out after 180 seconds.
A later JTAG snapshot put PC at `0x58067516` in `delayMtimeUs`, with no trap
recorded in `mepc` or `mtval`. This is a Wi-Fi startup failure, not a CSI
control result. Its early
write is still not the Beken TX-completion arming sequence. A true positive
requires an RX-data-correlated ready event and changing coefficient words,
not merely a nonzero control readback.

A second JTAG run used `--jtag-memory-log` on the flashed probe. The harness
could not read its ring metadata and fell back to uninterpreted buffer bytes;
it also timed out without a UART marker. Do not treat those bytes as a startup
trace or as evidence that the CSI control write ran.

Running that exact Thumb routine in an instruction emulator with an indexed
test pattern at `0x49809000` establishes what the Beken copy loop exports.
The length at output offset `0xE` counts 32-bit words. The output begins at
`0x10`, and all retained words match the input bit for bit.

| Format argument | MMIO words read | Words exported | Source word indices retained |
| ---: | ---: | ---: | --- |
| 0 | 52 | 48 | Within 2–54, skipping 7, 21, 28, 35, 49 |
| 2 | 52 | 52 | Within 0–56, skipping 7, 21, 28, 35, 49 |
| 5 | 240 | 238 | Within 0–244, skipping 101, 115, 121, 122, 123, 129, 143 |

Other format arguments tested between 0 and 8 exported zero words. This
exercise verifies the copy and selection logic. The meaning and packing of
the input words require data from a live modem. [Beken CSI archive][bk-lib]

The local harness work directory `build/hw-validation-wifi-csi-flash/research`
contains `beken_csi_copy.log` and `emulate_beken_csi.py`. The latter takes
the BK7236 archive path and extracts the executable section with LLVM.
The run used Python 3.12 and Unicorn 2.1.4.

The [Beken build recipe][bk-build] selects a CSI-enabled archive when
`CONFIG_WIFI_CSI_EN` is set. The [public CSI example][bk-example] registers
`bk_wifi_csi_info_cb_register`, sets a CSI configuration, and enables reports.
The [public report type][bk-types] includes RX metadata, sender MAC, length, and
a storage capacity of 240 `uint32_t` words. That capacity is not a fixed tone
count or a BL808 software ABI. Together these sources establish a working design
for another Karst implementation, not a firmware binary that can run on BL808.

## Repository and History Search

The search moved from searching generic descriptions to checking actual tracked
filenames, paths, branches, tags, mirrors, and binary object names. This produced
more useful evidence than looking for a repo labelled "RivieraWaves source".

| Lead | Result |
| --- | --- |
| [SiFlower `1806_SDK`, SFAX8 factory Wi-Fi tree][sfax8] | Tracked `reg_mdm_cfg.h`, `reg_mdm_stat.h`, `reg_macbypass.h`, `reg_riu.h`, `agc_ram_bin.h`, and `phy_aetnensis.c`. Good register and AGC comparison; Aetnensis, not Karst. The checked header had channel-estimator/memory clock controls but did not name the QCC `CSIRD*` pair. |
| [QCC743 WLAN register tree][qcc-reg] | Full `reg_mdm_cfg.h`, `reg_macbypass.h`, `reg_riu.h`, `reg_rc.h`, `reg_la.h`; `_reg_mdm_cfg.h` is only a base/size wrapper. The same numerical offset in the separate RF block is not a modem register. [CodeLinaro][qcc-official] is the upstream repository lead; the GitHub mirror was directly inspectable. |
| [PINE64 `bl602-re` Karst compatibility directory][bl602-karst] and [register blobs][bl602-blobs] | Karst-path headers exist, including `reg_mdm_cfg.h`, `reg_mdm_stat.h`, `reg_macbypass.h`, `reg_mdmdsss_cfg.h`, `reg_rc.h`, and `reg_riu.h`. These are narrow compatibility headers. The fuller BL602 `reg_bl_rc2.h` in `blobs/reg` duplicates the historical SDK accessor code and has 28 verified offset-and-mask matches. The apparent PHY implementation is a [DWARF reconstruction][bl602-dwarf-recovery] with stub bodies. |
| [Older Beken FreeRTOS build recipe on Gitee][bk-old] | The `CFG_IEEE80211AX` branch names `beken378/ip_ax/macsw/plf/refip/src/driver/phy/phy_karst.c` and a DMA implementation. A full path history walk across five branch heads and 22 tags located the Trident implementation and older generated modem headers. No candidate Karst or CSI DMA source file appeared in the 33 reachable commits. |
| Beken SDK forks and downstream trees | `quectel-official/F02D`, `dreamcmi/fc41d-pikascript`, and `dawmlight/device_beken` exposed duplicate older `reg_mdm_cfg.h`/`reg_mdm_stat.h` blobs and Trident material. The MOC108 trees `asrlora/alios-asr-lora` and `RiceChen/R_Plan` were another duplicate pair. Useful for comparison, not evidence of a Karst source release. |
| [AliOS Things upstream][alios] | Ceva's 2019 RISC-V Wi-Fi demonstration used AliOS Things. A path-history walk over 25,359 reachable AliOS commits located public Trident C and modem headers for Beken platforms, including a BK7231U driver blob distinct from the Gitee SDK. No tracked `phy_karst*.c`, `phy_custom_rf.c`, `rxl_cntrl.c` or `csidma*.c` appeared in that walk. [Ceva announcement][ceva-alios] · [AliOS Trident PHY][alios-trident] |
| [Historical Sipeed M1s SDK][m1s-phy-history] | The current public main and the separate lineage referenced by OpenBouffalo's RF-header source comprise 92 reachable commits. Tracked PHY headers in the older lineage supply the RF SRAM map. Searches across both histories found no `phy_karst*.c`, `reg_mdm_cfg.h`, or `csidma*.[ch]`. Both lineages publish identical Wi-Fi and BL606P PHY/RF archive blobs. |
| Other BL808 repositories | `9names/bl808-data` has a generic peripheral description. `9names/bl808-sdk-header-tools` had GLB headers and `SoCXin/BL808` had PDFs. The inspected `lupyuen/nuttx-pinevox` default tree and [OpenBouffalo vendor data][bl-vendor-data] lacked the Wi-Fi modem files. The latter has BL808 RF and camera CSI headers. |

[Beken's SDK documentation][bk-docs] identifies its corporate GitLab as another
upstream and notes the lagging GitHub release. Public repository access and
source availability are separate. No evidence was found that a full
`phy_karst.c`, `phy_karst_bk7236.c`, or BL808 RivieraWaves modem source/header set
was publicly tracked in the searched trees. No separate BL808 modem microcode
implementation was located. These are scoped negative results, not proof of
absence. Indexed searches even missed `MDM_CSIRDCTL_ADDR` in the QCC mirror's
verified large header; inspect trees/raw blobs directly and deduplicate by blob
ID before treating mirrors as independent evidence.

The Gitee recursive tree API returned HTTP 403. A non-shallow
`git clone --filter=blob:none --no-checkout` exposed the branch and tag trees
for the path-history walk. Its `master` was
`dc47e34f7a5ffedcd3bfcccaae233eef50f011bb`. The `reg_mdm_cfg.h` hits were under
`beken378/driver/common/reg` and the same subtree prefixed with
`bk7231_freertos_full_code/`. The QCC CodeLinaro checkout at `8befa431`
listed `csidma_cmd.h` and `reg_mdm_cfg.h` in its available 42 commits. The
newer CodeLinaro clone at `964374a8` contains 46 reachable commits. Its tip
retains the CSI archive and host interface and omits the generated modem
header from the tree. The history contains the earlier header and CLI
declaration. The public `bk_idk` tree at `650e754e` supplies the compiled
Karst CSI routine in multiple chip archives. The Beken GitLab endpoint
requested authentication for read-only Git discovery.

Useful search keys for a later pass:

```text
phy_karst.c  phy_karst_bk7236.c  phy_custom_rf.c  phy_trident.c  phy_aetnensis.c
reg_mdm_cfg.h  _reg_mdm_cfg.h  reg_mdm_stat.h  reg_mdmdsss_cfg.h
wifi_mdmcfg_reg.h  mdm_set_channel  mdm_invcarrierfreq_setf  RXCFOBIASEST
mdm_dcestimctrl_pack  delaysynctd20  mdm_txctrl3_pack  0x02D00438
reg_macbypass.h  reg_riu.h  reg_rc.h  reg_la.h  agcmem.c  agc_ram_bin.h
csidma.c  csidma_cli.c  csidma_cmd.h  csidma_reg.h  csidata.c  csi_gen_report
libwifi_csi.a  libqcc74x_macsw.a  libmacsw_bl616_default.a
RW_NX_CSI  CFG_CSIDMA_CLI  CONFIG_WIFI_CSI_EN  rxl_csidma_int_handler
MDM_CSIRDCTL_ADDR  MDM_CSIRDSTAT_ADDR  CSI_RDREQUEST  CSI_READY
WIFI_CSIDMA_CTRL_ADDR  crm_phyahbclkforce_setf
ip_ax/macsw/plf/refip/src/driver/phy  plf/refip/src/driver/csidma
```

For already available clones, `git log --all --full-history --name-status --
':(glob)**/phy_karst*.c' ':(glob)**/csidma*.c'` searches tracked path history
without changing the clone. Use `git ls-tree -r <ref>` to verify exact paths and
blob IDs. A recipe reference or a DWARF source name is not a tracked file hit.

## Resume Plan

1. **Establish hardware behavior before reading coefficients.** Use the repo's
   [`tools/hw_validate.py` harness](hardware_validation_harness.md) on the lab
   BL808. The forced-RF receive check above found zero readback after writes
   of `2` and `3`; the remaining decisive test needs a working normal MAC
   receive path. Keep BLE inactive, use known-good Wi-Fi RX on one channel,
   and compare no-traffic and controlled HT20/OFDM traffic. Record
   `HDMCONFIG`, the version word at `+0x3C`, and the two CSI candidate words.
   Compare idle, repeated
   legacy OFDM and HT20 data RX, and a controlled exchange with successful
   outbound and inbound data with power save off. Check the firmware RX
   counter or descriptor so that each mode has
   an independent traffic confirmation. A passive zero read or a writable
   bit is inconclusive. A traffic-correlated ready transition, with matching
   format and bandwidth and repeatable re-arm behavior, is stronger evidence.
   Resolve the BL808 clock and ownership assumptions before a write or a
   coefficient read. Beken's PHY clock force and TX arming are material
   dependencies to test if passive observations are inconclusive.
2. **Recover the report contract.** Once there is a proven event, determine where
   the words are produced, how long they remain valid, and how to pair each buffer
   with a specific RX event. Decode signed I/Q width and order, scale, tone order,
   skipped/null tones, bandwidth/format, and RX-chain/spatial-stream count. Keep
   the original raw words with RX metadata and validate against a controlled
   transmitter and repeated captures. Packet data, RSSI, an interrupt alone, or
   reading back a static LDPC table does not meet the CSI criterion.
3. **Evaluate raw ADC capture if direct readout remains unreachable.**
   Characterize the M1s SRAM capture path on BL808. For raw
   samples to yield CSI, they must include the packet training field with usable
   timing and rate. For a 20 MHz single-stream first pass, synchronize to the
   packet, correct frequency offset, FFT the appropriate LTF, then divide received
   active tones by the known transmitted training tones (`H[k] = Y[k] / X[k]`).
   This yields a software channel estimate from a validated ADC capture.

### Bench preparation

The existing `m0_wifi_nimfw_scan_hal_test` built in the normal flash
layout and exports `rxl_cntrl_evt`. A harness dry run emitted a breakpoint
there with single-word reads at `0x24C00000`, `0x24C0003C`, `0x24C00064`,
and `0x24C008F8`. A halted snapshot is an initial register check. Use
bounded firmware-side sampling around confirmed RX if the status is
short-lived. Correlate it with the RX header's TSF, PHY vector, and packet
identity before releasing its descriptor. [RX handler][local-rx] ·
[RX descriptor layout][local-rx-layout] · [Hardware harness][local-harness]

The default `--jtag-load` RAM layout failed to link this example because
the image exceeds that layout. The successful build used `--jtag-flash
--build-only`. Loading the image with the ordinary `--jtag-flash` flow
would write the boot, partition, and firmware areas of the bench target.
Both checks here were performed on the host.

### Local reproduction

Run in Bash or Zsh from the repo root. These commands use existing inputs and
write no files:

```bash
sdk=build/vendor-cache/M1s_BL808_SDK
m1s_wifi=$sdk/components/network/wifi/lib/libwifi.a
m1s_rf=$sdk/components/platform/soc/bl606p/bl606p_phyrf/lib/libbl606p_phyrf.a

git -C "$sdk" rev-parse HEAD
shasum -a 256 src/bl808/libwifi_fw.a src/bl808/librf_bl808.a "$m1s_wifi" "$m1s_rf"

symbols() {
  llvm-nm -P --defined-only --extern-only "$1" |
    awk 'NF >= 2 { print $1 }' | LC_ALL=C sort -u
}
comm -13 <(symbols src/bl808/libwifi_fw.a) <(symbols "$m1s_wifi")
comm -13 <(symbols src/bl808/librf_bl808.a) <(symbols "$m1s_rf")

llvm-ar p "$m1s_rf" phy.o | llvm-objdump -dr --section=.text.ldpc_config -
llvm-ar p "$m1s_rf" phy.o | llvm-objdump -dr --mattr=+xtheadmemidx --section=.text.phy_init -
llvm-ar p "$m1s_rf" cli.o | llvm-objdump -dr \
  --section=.text.cmd_sram_rx --section=.text.cmd_sram_rx_addr -
```

For downloaded cross-chip archives, use `llvm-ar p <archive> <object>` piped to
`llvm-objdump -dr` or `llvm-dwarfdump --debug-info`. The QCC archive is about
60 MB; the GNU ar symbol index and the relevant member can also be inspected with
HTTP ranges. At the pinned mirror revision the member headers are at decimal
byte offsets `32513178` (`csidma.c.o`), `32259254` (`csidma_cli.c.o`), and
`28067222` (`intc.c.o`). LLVM reported relocation-reader warnings on the QCC
DWARF but still printed the compilation unit path; use the ar index or symbol
table for symbol ownership.

The T-Head extensions below decode the QCC IRQ's slot bit extraction and the
report parser's indexed word loads. The debug strings name the DMA register
macros. The stripped upstream archive can also be used for the instruction
trace.

```sh
llvm-ar p qcc_mac.a csidma.c.o | llvm-objdump -dr \
  --mattr=+xtheadba,+xtheadbb,+xtheadmac,+xtheadmemidx,+xtheadmempair,+xtheadcondmov -
llvm-ar p qcc_mac.a csidma.c.o | llvm-strings - | rg '^WIFI_CSIDMA_(CTRL|IRQCTRL|CSIBUF)'
llvm-ar p qcc_mac.a csidata.c.o | llvm-objdump -dr \
  --mattr=+xtheadbb,+xtheadmemidx,+xtheadcondmov -
llvm-ar p beken.a phy_karst_bk7236.c.obj | llvm-objdump -dr \
  --triple=thumbv8m.main-none-eabi --section=.text.csi_info_report_setup \
  --section=.text.csi_info_get_enable --section=.text.csi_info_read \
  --section=.text.print_csi_report_info -
```

[local-phy]: ../src/bl808/wifi/fw/global_state/rf_bl808_core.nim
[local-rx]: ../src/bl808/wifi/fw/rx_layer.nim
[local-rx-layout]: ../src/bl808/wifi/fw/layout_types.nim
[local-harness]: hardware_validation_harness.md
[bl-ble-loader]: ../src/bl808/blecontroller/registers_wireless_rf.nim
[bl-ldpc]: ../src/bl808/blerfdata.nim
[bl-wifi-linker]: ../src/linker/bl808_m0_wifi.ld
[m1s-rf-archive]: https://github.com/sipeed/M1s_BL808_SDK/blob/bf7e689cf49d57dd529e2492e5264ef602ed5b3c/components/platform/soc/bl606p/bl606p_phyrf/lib/libbl606p_phyrf.a
[m1s-phy-history]: https://github.com/sipeed/M1s_BL808_SDK/tree/0ba0c5bddf4ba92a49457914aa487b8c89cae707/components/network/wifi/plf/refip/src/driver/phy
[m1s-bl602-rc2]: https://raw.githubusercontent.com/sipeed/M1s_BL808_SDK/b737a1b7061da59e48770322cdde3e5ee28bbc1d/components/network/wifi/plf/refip/src/driver/phy/bl602_phy_rf/reg/reg_bl_rc2.h
[m1s-rf-reg]: https://github.com/sipeed/M1s_BL808_SDK/blob/0ba0c5bddf4ba92a49457914aa487b8c89cae707/components/network/wifi/plf/refip/src/driver/phy/bl602_phy_rf/rf/Inc/rf_reg.h#L3740-L3809
[m1s-rf-base]: https://github.com/sipeed/M1s_BL808_SDK/blob/bf7e689cf49d57dd529e2492e5264ef602ed5b3c/components/platform/soc/bl808/bl808_e907_std/bl808_bsp_driver/regs/bl808.h#L502
[m1s-factory-dec]: https://github.com/cjacker/opensource-toolchain-bouffalo-lab/blob/5acc2d7d3f9e4ee12da9cc56f32892e4b55476c0/m1s_dock_factory_firmware/do-not-use/firmware_20221212.bin
[m1s-factory-feb]: https://github.com/cjacker/opensource-toolchain-bouffalo-lab/blob/5acc2d7d3f9e4ee12da9cc56f32892e4b55476c0/m1s_dock_factory_firmware/firmware_20230227.bin
[bl-rm]: https://raw.githubusercontent.com/bouffalolab/bl_docs/main/BL808_RM/en/BL808_RM_en_1.3.pdf
[ox64-schematic]: https://files.pine64.org/doc/ox64/PINE64_Ox64-Schematic-202221018.pdf
[bl-bootrom]: https://openbouffalo.org/chips/bl808/bootrom/
[m1s-rom-api]: https://github.com/sipeed/M1s_BL808_SDK/blob/bf7e689cf49d57dd529e2492e5264ef602ed5b3c/components/platform/soc/bl808/bl808_e907_std/bl808_bsp_driver/std_drv/src/bl808_romapi_e907.c
[bl-iot]: https://github.com/bouffalolab/bl_iot_sdk
[bl-sdk]: https://github.com/bouffalolab/bouffalo_sdk
[bl-drivers]: https://github.com/bouffalolab/bouffalo_sdk-drivers
[bl-iot-forks]: https://github.com/bouffalolab/bl_iot_sdk/forks
[bl-sdk-forks]: https://github.com/bouffalolab/bouffalo_sdk/forks
[bl-driver-forks]: https://github.com/bouffalolab/bouffalo_sdk-drivers/forks
[vela-phy-port]: https://raw.githubusercontent.com/bouffalolab/vela-vendor-bouffalolab/865972926d79c02e3ea6575ff23fad22be8024ff/docs/bl616cl-wifi-sta-porting-solution.md
[bl616-phy-archive]: https://github.com/bouffalolab/bouffalo_sdk-drivers/blob/1f406cee04b50b14cd5b401ca65b0e04040d7231/soc/bl616/phyrf/lib-gcc_10.2.0-toolchain_V2.6.1/libbl616_phyrf.a
[bl616cl-phy-archive]: https://github.com/bouffalolab/bouffalo_sdk-drivers/blob/1f406cee04b50b14cd5b401ca65b0e04040d7231/soc/bl616cl/phyrf/lib-gcc_10.2.0-toolchain_V2.6.1/libbl616cl_phyrf.a
[bl618dg-phy-archive]: https://github.com/bouffalolab/bouffalo_sdk-drivers/blob/1f406cee04b50b14cd5b401ca65b0e04040d7231/soc/bl618dg/phyrf/lib-gcc_10.2.0-toolchain_V2.6.1/libbl618dg_phyrf.a
[tuya-phy-wrappers]: https://raw.githubusercontent.com/tuya/TuyaOpen-T5AI/e324ca0ffd5f7dbedaa28ae01fc48ba2e2493096/t5_os/cp/components/bk_wifi/src/phy.c
[m1s-forks]: https://github.com/sipeed/M1s_BL808_SDK/forks
[m1s-fork-early]: https://github.com/Embedded-Tech/M1s_BL808_SDK/tree/28e6cf28648dcba32723db4cd1e23fb550186b08
[m1s-fork-rtthread]: https://github.com/flyingcys/M1s_BL808_SDK/tree/f6d69aaae300c900911a939bf02276fb6518b6aa
[bl-gitee]: https://gitee.com/bouffalolab/bl_iot_sdk
[bl-dev-docs]: https://dev.bouffalolab.com/document
[bl-dev-firmware]: https://dev.bouffalolab.com/firmware
[bl-dev-tools]: https://dev.bouffalolab.com/download
[pine-ox64]: https://pine64.org/documentation/Ox64/Software/Releases/
[m1s-downloads]: https://dl.sipeed.com/MAIX/M1s/
[m1s-linux-zip]: https://api.dl.sipeed.com/fileList/MAIX/M1s/M1s_Dock/7_Firmware/m1sdock_linux_20221116.zip
[arm000-mcu]: https://github.com/arm000/bl_mcu_sdk/tree/63794163d0eed61cdf300b277e84b5a114199926
[rtthread-wlan-port]: https://github.com/flyingcys/wlan_bl808_rtthread/tree/6e479190cc3a1005378537ae29f4a0a3d547d62a
[rtthread-wlan-tar]: https://codeload.github.com/flyingcys/wlan_bl808_rtthread/tar.gz/6e479190cc3a1005378537ae29f4a0a3d547d62a
[yocop-phy-zip]: https://gitee.com/yocop/bl606p_phyrf/repository/archive/v8.1.0.zip
[yocop-phy]: https://gitee.com/yocop/bl606p_phyrf/tree/018cb99abf6de4fc0ba6237d78c84cd48bc3afe1
[yocop-wifi]: https://gitee.com/yocop/bl606p_firmware/tree/8019a49d1a4643ac844a49d59292454c4ba769fd
[yocop-manifest]: https://gitee.com/yocop/manifest/blob/14f657e919fdd0a482e14a13019fb17c4e2a9df6/default.yaml
[yocop-longyuan]: https://gitee.com/yocop/sdk_longyuan
[xrvm-longyuan-offline]: https://www.xrvm.cn/community/download?id=4080667575720153088
[longyuan-board-evaluation]: https://www.eet-china.com/mp/a292833.html
[yocop-longyuan-lakebook]: https://gitee.com/yocop/sdk_longyuan/tree/v2.1.1/lakebook
[yocop-longyuan-wifi-demo]: https://gitee.com/yocop/wifi_ble_provisioning_demo/blob/v2.1.1/package.yaml
[yocop-longyuan-bt-demo]: https://gitee.com/yocop/bt_audio_demo/blob/v2.1.1/package.yaml
[yocop-chip-sdk-v761]: https://gitee.com/yocop/sdk_chip_bl606p_e907/blob/v7.6.1/package.yaml
[yoc-cdk-publishing]: https://developer.aliyun.com/article/808585
[xrvm-bl606p-quickstart]: https://www.xrvm.cn/community/post/detail?id=4106009187719385088
[xrvm-bl606p-board]: https://www.xrvm.cn/product/board/4105634631926222848
[xrvm-bl606p-chip]: https://www.xrvm.cn/product/chip/4105746367257841664
[xrvm-longyuan-platform]: https://www.xrvm.cn/soft-tools/application/4197789119553802240
[yocop-cdk-board-zip]: https://gitee.com/yocop/bl606p_evb_e907/repository/archive/v7.6.2.zip
[xrvm-bl606p-speaker]: https://www.xrvm.cn/community/post/detail?id=4180991564241244160
[yocop-cdk-speaker-manifest]: https://gitee.com/yocop/smart_speaker_v2/blob/v2.1.1/package_bl606p_mind.yaml
[yocop-cdk-speaker-binaries]: https://gitee.com/yocop/smart_speaker_v2/tree/1c095e82b12947665966c7861b03bdcf90af6781/app/board/bl606p/firmware
[xuantie-cdk-speaker-elf]: https://github.com/XUANTIE-RV/open-yoc/tree/664b842d19405d3635b6269e94b52ccb7b4060ba/components/alg_kws_mind/libs/chip_bl606p/e907fp/firmware
[xrvm-f133-panel]: https://www.xrvm.cn/product/solution/4128197344309088256
[pinevoice-repack-phy]: https://github.com/ndom91/pinevoice-realtime-firmware/tree/aac58c1e245a59be1ec39664d68132ce983cd7ac/components/bl606p_wireless/bl606p_phy/bl606p_phyrf
[bl616-early-repack]: https://raw.githubusercontent.com/zxf1023818103/bouffalo_sdk/01f8efda71026e0334c105702d811fea4341b7ee/drivers/soc/bl616/phyrf/lib-gcc_10.2.0-toolchain_V2.6.1/libbl616_phyrf.a
[zt9612-fw-note]: https://github.com/Spkicn/zt9612-linux/blob/9b5dcfe1c0855b920c51feb143e0391e10ca7792/firmware/README.md
[yocop-tools]: https://pypi.org/project/yoctools/2.0.40/
[yocop-chip-sdk]: https://gitee.com/yocop/sdk_chip_bl606p_e907/blob/fa3ada63d1855956920eedf317e6672d82673d66/package.yaml
[yocop-early-wifi-phy]: https://gitee.com/yocop/drv_wifi_bl606p/blob/a6fe5d34fb927dd25c1c8cf982870983d2ff97fc/libs/libphyrf.a
[xuantie-yoc-phy]: https://github.com/XUANTIE-RV/open-yoc/tree/1b7d830c/components/bl606p_phyrf
[xuantie-yoc-forks]: https://github.com/XUANTIE-RV/open-yoc/forks
[zephyr-rf-wrapper]: https://github.com/zephyrproject-rtos/zephyr/blob/894a7bb323c16821d87766a5eb1b21d1a3f15acf/soc/bflb/bl808/bflb_rf.c
[pinevoice-phy]: https://github.com/pine64/pinevoice_smartspeaker_sdk/tree/305dd9a535ce7751de8d77bd2134873469072df0/components/bl606p_wireless/bl606p_phy
[zephyr-phy-blobs]: https://github.com/zephyrproject-rtos/hal_bouffalolab/blob/18c998da7dcf550303bc9b2852602dcb401e21a1/zephyr/module.yml#L392-L416
[arduino-phy-bundle]: https://github.com/bouffalolab/arduino-bouffalo-lib-builder/releases/tag/v0.12.0
[swh-iot-archive]: https://archive.softwareheritage.org/api/1/snapshot/bc5eaf036b70f8c65dd389439062b169f8d09daa/
[swh-iot-tip]: https://github.com/bouffalolab/bl_iot_sdk/tree/ccc9f70983a447f429093365b9a30e49d7973100/components/platform/soc/bl606p/bl606p_phyrf
[aipi-m6x-phy]: https://gitee.com/Ai-Thinker-Open/aithinker_Ai-M6X_SDK/tree/d444b4c46aa287857b9ef1e4e86f56ca91ba3756
[bl-iot-components]: https://github.com/bouffalolab/bl_iot_sdk-components/tree/a18c0f9215a9490ca2ce4811084b96ee60e4f205
[bl-patent-sensing]: https://patents.google.com/patent/CN113156220A/en
[bl-patent-csi]: https://patents.google.com/patent/CN116150584A/zh
[bl-patent-reg]: https://patents.google.com/patent/CN113705161B/zh
[iot-tool-175]: https://pypi.org/project/bflb-iot-tool/1.7.5/#files
[iot-tool-180]: https://pypi.org/project/bflb-iot-tool/1.8.0/#files
[iot-tool-183]: https://pypi.org/project/bflb-iot-tool/1.8.3/#files
[iot-tool-187]: https://pypi.org/project/bflb-iot-tool/1.8.7/#files
[iot-tool-1100]: https://pypi.org/project/bflb-iot-tool/1.10.0/#files
[bl808-wifi-log]: https://bbs.bouffalolab.com/d/247-bl808awslogaws
[socxin-sdk-rf]: https://github.com/SoCXin/SDK-BL/tree/9e1325625351c1e1fdc6497a3d18e3fd6f18c427/drivers/soc/bl616/rf
[bl-pinned-wifi]: https://github.com/bouffalolab/bl_iot_sdk/blob/b773b3f4bf6154125304a328c72bf2aa7168a715/components/network/wifi/lib/libwifi.a
[bl-pinned-wifi-mk]: https://github.com/bouffalolab/bl_iot_sdk/blob/b773b3f4bf6154125304a328c72bf2aa7168a715/components/network/wifi/bouffalo.mk
[bl-pinned-rf]: https://raw.githubusercontent.com/bouffalolab/bouffalo_sdk/a05d70b078b2f8a7f6aa402353c7abba14a64c6f/drivers/soc/bl616/rf/lib/librf.a
[bl-pinned-rf-mk]: https://raw.githubusercontent.com/bouffalolab/bouffalo_sdk/a05d70b078b2f8a7f6aa402353c7abba14a64c6f/drivers/soc/bl616/rf/CMakeLists.txt
[bl-early-rf]: https://github.com/bouffalolab/bl_iot_sdk/tree/b773b3f4bf6154125304a328c72bf2aa7168a715/components/platform/soc/bl606p/bl606p_phyrf
[bl-vela-policy]: https://github.com/bouffalolab/vela-manifest#2-仓库拓扑
[bl-support]: https://en.bouffalolab.com/community/
[ceva-rw-options]: https://www.prnewswire.com/news-releases/ceva-unveils-wi-fi-ip-platforms-to-enable-a-broad-range-of-connected-devices-300097425.html
[ceva-rw-sense]: https://www.ceva-ip.com/wp-content/uploads/20160406-Wi-Fi-SoC-for-IoT_webinar.pdf
[ceva-contact]: https://www.ceva-ip.com/contact-us/
[ceva-aic]: https://www.ceva-ip.com/press/aic-semiconductor-licenses-cevas-802-11ax-wi-fi-6-ip-for-iot-connectivity/
[github-commit-search-scope]: https://docs.github.com/en/search-github/searching-on-github/searching-commits
[common-crawl-index]: https://index.commoncrawl.org/
[ceva-winner-license]: https://www.ceva-ip.com/press/winner-micro-licenses-cevas-bluetooth-and-wi-fi-ip-platforms-for-iot-connectivity-soc/
[winner-sdk-phy]: https://raw.githubusercontent.com/winnermicro/wm_iot_sdk/cf963cdaf9e44a12e02cb9c86f848b4060c530cf/components/wm_soc/w80x/lib/libmacsw.a
[winner-repack-phy]: https://github.com/cjacker/wm_sdk_w80x/blob/197ad911d3b3ab988a1f4cb539184984d12e743e/lib/w800/libwlan.a
[winner-w600-320]: https://github.com/w600/sdk/blob/2c91c42760c7606df9adda83f55faad0eb78d8b4/lib/libwlan.a
[winner-w600-340]: https://github.com/w600/sdk/blob/a3aa672e8fb87c1cda7420ab59e7cdf1b8271c3e/lib/libwlan.a
[winner-w600-tools-zip]: https://github.com/w600/sdk/blob/c38d04f3218bc897c9800aae1d83f43a3928e3f8/tools/library.zip
[openharmony-w800-phy]: https://gitee.com/openharmony/device_soc_winnermicro
[aic-rwnx]: https://github.com/radxa-pkg/aic8800/blob/main/src/USB/driver_fw/drivers/aic8800/aic8800_fdrv/rwnx_main.c
[aic-embedded]: https://gitee.com/im-eks-dev/aic8800-sdk/tree/06164fca59a8d0a04b743adf59a7360438bf01ba
[aic-riu]: https://github.com/vsfteam/AIC8800M_SDK_vsf/blob/cec536008ab6a99f205777a6a452439ced529ecb/plf/aic8800/src/driver/rf/reg_riu.h
[aic-csi-c]: https://gitee.com/im-eks-dev/aic8800-sdk/blob/06164fca59a8d0a04b743adf59a7360438bf01ba/applications/csiwifi/src/fhost_wifi_csi.c
[aic-csi-target]: https://gitee.com/im-eks-dev/aic8800-sdk/tree/06164fca59a8d0a04b743adf59a7360438bf01ba/config/aic8800/target_wifi_csi
[ceva-eswin]: https://www.ceva-ip.com/press/ceva-wi-fi-6-ip-powers-eswin-ecr6600-smart-connectivity-ic/
[eswin-wifi]: https://github.com/NonPIayerCharacter/ecr6600/blob/b8c9f7894608cdebfcf18d891911ee044fff331e/libs/libps_wifi.a
[eswin-open-wifi]: https://github.com/jasperro/OpenECR6600/blob/9ce4dd3c306c39b462ca132f3d4fc5cc14c621f0/libs/libps_wifi.a
[alios]: https://github.com/alibaba/AliOS-Things
[alios-trident]: https://github.com/alibaba/AliOS-Things/blob/585d6536d86a464a136f7eb4a0a36e96567fdc8b/platform/mcu/bk7231u/beken/driver/phy/phy_trident.c
[ceva-alios]: https://www.ceva-ip.com/press/ceva-introduces-fully-integrated-wi-fi-solution-to-connect-iot-devices-to-the-alibaba-cloud/
[gd32-sdk]: https://github.com/GigaDeviceSemiconductor/GD32VW55x_WiFi_BLE_SDK/tree/9c303dc294645f06916f71f7244edf377362bfaa/MSDK/lib
[listen-sdk]: https://cloud.listenai.com/CSKG836746/arcs-sdk/public/arcs_mini
[listen-docs]: https://docs2.listenai.com/x/yffNVbsmK
[listen-mdm]: https://github.com/justa-cai/listenai-arcs_mini/blob/66568d04375a933bf814b921c8f4442e8918f101/arcs-sdk/soc/arcs/hal/chip/arcs/include/register/wifi_mdmcfg_reg.h
[listen-crm]: https://github.com/justa-cai/listenai-arcs_mini/blob/66568d04375a933bf814b921c8f4442e8918f101/arcs-sdk/soc/arcs/hal/chip/arcs/include/register/wifi_crm_reg.h
[listen-base]: https://github.com/justa-cai/listenai-arcs_mini/blob/66568d04375a933bf814b921c8f4442e8918f101/arcs-sdk/soc/arcs/hal/chip/arcs/include/memdump.h#L43-L47
[listen-rf]: https://github.com/justa-cai/listenai-arcs_mini/blob/66568d04375a933bf814b921c8f4442e8918f101/arcs-sdk/soc/arcs/hal/chip/arcs/wcnd/rf/rf_drv.c#L1219-L1222
[listen-wifi-build]: https://github.com/justa-cai/listenai-arcs_mini/blob/66568d04375a933bf814b921c8f4442e8918f101/arcs-sdk/soc/arcs/hal/chip/arcs/lib/wifi/CMakeLists.txt#L16-L26
[listen-plf]: https://github.com/justa-cai/listenai-arcs_mini/blob/66568d04375a933bf814b921c8f4442e8918f101/arcs-sdk/soc/arcs/hal/chip/arcs/lib/wifi/ilp32/libplf.a
[zt-phy-name]: https://github.com/Spkicn/zt9612-linux/blob/9b5dcfe1c0855b920c51feb143e0391e10ca7792/CHANGELOG.md
[tuya-t3-csi]: https://github.com/tuya/TuyaOpen-T3/blob/6d63341c50e86dadbfae676df2485b7e77722cb5/t3_os/armino/components/bk_libs/bk7236/libs/libwifi_csi.a
[tuya-t5-csi]: https://github.com/tuya/TuyaOpen-T5AI/blob/e324ca0ffd5f7dbedaa28ae01fc48ba2e2493096/t5_os/cp/components/bk_libs/bk7258/libs/libwifi_csi.a
[tizen-bk-wifi]: https://github.com/Samsung/TizenRT/blob/a6920b81a07f0164b415ce2a1bc821225fde59db/os/board/bk7239n/src/libs/libwifi.a
[sfwifi-mdm]: https://github.com/Siflower/sf_wifi/blob/da991fafab179a2ed495c2925a0bf219ef38e22e/sf_smac/src/bb_src/umac/reg_mdm_cfg.h
[rtthread-mfg]: https://github.com/RT-Thread/rt-thread/tree/6fdfe70062ec394e5dd7099c51cbcff127cacab1/bsp/bouffalo_lab/bl808/builtin_imgs
[bl-linux-wifi]: https://github.com/bouffalolab/bl_iot_sdk/blob/b90664de0bd4c1897a9f1f5d9e360a9631d38b34/components/network/bl808_wifi/lib/libwifi.a
[bl-linux-rf]: https://github.com/bouffalolab/bl_iot_sdk/blob/b90664de0bd4c1897a9f1f5d9e360a9631d38b34/components/platform/soc/bl606p/bl606p_phyrf/lib/libbl606p_phyrf.a
[bl-xram]: https://github.com/bouffalolab/blwnet_xram/blob/9038d387040b3fbfb13805ad7e9cd96df6c7e8a0/README.md
[m1s-linux]: https://github.com/sipeed/M1s_BL808_Linux_SDK/blob/baee2020e4dc418363205ac94a2d80deb9477cc2/README.md
[bl-lowload]: https://github.com/bouffalolab/bflb_linux_fw/blob/e87068cdc6a1b5833d0891e06f5f387b3a8bfb36/apps/m0_lowload/src/main.c
[bl-vendor-data]: https://github.com/openbouffalo/bouffalo-vendor-data/tree/d047b454d4aa2fb6e3d11dbd6ee48d5b5582f02c/bl808
[bl-mac-archives]: https://github.com/bouffalolab/bouffalo_sdk/tree/ad2a37b8eae3e618d5e9baafdfc4013266ebb59a/components/wireless/macsw/lib
[bl-tx-status]: https://github.com/bouffalolab/bouffalo_sdk/blob/ad2a37b8eae3e618d5e9baafdfc4013266ebb59a/components/wireless/macsw/inc/macsw.h#L1365
[qcc-reg]: https://github.com/amitv87/QCCSDK-QCC74x/tree/82c5538ac3b1408d102c331f6d67e142f8e12549/drivers/soc/qcc743/phyrf/reg/wlan11
[qcc-config]: https://github.com/amitv87/QCCSDK-QCC74x/blob/82c5538ac3b1408d102c331f6d67e142f8e12549/drivers/soc/qcc743/phyrf/reg/wlan11/reg_mdm_cfg.h
[qcc-control]: https://github.com/amitv87/QCCSDK-QCC74x/blob/82c5538ac3b1408d102c331f6d67e142f8e12549/drivers/soc/qcc743/phyrf/reg/wlan11/reg_mdm_cfg.h#L15293-L15343
[qcc-status]: https://github.com/amitv87/QCCSDK-QCC74x/blob/82c5538ac3b1408d102c331f6d67e142f8e12549/drivers/soc/qcc743/phyrf/reg/wlan11/reg_mdm_cfg.h#L1661-L1723
[qcc-guard]: https://github.com/amitv87/QCCSDK-QCC74x/blob/82c5538ac3b1408d102c331f6d67e142f8e12549/drivers/soc/qcc743/phyrf/reg/wlan11/reg_mdm_cfg.h#L34-L36
[qcc-cli]: https://github.com/amitv87/QCCSDK-QCC74x/blob/82c5538ac3b1408d102c331f6d67e142f8e12549/components/wireless/qcc74x_macsw/include/export/csidma_cmd.h
[qcc-lib]: https://github.com/amitv87/QCCSDK-QCC74x/blob/82c5538ac3b1408d102c331f6d67e142f8e12549/components/wireless/qcc74x_macsw/lib/libqcc74x_macsw.a
[qcc-official]: https://git.codelinaro.org/clo/qcc7xx/QCCSDK-QCC74x
[qcc-capture-api]: https://git.codelinaro.org/clo/qcc7xx/QCCSDK-QCC74x/-/blob/964374a85153b20be3b1f3aaf1fa46329a08ab44/components/wireless/qcc74x_macsw/include/export/csidma_cmd.h
[qcc-collector]: https://git.codelinaro.org/clo/qcc7xx/QCCSDK-QCC74x/-/blob/964374a85153b20be3b1f3aaf1fa46329a08ab44/tools/script/csidata-hz.py
[qcc-wfa-linker]: https://git.codelinaro.org/clo/qcc7xx/QCCSDK-QCC74x/-/blob/964374a85153b20be3b1f3aaf1fa46329a08ab44/bsp/board/qcc74xdk/qcc743_wfa_flash.ld
[aic]: https://marc.info/?l=linux-wireless&m=178791906254861
[bl-wifi6-cli]: https://github.com/bouffalolab/bouffalo_sdk/blob/master/components/wireless/wifi6/wifi6_lwip_adapter/cli_al.c#L1311-L1320
[bl616-crm]: https://github.com/bouffalolab/bouffalo_sdk/blob/872f8e89071bdcd1e85a6cc1519aeb0599b185c2/drivers/soc/bl616/phyrf/include/crm.h#L32-L42
[bk-lib]: https://github.com/bekencorp/bk_idk/blob/650e754e12fe1e43c37ce2316a973668b033fd48/components/bk_libs/bk7236/libs/libwifi_csi.a
[bk-archives]: https://github.com/bekencorp/bk_idk/tree/650e754e12fe1e43c37ce2316a973668b033fd48/components/bk_libs
[bk-build]: https://github.com/bekencorp/bk_idk/blob/650e754e12fe1e43c37ce2316a973668b033fd48/components/bk_wifi/CMakeLists.txt#L77-L93
[bk-example]: https://github.com/bekencorp/bk_idk/blob/650e754e12fe1e43c37ce2316a973668b033fd48/projects/wifi/csi/main/armino_main.c#L153-L166
[bk-types]: https://github.com/bekencorp/bk_idk/blob/650e754e12fe1e43c37ce2316a973668b033fd48/include/modules/wifi_types.h#L709-L716
[bk-old]: https://gitee.com/belonpeter/beken_freertos_sdk_release/blob/master/application.mk?skip_mobile=true
[bk-old-mdm]: https://gitee.com/belonpeter/beken_freertos_sdk_release/blob/dc47e34f7a5ffedcd3bfcccaae233eef50f011bb/beken378/driver/common/reg/reg_mdm_cfg.h
[bk-trident]: https://gitee.com/belonpeter/beken_freertos_sdk_release/blob/dc47e34f7a5ffedcd3bfcccaae233eef50f011bb/beken378/driver/phy/phy_trident.c
[bk-docs]: https://docs.riselink.ai/arminodoc/bk_idk/bk7236/en/v2.0.2/get-started/index.html
[sfax8]: https://github.com/Siflower/1806_SDK/tree/35c5a3dda4d3be02a86fc9b17eba20d2dbef90e0/uboot/arch/mips/mach-sfax8/pcba-test/wifi
[sfax8-phy]: https://github.com/Siflower/1806_SDK/blob/35c5a3dda4d3be02a86fc9b17eba20d2dbef90e0/uboot/arch/mips/mach-sfax8/pcba-test/wifi/phy_aetnensis.c
[sfax8-mdm]: https://github.com/Siflower/1806_SDK/blob/35c5a3dda4d3be02a86fc9b17eba20d2dbef90e0/uboot/arch/mips/mach-sfax8/pcba-test/wifi/reg_mdm_cfg.h
[sfax8-stat]: https://github.com/Siflower/1806_SDK/blob/35c5a3dda4d3be02a86fc9b17eba20d2dbef90e0/uboot/arch/mips/mach-sfax8/pcba-test/wifi/reg_mdm_stat.h
[sfax8-agc-loader]: https://github.com/Siflower/1806_SDK/blob/35c5a3dda4d3be02a86fc9b17eba20d2dbef90e0/uboot/arch/mips/mach-sfax8/pcba-test/wifi/wifi_ldfw.c#L43-L67
[sfax8-riu-events]: https://github.com/Siflower/1806_SDK/blob/35c5a3dda4d3be02a86fc9b17eba20d2dbef90e0/uboot/arch/mips/mach-sfax8/pcba-test/wifi/reg_riu.h#L6334-L6472
[sfax8-agc-image]: https://github.com/Siflower/1806_SDK/blob/35c5a3dda4d3be02a86fc9b17eba20d2dbef90e0/uboot/arch/mips/mach-sfax8/pcba-test/wifi/agc_ram_bin.h
[sf-ax3000-agc-images]: https://github.com/Siflower/Siflower_ax3000_sdk/tree/f52656308c80e3984f512aba10cc1d4f1ab46cd0/Openwrt-master/package/kernel/siflower/openwrt-x2880-driver/config/wlan_vendor_siflower
[bl602-karst]: https://github.com/pine64/bl602-re/tree/ed05fb4072a649efec11cc242edfa8478ebf7dfc/components/bl602/bl602_wifi/plf/refip/build/reg/bouffalo/rv32i/karst
[bl602-blobs]: https://github.com/pine64/bl602-re/tree/ed05fb4072a649efec11cc242edfa8478ebf7dfc/blobs/reg
[bl602-rc2]: https://github.com/pine64/bl602-re/blob/ed05fb4072a649efec11cc242edfa8478ebf7dfc/blobs/reg/reg_bl_rc2.h
[bl602-dwarf-recovery]: https://github.com/pine64/bl602-re/commit/e34f3df
[bl602-phy-stubs]: https://github.com/pine64/bl602-re/blob/ed05fb4072a649efec11cc242edfa8478ebf7dfc/components/bl602/bl602_wifi/plf/refip/src/driver/phy/bl602_phy_rf/phy_bl602.c
