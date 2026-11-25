"""Shared native harness utilities and deferred authentication regressions."""

from pathlib import Path
import shutil
import subprocess

import pytest

from test_wifi_disconnect_tx import FW, ROOT


def run_nim(tmp_path: Path, code: str) -> None:
    nim = shutil.which("nim")
    if nim is None:
        pytest.skip("nim is not installed")
    path = tmp_path / "deferred.nim"
    path.write_text(code)
    result = subprocess.run(
        [nim, "c", "-r", "--skipParentCfg:on", "--skipProjCfg:on", "--skipUserCfg:on",
         "--checks:on", f"--path:{ROOT / 'src'}", f"--nimcache:{tmp_path / 'nimcache'}",
         f"-o:{tmp_path / 'check'}", str(path)],
        cwd=ROOT, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=90,
    )
    assert result.returncode == 0, result.stdout


def source_parts() -> tuple[str, str, str]:
    layout = (FW / "layout_types.nim").read_text()
    types = "type\n"
    for name in ["SmConnectAuthAssocReqPayload", "SmConnectAuthAssocChallengePayload"]:
        types += "  " + name + layout.split("  " + name, 1)[1].split("\n\n  ", 1)[0] + "\n"
    constants = ("const SmConnectAuthAssocReqPayloadSize = 8'u32\n"
                 "const SmConnectAuthAssocChallengePayloadSize = 136'u32\n")
    return types, constants, (FW / "task_handlers.nim").read_text()


def test_deferred_auth_command_ownership(tmp_path: Path) -> None:
    from test_wifi_deferred_auth_lifetime import run_case
    run_case(tmp_path, "matrix")


def test_ended_attempt_does_not_send_its_request(tmp_path: Path) -> None:
    from test_wifi_deferred_auth_lifetime import run_case
    run_case(tmp_path, "attempt_ended_while_queued")


def test_retired_vif_ends_the_attempt(tmp_path: Path) -> None:
    from test_wifi_deferred_auth_lifetime import run_case
    run_case(tmp_path, "vif_retired_while_queued")
