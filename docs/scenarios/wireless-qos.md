# Wireless QoS evidence (TC-WQOS-01)

Run `sudo ./scripts/scenario.sh --duration 30 wireless_qos`. Best Effort starts
first, with a two-second warm-up, and continues through Voice/Video measurement.
Its lifetime includes startup/grace time, so wall-clock runtime exceeds
`--duration`. `--be-proto udp --be-rate 0` explicitly sends `iperf3 -b 0`.
Unsuffixed rates are bits/s; K/M/G use decimal units. DSCP 0 is explicit for BE.
For remote mode, synchronize the updated tools first with
`./scripts/remote_client.sh sync`; the Video client now accepts per-scenario
quality limits.

The final `logs/wireless_qos_audit.json` has four possible verdicts:

| Verdict | Meaning |
| --- | --- |
| PASS | The selected audit profile's criteria are satisfied; see `audit_profile` and `mapping_basis`. |
| FAIL | Valid measurements show a loss, marking, jitter, mapping or EDCA failure. |
| INVALID | Missing/failed generators, unreadable captures, insufficient traffic or measurement overlap. |
| INCONCLUSIVE | Quality can be measured, but some wireless evidence is unavailable. |

`quality_status` records the service quality separately. Without capture, client
metrics cannot prove DSCP preservation, jitter, TID or the radio bottleneck;
they never produce an overall PASS. Virtual mode cannot produce a WMM PASS.
Wired BE and uplink BE are different congestion domains and do not establish
the downlink WMM claim.

## Audit profiles

`practical` is the default, including for archived context files without a
profile. It checks measured Voice/Video loss <=1%, DSCP preservation >=95%,
jitter <20 ms, active concurrent BE on Wi-Fi, and AP TX EDCA. If OTA payloads
cannot be decrypted, it accepts the presence of AC_VO, AC_VI and AC_BE in
QoS Data frames filtered by the exact AP BSSID/transmitter and station receiver
MAC. It does not require radio telemetry or 95% decoded-flow coverage.

This MAC/TID fallback identifies the station and its access categories, not
the individual IP service flow. Frame counts may include retries and other
traffic of that station. The report keeps decoded mapping `NOT_VERIFIED`, sets
`mapping_basis=MAC_TID`, and prints notes explaining the inference. It never
reports a measured DSCP/TID preservation percentage for encrypted frames.
A positive decoded mapping failure still causes FAIL in either profile.

`strict` retains the decoded-flow coverage and radio bottleneck requirements.
Set `WQOS_AUDIT_PROFILE="strict"` in configuration for new scenario runs, or
pass `--audit-profile strict` to `tools/wireless_qos_audit.py` for replay.
Set the value to `practical` to use the default criteria explicitly.

Both profiles preserve the EDCA tables and captured-file list. The service
table includes packet counts, measured DSCP preservation, maximum jitter and
OTA frame counts; OTA frame counts are station AC observations, not deliveries.

Client metrics are retained in `logs/wireless_qos_client_audit.json` and the
run directory printed by the script. PCAP evaluation includes them, preserving
client failures rather than overwriting them with packet-count results.
`state/latest_wqos_context.json` and the run's `context.json` identify the
station, BSSID, duration and evidence paths. When auditing archived captures,
pass the matching archived `--context-json`; do not combine different runs.
The WQoS Video client uses loss <=1% without the standalone UHD VOD tool's
35 Mbps minimum, since this profile sends 20 Mbps at 1.2x speed. Standalone
VOD retains its original throughput and loss defaults. A completed quality
failure is FAIL; a client that produces no metrics is INVALID.

## Packet measurement

The audit uses one receiver capture, preferring the station Wi-Fi capture.
RTP sequence/timestamp/SSRC and Video sequence/send timestamp identify unique
packets across NAT. Duplicate observations/retries never count as extra
deliveries. NAT Video probes and acknowledgments are excluded. Sender packets
define the loss denominator, including missing tails within the window.

Downlink Voice/Video use the same steady-state window derived entirely from
WAN timestamps, intersected with active BE traffic. At least 80% of the requested
duration (and at least two seconds) must be observed, with no empty BE second
inside the window. Voice uplink is checked separately over the call, which starts
after BE warm-up. Receiver timestamps measure local RTP interarrival jitter;
they are never subtracted from another host's timestamps. The maximum smoothed
RFC 3550 jitter must be below 20 ms for the G.711 8000 Hz clock.
Video uses the same 20 ms limit on smoothed interarrival variation calculated
from its embedded send timestamps; clock origins cancel in time differences.

Strict OTA flow mapping requires decoded IP/transport headers, the target AP and station,
and matching Voice/Video packet identities. BE uses up to 64 reference packet
identities per second to bound memory use, for both UDP and TCP. At least 95%
of the reference identities must appear in decoded OTA evidence; a small number
of unrelated frames cannot establish mapping. Encrypted frames with visible TIDs
alone cannot establish a DSCP-to-flow association. Supply a capture that tshark
can decrypt using its configured WLAN keys, or an already decoded capture.
Voice must map to AC_VO (TID 6/7), Video to AC_VI (TID 4/5), and BE to AC_BE
(TID 0/3). AF41 to UP 4 is recommended by
[RFC 8325](https://www.rfc-editor.org/rfc/rfc8325.html#section-4.2.3);
TID 5 remains acceptable for the AC_VI objective.

## Radio congestion telemetry

An offered rate calculated from PHY bitrate and end-to-end UDP loss do not
locate the bottleneck. Set `WQOS_CONGESTION_EVIDENCE_JSON` to telemetry collected
from the AP for this run. The script prints its run ID before traffic starts.
The JSON must identify that run/BSSID and cover the measurement window:

```json
{
  "run_id": "tc_wqos_01_<timestamp>_<pid>",
  "domain": "wifi",
  "bssid": "00:11:22:33:44:55",
  "source": "AP radio queue counters collected during this run",
  "start_epoch": 1791368700.0,
  "end_epoch": 1791368750.0,
  "wifi_queue_backlog_packets": 120,
  "wifi_queue_drops_delta": 400,
  "channel_busy_pct": 95
}
```

At least one of positive Wi-Fi queue backlog, positive Wi-Fi queue drop delta,
or channel busy >=90% must be measured. Counters must describe the relevant
radio/queue, not a WAN interface. The audit verifies the supplied identity,
time coverage and counters; it does not collect vendor-specific telemetry or
independently authenticate its source. Missing or uncovered telemetry leaves
strict mode INCONCLUSIVE; practical mode prints an informational note and
uses the observed concurrent BE load condition. The AP downlink EDCA evidence is supplied separately
by the existing DUT collector.

For an experiment attributing improvement specifically to priority marking,
also compare repeated runs at the same radio conditions and offered load with
Voice/Video marked CS0. This scenario verifies the marked classes under
load; a practical PASS does not locate the radio bottleneck or claim a causal
effect from a single observation.

## Offline verification

```bash
python3 -m unittest discover -s tests -v
```

Tests generate synthetic Ethernet and 802.11 PCAPs and exercise real tshark and
CLI evaluators. They do not configure interfaces or send traffic to a DUT.
