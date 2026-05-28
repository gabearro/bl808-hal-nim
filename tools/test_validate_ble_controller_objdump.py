"""Tests for BLE controller static audit helpers."""
from __future__ import annotations

from pathlib import Path

import validate_ble_controller_objdump as audit


def test_function_instruction_count_includes_compiler_body_fragments():
    disassembly = {
        "sch_prog_push": {"bytes": ["c509", "00000317", "00030067"], "mnem": []},
        "sch_prog_push.part.0": {"bytes": ["1141", "c606", "8082"], "mnem": []},
        "sch_prog_push.isra.0": {"bytes": ["4501"], "mnem": []},
        "sch_prog_push.constprop.0": {"bytes": ["8082"], "mnem": []},
        "sch_prog_push.cold": {"bytes": ["0000"], "mnem": []},
    }

    assert audit.function_instruction_count(disassembly, "sch_prog_push") == 8


def test_function_instruction_count_handles_missing_symbol():
    assert audit.function_instruction_count({}, "missing") == 0


def test_likely_active_placeholder_ignores_compiled_wrapper_fallback(tmp_path):
    source = tmp_path / "blecontroller.nim"
    source.write_text(
        "\n".join(
            [
                "proc lld_con_data_tx*() {.exportc, cdecl.} =",
                "  vendor_lld_con_data_tx()",
                "when not defined(bl808BleVendorManualConnTx):",
                "  vendorZeroStub(lld_con_data_tx)",
                "vendorZeroStub(ll_length_req_handler)",
            ]
        )
    )

    line_map, stubs, stub_lines = audit.source_lines(source)

    assert "lld_con_data_tx" in stubs
    assert not audit.likely_active_placeholder_stub(
        "lld_con_data_tx",
        2,
        line_map,
        stub_lines,
    )
    assert audit.likely_active_placeholder_stub(
        "ll_length_req_handler",
        2,
        line_map,
        stub_lines,
    )


def test_llcp_data_length_response_is_feature_gated():
    source = Path(__file__).resolve().parents[1] / "src/bl808/blecontroller.nim"
    text = source.read_text(encoding="utf-8")

    feature_block = text.split("NimBleConservativeLeFeatures =", 1)[1].split(
        "proc nimBleFeatureByte", 1
    )[0]
    assert "NimBleFeatureDataPacketLengthExtension" not in feature_block

    length_branch = text.split("of LlcpLengthReq:", 1)[1].split(
        "of LlcpPhyReq:", 1
    )[0]
    assert (
        "nimBleLocalFeatureSupported(NimBleFeatureDataPacketLengthExtension)"
        in length_branch
    )
    assert "vendorBuildLengthRsp()" in length_branch
    assert "vendorBuildUnsupportedFeatureRsp(opcode)" in length_branch

    record_peer_length = text.split("proc vendorRecordPeerDataLength", 1)[1].split(
        "proc vendorConfigCount", 1
    )[0]
    assert (
        "nimBleLocalFeatureSupported(NimBleFeatureDataPacketLengthExtension)"
        in record_peer_length
    )

    hci_set_data_length = text.split("proc nimBleDataLengthStatus", 1)[1].split(
        "proc sendLeSetDataLengthComplete", 1
    )[0]
    assert (
        "nimBleLocalFeatureSupported(NimBleFeatureDataPacketLengthExtension)"
        in hci_set_data_length
    )
    assert "HciStatusUnsupportedFeatureParam" in hci_set_data_length


def test_hci_local_supported_features_matches_advertised_bitmap():
    source = Path(__file__).resolve().parents[1] / "src/bl808/blecontroller.nim"
    text = source.read_text(encoding="utf-8")

    assert "HciOpLeReadLocalSupportedFeatures = 0x2003'u16" in text
    assert "sendLeReadLocalSupportedFeaturesComplete" in text

    command_dispatch = text.split("proc completeHciCommand", 1)[1].split(
        "nim_hci_debug_stage = 0x4110'u32", 1
    )[0]
    assert "HciOpLeReadLocalSupportedFeatures" in command_dispatch

    feature_complete = text.rsplit(
        "proc sendLeReadLocalSupportedFeaturesComplete", 1
    )[1].split("proc sendLeReadLocalP256Complete", 1)[0]
    assert "var rsp: array[9, uint8]" in feature_complete
    assert "nimBleFeatureByte(NimBleConservativeLeFeatures, i)" in feature_complete
    assert "sendCmdCompletePayload(opcode, addr rsp[0], rsp.len.uint8)" in feature_complete


def test_remote_feature_exchange_tracks_feature_req_and_hci_pending_event():
    source = Path(__file__).resolve().parents[1] / "src/bl808/blecontroller.nim"
    text = source.read_text(encoding="utf-8")

    assert "HciOpLeReadRemoteFeatures = 0x2016'u16" in text

    record_peer_features = text.split("proc vendorRecordPeerFeatures", 1)[1].split(
        "proc vendorMaybeCompleteRemoteFeatures", 1
    )[0]
    assert "opcode != LlcpFeatureReq" in record_peer_features
    assert "opcode != LlcpFeatureRsp" in record_peer_features
    assert "opcode != LlcpSlaveFeatureReq" in record_peer_features
    assert "nim_vendor_llcp_state.peerFeaturesKnown = true" in record_peer_features

    used_features = text.split("proc vendorLlcpUsedFeaturesForPeer", 1)[1].split(
        "proc vendorRecordUsedFeatures", 1
    )[0]
    assert "NimBleConservativeLeFeatures and" in used_features
    assert "nim_vendor_llcp_state.peerFeatures" in used_features

    feature_response = text.split("proc vendorBuildFeatureRsp", 1)[1].split(
        "proc vendorBuildPhyRsp", 1
    )[0]
    assert "vendorLlcpUsedFeaturesForPeer()" in feature_response
    assert "vendorBuildFeaturePdu(LlcpFeatureRsp, features)" in feature_response

    observe_block = text.split("proc vendorObserveLlcpPdu", 1)[1].split(
        "proc vendorObserveLlcpEm", 1
    )[0]
    assert "vendorMaybeCompleteRemoteFeatures(conhdl)" in observe_block

    remote_features_command = text.split(
        "proc sendLeReadRemoteFeaturesCommand", 1
    )[1].split("proc nimBleRequestedPhySupported", 1)[0]
    assert "sendCmdStatus(opcode, result)" in remote_features_command
    assert "remoteFeaturesEventPending = true" in remote_features_command
    assert "llc_llcp_feats_req_pdu_send(handle)" in remote_features_command

    command_dispatch = text.split("proc completeHciCommand", 1)[1].split(
        "nim_hci_debug_stage = 0x4110'u32", 1
    )[0]
    assert "HciOpLeReadRemoteFeatures" in command_dispatch
    assert "sendLeReadRemoteFeaturesCommand(opcode, params, paramLen)" in command_dispatch


def test_read_remote_version_info_is_async_command_status_then_complete_event():
    source = Path(__file__).resolve().parents[1] / "src/bl808/blecontroller.nim"
    text = source.read_text(encoding="utf-8")

    assert "HciOpReadRemoteVersionInfo = 0x041D'u16" in text

    command = text.rsplit("proc sendReadRemoteVersionInfoCommand", 1)[1].split(
        "proc nimBleConnectionUpdateParamStatus", 1
    )[0]
    assert "sendCmdStatus(opcode, result)" in command
    assert "sendRemoteVersionInfoComplete(handle, result)" in command
    assert "sendCmdComplete" not in command

    legacy_handler = text.split("proc hci_rd_rem_ver_info_cmd_handler", 1)[1].split(
        "proc hci_vs_set_max_rx_size_and_time_cmd_handler", 1
    )[0]
    assert "sendReadRemoteVersionInfoCommand(opcode, params, 2'u8)" in legacy_handler
    assert "sendCmdComplete" not in legacy_handler

    command_dispatch = text.split("proc completeHciCommand", 1)[1].split(
        "nim_hci_debug_stage = 0x4110'u32", 1
    )[0]
    assert "HciOpReadRemoteVersionInfo" in command_dispatch
    assert "sendReadRemoteVersionInfoCommand(opcode, params, paramLen)" in command_dispatch


def test_connection_update_command_queues_llcp_and_completes_at_instant():
    source = Path(__file__).resolve().parents[1] / "src/bl808/blecontroller.nim"
    text = source.read_text(encoding="utf-8")

    assert "HciOpLeConnectionUpdate = 0x2013'u16" in text

    command = text.split("proc sendLeConnectionUpdateCommand", 1)[1].split(
        "proc nimBleRequestedPhySupported", 1
    )[0]
    assert "nimBleConnectionUpdateParamStatus(params, paramLen, handle)" in command
    assert "vendorStartConnectionUpdate(handle, hciLeConnUpdateReq(params))" in command
    assert "sendCmdStatus(opcode, result)" in command
    assert "sendLeConnectionUpdateComplete(handle" not in command

    llcp_start = text.split("proc vendorStartConnectionUpdate", 1)[1].split(
        "proc vendorBuildChannelMapInd", 1
    )[0]
    assert "vendorBuildConnectionUpdateInd(req)" in llcp_start
    assert "vendorQueueLlcpPdu(conhdl, pdu)" in llcp_start
    assert "nimConnStorePendingConnectionUpdate" in llcp_start

    apply_update = text.split("proc nimConnApplyPendingConnectionUpdate", 1)[1].split(
        "proc nimConnRecordTxHeader", 1
    )[0]
    assert "sendLeConnectionUpdateCompleteValues" in apply_update
    assert "connUpdateNotifyHost = false" in apply_update

    command_dispatch = text.split("proc completeHciCommand", 1)[1].split(
        "if opcode == HciOpLeReadRemoteFeatures", 1
    )[0]
    assert "HciOpLeConnectionUpdate" in command_dispatch
    assert "sendLeConnectionUpdateCommand(opcode, params, paramLen)" in command_dispatch


def test_remote_connection_parameter_reply_is_not_fake_success():
    source = Path(__file__).resolve().parents[1] / "src/bl808/blecontroller.nim"
    text = source.read_text(encoding="utf-8")

    reply = text.split(
        "proc hci_le_rem_con_param_req_reply_cmd_handler", 1
    )[1].split("proc hci_le_rem_con_param_req_neg_reply_cmd_handler", 1)[0]
    assert "status = HciStatusCommandDisallowed" in reply
    assert "sendLeConnectionUpdateComplete" not in reply

    neg_reply = text.split(
        "proc hci_le_rem_con_param_req_neg_reply_cmd_handler", 1
    )[1].split("proc hci_le_req_peer_sca_cmd_handler", 1)[0]
    assert "status = HciStatusCommandDisallowed" in neg_reply
    assert "sendHandleCmdComplete(opcode, status, handle)" in neg_reply


def test_ble_controller_trng_polling_masks_done_interrupt():
    source = Path(__file__).resolve().parents[1] / "src/bl808/blecontroller.nim"
    text = source.read_text(encoding="utf-8")

    read_block = text.split("proc bleTrngReadBlock", 1)[1].split(
        "proc bleFillRandomBytesUnlocked", 1
    )[0]
    assert "TrngIntMask" in read_block
    assert "bleTrngClearInterrupt()" in read_block


def test_hci_p256_crypto_outputs_are_marshaled_from_controller_buffer():
    source = Path(__file__).resolve().parents[1] / "src/bl808/blecontroller.nim"
    text = source.read_text(encoding="utf-8")

    read_p256 = text.rsplit("proc sendLeReadLocalP256Complete", 1)[1].split(
        "proc sendLeGenerateDhKeyComplete", 1
    )[0]
    assert "p256ControllerBaseMultLe(" in read_p256
    assert "addr pka_result[0]" in read_p256
    assert "addr pka_result[ECC_KEY_LEN]" in read_p256
    assert "addr evt[2]" not in read_p256.split("p256ControllerBaseMultLe(", 1)[1].split(
        "bleP256Result", 1
    )[0]
    assert "c_memcpy(addr evt[2], addr pka_result[0]" in read_p256

    dh_key = text.rsplit("proc sendLeGenerateDhKeyComplete", 1)[1].split(
        "proc hci_rd_rssi_cmd_handler", 1
    )[0]
    assert "p256ControllerScalarMultLe(" in dh_key
    assert "addr pka_result[0]" in dh_key
    assert "addr pka_result[ECC_KEY_LEN]" in dh_key
    assert "addr evt[2]" not in dh_key.split("p256ControllerScalarMultLe(", 1)[1].split(
        "bleP256Mark(0x00000330", 1
    )[0]
    assert "c_memcpy(addr evt[2], addr pka_result[0]" in dh_key
