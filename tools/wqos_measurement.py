#!/usr/bin/env python3
"""Evidence-based measurements for TC-WQOS-01 (no network configuration)."""

import argparse
import json
import math
import struct
import subprocess
import tempfile
from pathlib import Path


class EvidenceError(ValueError):
    """Missing, malformed, or unreadable measurement evidence."""


def load_json(path):
    try:
        result = json.loads(Path(path).read_text())
        if not isinstance(result, dict):
            raise ValueError("expected a JSON object")
        return result
    except (OSError, ValueError, TypeError) as exc:
        raise EvidenceError(f"Cannot read evidence {path}: {exc}") from exc


def tshark_rows(path, display_filter, fields):
    """Stream fields, preserving tool errors rather than treating them as zero traffic."""
    if not path:
        raise EvidenceError("Capture path is missing")
    cmd = ["tshark", "-n", "-r", "-", "-Y", display_filter,
           "-T", "fields", "-E", "occurrence=f"]
    for field in fields:
        cmd.extend(["-e", field])
    try:
        with open(path, "rb") as source, tempfile.TemporaryFile(mode="w+") as errors:
            with subprocess.Popen(cmd, stdin=source, stdout=subprocess.PIPE,
                                  stderr=errors, text=True) as process:
                for line in process.stdout:
                    yield line.rstrip("\n").split("\t")
                if process.wait() != 0:
                    errors.seek(0)
                    raise EvidenceError(f"tshark failed for {path}: {errors.read().strip()}")
    except OSError as exc:
        raise EvidenceError(f"Cannot dissect {path}: {exc}") from exc


def packet_identity(service, payload):
    """Transport identities survive NAT and distinguish retransmissions/duplicates."""
    if service == "voice" and len(payload) >= 12 and payload[0] >> 6 == 2:
        return payload[2:12]  # RTP sequence, timestamp and SSRC
    if service == "video" and len(payload) >= 20:
        magic, stream_id, _ = struct.unpack("!III", payload[:12])
        if magic == 0x55484456 and stream_id != 0xFFFFFFFF:
            return payload[:20]  # Includes send timestamp; excludes NAT probes/ACKs.
    return None


def read_capture(path, server_ip, voice_ports, video_ports, be_ports):
    services = {name: {"downlink": {}, "uplink": {}} for name in ("voice", "video")}
    be = {"packets": 0, "bytes": 0, "first": None, "last": None, "bins": set(),
          "samples": {}, "sample_bins": {}}
    fields = ["frame.time_epoch", "ip.src", "ip.dst", "udp.srcport", "udp.dstport",
              "udp.payload", "ip.dsfield.dscp", "tcp.srcport", "tcp.dstport", "ip.len",
              "tcp.seq_raw", "tcp.len"]
    for row in tshark_rows(path, "ip and (udp or tcp)", fields):
        if len(row) != len(fields):
            raise EvidenceError(f"Malformed tshark row in {path}")
        ts, src, dst, sport, dport, payload, dscp, tcp_sport, tcp_dport, length, tcp_seq, tcp_len = row
        try:
            ts = float(ts)
            direction = "downlink" if src == server_ip else "uplink" if dst == server_ip else None
            if direction is None:
                continue
            server_port = int((sport or tcp_sport) if direction == "downlink" else (dport or tcp_dport))
            if server_port in be_ports and direction == "downlink":
                # TCP ACK/control packets alone cannot demonstrate downstream load.
                if int(length) > 100:
                    be["packets"] += 1
                    be["bytes"] += int(length)
                    be["first"] = ts if be["first"] is None else min(be["first"], ts)
                    be["last"] = ts if be["last"] is None else max(be["last"], ts)
                    be["bins"].add(math.floor(ts))
                    second = math.floor(ts)
                    if be["sample_bins"].get(second, 0) < 64:
                        key = (("tcp", tcp_seq, tcp_len) if tcp_sport
                               else bytes.fromhex(payload.replace(":", ""))[:12])
                        if key and key not in be["samples"]:
                            be["samples"][key] = ts
                            be["sample_bins"][second] = be["sample_bins"].get(second, 0) + 1
                continue
            service = "voice" if server_port in voice_ports else "video" if server_port in video_ports else None
            if service is None or not sport:
                continue
            raw = bytes.fromhex(payload.replace(":", ""))
            key = packet_identity(service, raw)
            if key is not None:
                key = (server_port, key)
                records = services[service][direction]
                if key not in records:
                    records[key] = (ts, int(dscp), raw)
        except (ValueError, IndexError) as exc:
            raise EvidenceError(f"Malformed transport evidence in {path}: {exc}") from exc
    return services, be


def rtp_jitter(records):
    """RFC 3550 interarrival jitter per SSRC, G.711 clock 8000 Hz, milliseconds."""
    states = {}
    maximum = None
    for arrival, _, payload in sorted(records.values()):
        _, _, sequence, timestamp, ssrc = struct.unpack("!BBHII", payload[:12])
        previous = states.get(ssrc)
        jitter = 0.0
        if previous:
            last_arrival, last_timestamp, last_sequence, jitter = previous
            delta = (timestamp - last_timestamp + 2**31) % 2**32 - 2**31
            # Reordering is retained; RTP timestamp wrap is handled explicitly.
            jitter += (abs((arrival - last_arrival) * 1000 - delta / 8) - jitter) / 16
            maximum = jitter if maximum is None else max(maximum, jitter)
        states[ssrc] = (arrival, timestamp, sequence, jitter)
    return maximum


def video_jitter(records):
    """Smoothed interarrival variation from Video's embedded send timestamps.

    Only time differences are used, so sender and receiver clock origins do
    not need synchronization. This is packet jitter, not playback buffer depth.
    """
    states = {}
    maximum = None
    for arrival, _, payload in sorted(records.values()):
        _, stream_id, _, sent = struct.unpack("!IIId", payload[:20])
        if not math.isfinite(sent):
            raise EvidenceError("Non-finite Video send timestamp")
        jitter = 0.0
        if stream_id in states:
            last_arrival, last_sent, jitter = states[stream_id]
            delta = abs((arrival - last_arrival) - (sent - last_sent)) * 1000
            jitter += (delta - jitter) / 16
            maximum = jitter if maximum is None else max(maximum, jitter)
        states[stream_id] = (arrival, sent, jitter)
    return maximum


def compare_direction(sent, received, dscp, window=None):
    selected = {key: value for key, value in sent.items()
                if window is None or window[0] <= value[0] <= window[1]}
    matched = {key: received[key] for key in selected if key in received}
    count = len(selected)
    loss = 100 * (count - len(matched)) / count if count else None
    preservation = 100 * sum(value[1] == dscp for value in matched.values()) / len(matched) if matched else None
    marked = 100 * sum(value[1] == dscp for value in selected.values()) / count if count else None
    return {"sent_packets": count, "received_packets": len(matched), "loss_pct": loss,
            "dscp_preservation_pct": preservation, "sender_dscp_pct": marked}, selected, matched


def ota_mapping(path, expected, bssid, station_mac, voice_ports, video_ports, be_ports,
                voice_dscp=46, video_dscp=34):
    """Require decoded test-flow identities, AP→STA direction and actual QoS TIDs.

    Encrypted captures without usable decryption keys cannot prove DSCP mapping.
    Duplicate retry frames count once; conflicting TIDs remain a failure.
    """
    result = {name: {"status": "NOT_VERIFIED", "matched_packets": 0,
                     "mapping_pct": None, "coverage_pct": None, "observed_tids": []} for name in expected}
    if not path or not bssid or not station_mac:
        return result
    found = {name: {} for name in expected}
    flt = f"wlan.fc.type == 2 and wlan.bssid == {bssid} and wlan.ta == {bssid} and wlan.ra == {station_mac} and (udp or tcp)"
    fields = ["udp.srcport", "udp.payload", "ip.dsfield.dscp", "wlan.qos.tid",
              "tcp.srcport", "tcp.seq_raw", "tcp.len"]
    for row in tshark_rows(path, flt, fields):
        try:
            port, raw, dscp, tid, tcp_port, tcp_seq, tcp_len = row
            port, dscp, tid = int(port or tcp_port), int(dscp), int(tid)
            name = "voice" if port in voice_ports else "video" if port in video_ports else "best_effort" if port in be_ports else None
            if name not in expected:
                continue
            payload = bytes.fromhex(raw.replace(":", ""))
            if tcp_port:
                if name != "best_effort" or int(tcp_len) <= 0:
                    continue
                key = ("tcp", tcp_seq, tcp_len)
            else:
                identity = packet_identity(name, payload) if name != "best_effort" else payload[:12]
                key = (port, identity) if name != "best_effort" and identity else identity
            if not key:
                continue
            if key not in expected[name]:
                continue
            found[name].setdefault(key, set()).add((dscp, tid))
        except (ValueError, IndexError) as exc:
            raise EvidenceError(f"Malformed OTA evidence: {exc}") from exc
    targets = {"voice": (voice_dscp, {6, 7}), "video": (video_dscp, {4, 5}), "best_effort": (0, {0, 3})}
    for name, packets in found.items():
        if packets:
            target_dscp, tids = targets[name]
            good = sum(all(ds == target_dscp and tid in tids for ds, tid in observations)
                       for observations in packets.values())
            pct = 100 * good / len(packets)
            coverage = 100 * len(packets) / len(expected[name]) if expected[name] else None
            enough = len(packets) >= (50 if name == "voice" else 100)
            enough = enough and coverage is not None and coverage >= 95
            status = "FAIL" if pct < 95 else "PASS" if enough else "NOT_VERIFIED"
            result[name] = {"status": status,
                            "matched_packets": len(packets), "mapping_pct": pct, "coverage_pct": coverage,
                            "observed_tids": sorted({tid for observations in packets.values() for _, tid in observations})}
    return result


def ota_mac_categories(path, bssid, station_mac):
    """Observe AP→station access categories without decrypting the payload.

    These are station-level frame observations, not flow identities or loss.
    Retries remain in the frame counts; missing monitor frames are not DUT loss.
    """
    result = {"status": "NOT_VERIFIED", "basis": "MAC_TID", "bssid": bssid,
              "station_mac": station_mac, "direction": "AP_TO_STA", "total_frames": 0,
              "protected_frames": 0, "decoded_ip_frames": 0, "categories": {}}
    if not path or not bssid or not station_mac:
        return result
    tids = {tid: 0 for tid in range(8)}
    flt = (f"wlan.fc.type_subtype == 0x28 and wlan.bssid == {bssid} "
           f"and wlan.ta == {bssid} and wlan.ra == {station_mac}")
    for row in tshark_rows(path, flt, ["wlan.qos.tid", "wlan.fc.protected", "ip.src"]):
        try:
            tid, protected, ip_src = row
            if not tid:
                continue
            tid = int(tid)
            if tid not in tids:
                continue
            tids[tid] += 1
            result["total_frames"] += 1
            result["protected_frames"] += protected.lower() in ("1", "true")
            result["decoded_ip_frames"] += bool(ip_src)
        except (ValueError, IndexError) as exc:
            raise EvidenceError(f"Malformed OTA MAC/TID evidence: {exc}") from exc
    for name, ac, members in (("voice", "AC_VO", (6, 7)), ("video", "AC_VI", (4, 5)),
                               ("best_effort", "AC_BE", (0, 3))):
        count = sum(tids[tid] for tid in members)
        result["categories"][name] = {"ac": ac, "frame_count": count,
            "observed_tids": [tid for tid in members if tids[tid]],
            "status": "OBSERVED" if count else "NOT_OBSERVED"}
    result["status"] = "OBSERVED" if result["total_frames"] else "NOT_VERIFIED"
    return result


def congestion_status(context, window, receiver_be):
    """Only radio telemetry covering this measurement window proves its bottleneck."""
    if context.get("congestion_source") != "wifi" or context.get("be_direction", "downlink") != "downlink":
        return "NOT_VERIFIED"
    if not window or receiver_be["packets"] == 0:
        return "NOT_VERIFIED"
    path = context.get("congestion_evidence_json")
    if not path:
        return "NOT_VERIFIED"
    evidence = load_json(path)
    # This is supplied telemetry, not a conclusion inferred from UDP drops elsewhere.
    if (evidence.get("run_id") != context.get("run_id") or evidence.get("domain") != "wifi"
            or evidence.get("bssid", "").lower() != context.get("bssid", "").lower()
            or not evidence.get("source")):
        raise EvidenceError("Congestion telemetry does not identify this run/BSSID")
    try:
        first, last = float(evidence["start_epoch"]), float(evidence["end_epoch"])
        backlog = float(evidence.get("wifi_queue_backlog_packets", 0))
        drops = float(evidence.get("wifi_queue_drops_delta", 0))
        busy = float(evidence.get("channel_busy_pct", 0))
        if (not all(math.isfinite(v) for v in (first, last, backlog, drops, busy))
                or min(backlog, drops, busy) < 0 or busy > 100 or last < first):
            raise ValueError("non-finite or out-of-range telemetry")
        covers = first <= window[0] and last >= window[1]
    except (ValueError, TypeError, KeyError) as exc:
        raise EvidenceError("Invalid congestion telemetry counters/window") from exc
    return "PASS" if covers and (backlog > 0 or drops > 0 or busy >= 90) else "NOT_VERIFIED"


def audit_captures(wan_path, receiver_path, ota_path=None, context=None,
                   voice_ports=(10000,), video_ports=(5005,), be_ports=(5201,),
                   voice_dscp=46, video_dscp=34, max_loss=1.0, max_jitter=20.0):
    context = context or {}
    profile = context.get("audit_profile", "practical")
    result = {"test": "wireless_qos_multi_service", "mode": context.get("mode", "unknown"),
              "audit_profile": profile, "warnings": [],
              "overall_status": "INVALID", "verdict": "INVALID", "reasons": [], "services": {},
              "audit_evidence": {"wan_pcap": wan_path, "receiver_pcap": receiver_path, "ota_pcap": ota_path}}
    if context.get("be_direction", "downlink") != "downlink":
        result.update(overall_status="INCONCLUSIVE", verdict="INCONCLUSIVE",
                      reasons=["Uplink BE does not establish the downlink WMM congestion claim"])
        return result
    try:
        if profile not in ("practical", "strict"):
            raise EvidenceError(f"Unknown audit profile: {profile}")
        server_ip = context.get("server_ip", "10.10.0.1")
        wan, be = read_capture(wan_path, server_ip, voice_ports, video_ports, be_ports)
        receiver, rx_be = read_capture(receiver_path, server_ip, voice_ports, video_ports, be_ports)
        spans = [list(wan[name]["downlink"].values()) for name in ("voice", "video")]
        needs_radio_be = context.get("congestion_source", "wifi") == "wifi"
        if not all(spans) or be["first"] is None or (needs_radio_be and rx_be["packets"] == 0):
            raise EvidenceError("Missing downstream Voice, Video or Best Effort traffic")
        # All reference timestamps originate on the WAN capture clock. Receiver
        # timestamps are used only for local jitter, never cross-host subtraction.
        start = max(be["first"] + 1.0, *(min(v[0] for v in span) for span in spans))
        end = min(be["last"] - 0.2, *(max(v[0] for v in span) for span in spans))
        minimum = max(2.0, 0.8 * float(context.get("duration", 0)))
        if not math.isfinite(end - start) or end - start < minimum:
            raise EvidenceError("Insufficient common steady-state measurement window")
        window = (start, end)
        if any(second not in be["bins"] for second in range(math.ceil(start), math.floor(end))):
            raise EvidenceError("Best Effort traffic has a gap in the measurement window")
        result["measurement_window"] = {"start_epoch": start, "end_epoch": end, "duration_s": end - start}
        expected = {}
        failures = []
        for name, dscp in (("voice", voice_dscp), ("video", video_dscp)):
            metrics, selected, matched = compare_direction(wan[name]["downlink"], receiver[name]["downlink"], dscp, window)
            expected[name] = selected
            metrics.update({"service_name": name, "dscp_value": dscp,
                            "wan_packets": metrics["sent_packets"], "lan_packets": metrics["received_packets"]})
            if metrics["sent_packets"] < (50 if name == "voice" else 100):
                raise EvidenceError(f"Insufficient {name} packets")
            passed = (metrics["loss_pct"] <= max_loss and (metrics["dscp_preservation_pct"] or 0) >= 95
                      and (metrics["sender_dscp_pct"] or 0) >= 95)
            jitter = rtp_jitter(matched) if name == "voice" else video_jitter(matched)
            metrics["max_jitter_ms"] = jitter
            passed = passed and jitter is not None and jitter < max_jitter
            if name == "voice":
                uplink, _, _ = compare_direction(receiver[name]["uplink"], wan[name]["uplink"], dscp)
                metrics["uplink"] = uplink
                if not uplink["sent_packets"]:
                    raise EvidenceError("Missing voice uplink evidence")
                passed = (passed and uplink["loss_pct"] <= max_loss
                          and (uplink["dscp_preservation_pct"] or 0) >= 95
                          and (uplink["sender_dscp_pct"] or 0) >= 95)
            metrics["status"] = "PASS" if passed else "FAIL"
            if not passed:
                failures.append(f"{name} loss, DSCP or jitter threshold exceeded")
            result["services"][name] = metrics
        be_span = rx_be["last"] - rx_be["first"] if rx_be["packets"] else 0
        result["services"]["best_effort"] = {"status": "ACTIVE" if rx_be["packets"] else "NOT_OBSERVED_ON_WIFI", "dscp_value": 0,
            "wan_packets": be["packets"], "lan_packets": rx_be["packets"], "loss_pct": None,
            "throughput_mbps": rx_be["bytes"] * 8 / max(be_span, 0.001) / 1e6}
        expected["best_effort"] = {key: ts for key, ts in be["samples"].items() if start <= ts <= end}
        mapping = ota_mapping(ota_path, expected, context.get("bssid"), context.get("station_mac"),
                              voice_ports, video_ports, be_ports, voice_dscp, video_dscp)
        result["mapping"] = mapping
        mac_evidence = ota_mac_categories(ota_path, context.get("bssid"), context.get("station_mac"))
        result["mac_tid_evidence"] = mac_evidence
        if any(m["status"] == "FAIL" for m in mapping.values()):
            failures.append("Observed test-flow DSCP/TID mapping failure")
        result["congestion_status"] = congestion_status(context, window, rx_be)
        client_path = context.get("client_audit_json")
        if client_path:
            client = load_json(client_path)
            result["client_metrics"] = client
            if client.get("overall_status") == "INVALID":
                raise EvidenceError("Client metrics are invalid")
            if client.get("quality_status") == "FAIL":
                failures.append("Client quality check failed")
        result["quality_status"] = "FAIL" if failures else "PASS"
        missing = []
        if context.get("mode") in ("virtual", "unknown", None):
            missing.append("Physical Wi-Fi execution not verified")
        decoded = all(m["status"] == "PASS" for m in mapping.values())
        mac_observed = all(mac_evidence["categories"].get(name, {}).get("status") == "OBSERVED"
                           for name in ("voice", "video", "best_effort"))
        result["mapping_basis"] = "DECODED_FLOW" if decoded else "MAC_TID" if mac_observed else "IP_DSCP_ONLY"
        if not decoded:
            if profile == "strict":
                missing.append("Decoded OTA test-flow DSCP/TID mapping not fully verified")
            elif mac_observed:
                result["warnings"].append("ACs observed by AP/station MAC and TID; encrypted test flows are not individually correlated")
            else:
                missing.append("Expected station AC_VO, AC_VI and AC_BE not observed in OTA MAC/TID evidence")
        if result["congestion_status"] != "PASS":
            if profile == "strict":
                missing.append("Wi-Fi bottleneck telemetry not verified")
            else:
                result["warnings"].append("Concurrent Wi-Fi BE load verified; radio bottleneck location was not measured")
        if context.get("congestion_source", "wifi") != "wifi":
            missing.append("Wired BE does not establish the Wi-Fi load condition")
        status = "FAIL" if failures else "INCONCLUSIVE" if missing else "PASS"
        result.update(overall_status=status, verdict=status, reasons=failures + missing)
    except EvidenceError as exc:
        result["reasons"].append(str(exc))
    return result


def main():
    parser = argparse.ArgumentParser(description="Write run-scoped Wireless QoS measurement context")
    parser.add_argument("--output", required=True)
    parser.add_argument("--run-id", required=True)
    parser.add_argument("--mode", required=True)
    parser.add_argument("--duration", required=True, type=float)
    parser.add_argument("--server-ip", required=True)
    parser.add_argument("--bssid", default="")
    parser.add_argument("--station-mac", default="")
    parser.add_argument("--congestion-source", default="wifi")
    parser.add_argument("--be-direction", default="downlink")
    parser.add_argument("--congestion-evidence-json", default="")
    parser.add_argument("--client-audit-json", required=True)
    parser.add_argument("--audit-profile", choices=("practical", "strict"), default="practical")
    args = vars(parser.parse_args())
    path = Path(args.pop("output"))
    temporary = path.with_suffix(".tmp")
    temporary.write_text(json.dumps(args, indent=2))
    temporary.replace(path)


if __name__ == "__main__":
    main()
