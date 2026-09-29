# GATEWAY PERFORMANCE VERIFICATION TEST PLAN

This document defines the quantitative test methodology, packet profile specifications, environmental parameters, and acceptance criteria for evaluating carrier-grade Gateway and Access Point (AP) performance under high-load, mixed-traffic, and rate-mismatched conditions.

---

## 1. Test Architecture & Objectives

The test suite validates:
1. **Wire-Rate Datapath:** Guaranteeing 100% theoretical wire-rate forwarding without packet loss for bidirectional unicast and multicast streams (1024-byte packets).
2. **Buffer Absorption under Rate Mismatch:** Verifying that incoming 1 Gbps WAN bursts into a 100 Mbps downstream Fast Ethernet link do not cause buffer overflow or tail drop.
3. **Application Quality of Experience (QoE):** Ensuring that interactive Cloud Gaming (GeForce NOW) and high-bitrate 4K UHD video (1.2x VOD) operate flawlessly on 100M endpoints.
4. **Bandwidth Preservation & Resource Allocation:** Guaranteeing that concurrent wireless usage across 2.4 GHz, 5 GHz, 6 GHz, and wired ports achieves full 1 Gbps wire rate with $\le 1.0\%$ deviation.
5. **Voice QoS Isolation:** Confirming that high-priority Wi-Fi Phone calls do not degrade wired PC throughput by more than $1.0\%$.

---

## 2. Test Cases Specification

### 2.1 TC-WR-01: Bidirectional Wire-Rate Unicast Forwarding
* **Objective:** Verify zero packet drop when forwarding full-duplex 1024-byte unicast traffic through the gateway datapath.
* **Traffic Profile:**
  * Frame size: 1024 bytes (L2 Ethernet frame)
  * Direction: Bidirectional (WAN $\leftrightarrow$ LAN PC)
  * Target rate: 950 Mbps (wire-rate line speed minus framing overhead)
* **Measurement Mechanism:** `tools/traffic_generator.py unicast-send` and `unicast-recv`.
* **Pass Criteria:**
  * Packet Loss Rate: $\mathbf{0.00\%}$
  * Verdict: `PASS`

### 2.2 TC-WR-02: Wire-Rate Multicast Forwarding
* **Objective:** Ensure multicast IPTV streams are forwarded across the bridge/switch without software CPU slow-path packet drops.
* **Traffic Profile:**
  * Group Address: `239.255.0.1` (UDP port 5003)
  * Frame size: 1024 bytes
  * Direction: Downstream (WAN $\to$ LAN STB/PC)
  * Frame count: 2,000 packets
* **Measurement Mechanism:** `tools/traffic_generator.py mcast-send` and `mcast-recv`.
* **Pass Criteria:**
  * Packet Loss Rate: $\mathbf{0.00\%}$ (All 2,000 packets delivered)
  * Verdict: `PASS`

---

### 2.3 TC-RM-01: WAN-to-LAN Rate Mismatch Burst (Case 1: 50% Load, 53 Frames)
* **Objective:** Verify that the gateway absorbs 1 Gbps ingress bursts targeted at a 100 Mbps Fast Ethernet endpoint.
* **Traffic Profile:**
  * Frame size: 1500 bytes
  * Ingress rate: 1000 Mbps (WAN link)
  * Egress rate: 100 Mbps (LAN STB link)
  * Burst length: 53 frames continuous
  * Burst load (Duty cycle): 50% (Active time = Idle time)
  * Bursts emitted: 20 bursts (Total 1,060 frames)
* **Buffer Requirement:** Minimum switch buffer absorption: $53 - 5.3 \approx 48\text{ frames} \approx 73\text{ KB}$.
* **Pass Criteria:**
  * Total frames received: 1,060 / 1,060
  * Packet Loss: $\mathbf{0.00\%}$
  * Verdict: `PASS`

### 2.4 TC-RM-02: WAN-to-LAN Rate Mismatch Burst (Case 2: 16% Load, 100 Frames)
* **Objective:** Verify large burst absorption with extended inter-burst draining intervals.
* **Traffic Profile:**
  * Frame size: 1500 bytes
  * Ingress rate: 1000 Mbps
  * Egress rate: 100 Mbps
  * Burst length: 100 frames continuous
  * Burst load: 16% (Inter-burst idle time $\approx 5.25 \times$ active burst duration)
  * Bursts emitted: 20 bursts (Total 2,000 frames)
* **Buffer Requirement:** Minimum switch buffer absorption: $100 - 10 = 90\text{ frames} \approx 137\text{ KB}$.
* **Pass Criteria:**
  * Total frames received: 2,000 / 2,000
  * Packet Loss: $\mathbf{0.00\%}$
  * Verdict: `PASS`

---

### 2.5 TC-APP-01: GeForce NOW Cloud Gaming Network Test
* **Objective:** Verify that interactive UDP game streaming across the 100M rate-mismatched link achieves real-time responsiveness without bufferbloat.
* **Traffic Profile:**
  * Protocol: UDP streaming (slice size 1200 bytes)
  * Frame rate: 60 FPS
  * Target bitrate: 25 Mbps
  * Pacing: Isochronous frame slices
* **Measurement Tool:** `tools/geforce_now_tester.py`.
* **Pass Criteria:**
  * Packet Loss: $\mathbf{0.00\%}$
  * RFC 3550 Interarrival Jitter: $\mathbf{\le 2.0\text{ ms}}$
  * App Diagnostic Status: `NORMAL`
  * Verdict: `PASS`

### 2.6 TC-APP-02: UHD+Dolby VOD at 1.2x Accelerated Playback
* **Objective:** Validate playback stability for 4K UHD video streams accelerated to 1.2x on a 100M STB.
* **Traffic Profile:**
  * Base bitrate: 35 Mbps (4K UHD + Dolby Atmos)
  * Playback multiplier: 1.2x $\to$ Effective delivery rate: $\approx 42\text{ Mbps}$
  * Packet size: 1316 bytes (7 $\times$ 188-byte MPEG-TS packets)
* **Measurement Tool:** `tools/vod_stream_tester.py`.
* **Pass Criteria:**
  * Sustained throughput: $\mathbf{\ge 35.0\text{ Mbps}}$
  * Buffer Underrun / Stall Events: $\mathbf{\le 1}$
  * Playback Status: `NORMAL`
  * Verdict: `PASS`

---

### 2.7 TC-SIM-01: Simultaneous Wired & Tri-band Wireless Throughput
* **Objective:** Guarantee that simultaneous download across 2.4 GHz, 5 GHz, 6 GHz, and Wired LAN utilizes full 1 Gbps uplink capacity without internal bottleneck degradation.
* **Methodology (5-Trial Averaging):**
  1. Measure Wireless-only throughput ($A$): Aggregate parallel iperf3 across 2.4G, 5G, 6G. Average of 5 trials.
  2. Measure Wired-only throughput ($B$): iperf3 on Gigabit PC. Average of 5 trials.
  3. Measure Simultaneous throughput ($C$): Aggregate parallel iperf3 across PC + 2.4G + 5G + 6G. Average of 5 trials.
* **Preservation Formula:**
  $$\Delta = \frac{|C - B|}{B} \times 100\%$$
* **Pass Criteria:**
  * $\Delta \mathbf{\le 1.00\%}$
  * Verdict: `PASS`

---

### 2.8 TC-QOS-01: Wired PC Throughput during Active Wi-Fi Phone Calling
* **Objective:** Verify that voice traffic (SIP/RTP G.711) prioritization does not cause softirq spikes or throughput loss on the wired PC.
* **Methodology:**
  1. Measure baseline PC throughput ($A$) via iperf3 for 4 seconds.
  2. Initiate 2 concurrent Wi-Fi phone calls sending G.711 RTP (20ms packets, DSCP EF / 46).
  3. Measure PC throughput ($B$) while both calls are active.
* **Impact Formula:**
  $$\Delta_{\text{voice}} = \frac{|A - B|}{A} \times 100\%$$
* **Pass Criteria:**
  * Throughput Degradation: $\Delta_{\text{voice}} \mathbf{\le 1.00\%}$
  * Voice call loss: $< 2.0\%$
  * Verdict: `PASS`

---

## 3. Execution Commands Summary

```bash
# 1. Start Lab Topology
sudo ./scripts/setup.sh --virtual

# 2. Run Test Suite
sudo ./scripts/scenario.sh all

# 3. Verify Compliance and View Evidence
./scripts/verify_compliance.sh

# 4. Clean Lab
sudo ./scripts/cleanup.sh
```
