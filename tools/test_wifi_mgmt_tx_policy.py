"""Check auth/association policy preservation and explicit diagnostic overrides."""

from pathlib import Path
import shutil
import subprocess

import pytest

from test_wifi_auth_frames import layouts
from test_wifi_disconnect_tx import FW, ROOT, procedure
from test_wifi_station_tx_build import program_source


def replace_once(source: str, old: str, new: str) -> str:
    assert source.count(old) == 1
    return source.replace(old, new, 1)


def policy_source(workaround: bool, primary: str, power: int | None) -> str:
    sm = (FW / "scan_station_ap_me.nim").read_text()
    rf = (FW / "global_state/rf_bl808_core.nim").read_text()
    constants = (FW / "register_constants.nim").read_text()
    code = layouts("HostTxRateTemplateView")
    code += constants[constants.index("when defined(bl808WifiForceTxPwr70):") :]
    code += program_source()
    code = replace_once(code,
        "    payloadStart, payloadEnd, frameLen, ackPolicyControl, retryLimitControl: uint32",
        "    payloadStart, payloadEnd, frameLen, ackPolicyControl, retryLimitControl: uint32\n"
        "    chainedThd: pointer")
    code = replace_once(code,
        "    macHeader: array[512, uint8]",
        "    macHeader: array[512, uint8]\n    rateTemplate: HostTxRateTemplateView")
    code = replace_once(code, "var\n  sm: SmEnv", "type\n"
        "  HostTxLinkDescView = Link\n  HostTxHwDescView = Hw\n"
        "var\n  originalPolicy: HostTxRateTemplateView\n  tpcCalls: int\n  sm: SmEnv")
    code = replace_once(code,
        "proc hostTxHwDescAt(p: pointer): ptr Hw = cast[ptr Hw](p)",
        "proc hostTxHwDescAt(p: pointer): ptr Hw = cast[ptr Hw](p)\n"
        "proc hostTxRateTemplate(p: ptr Link): ptr HostTxRateTemplateView = addr p.rateTemplate\n"
        "proc hostTxRateTemplateAt(p: pointer): ptr HostTxRateTemplateView = cast[ptr HostTxRateTemplateView](p)")
    code = replace_once(code,
        "proc tpc_update_frame_tx_power(vif, frame: pointer) = observe(2)", r'''
proc tpc_update_frame_tx_power(vif, frame: pointer) =
  inc tpcCalls
  let desc = hostTxDescAt(frame)
  let link = hostTxLinkDescAt(desc.bufDesc)
  let hw = hostTxHwDescAt(desc.hwDesc)
  link.rateTemplate = originalPolicy
  link.ackPolicyControl = 0x12345678
  link.retryLimitControl = 0x76543210
  hw.chainedThd = addr link.rateTemplate
  hw.ackPolicyControl = 0
  hw.retryLimitControl = 0
  observe(2)
''')
    code = replace_once(code,
        "proc applyConservativeMgmtTxRetryPolicy(p: ptr Link) = observe(5)",
        sm[sm.index("template selectedMgmtTxPower()"):sm.index("\nproc macPtrIsSpecific")]
        + "\n" + procedure(sm, "applyConservativeMgmtTxRetryPolicy"))
    code = replace_once(code,
        "proc applyForcedInternalMgmtTxPower(p: ptr Hw) = observe(5)",
        procedure(rf, "applyForcedInternalMgmtTxPower"))
    expected = "var expected = originalPolicy\n"
    if workaround:
        if primary != "keep":
            expected += f"expected.rateWord = {primary}'u32\n"
        retries = [0x80001007, 0x80000400, 0x8000040A] if primary == str(0x80001007) else [
            0x80000400, 0x8000040A, 0x80001007]
        for index, rate in enumerate(retries):
            expected += f"expected.retryRateControl{index} = {rate}'u32\n"
    if workaround or power is not None:
        tx_power = power if power is not None else 0x70
        expected += f"expected.txPower = {tx_power}\n"
        for index in range(3):
            expected += f"expected.retryTxPowerControl{index} = {tx_power}\n"
    ack, retry = (0x200, 0x3F0000) if workaround else (0, 0)
    link_ack, link_retry = (ack, retry) if workaround else (0x12345678, 0x76543210)
    checks = r'''
for seed in 0..3:
  originalPolicy = HostTxRateTemplateView(magic: 0xBADCAB1E'u32, ntxConfig: 0x4000,
    bwMask: 3, policyWord: 0xFFFF0704'u32, rateWord: 0x400, txPower: -17)
  if seed != 0:
    let bytes = cast[ptr UncheckedArray[uint8]](addr originalPolicy)
    for i in 0..<sizeof(originalPolicy): bytes[i] = ((seed * 31 + i * 17) and 255).uint8
  for kind in 0..1:
    setup(kind)
    tpcCalls = 0
    let savedPolicy = originalPolicy
    perform(kind)
    doAssert pushes == 1 and failures == 0 and tpcCalls == 1
    doAssert originalPolicy == savedPolicy
    let desc = activeFrame
    let link = hostTxLinkDescAt(desc.bufDesc)
    let hw = hostTxHwDescAt(desc.hwDesc)
    doAssert hw.chainedThd == (addr link.rateTemplate)
    EXPECTED
    doAssert link.rateTemplate == expected, "builder changed the selected TX policy"
    doAssert hw.ackPolicyControl == ACK'u32
    doAssert hw.retryLimitControl == RETRY'u32
    doAssert link.ackPolicyControl == LINK_ACK'u32
    doAssert link.retryLimitControl == LINK_RETRY'u32
    doAssert currentState == (if kind == 0: 6'u16 else: 8'u16) and timerDelay == 0x7D000
'''
    checks = checks.replace("    EXPECTED", "\n".join("    " + line for line in expected.splitlines()))
    checks = checks.replace("LINK_ACK", str(link_ack)).replace("LINK_RETRY", str(link_retry))
    checks = checks.replace("ACK", str(ack)).replace("RETRY", str(retry))
    return code + checks


def run_policy(tmp_path: Path, *, mode: str = "checked", flags: tuple[str, ...] = (),
               workaround: bool = False, primary: str = "keep", power: int | None = None) -> None:
    nim = shutil.which("nim")
    if nim is None:
        pytest.skip("Nim is required")
    source = tmp_path / "mgmt_tx_policy.nim"
    source.write_text(policy_source(workaround, primary, power))
    modes = {
        "checked": [],
        "release": ["-d:release", "--assertions:on"],
        "asan": ["--cc:clang", "--passC:-fsanitize=address", "--passL:-fsanitize=address"],
    }
    result = subprocess.run([nim, "c", "-r", "--skipParentCfg:on", "--skipProjCfg:on",
        "--skipUserCfg:on", "--checks:on", f"--path:{ROOT / 'src'}", *modes[mode],
        *(f"-d:{flag}" for flag in flags), f"--nimcache:{tmp_path / 'cache'}",
        f"-o:{tmp_path / 'check'}", str(source)], cwd=ROOT, text=True,
        stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=90)
    assert result.returncode == 0, result.stdout


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_default_management_policy(tmp_path: Path, mode: str) -> None:
    run_policy(tmp_path, mode=mode)


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
@pytest.mark.parametrize("flags,primary", [
    ((), str(0x80000400)),
    (("bl808WifiKeepMgmtRcPrimary",), "keep"),
    (("bl808WifiMgmtLegacyFirst",), str(0x8000040A)),
    (("bl808WifiMgmtOfdmFirst",), str(0x80001007)),
    (("bl808WifiMgmtOfdmFirst", "bl808WifiMgmtLegacyFirst", "bl808WifiKeepMgmtRcPrimary"), str(0x80001007)),
])
def test_explicit_management_workaround(tmp_path: Path, mode: str, flags: tuple[str, ...], primary: str) -> None:
    run_policy(tmp_path, mode=mode, flags=("bl808WifiMgmtRetryWorkaround", *flags),
               workaround=True, primary=primary)


@pytest.mark.parametrize("power", [0x20, 0x30, 0x70])
@pytest.mark.parametrize("workaround", [False, True])
def test_explicit_power_override(tmp_path: Path, power: int, workaround: bool) -> None:
    flags = (f"bl808WifiForceTxPwr{power:x}",)
    if workaround:
        flags += ("bl808WifiMgmtRetryWorkaround",)
    run_policy(tmp_path, flags=flags, workaround=workaround,
               primary=str(0x80000400) if workaround else "keep", power=power)


@pytest.mark.parametrize("flag", ["bl808WifiKeepMgmtRcPrimary", "bl808WifiMgmtLegacyFirst",
                                 "bl808WifiMgmtOfdmFirst", "bl808WifiBootstrapRetryWorkaround"])
def test_other_flags_do_not_enable_management_workaround(tmp_path: Path, flag: str) -> None:
    run_policy(tmp_path, flags=(flag,))
