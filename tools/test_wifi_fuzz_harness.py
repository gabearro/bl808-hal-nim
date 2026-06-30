"""Host fuzz/regression entrypoints for local WiFi firmware parsing."""

from __future__ import annotations

import shutil
import subprocess
from pathlib import Path

import pytest


REPO_ROOT = Path(__file__).resolve().parents[1]


@pytest.mark.parametrize(
    "source",
    [
        "tools/fuzz_wifi_rsn_auth.nim",
        "tools/fuzz_wifi_mgmt_replay.nim",
        "tools/fuzz_wifi_connect_state.nim",
        "tools/fuzz_wifi_key_install.nim",
    ],
)
def test_wifi_host_fuzzers(source: str, tmp_path: Path) -> None:
    nim = shutil.which("nim")
    if nim is None:
        pytest.skip("nim is not installed")

    subprocess.run(
        [
            nim,
            "c",
            "-r",
            "--skipParentCfg:on",
            "--skipProjCfg:on",
            "--checks:on",
            "--path:src",
            "--nimcache:" + str(tmp_path / "nimcache"),
            "-o:" + str(tmp_path / Path(source).stem),
            source,
        ],
        check=True,
        cwd=REPO_ROOT,
    )
