"""Regression cases retained from the activation baseline comparison."""

from pathlib import Path

import pytest

from test_wifi_activation_exchange import source
from test_wifi_message_allocation import run_program


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_unrelated_activation_confirmation(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
setup()
state = 9
let p = ke_msg_alloc(MM_SET_VIF_STATE_CFM, TASK_SM, TASK_MM, 0)
mm_set_vif_state_cfm_handler(p)
doAssert stationReady == 0 and connected == 0 and filterUpdates == 0
ke_msg_free(keMsgHdrFromPayload(p))
finish()
''')
