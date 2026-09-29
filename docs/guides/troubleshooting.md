# Troubleshooting & Diagnostic Runbook

This guide covers common diagnostic procedures, error conditions, and operational gotchas for the **Gateway Performance & Wire-Rate Test Lab (`gwlab`)**.

---

## 1. Quick Diagnostic Checklist

Before running tests, perform these non-root health checks:

```bash
# 1. Check all required binaries and kernel features
./scripts/diagnose.sh

# 2. Check running topology state and supervised processes
./scripts/show_state.sh

# 3. Check WAN Server and LAN DHCP Client status
./scripts/wan_server.sh status
./scripts/client_dhcp.sh status

# 4. Preview test scenario without executing traffic
./scripts/scenario.sh --dry-run all
```

---

## 2. Common Issues & Solutions

### 2.1 Host Network Safety & NetworkManager Interference
* **Symptom:** Physical test NIC loses IP or automatically reconnects to the host network during testing.
* **Root Cause:** Host `NetworkManager` manages the physical adapter and overwrites netns link state.
* **Resolution:**
  - `scripts/lib/common.sh` automatically runs `nmcli device set <iface> managed no`.
  - To manually isolate:
    ```bash
    sudo nmcli device set <iface> managed no
    ```
  - On teardown, `scripts/cleanup.sh` automatically restores NetworkManager management.

### 2.2 Kea DHCP Server Startup Failures
* **Symptom:** `wan_server.sh start kea` fails or Kea exits immediately.
* **Checks:**
  1. **Log Path Sandbox Trap (Kea 3.0+)**:
     - Kea 3.0 rejects non-standard output file paths (`COMMAND_PROCESS_ERROR2: invalid path in output`).
     - *Fix*: Keep `"output": "stdout"` in `config/kea/kea-dhcp*.conf.in`. The launcher script safely redirects stdout to `logs/kea-dhcp*.log`.
  2. **Host AppArmor Lock**:
     - AppArmor profiles restrict Kea write access outside system directories.
     - *Fix*: `wan_server.sh` automatically unloads host profiles via:
       ```bash
       sudo apparmor_parser -R /etc/apparmor.d/usr.sbin.kea-dhcp4 2>/dev/null || true
       sudo apparmor_parser -R /etc/apparmor.d/usr.sbin.kea-dhcp6 2>/dev/null || true
       ```
  3. **Netns Socket Readiness (`DHCPSRV_NO_SOCKETS_OPEN`)**:
     - Kea binds raw sockets to `eth0` in `ns-wan`. If link-local IPv6 address is missing or DAD is pending, it aborts.
     - *Fix*: `wan_server.sh` explicitly assigns `fe80::254/64 nodad` before launching Kea.
  4. **Fallback Daemon**:
     - Run `./scripts/wan_server.sh start dnsmasq` for a lightweight fallback that does not require Kea runtime daemons.

### 2.3 LAN DHCP Client Leases & Renewals
* **Symptom:** Client endpoint in `ns-pc` or `ns-stb` fails to obtain an IP lease from the DUT.
* **Checks:**
  1. Inspect client status:
     ```bash
     ./scripts/client_dhcp.sh status
     ```
  2. Renew client lease manually:
     ```bash
     sudo ./scripts/client_dhcp.sh renew ns-pc
     ```
  3. Check DUT DHCP server status and lease pool availability on `br0`.
  4. If DHCP client is unneeded, revert to static mode:
     ```bash
     sudo ./scripts/setup.sh --single --no-lan-dhcp
     ```

### 2.4 Multicast Forwarding (IGMP) Drops
* **Symptom:** TC-WR-02 (Multicast Forwarding) reports 100% loss.
* **Checks:**
  1. **Reverse Path Filtering (`rp_filter`)**:
     - Linux kernel drops incoming multicast packets if reverse path filtering is enabled.
     - Ensure `rp_filter` is disabled on the bridge and interfaces:
       ```bash
       sudo ip netns exec ns-dut sysctl -w net.ipv4.conf.all.rp_filter=0
       sudo ip netns exec ns-dut sysctl -w net.ipv4.conf.default.rp_filter=0
       ```
  2. **Multicast Routing**:
     - Ensure the multicast route `224.0.0.0/4` is present in `ns-wan`:
       ```bash
       sudo ip -n ns-wan route replace 224.0.0.0/4 dev eth0
       ```

### 2.5 Packet Capture Privilege Drop (`dumpcap`)
* **Symptom:** `capture.sh` fails with `Permission denied` when invoked with `sudo`.
* **Root Cause:** Running `tshark` under root causes `dumpcap` to drop privileges to the unprivileged `wireshark` user, preventing file creation in restricted directories.
* **Resolution:**
  - Always use `tcpdump -U -s 0` for packet capture (enforced in `capture.sh`).
  - Use `tshark` strictly for post-capture analysis in `verify_compliance.sh`.

### 2.6 Traffic Control (TC) Queue Discipline Verification
* **Symptom:** Burst absorption tests fail unexpectedly in simulation mode.
* **Checks:**
  - Inspect active queue discipline on the STB bottleneck interface:
    ```bash
    sudo tc -s qdisc show dev veth-dut-stb
    ```
  - Verify Token Bucket Filter (TBF) parameters:
    `rate 100Mbit`, `burst 512Kb`, `limit 4Mb`.

### 2.7 USB-to-LAN Throughput Bottleneck & Max Bitrate Verification
* **Symptom:** TCP throughput on `ns-pc` (or `PC_IF` / `LAN_IF`) caps around ~930–940 Mbps, or drops unexpectedly to ~300–350 Mbps.
* **Root Causes:**
  1. **USB 2.0 Fallback**: USB 3.0 adapter accidentally plugged into a USB 2.0 port or negotiated at HighSpeed (480 Mbps), limiting actual throughput to ~320–380 Mbps.
  2. **Physical Ethernet Ceiling**: A 1 Gbps link has a theoretical L4 TCP payload limit of ~941–949 Mbps due to L1–L4 headers. A measured 930–940 Mbps represents full wire-rate saturation (98–99% efficiency).
  3. **Traffic Control (TC) Shaping**: The internal veth bridge pair (`v-pc-h`) has a `tbf` rate limiter configured to 1 Gbps.
* **Diagnostic Workflow & Verification Commands:**

  1. **Check USB Bus Negotiation & Speed (lsusb)**:
     ```bash
     lsusb
     lsusb -t
     ```
     - *Healthy USB 3.0*: Must show `Driver=xhci_hcd` and `5000M` (SuperSpeed 5 Gbps).
     - *Bottleneck USB 2.0*: Shows `480M` (HighSpeed), causing bandwidth to throttle at ~350 Mbps.

  2. **Inspect sysfs Hardware Mapping & Physical Negotiated Speed**:
     ```bash
     for iface in /sys/class/net/enx*; do
         if [ -e "$iface" ]; then
             echo "=== $(basename "$iface") ==="
             readlink -f "$iface/device"
             echo -n "MAC   : "; cat "$iface/address" 2>/dev/null
             echo -n "Speed : "; cat "$iface/speed" 2>/dev/null; echo " Mbps"
         fi
     done
     ```
     - Verifies whether the physical NIC is negotiated at `1000` (1 Gbps) or `2500` (2.5 Gbps Multi-Gigabit).

  3. **Inspect PHY Link State, Driver, and Hardware Offloads (ethtool)**:
     ```bash
     # Check link speed, duplex, and partner advertised modes
     ethtool <interface>

     # Check driver and firmware version (e.g. r8152, rtl8153)
     ethtool -i <interface>

     # Verify Hardware Offload acceleration (TSO, GSO, GRO, Checksums)
     ethtool -k <interface> | grep -E "tcp-segmentation-offload|generic-segmentation-offload|generic-receive-offload|rx-checksumming|tx-checksumming"
     ```

  4. **Check Interface Error Counters & Drops**:
     ```bash
     ip -s link show dev <interface>
     ```
     - Verify that `errors`, `carrier`, and `collsns` remain `0`.

  5. **Inspect Virtual Bridge & Traffic Control Rate Limiter (tc & veth)**:
     ```bash
     # Inspect LAN bridge and host-side veth endpoint
     ip -s link show dev br-test-lan
     ip -s link show dev v-pc-h

     # Check active TC qdisc rate-limiting parameters
     tc qdisc show dev v-pc-h
     tc qdisc show dev <interface>
     ```
     - Look for `qdisc tbf ... rate 1Gbit burst 512Kb latency 50ms`.

* **1 Gbps Wire-Rate Theoretical Maximum Calculation Reference (MTU 1500)**:
  | Header Layer | Overhead per Frame | Cumulative Size |
  | :--- | :--- | :--- |
  | **L1 Physical** | Preamble (7B) + SFD (1B) + Inter-Packet Gap (12B) | 20 Bytes |
  | **L2 Data Link** | Ethernet MAC Header (14B) + FCS CRC (4B) | 18 Bytes |
  | **L3 Network** | IPv4 Header | 20 Bytes |
  | **L4 Transport** | TCP Header (20B) + TCP Timestamps Option (12B) | 32 Bytes |
  | **TCP Payload (MSS)** | $1500\text{ B (MTU)} - 20\text{ B} - 32\text{ B}$ | **1,448 Bytes** |
  | **Total on Wire** | $1500\text{ B} + 18\text{ B} + 20\text{ B}$ | **1,538 Bytes** |

  $$\text{Max Theoretical TCP Throughput} = \frac{1448\text{ Bytes}}{1538\text{ Bytes}} \times 1000\text{ Mbps} \approx \mathbf{941.48\text{ Mbps}}$$
  *(933.22 Mbps represents **99.12%** of the theoretical physical maximum on a 1 Gbps link).*

---

## 3. Safe Teardown & Reset

If test execution is aborted mid-flight or namespaces remain in an inconsistent state:

```bash
# 1. Full clean teardown and NIC restoration
sudo ./scripts/cleanup.sh --restore

# 2. Verify all test namespaces and bridges are deleted
./scripts/show_state.sh

# 3. Clean stale logs and captures
./scripts/cleanup.sh data
```
