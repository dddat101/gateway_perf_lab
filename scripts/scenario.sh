#!/usr/bin/env bash
# ==============================================================================
# GATEWAY PERFORMANCE LAB - AUTOMATED SCENARIO RUNNER
# Evaluates Wire-rate, Rate Mismatch Bursts, STB Gaming/VOD, Simultaneous Use, QoS
# Supports Per-Test-Case Independent Runs & Dual-Sided (WAN/LAN) Captures
# ==============================================================================

set -Eeuo pipefail
IFS=$'\n\t'

readonly SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
readonly LAB_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd -P)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

DRY_RUN=0
NO_CAPTURE=0
CUSTOM_DURATION=""
CUSTOM_WIFI_MODE=""
SCENARIO_TMP_DIR=""
ACTIVE_BG_PIDS=()

usage() {
    cat <<'EOF'
==================================================================
  Gateway Performance Lab - Scenario Runner
==================================================================

Description:
  Executes automated test scenarios with simultaneous dual-sided
  packet capture (WAN + LAN) and isolated per-test PCAP files:
  - TC-WR-01: Wire-rate 1024B bidirectional unicast (0% loss)
  - TC-WR-02: Wire-rate 1024B multicast forwarding (0% loss)
  - TC-RM-01: 1G-to-100M rate mismatch burst (53 frames @ 50%)
  - TC-RM-02: 1G-to-100M rate mismatch burst (100 frames @ 16%)
  - TC-APP-01: GeForce NOW network test on 100M STB (Normal status)
  - TC-APP-02: UHD+Dolby 1.2x VOD playback on 100M STB
  - TC-SIM-01: Simultaneous Wired + Tri-band Wireless (5 trials)
  - TC-QOS-01: PC throughput stability during 2 Wi-Fi phone calls

Usage:
  sudo ./scripts/scenario.sh [OPTIONS] [SCENARIO]

Discrete Test Scenarios (Independent PCAP & Execution):
  unicast, tc_wr_01        TC-WR-01: 1024B Bidirectional Unicast Wire-rate
  multicast, tc_wr_02      TC-WR-02: 1024B Multicast 80 Mbps Forwarding
  burst_case1, tc_rm_01    TC-RM-01: 1500B Burst 50% Load, 53 Frames
  burst_case2, tc_rm_02    TC-RM-02: 1500B Burst 16% Load, 100 Frames
  geforce, tc_app_01       TC-APP-01: GeForce NOW UDP Cloud Gaming Test
  simultaneous, tc_sim_01  TC-SIM-01: Simultaneous Wired + 2.4G/5G/6G Tri-Band
  sequential, tc_sim_seq   TC-SIM-01: Sequential Multi-Band (5GHz & 2.4GHz) Benchmark
  remote, tc_sim_remote    TC-SIM-01: Distributed Multi-Station Benchmark (via SSH)
  tri_station, tc_sim_tri  TC-SIM-01: 3-Way Concurrent Physical Benchmark (Wired + 5G + 2.4G)
  voice_qos, tc_qos_01     TC-QOS-01: PC Throughput during 2 VoIP Calls

Composite Scenarios:
  wire_rate                Phase 1: Both Unicast and Multicast tests
  rate_mismatch            Phase 2: Both Burst Case 1 and Case 2 tests
  real_world_stb           Phase 3: Both GeForce NOW and UHD VOD tests
  all                      (Default) Complete automated test suite

Options:
  --wifi-mode, -W <mode>   Set adaptive Wi-Fi mode: auto, real_single, sequential, remote, tri_station, hybrid, emulated
  --voip-engine, -E <eng>  Set VoIP test engine: auto, pjsua, sipp, python (default: auto)
  --no-capture, -C         Disable packet capture (saves disk space for stability/soak testing)
  --duration, -d <sec>     Set custom test duration in seconds (e.g. -d 60 or -d 300)
  --stability, --soak      Long-running stability mode (disables capture, default duration 60s)
  --dry-run, -n            Preview test parameters without generating traffic
  -h, --help               Show this help message and exit

Examples:
  sudo ./scripts/scenario.sh vod
  sudo ./scripts/scenario.sh --duration 60 --no-capture vod
  sudo ./scripts/scenario.sh --stability geforce
  sudo ./scripts/scenario.sh -d 300 -C vod
  sudo ./scripts/scenario.sh all
==================================================================
EOF
}

# Defensive cleanup trap: cleans up temporary directory, background PIDs, and active captures
cleanup_scenario_trap() {
    local exit_code=$?
    trap - EXIT INT TERM ERR

    # Terminate any active captures
    if [[ -x "${SCRIPT_DIR}/capture.sh" ]]; then
        "${SCRIPT_DIR}/capture.sh" stop 2>/dev/null || true
    fi

    # Terminate any tracked background jobs
    if (( ${#ACTIVE_BG_PIDS[@]} > 0 )); then
        for pid in "${ACTIVE_BG_PIDS[@]}"; do
            if kill -0 "${pid}" 2>/dev/null; then
                kill "${pid}" 2>/dev/null || true
            fi
        done
    fi

    # Terminate any remaining test servers in ns-wan
    if ns_exists "${WAN_NS:-ns-wan}"; then
        ip netns exec "${WAN_NS:-ns-wan}" pkill -TERM iperf3 2>/dev/null || true
        ip netns exec "${WAN_NS:-ns-wan}" pkill -f "pjsua|sipp|voip_call_simulator" 2>/dev/null || true
    fi

    # Terminate lingering remote processes if remote client was engaged
    if [[ -n "${REMOTE_CLIENT_HOST:-}" ]]; then
        "${SCRIPT_DIR}/remote_client.sh" clean >/dev/null 2>&1 || true
    fi

    # Defensive cleanup of physical Wi-Fi test route and iptables mangle rule
    if [[ -n "${CLEANUP_WIFI_ROUTE:-}" ]]; then
        ip route del ${CLEANUP_WIFI_ROUTE} 2>/dev/null || true
    fi
    if [[ -n "${CLEANUP_IPTABLES_MANGLE:-}" ]]; then
        eval "${CLEANUP_IPTABLES_MANGLE}" 2>/dev/null || true
    fi

    # Safely remove scenario temporary directory
    if [[ -n "${SCENARIO_TMP_DIR:-}" && -d "${SCENARIO_TMP_DIR}" ]]; then
        rm -rf "${SCENARIO_TMP_DIR}" 2>/dev/null || true
    fi

    if (( exit_code != 0 )); then
        log_error "Scenario runner exited with code ${exit_code}."
    fi
    exit "${exit_code}"
}

# Helper to execute a subphase wrapped in dual-sided packet capture
run_with_dual_capture() {
    local tag="$1"
    local lan_ns="$2"
    local bpf_filter="$3"
    shift 3

    if (( DRY_RUN == 0 && NO_CAPTURE == 0 )) && [[ -x "${SCRIPT_DIR}/capture.sh" ]]; then
        "${SCRIPT_DIR}/capture.sh" start_dual "${tag}" "${lan_ns}" "${bpf_filter}" || true
    fi

    # Execute the test function
    "$@"

    if (( DRY_RUN == 0 && NO_CAPTURE == 0 )) && [[ -x "${SCRIPT_DIR}/capture.sh" ]]; then
        "${SCRIPT_DIR}/capture.sh" stop || true
    fi
}

# ------------------------------------------------------------------------------
# Defensive Client Endpoint Setup (Assures IP & Default Route in Netns)
# ------------------------------------------------------------------------------
ensure_client_endpoint() {
    local ns="$1"
    local fallback_ip="$2"
    local gw="${DUT_LAN_IP:-192.168.1.1}"

    if ! ns_exists "${ns}"; then
        return 0
    fi

    ip -n "${ns}" link set dev eth0 up 2>/dev/null || true

    # Check if any active IPv4 is already assigned to eth0
    local curr_ip
    curr_ip="$(ip -n "${ns}" -4 -br addr show dev eth0 2>/dev/null | awk '{print $3}' | cut -d/ -f1 || true)"
    if [[ -z "${curr_ip}" ]]; then
        log_info "Assigning fallback IPv4 ${fallback_ip}/${LAN_PREFIX:-24} to ${ns}:eth0..."
        ip -n "${ns}" addr replace "${fallback_ip}/${LAN_PREFIX:-24}" dev eth0 2>/dev/null || true
    fi

    # Ensure default route exists via DUT LAN IP to route traffic to WAN
    if ! ip -n "${ns}" -4 route show | grep -q default; then
        log_info "Configuring default route via ${gw} in ${ns}..."
        ip -n "${ns}" route replace default via "${gw}" dev eth0 2>/dev/null || true
    fi
}

# ------------------------------------------------------------------------------
# Sub-phase 1A: Bidirectional 1024-byte Unicast (TC-WR-01)
# ------------------------------------------------------------------------------
run_subphase_unicast() {
    log_step "[TC-WR-01] Bidirectional Unicast 1024B Wire-Rate Forwarding"
    local tools_dir="${LAB_DIR}/tools"
    local uni_json="${LOG_DIR}/unicast_result.json"

    if (( DRY_RUN == 1 )); then
        log_info "[DRY-RUN] Would test 1024B bidirectional unicast at 950 Mbps between ns-wan and ns-pc"
        return 0
    fi

    local engine="${WIRE_RATE_ENGINE:-auto}"
    if [[ "${engine}" == "auto" ]]; then
        if check_command iperf3; then
            engine="iperf3"
        else
            engine="python"
        fi
    fi

    if [[ "${engine}" == "iperf3" ]]; then
        log_info "Using high-performance C-based engine: iperf3 UDP (-l 982, ~116k PPS)..."
        local fwd_out="${SCENARIO_TMP_DIR}/iperf_uni_fwd.json"
        local rev_out="${SCENARIO_TMP_DIR}/iperf_uni_rev.json"

        # Start iperf3 server in ns-wan (central WAN endpoint)
        ip netns exec "${WAN_NS:-ns-wan}" pkill -TERM iperf3 2>/dev/null || true
        ip netns exec "${WAN_NS:-ns-wan}" iperf3 -s -p 5002 -D >/dev/null 2>&1
        sleep 0.3

        # Downlink Direction: WAN -> PC (Initiated by PC with -R Reverse mode to pass NAT firewall)
        ip netns exec "${PC_NS:-ns-pc}" iperf3 -c "${WAN_SERVER_IP:-10.10.0.1}" -u -p 5002 -b 950M -l 982 -t 3 -R -J > "${fwd_out}" 2>&1 || true
        sleep 0.3

        # Uplink Direction: PC -> WAN (Initiated by PC to WAN server)
        ip netns exec "${PC_NS:-ns-pc}" iperf3 -c "${WAN_SERVER_IP:-10.10.0.1}" -u -p 5002 -b 950M -l 982 -t 3 -J > "${rev_out}" 2>&1 || true
        ip netns exec "${WAN_NS:-ns-wan}" pkill -TERM iperf3 2>/dev/null || true

        # Consolidate bidirectional results into standard schema
        "${tools_dir}/metric_parser.py" consolidate-iperf-bidi \
            --forward "${fwd_out}" \
            --reverse "${rev_out}" \
            --output "${uni_json}"
    else
        log_info "Using native zero-allocation Python engine: traffic_generator.py..."
        ip netns exec "${PC_NS:-ns-pc}" "${tools_dir}/traffic_generator.py" unicast-recv \
            --bind-ip "${PC_IP:-192.168.1.10}" --bind-port 5002 \
            --server-ip "${WAN_SERVER_IP:-10.10.0.1}" --server-port 5002 \
            --duration 6 \
            --output-json "${uni_json}" >/dev/null 2>&1 &
        local rx_pid=$!
        ACTIVE_BG_PIDS+=("${rx_pid}")
        sleep 0.2

        ip netns exec "${WAN_NS:-ns-wan}" "${tools_dir}/traffic_generator.py" unicast-send \
            --dest-ip "${PC_IP:-192.168.1.10}" --dest-port 5002 \
            --wait-handshake \
            --packet-size "${UNICAST_PACKET_SIZE:-1024}" --duration 4 --rate-mbps 950.0

        wait "${rx_pid}" || true
        if [[ -f "${uni_json}" ]]; then
            cat "${uni_json}"
        fi
    fi
}

# ------------------------------------------------------------------------------
# Sub-phase 1B: Multicast Forwarding 1024B (TC-WR-02)
# ------------------------------------------------------------------------------
run_subphase_multicast() {
    log_step "[TC-WR-02] Multicast Forwarding 1024B (Group: ${MULTICAST_GROUP:-239.255.0.1})"
    local tools_dir="${LAB_DIR}/tools"
    local mcast_json="${LOG_DIR}/multicast_result.json"

    if (( DRY_RUN == 1 )); then
        log_info "[DRY-RUN] Would test 1024B multicast forwarding (2,000 packets) to group ${MULTICAST_GROUP:-239.255.0.1}"
        return 0
    fi

    # Start IGMP proxy forwarder in DUT namespace if simulated
    local mcast_fwd_pid=""
    if ns_exists "${DUT_NS:-ns-dut}"; then
        ip netns exec "${DUT_NS:-ns-dut}" "${tools_dir}/mcast_forwarder.py" \
            --group-ip "${MULTICAST_GROUP:-239.255.0.1}" --port 5003 \
            --wan-if-ip "${DUT_WAN_IP:-10.10.0.100}" --lan-if-ip "${DUT_LAN_IP:-192.168.1.1}" \
            --duration 12.0 >/dev/null 2>&1 &
        mcast_fwd_pid=$!
        ACTIVE_BG_PIDS+=("${mcast_fwd_pid}")
        sleep 0.2
    fi

    # Start multicast receiver in STB namespace
    ip netns exec "${STB_NS:-ns-stb}" "${tools_dir}/traffic_generator.py" mcast-recv \
        --group-ip "${MULTICAST_GROUP:-239.255.0.1}" --port 5003 \
        --expected-packets 2000 --timeout 5.0 --output-json "${mcast_json}" >/dev/null 2>&1 &
    local mcast_rx_pid=$!
    ACTIVE_BG_PIDS+=("${mcast_rx_pid}")
    sleep 1.2

    # Start multicast sender in WAN namespace with warmup burst to trigger HW flow cache
    ip netns exec "${WAN_NS:-ns-wan}" "${tools_dir}/traffic_generator.py" mcast-send \
        --group-ip "${MULTICAST_GROUP:-239.255.0.1}" --port 5003 \
        --packet-size "${MULTICAST_PACKET_SIZE:-1024}" --packets 2000 --rate-mbps 80.0 \
        --warmup-packets 30

    wait "${mcast_rx_pid}" || true
    if [[ -n "${mcast_fwd_pid}" ]]; then
        kill "${mcast_fwd_pid}" 2>/dev/null || true
    fi
    if [[ -f "${mcast_json}" ]]; then
        cat "${mcast_json}"
    fi
}

# ------------------------------------------------------------------------------
# Sub-phase 2A: Burst Case 1 (1500B, 50% Load, >=53 Frames) (TC-RM-01)
# ------------------------------------------------------------------------------
run_subphase_burst_case1() {
    log_step "[TC-RM-01] WAN-to-LAN Rate Mismatch Burst Case 1 (1500B, 50% Load, >=53 Frames)"
    local tools_dir="${LAB_DIR}/tools"

    local c1_frames="${BURST_CASE1_FRAMES:-53}"
    local c1_load="${BURST_CASE1_LOAD:-50.0}"
    local c1_count="${BURST_COUNT:-20}"
    local c1_expected=$(( c1_frames * c1_count ))
    local c1_json="${LOG_DIR}/burst_case1.json"

    if (( DRY_RUN == 1 )); then
        log_info "[DRY-RUN] Would test Burst Case 1: 1500B, Length=${c1_frames} frames, Load=${c1_load}%, Total=${c1_expected} frames"
        return 0
    fi

    ensure_client_endpoint "${STB_NS:-ns-stb}" "${STB_IP:-192.168.1.20}"
    local c1_rx_log="${SCENARIO_TMP_DIR}/burst_c1_rx.log"

    ip netns exec "${STB_NS:-ns-stb}" "${tools_dir}/traffic_generator.py" burst-recv \
        --bind-ip "0.0.0.0" --bind-port 5001 \
        --server-ip "${WAN_SERVER_IP:-10.10.0.1}" --server-port 5000 \
        --expected-packets "${c1_expected}" --timeout 5.0 --output-json "${c1_json}" > "${c1_rx_log}" 2>&1 &
    local c1_rx_pid=$!
    ACTIVE_BG_PIDS+=("${c1_rx_pid}")
    sleep 0.3

    ip netns exec "${WAN_NS:-ns-wan}" "${tools_dir}/traffic_generator.py" burst-send \
        --dest-ip "${STB_IP:-192.168.1.20}" --dest-port 5001 \
        --bind-port 5000 --wait-handshake \
        --packet-size "${BURST_PACKET_SIZE:-1500}" --burst-length "${c1_frames}" \
        --burst-load "${c1_load}" --burst-count "${c1_count}" --rate-mbps 1000.0

    wait "${c1_rx_pid}" || true
    if [[ -f "${c1_json}" ]]; then
        cat "${c1_json}"
    else
        log_warn "Burst receiver log output:"
        cat "${c1_rx_log}" 2>/dev/null || true
    fi
}

# ------------------------------------------------------------------------------
# Sub-phase 2B: Burst Case 2 (1500B, 16% Load, 100 Frames) (TC-RM-02)
# ------------------------------------------------------------------------------
run_subphase_burst_case2() {
    log_step "[TC-RM-02] WAN-to-LAN Rate Mismatch Burst Case 2 (1500B, 16% Load, 100 Frames)"
    local tools_dir="${LAB_DIR}/tools"

    local c2_frames="${BURST_CASE2_FRAMES:-100}"
    local c2_load="${BURST_CASE2_LOAD:-16.0}"
    local c2_count="${BURST_COUNT:-20}"
    local c2_expected=$(( c2_frames * c2_count ))
    local c2_json="${LOG_DIR}/burst_case2.json"

    if (( DRY_RUN == 1 )); then
        log_info "[DRY-RUN] Would test Burst Case 2: 1500B, Length=${c2_frames} frames, Load=${c2_load}%, Total=${c2_expected} frames"
        return 0
    fi

    ensure_client_endpoint "${STB_NS:-ns-stb}" "${STB_IP:-192.168.1.20}"
    local c2_rx_log="${SCENARIO_TMP_DIR}/burst_c2_rx.log"

    ip netns exec "${STB_NS:-ns-stb}" "${tools_dir}/traffic_generator.py" burst-recv \
        --bind-ip "0.0.0.0" --bind-port 5001 \
        --server-ip "${WAN_SERVER_IP:-10.10.0.1}" --server-port 5000 \
        --expected-packets "${c2_expected}" --timeout 5.0 --output-json "${c2_json}" > "${c2_rx_log}" 2>&1 &
    local c2_rx_pid=$!
    ACTIVE_BG_PIDS+=("${c2_rx_pid}")
    sleep 0.3

    ip netns exec "${WAN_NS:-ns-wan}" "${tools_dir}/traffic_generator.py" burst-send \
        --dest-ip "${STB_IP:-192.168.1.20}" --dest-port 5001 \
        --bind-port 5000 --wait-handshake \
        --packet-size "${BURST_PACKET_SIZE:-1500}" --burst-length "${c2_frames}" \
        --burst-load "${c2_load}" --burst-count "${c2_count}" --rate-mbps 1000.0

    wait "${c2_rx_pid}" || true
    if [[ -f "${c2_json}" ]]; then
        cat "${c2_json}"
    else
        log_warn "Burst receiver log output:"
        cat "${c2_rx_log}" 2>/dev/null || true
    fi
}

# ------------------------------------------------------------------------------
# Sub-phase 3A: GeForce NOW Network Test Simulation (TC-APP-01)
# ------------------------------------------------------------------------------
run_subphase_geforce() {
    log_step "[TC-APP-01] GeForce NOW Cloud Gaming Network Test Simulation"
    local tools_dir="${LAB_DIR}/tools"
    local gfn_json="${LOG_DIR}/geforce_now.json"

    if (( DRY_RUN == 1 )); then
        log_info "[DRY-RUN] Would test GeForce NOW UDP game streaming (60 FPS, 25 Mbps) on ns-stb"
        return 0
    fi

    ensure_client_endpoint "${STB_NS:-ns-stb}" "${STB_IP:-192.168.1.20}"
    local gfn_rx_log="${SCENARIO_TMP_DIR}/gfn_rx.log"
    local gfn_srv_duration="${CUSTOM_DURATION:-5.0}"
    local gfn_cli_duration
    gfn_cli_duration="$(python3 -c "print(float(${gfn_srv_duration}) + 3.0)")"

    # Clean any stale GeForce tester instances
    ip netns exec "${STB_NS:-ns-stb}" pkill -f "geforce_now_tester.py" 2>/dev/null || true
    ip netns exec "${WAN_NS:-ns-wan}" pkill -f "geforce_now_tester.py" 2>/dev/null || true
    sleep 0.1

    ip netns exec "${STB_NS:-ns-stb}" "${tools_dir}/geforce_now_tester.py" client \
        --bind-ip "0.0.0.0" --bind-port 5004 \
        --server-ip "${WAN_SERVER_IP:-10.10.0.1}" --server-port 5004 \
        --duration "${gfn_cli_duration}" \
        --max-loss-pct "${GEFORCE_NOW_MAX_LOSS_PCT:-0.0}" \
        --max-jitter-ms "${GEFORCE_NOW_MAX_JITTER_MS:-2.0}" \
        --output-json "${gfn_json}" > "${gfn_rx_log}" 2>&1 &
    local gfn_rx_pid=$!
    ACTIVE_BG_PIDS+=("${gfn_rx_pid}")
    sleep 0.3

    ip netns exec "${WAN_NS:-ns-wan}" "${tools_dir}/geforce_now_tester.py" server \
        --dest-ip "${STB_IP:-192.168.1.20}" --dest-port 5004 \
        --wait-handshake \
        --duration "${gfn_srv_duration}" \
        --frame-rate "${GEFORCE_NOW_FPS:-60}" --bitrate-mbps "${GEFORCE_NOW_BITRATE_MBPS:-25.0}"

    wait "${gfn_rx_pid}" || true
    if [[ -f "${gfn_json}" ]]; then
        cat "${gfn_json}"
    else
        cat "${gfn_rx_log}" 2>/dev/null || true
    fi
}

# ------------------------------------------------------------------------------
# Sub-phase 3B: UHD+Dolby VOD 1.2x Speed Playback (TC-APP-02)
# ------------------------------------------------------------------------------
run_subphase_vod() {
    log_step "[TC-APP-02] UHD+Dolby VOD @ 1.2x Speed Playback"
    local tools_dir="${LAB_DIR}/tools"
    local vod_json="${LOG_DIR}/vod_1_2x.json"

    if (( DRY_RUN == 1 )); then
        log_info "[DRY-RUN] Would test UHD+Dolby VOD @ 1.2x playback (35 Mbps x 1.2 = 42 Mbps) on ns-stb"
        return 0
    fi

    ensure_client_endpoint "${STB_NS:-ns-stb}" "${STB_IP:-192.168.1.20}"
    local vod_rx_log="${SCENARIO_TMP_DIR}/vod_rx.log"
    local vod_srv_duration="${CUSTOM_DURATION:-5.0}"
    local vod_cli_duration
    vod_cli_duration="$(python3 -c "print(float(${vod_srv_duration}) + 4.0)")"

    # Clean any stale VOD tester instances
    ip netns exec "${STB_NS:-ns-stb}" pkill -f "vod_stream_tester.py" 2>/dev/null || true
    ip netns exec "${WAN_NS:-ns-wan}" pkill -f "vod_stream_tester.py" 2>/dev/null || true
    sleep 0.1

    ip netns exec "${STB_NS:-ns-stb}" "${tools_dir}/vod_stream_tester.py" client \
        --bind-ip "0.0.0.0" --bind-port 5005 \
        --server-ip "${WAN_SERVER_IP:-10.10.0.1}" --server-port 5005 \
        --duration "${vod_cli_duration}" \
        --output-json "${vod_json}" > "${vod_rx_log}" 2>&1 &
    local vod_rx_pid=$!
    ACTIVE_BG_PIDS+=("${vod_rx_pid}")
    sleep 0.3

    ip netns exec "${WAN_NS:-ns-wan}" "${tools_dir}/vod_stream_tester.py" server \
        --dest-ip "${STB_IP:-192.168.1.20}" --dest-port 5005 \
        --wait-handshake \
        --duration "${vod_srv_duration}" \
        --base-bitrate-mbps "${VOD_BASE_BITRATE_MBPS:-35.0}" \
        --playback-speed "${VOD_SPEED_MULTIPLIER:-1.2}"

    wait "${vod_rx_pid}" || true
    if [[ -f "${vod_json}" ]]; then
        cat "${vod_json}"
    else
        cat "${vod_rx_log}" 2>/dev/null || true
    fi
}

# Helper: Run N trials of Simultaneous Benchmark (A: Wireless, B: Wired, C: Simultaneous) for a specific band
run_single_band_trials() {
    local band_tag="$1"
    local band_name="$2"
    local target_ssid="$3"
    local wifi_if="$4"
    local out_json="$5"
    local trials="${BENCHMARK_TRIALS:-5}"
    local duration="${CUSTOM_DURATION:-${BENCHMARK_DURATION_SEC:-3}}"
    local tools_dir="${LAB_DIR}/tools"

    local a_trials=()
    local b_trials=()
    local c_trials=()
    local c_wired_trials=()
    local c_wifi_trials=()

    log_info "Executing ${trials} measurement trials for [${band_name}] (SSID: '${target_ssid}')..."
    for (( i=1; i<=trials; i++ )); do
        log_info "--- [${band_name}] Trial ${i}/${trials} ---"

        # 1. Real Wireless-only speed (A): Single physical card over-the-air (OTA)
        local wifi_out="${SCENARIO_TMP_DIR}/iperf_wifi_${band_tag}_${i}.json"
        iperf3 -c "${WAN_SERVER_IP:-10.10.0.1}" --bind-dev "${wifi_if}" -p 5202 -t "${duration}" -J > "${wifi_out}" 2>&1 || true
        sleep 0.2
        local a_val
        a_val="$("${tools_dir}/metric_parser.py" sum-mbps "${wifi_out}")"
        a_trials+=("${a_val}")
        log_info "  [Trial ${i}] Real Wireless-only (A, ${band_name}): ${a_val} Mbps"

        # 2. Wired-only speed (B): PC via ns-pc
        local pc_out="${SCENARIO_TMP_DIR}/iperf_pc_${band_tag}_${i}.json"
        ip netns exec "${PC_NS:-ns-pc}" iperf3 -c "${WAN_SERVER_IP:-10.10.0.1}" -p 5201 -t "${duration}" -J > "${pc_out}" 2>&1 || true
        sleep 0.2
        local b_val
        b_val="$("${tools_dir}/metric_parser.py" sum-mbps "${pc_out}")"
        b_trials+=("${b_val}")
        log_info "  [Trial ${i}] Wired-only (B, 1G LAN): ${b_val} Mbps"

        # 3. Simultaneous speed (C): Wired PC + Real Wi-Fi concurrently
        local sim_pc_out="${SCENARIO_TMP_DIR}/iperf_sim_pc_${band_tag}_${i}.json"
        local sim_wifi_out="${SCENARIO_TMP_DIR}/iperf_sim_wifi_${band_tag}_${i}.json"

        ip netns exec "${PC_NS:-ns-pc}" iperf3 -c "${WAN_SERVER_IP:-10.10.0.1}" -p 5201 -t "${duration}" -J > "${sim_pc_out}" 2>&1 &
        local sp0=$!
        iperf3 -c "${WAN_SERVER_IP:-10.10.0.1}" --bind-dev "${wifi_if}" -p 5202 -t "${duration}" -J > "${sim_wifi_out}" 2>&1 &
        local sp1=$!

        wait "${sp0}" "${sp1}" || true
        sleep 0.2

        local c_wired c_wifi c_val
        c_wired="$("${tools_dir}/metric_parser.py" sum-mbps "${sim_pc_out}")"
        c_wifi="$("${tools_dir}/metric_parser.py" sum-mbps "${sim_wifi_out}")"
        c_val="$("${tools_dir}/metric_parser.py" sum-mbps "${sim_pc_out}" "${sim_wifi_out}")"
        c_trials+=("${c_val}")
        c_wired_trials+=("${c_wired}")
        c_wifi_trials+=("${c_wifi}")
        log_info "  [Trial ${i}] Simultaneous (C): ${c_val} Mbps (Wired: ${c_wired} Mbps, Wi-Fi: ${c_wifi} Mbps)"
    done

    local a_str b_str c_str c_wired_str c_wifi_str
    a_str="$(IFS=,; echo "${a_trials[*]}")"
    b_str="$(IFS=,; echo "${b_trials[*]}")"
    c_str="$(IFS=,; echo "${c_trials[*]}")"
    c_wired_str="$(IFS=,; echo "${c_wired_trials[*]}")"
    c_wifi_str="$(IFS=,; echo "${c_wifi_trials[*]}")"

    local eval_cmd=(
        "${tools_dir}/metric_parser.py" eval-simultaneous
        "--trials-a" "${a_str}"
        "--trials-b" "${b_str}"
        "--trials-c" "${c_str}"
        "--mode" "real_single_band"
        "--tolerance" "${THROUGHPUT_DROP_TOLERANCE_PCT:-1.0}"
        "--output" "${out_json}"
        "--wifi-if" "${wifi_if}"
        "--wifi-band" "${band_name}"
        "--wifi-ssid" "${target_ssid}"
        "--trials-c-wired" "${c_wired_str}"
        "--trials-c-wifi" "${c_wifi_str}"
    )
    "${eval_cmd[@]}"
}

# Helper: Run N trials of Simultaneous Benchmark with a Remote PC Client over SSH
run_remote_station_trials() {
    local trials="${BENCHMARK_TRIALS:-5}"
    local duration="${CUSTOM_DURATION:-${BENCHMARK_DURATION_SEC:-3}}"
    local tools_dir="${LAB_DIR}/tools"
    local sim_json="${LOG_DIR}/simultaneous_benchmark.json"
    local remote_host="${REMOTE_CLIENT_HOST:-}"
    local remote_script="${SCRIPT_DIR}/remote_client.sh"

    local remote_env_dump
    remote_env_dump="$("${remote_script}" wifi-env --check-ping "${DUT_LAN_IP:-192.168.1.1}" 2>/dev/null || true)"
    eval "${remote_env_dump}"

    local remote_wifi_if="${REMOTE_WIFI_IF:-wlan0}"
    local remote_status="${REMOTE_WIFI_STATUS:-DISCONNECTED}"

    log_info "  -> Remote Wi-Fi Station   : ${remote_host} (${remote_wifi_if} [${remote_status}])"
    log_info "     * Target SSID & Band   : '${REMOTE_WIFI_SSID:-none}' (${REMOTE_WIFI_BAND:-none} / Ch ${REMOTE_WIFI_CHANNEL:-?}, Width: ${REMOTE_WIFI_WIDTH:-?})"
    log_info "     * Signal & Bitrate     : ${REMOTE_WIFI_SIGNAL:-none} (Tx: ${REMOTE_WIFI_BITRATE:-none})"
    log_info "     * Station IPv4 Address : ${REMOTE_WIFI_IP:-none} (Gateway: ${REMOTE_WIFI_GATEWAY:-none})"
    if [[ "${REMOTE_WIFI_PING_OK:-0}" == "1" ]]; then
        log_pass "     * Remote DUT Reachability: OK (Ping to ${DUT_LAN_IP:-192.168.1.1}: ${REMOTE_WIFI_PING_RTT})"
    else
        log_warn "     * Remote DUT Reachability: FAILED (Cannot ping gateway ${DUT_LAN_IP:-192.168.1.1})"
        log_warn "     * Please ensure Remote PC is connected to DUT SSID ('${DUT_SSID_2G:-DUT}' / '${DUT_SSID_5G:-DUT}')."
    fi

    local bind_opt=()
    if [[ -n "${remote_wifi_if}" ]]; then
        bind_opt=("--bind-dev" "${remote_wifi_if}")
    fi

    local a_trials=()
    local b_trials=()
    local c_trials=()
    local c_wired_trials=()
    local c_wifi_trials=()

    log_info "Executing ${trials} measurement trials with Remote PC Station (${remote_host})..."
    for (( i=1; i<=trials; i++ )); do
        log_info "--- [Remote Station] Trial ${i}/${trials} ---"

        # 1. Remote Wireless-only speed (A): Trigger remote PC via SSH
        local wifi_out="${SCENARIO_TMP_DIR}/iperf_wifi_remote_${i}.json"
        "${remote_script}" run-iperf -c "${WAN_SERVER_IP:-10.10.0.1}" "${bind_opt[@]}" -p 5202 -t "${duration}" -J > "${wifi_out}" 2>&1 || true
        sleep 0.2
        local a_val
        a_val="$("${tools_dir}/metric_parser.py" sum-mbps "${wifi_out}")"
        a_trials+=("${a_val}")
        log_info "  [Trial ${i}] Remote Wireless-only (A, Remote PC): ${a_val} Mbps"

        # 2. Local Wired-only speed (B): Local PC via ns-pc
        local pc_out="${SCENARIO_TMP_DIR}/iperf_pc_remote_${i}.json"
        ip netns exec "${PC_NS:-ns-pc}" iperf3 -c "${WAN_SERVER_IP:-10.10.0.1}" -p 5201 -t "${duration}" -J > "${pc_out}" 2>&1 || true
        sleep 0.2
        local b_val
        b_val="$("${tools_dir}/metric_parser.py" sum-mbps "${pc_out}")"
        b_trials+=("${b_val}")
        log_info "  [Trial ${i}] Local Wired-only (B, 1G LAN): ${b_val} Mbps"

        # 3. Simultaneous speed (C): Local Wired PC + Remote Wi-Fi concurrently
        local sim_pc_out="${SCENARIO_TMP_DIR}/iperf_sim_pc_remote_${i}.json"
        local sim_wifi_out="${SCENARIO_TMP_DIR}/iperf_sim_wifi_remote_${i}.json"

        ip netns exec "${PC_NS:-ns-pc}" iperf3 -c "${WAN_SERVER_IP:-10.10.0.1}" -p 5201 -t "${duration}" -J > "${sim_pc_out}" 2>&1 &
        local sp0=$!
        "${remote_script}" run-iperf -c "${WAN_SERVER_IP:-10.10.0.1}" "${bind_opt[@]}" -p 5202 -t "${duration}" -J > "${sim_wifi_out}" 2>&1 &
        local sp1=$!

        wait "${sp0}" "${sp1}" || true
        sleep 0.2

        local c_wired c_wifi c_val
        c_wired="$("${tools_dir}/metric_parser.py" sum-mbps "${sim_pc_out}")"
        c_wifi="$("${tools_dir}/metric_parser.py" sum-mbps "${sim_wifi_out}")"
        c_val="$("${tools_dir}/metric_parser.py" sum-mbps "${sim_pc_out}" "${sim_wifi_out}")"
        c_trials+=("${c_val}")
        c_wired_trials+=("${c_wired}")
        c_wifi_trials+=("${c_wifi}")
        log_info "  [Trial ${i}] Simultaneous (C): ${c_val} Mbps (Local Wired: ${c_wired} Mbps, Remote Wi-Fi: ${c_wifi} Mbps)"
    done

    local a_str b_str c_str c_wired_str c_wifi_str
    a_str="$(IFS=,; echo "${a_trials[*]}")"
    b_str="$(IFS=,; echo "${b_trials[*]}")"
    c_str="$(IFS=,; echo "${c_trials[*]}")"
    c_wired_str="$(IFS=,; echo "${c_wired_trials[*]}")"
    c_wifi_str="$(IFS=,; echo "${c_wifi_trials[*]}")"

    local eval_cmd=(
        "${tools_dir}/metric_parser.py" eval-simultaneous
        "--trials-a" "${a_str}"
        "--trials-b" "${b_str}"
        "--trials-c" "${c_str}"
        "--mode" "distributed_remote_station"
        "--tolerance" "${THROUGHPUT_DROP_TOLERANCE_PCT:-1.0}"
        "--output" "${sim_json}"
        "--wifi-if" "remote_pc"
        "--wifi-band" "Remote-WiFi"
        "--wifi-ssid" "${remote_host}"
        "--trials-c-wired" "${c_wired_str}"
        "--trials-c-wifi" "${c_wifi_str}"
    )
    "${eval_cmd[@]}"
}

# Helper: Run N trials of 3-Way Concurrent Benchmark (Wired 1G + Local Wi-Fi 5GHz + Remote Wi-Fi 2.4GHz)
run_tri_station_trials() {
    local trials="${BENCHMARK_TRIALS:-5}"
    local duration="${CUSTOM_DURATION:-${BENCHMARK_DURATION_SEC:-3}}"
    local tools_dir="${LAB_DIR}/tools"
    local sim_json="${LOG_DIR}/simultaneous_benchmark.json"
    local remote_host="${REMOTE_CLIENT_HOST:-}"
    local remote_script="${SCRIPT_DIR}/remote_client.sh"
    local local_wifi_if="${DETECTED_WIFI_IF:-wlp3s0}"

    local remote_env_dump
    remote_env_dump="$("${remote_script}" wifi-env --check-ping "${DUT_LAN_IP:-192.168.1.1}" 2>/dev/null || true)"
    eval "${remote_env_dump}"

    local remote_wifi_if="${REMOTE_WIFI_IF:-wlan0}"
    local remote_status="${REMOTE_WIFI_STATUS:-DISCONNECTED}"

    log_info "  -> Local Wired PC Adapter   : ${PC_IF:-enx6c1ff76608e2} (ns-pc: 1 Gbps LAN)"
    log_info "  -> Local Wi-Fi Adapter      : ${local_wifi_if} [${DETECTED_WIFI_STATUS:-CONNECTED}] (SSID: '${DETECTED_WIFI_SSID:-DUT}', Band: ${DETECTED_WIFI_BAND:-none}, Signal: ${DETECTED_WIFI_SIGNAL:-none})"
    log_info "  -> Remote Wi-Fi Station     : ${remote_host} (${remote_wifi_if} [${remote_status}], SSID: '${REMOTE_WIFI_SSID:-none}', Band: ${REMOTE_WIFI_BAND:-none}, Signal: ${REMOTE_WIFI_SIGNAL:-none})"

    local bind_opt=()
    if [[ -n "${remote_wifi_if}" ]]; then
        bind_opt=("--bind-dev" "${remote_wifi_if}")
    fi

    # Pre-flight checks: Verify local & remote Wi-Fi connectivity to DUT gateway
    log_info "Verifying Local Wi-Fi connectivity to DUT..."
    if ! ping -c 1 -W 2 -I "${local_wifi_if}" "${DUT_LAN_IP:-192.168.1.1}" >/dev/null 2>&1; then
        log_warn "Local Wi-Fi (${local_wifi_if}) cannot ping DUT gateway! Attempting reconnect to 5G..."
        "${SCRIPT_DIR}/wifi_connect.sh" connect 5g || true
    else
        log_pass "Local Wi-Fi (${local_wifi_if}) reachability to DUT is verified."
    fi

    log_info "Verifying Remote Wi-Fi connectivity to DUT..."
    if [[ "${REMOTE_WIFI_PING_OK:-0}" != "1" ]]; then
        log_warn "Remote Wi-Fi (${remote_wifi_if}) cannot ping DUT gateway! Attempting reconnect to 2G..."
        "${remote_script}" wifi-connect 2g || true
    else
        log_pass "Remote Wi-Fi (${remote_wifi_if}) reachability to DUT is verified (Ping RTT: ${REMOTE_WIFI_PING_RTT})."
    fi

    local a_trials=()
    local b_trials=()
    local c_trials=()
    local c_wired_trials=()
    local c_wifi_trials=()

    log_info "Executing ${trials} measurement trials with 3 Concurrent Clients (Wired + 5G + 2.4G)..."
    for (( i=1; i<=trials; i++ )); do
        log_info "--- [3-Way Concurrent] Trial ${i}/${trials} ---"

        # 1. Combined Wireless-only speed (A): Local 5GHz + Remote 2.4GHz concurrently
        local w5g_out="${SCENARIO_TMP_DIR}/iperf_w5g_a_${i}.json"
        local w2g_out="${SCENARIO_TMP_DIR}/iperf_w2g_a_${i}.json"

        iperf3 -c "${WAN_SERVER_IP:-10.10.0.1}" --bind-dev "${local_wifi_if}" -p 5202 -t "${duration}" -J > "${w5g_out}" 2>&1 &
        local ap0=$!
        "${remote_script}" run-iperf -c "${WAN_SERVER_IP:-10.10.0.1}" "${bind_opt[@]}" -p 5203 -t "${duration}" -J > "${w2g_out}" 2>&1 &
        local ap1=$!

        wait "${ap0}" "${ap1}" || true
        sleep 0.2

        local a5g_val a2g_val a_sum
        a5g_val="$("${tools_dir}/metric_parser.py" sum-mbps "${w5g_out}")"
        a2g_val="$("${tools_dir}/metric_parser.py" sum-mbps "${w2g_out}")"
        a_sum="$(awk "BEGIN {printf \"%.2f\", ${a5g_val} + ${a2g_val}}")"
        a_trials+=("${a_sum}")
        log_info "  [Trial ${i}] Wireless-only (A, 5G+2.4G): ${a_sum} Mbps (Local 5G: ${a5g_val} Mbps, Remote 2.4G: ${a2g_val} Mbps)"

        # 2. Local Wired-only speed (B): Local PC via ns-pc
        local pc_out="${SCENARIO_TMP_DIR}/iperf_pc_b_${i}.json"
        ip netns exec "${PC_NS:-ns-pc}" iperf3 -c "${WAN_SERVER_IP:-10.10.0.1}" -p 5201 -t "${duration}" -J > "${pc_out}" 2>&1 || true
        sleep 0.2
        local b_val
        b_val="$("${tools_dir}/metric_parser.py" sum-mbps "${pc_out}")"
        b_trials+=("${b_val}")
        log_info "  [Trial ${i}] Local Wired-only (B, 1G LAN): ${b_val} Mbps"

        # 3. Simultaneous speed (C): Local Wired PC + Local Wi-Fi 5G + Remote Wi-Fi 2.4G concurrently!
        local sim_pc_out="${SCENARIO_TMP_DIR}/iperf_sim_pc_${i}.json"
        local sim_w5g_out="${SCENARIO_TMP_DIR}/iperf_sim_w5g_${i}.json"
        local sim_w2g_out="${SCENARIO_TMP_DIR}/iperf_sim_w2g_${i}.json"

        ip netns exec "${PC_NS:-ns-pc}" iperf3 -c "${WAN_SERVER_IP:-10.10.0.1}" -p 5201 -t "${duration}" -J > "${sim_pc_out}" 2>&1 &
        local sp0=$!
        iperf3 -c "${WAN_SERVER_IP:-10.10.0.1}" --bind-dev "${local_wifi_if}" -p 5202 -t "${duration}" -J > "${sim_w5g_out}" 2>&1 &
        local sp1=$!
        "${remote_script}" run-iperf -c "${WAN_SERVER_IP:-10.10.0.1}" "${bind_opt[@]}" -p 5203 -t "${duration}" -J > "${sim_w2g_out}" 2>&1 &
        local sp2=$!

        wait "${sp0}" "${sp1}" "${sp2}" || true
        sleep 0.2

        local c_wired c_w5g c_w2g c_wifi_tot c_val
        c_wired="$("${tools_dir}/metric_parser.py" sum-mbps "${sim_pc_out}")"
        c_w5g="$("${tools_dir}/metric_parser.py" sum-mbps "${sim_w5g_out}")"
        c_w2g="$("${tools_dir}/metric_parser.py" sum-mbps "${sim_w2g_out}")"
        c_wifi_tot="$(awk "BEGIN {printf \"%.2f\", ${c_w5g} + ${c_w2g}}")"
        c_val="$("${tools_dir}/metric_parser.py" sum-mbps "${sim_pc_out}" "${sim_w5g_out}" "${sim_w2g_out}")"

        c_trials+=("${c_val}")
        c_wired_trials+=("${c_wired}")
        c_wifi_trials+=("${c_wifi_tot}")
        log_info "  [Trial ${i}] Simultaneous (C): ${c_val} Mbps [Wired: ${c_wired} Mbps | 5GHz: ${c_w5g} Mbps | 2.4GHz: ${c_w2g} Mbps]"
    done

    local a_str b_str c_str c_wired_str c_wifi_str
    a_str="$(IFS=,; echo "${a_trials[*]}")"
    b_str="$(IFS=,; echo "${b_trials[*]}")"
    c_str="$(IFS=,; echo "${c_trials[*]}")"
    c_wired_str="$(IFS=,; echo "${c_wired_trials[*]}")"
    c_wifi_str="$(IFS=,; echo "${c_wifi_trials[*]}")"

    local eval_cmd=(
        "${tools_dir}/metric_parser.py" eval-simultaneous
        "--trials-a" "${a_str}"
        "--trials-b" "${b_str}"
        "--trials-c" "${c_str}"
        "--mode" "tri_station_distributed"
        "--tolerance" "${THROUGHPUT_DROP_TOLERANCE_PCT:-1.0}"
        "--output" "${sim_json}"
        "--wifi-if" "${local_wifi_if}+${remote_wifi_if}"
        "--wifi-band" "5GHz(Local)+2.4GHz(Remote)"
        "--wifi-ssid" "${DETECTED_WIFI_SSID:-U+NetF254_5G}+U+NetF254"
        "--trials-c-wired" "${c_wired_str}"
        "--trials-c-wifi" "${c_wifi_str}"
    )
    "${eval_cmd[@]}"
}

# ------------------------------------------------------------------------------
# Phase 4: Simultaneous Wired & Wireless Use (TC-SIM-01)
# ------------------------------------------------------------------------------
run_phase_simultaneous() {
    local tools_dir="${LAB_DIR}/tools"
    local trials="${BENCHMARK_TRIALS:-5}"
    local duration="${CUSTOM_DURATION:-${BENCHMARK_DURATION_SEC:-3}}"
    local sim_json="${LOG_DIR}/simultaneous_benchmark.json"

    # Step 0: Probe Wi-Fi environment and determine execution mode
    local env_dump
    env_dump="$("${tools_dir}/wifi_inspector.py" export-env 2>/dev/null || true)"
    eval "${env_dump}"

    local eff_mode="${CUSTOM_WIFI_MODE:-${WIFI_TEST_MODE:-auto}}"
    if [[ "${eff_mode}" == "auto" ]]; then
        if [[ "${TOPOLOGY_MODE:-virtual}" == "virtual" ]]; then
            eff_mode="emulated"
        elif (( ${WIFI_CARD_COUNT:-0} == 0 )); then
            eff_mode="emulated"
        elif (( ${WIFI_CARD_COUNT:-0} == 1 )); then
            if [[ -n "${DETECTED_WIFI_SSID:-}" ]]; then
                eff_mode="real_single_band"
            else
                log_warn "Physical Wi-Fi card detected (${DETECTED_WIFI_IF}) but not connected to SSID. Falling back to emulated netns."
                eff_mode="emulated"
            fi
        else
            eff_mode="physical"
        fi
    elif [[ "${eff_mode}" == "real_single" ]]; then
        eff_mode="real_single_band"
    elif [[ "${eff_mode}" == "sequential" || "${eff_mode}" == "sequential_bands" || "${eff_mode}" == "multiband" ]]; then
        eff_mode="sequential"
    elif [[ "${eff_mode}" == "remote" || "${eff_mode}" == "distributed" || "${eff_mode}" == "remote_client" ]]; then
        eff_mode="remote"
    elif [[ "${eff_mode}" == "tri_station" || "${eff_mode}" == "tri_stream" || "${eff_mode}" == "concurrent" || "${eff_mode}" == "distributed_3way" ]]; then
        eff_mode="tri_station"
    fi

    # --------------------------------------------------------------------------
    # Case 1: Sequential Multi-Band Testing (5GHz -> 2.4GHz)
    # --------------------------------------------------------------------------
    if [[ "${eff_mode}" == "sequential" ]]; then
        log_step "[TC-SIM-01] Sequential Multi-Band Download Benchmark (5GHz & 2.4GHz)"
        log_info "Sequential Benchmark Mode: [SEQUENTIAL_MULTI_BAND] | Trials per Band: ${trials} | Duration: ${duration}s"
        log_info "  -> Physical Wi-Fi Adapter : ${DETECTED_WIFI_IF:-none}"
        log_info "  -> Wired PC Adapter       : ${PC_IF:-enx6c1ff76608e2} (ns-pc: 1 Gbps LAN)"
        log_info "  -> Upstream WAN Endpoint  : ${WAN_SERVER_IP:-10.10.0.1}"

        if (( DRY_RUN == 1 )); then
            log_info "[DRY-RUN] Would test 5GHz and 2.4GHz bands sequentially (${trials} trials each)."
            log_info "[DRY-RUN] Acceptance: Degradation <= ${THROUGHPUT_DROP_TOLERANCE_PCT:-1.0}% across all bands"
            return 0
        fi

        # Stop any stale iperf3 instances in ns-wan and start fresh
        ip netns exec "${WAN_NS:-ns-wan}" pkill -TERM iperf3 2>/dev/null || true
        sleep 0.2
        for port in 5201 5202 5203 5204; do
            ip netns exec "${WAN_NS:-ns-wan}" iperf3 -s -p "${port}" -D >/dev/null 2>&1
        done
        sleep 0.5

        # Determine bands to test: 5GHz first (already connected), then 2.4GHz
        local bands_to_test=()
        if [[ -n "${DUT_SSID_5G:-}" ]]; then
            bands_to_test+=("5g:5GHz:${DUT_SSID_5G}")
        fi
        if [[ -n "${DUT_SSID_2G:-}" ]]; then
            bands_to_test+=("2g:2.4GHz:${DUT_SSID_2G}")
        fi
        if [[ -n "${DUT_SSID_6G:-}" && "${DETECTED_WIFI_SUPPORTED_BANDS:-}" == *"6GHz"* ]]; then
            bands_to_test+=("6g:6GHz:${DUT_SSID_6G}")
        fi

        if (( ${#bands_to_test[@]} == 0 )); then
            die "No target DUT SSIDs configured for sequential testing in config.env."
        fi

        local band_json_files=()
        for b_item in "${bands_to_test[@]}"; do
            local b_tag b_name b_ssid
            IFS=":" read -r b_tag b_name b_ssid <<< "${b_item}"

            print_section "SEQUENTIAL MULTI-BAND PHASE: ${b_name} (SSID: ${b_ssid})"
            local cur_link_ssid
            cur_link_ssid="$(iw dev "${DETECTED_WIFI_IF}" link 2>/dev/null | awk -F'SSID: ' '/SSID:/{print $2}' | xargs || true)"

            if [[ "${cur_link_ssid}" != "${b_ssid}" ]]; then
                log_info "Switching physical Wi-Fi [${DETECTED_WIFI_IF}] to ${b_name} (SSID: '${b_ssid}')..."
                "${SCRIPT_DIR}/wifi_connect.sh" connect "${b_tag}" --force
                sleep 2
            else
                log_info "Physical Wi-Fi [${DETECTED_WIFI_IF}] is already associated to ${b_name} (SSID: '${b_ssid}')."
            fi

            # Warm up ARP table to DUT gateway
            ping -c 1 -W 2 -I "${DETECTED_WIFI_IF}" "${DUT_LAN_IP:-192.168.1.1}" >/dev/null 2>&1 || true

            local band_json="${LOG_DIR}/simultaneous_benchmark_${b_tag}.json"
            run_single_band_trials "${b_tag}" "${b_name}" "${b_ssid}" "${DETECTED_WIFI_IF}" "${band_json}"
            band_json_files+=("${band_json}")
        done

        # Reconnect to primary 5GHz band after testing finishes
        log_info "Restoring Wi-Fi connection to 5GHz..."
        "${SCRIPT_DIR}/wifi_connect.sh" connect 5g --force >/dev/null 2>&1 || true

        # Stop iperf3 servers in ns-wan
        ip netns exec "${WAN_NS:-ns-wan}" pkill -TERM iperf3 2>/dev/null || true

        # Consolidate results across all tested bands
        local seq_json="${LOG_DIR}/simultaneous_sequential_benchmark.json"
        "${tools_dir}/metric_parser.py" eval-sequential \
            "${band_json_files[@]}" \
            --tolerance "${THROUGHPUT_DROP_TOLERANCE_PCT:-1.0}" \
            --output "${seq_json}"

        # Mirror to simultaneous_benchmark.json for backward compatibility
        cp -f "${seq_json}" "${sim_json}" 2>/dev/null || true
        return 0
    fi

    # --------------------------------------------------------------------------
    # Case 2: Distributed Remote Client Testing (Local Wired + Remote Wi-Fi)
    # --------------------------------------------------------------------------
    if [[ "${eff_mode}" == "remote" ]]; then
        log_step "[TC-SIM-01] Distributed Multi-Station Benchmark (Local Wired + Remote Wi-Fi)"
        log_info "Simultaneous Benchmark Mode: [REMOTE_CLIENT] | Trials: ${trials} | Duration: ${duration}s"
        log_info "  -> Remote Station Host    : ${REMOTE_CLIENT_HOST:-not_configured}"
        log_info "  -> Local Wired PC Adapter : ${PC_IF:-enx6c1ff76608e2} (ns-pc: 1 Gbps LAN)"
        log_info "  -> Upstream WAN Endpoint  : ${WAN_SERVER_IP:-10.10.0.1}"

        if (( DRY_RUN == 1 )); then
            log_info "[DRY-RUN] Would run ${trials} benchmark trials measuring A (Remote Wi-Fi), B (Local Wired), C (Simultaneous)"
            log_info "[DRY-RUN] Acceptance: Degradation <= ${THROUGHPUT_DROP_TOLERANCE_PCT:-1.0}%"
            return 0
        fi

        if [[ -z "${REMOTE_CLIENT_HOST:-}" ]]; then
            die "REMOTE_CLIENT_HOST is not set in config.env. Configure remote client or run ./scripts/remote_client.sh --help"
        fi

        # Stop any stale iperf3 instances in ns-wan and start fresh
        ip netns exec "${WAN_NS:-ns-wan}" pkill -TERM iperf3 2>/dev/null || true
        sleep 0.2
        for port in 5201 5202 5203 5204; do
            ip netns exec "${WAN_NS:-ns-wan}" iperf3 -s -p "${port}" -D >/dev/null 2>&1
        done
        sleep 0.5

        run_remote_station_trials
        ip netns exec "${WAN_NS:-ns-wan}" pkill -TERM iperf3 2>/dev/null || true
        return 0
    fi

    # --------------------------------------------------------------------------
    # Case 3: 3-Way Concurrent Physical Testing (Wired 1G + Local 5G + Remote 2.4G)
    # --------------------------------------------------------------------------
    if [[ "${eff_mode}" == "tri_station" ]]; then
        log_step "[TC-SIM-01] 3-Way Concurrent Physical Benchmark (Wired 1G + Local 5G + Remote 2.4G)"
        log_info "Simultaneous Benchmark Mode: [TRI_STATION_CONCURRENT] | Trials: ${trials} | Duration: ${duration}s"
        log_info "  -> Local Wired Adapter    : ${PC_IF:-enx6c1ff76608e2} (ns-pc: 1 Gbps LAN)"
        log_info "  -> Local Wi-Fi Adapter    : ${DETECTED_WIFI_IF:-wlp3s0} (OTA 5GHz: '${DETECTED_WIFI_SSID:-U+NetF254_5G}')"
        log_info "  -> Remote Wi-Fi Station   : ${REMOTE_CLIENT_HOST:-not_configured} (OTA 2.4GHz: 'U+NetF254')"
        log_info "  -> Upstream WAN Endpoint  : ${WAN_SERVER_IP:-10.10.0.1}"

        if (( DRY_RUN == 1 )); then
            log_info "[DRY-RUN] Would run ${trials} benchmark trials measuring A (5G+2.4G Wireless), B (Wired 1G), C (Simultaneous 3-Way)"
            log_info "[DRY-RUN] Acceptance: Degradation <= ${THROUGHPUT_DROP_TOLERANCE_PCT:-1.0}%"
            return 0
        fi

        if [[ -z "${REMOTE_CLIENT_HOST:-}" ]]; then
            die "REMOTE_CLIENT_HOST is not set in config.env. Configure remote client or run ./scripts/remote_client.sh --help"
        fi

        # Stop any stale iperf3 instances in ns-wan and start fresh
        ip netns exec "${WAN_NS:-ns-wan}" pkill -TERM iperf3 2>/dev/null || true
        sleep 0.2
        for port in 5201 5202 5203 5204; do
            ip netns exec "${WAN_NS:-ns-wan}" iperf3 -s -p "${port}" -D >/dev/null 2>&1
        done
        sleep 0.5

        run_tri_station_trials
        ip netns exec "${WAN_NS:-ns-wan}" pkill -TERM iperf3 2>/dev/null || true
        return 0
    fi

    # --------------------------------------------------------------------------
    # Case 2: Real Single-Band Testing (Single Active Band)
    # --------------------------------------------------------------------------
    if [[ "${eff_mode}" == "real_single_band" ]]; then
        log_step "[TC-SIM-01] Simultaneous Wired & Wireless Download Benchmark (5 Trials)"
        log_info "Simultaneous Benchmark Mode: [REAL_SINGLE_BAND] | Trials: ${trials} | Duration: ${duration}s"
        log_info "  -> Physical Wi-Fi Adapter : ${DETECTED_WIFI_IF:-none} (OTA Band: ${DETECTED_WIFI_BAND:-5GHz}, SSID: '${DETECTED_WIFI_SSID:-DUT}')"
        log_info "  -> Wired PC Adapter       : ${PC_IF:-enx6c1ff76608e2} (ns-pc: 1 Gbps LAN)"
        log_info "  -> Upstream WAN Endpoint  : ${WAN_SERVER_IP:-10.10.0.1}"

        if (( DRY_RUN == 1 )); then
            log_info "[DRY-RUN] Would run ${trials} benchmark trials measuring A (WLAN), B (Wired), C (Simultaneous) under mode: real_single_band"
            log_info "[DRY-RUN] Acceptance: Degradation <= ${THROUGHPUT_DROP_TOLERANCE_PCT:-1.0}%"
            return 0
        fi

        # Stop any stale iperf3 instances in ns-wan and start fresh
        ip netns exec "${WAN_NS:-ns-wan}" pkill -TERM iperf3 2>/dev/null || true
        sleep 0.2
        for port in 5201 5202 5203 5204; do
            ip netns exec "${WAN_NS:-ns-wan}" iperf3 -s -p "${port}" -D >/dev/null 2>&1
        done
        sleep 0.5

        run_single_band_trials "single" "${DETECTED_WIFI_BAND:-5GHz}" "${DETECTED_WIFI_SSID:-DUT}" "${DETECTED_WIFI_IF}" "${sim_json}"
        ip netns exec "${WAN_NS:-ns-wan}" pkill -TERM iperf3 2>/dev/null || true
        return 0
    fi

    # --------------------------------------------------------------------------
    # Case 3: Hybrid / Emulated Multi-Netns Testing
    # --------------------------------------------------------------------------
    log_step "[TC-SIM-01] Simultaneous Wired & Wireless Download Benchmark (5 Trials)"
    log_info "Simultaneous Benchmark Mode: [${eff_mode^^}] | Trials: ${trials} | Duration: ${duration}s"
    if [[ "${eff_mode}" == "hybrid" ]]; then
        log_info "  -> Physical Wi-Fi Adapter : ${DETECTED_WIFI_IF:-none} (OTA Band: ${DETECTED_WIFI_BAND:-5GHz}, SSID: '${DETECTED_WIFI_SSID:-DUT}')"
        log_info "  -> Wired PC Adapter       : ${PC_IF:-enx6c1ff76608e2} (ns-pc: 1 Gbps LAN)"
        log_info "  -> Upstream WAN Endpoint  : ${WAN_SERVER_IP:-10.10.0.1}"
    fi

    if (( DRY_RUN == 1 )); then
        log_info "[DRY-RUN] Would run ${trials} benchmark trials measuring A (WLAN), B (Wired), C (Simultaneous) under mode: ${eff_mode}"
        log_info "[DRY-RUN] Acceptance: Degradation <= ${THROUGHPUT_DROP_TOLERANCE_PCT:-1.0}%"
        return 0
    fi

    # Stop any stale iperf3 instances in ns-wan
    ip netns exec "${WAN_NS:-ns-wan}" pkill -TERM iperf3 2>/dev/null || true
    sleep 0.2

    # Start 4 iperf3 server daemons in WAN namespace
    local srv_ports=(5201 5202 5203 5204)
    for port in "${srv_ports[@]}"; do
        ip netns exec "${WAN_NS:-ns-wan}" iperf3 -s -p "${port}" -D >/dev/null 2>&1
    done
    sleep 0.5

    local a_trials=()
    local b_trials=()
    local c_trials=()

    log_info "Executing ${trials} measurement trials..."
    for (( i=1; i<=trials; i++ )); do
        log_info "--- Trial ${i}/${trials} ---"

        if [[ "${eff_mode}" == "hybrid" ]]; then
            # 1. Hybrid Wireless-only speed (A): Real active band + Virtual netns for remaining bands
            local hw_wifi_out="${SCENARIO_TMP_DIR}/iperf_hw_wifi_${i}.json"
            local vir_w2g_out="${SCENARIO_TMP_DIR}/iperf_vir_w2g_${i}.json"
            local vir_w6g_out="${SCENARIO_TMP_DIR}/iperf_vir_w6g_${i}.json"

            iperf3 -c "${WAN_SERVER_IP:-10.10.0.1}" --bind-dev "${DETECTED_WIFI_IF}" -p 5202 -t "${duration}" -J > "${hw_wifi_out}" 2>&1 &
            local hp1=$!
            ip netns exec "${WLAN2G_NS:-ns-wlan2g}" iperf3 -c "${WAN_SERVER_IP:-10.10.0.1}" -p 5203 -t "${duration}" -J > "${vir_w2g_out}" 2>&1 &
            local hp2=$!
            ip netns exec "${WLAN6G_NS:-ns-wlan6g}" iperf3 -c "${WAN_SERVER_IP:-10.10.0.1}" -p 5204 -t "${duration}" -J > "${vir_w6g_out}" 2>&1 &
            local hp3=$!
            wait "${hp1}" "${hp2}" "${hp3}" || true
            sleep 0.2

            local a_val
            a_val="$("${tools_dir}/metric_parser.py" sum-mbps "${hw_wifi_out}" "${vir_w2g_out}" "${vir_w6g_out}")"
            a_trials+=("${a_val}")
            log_info "  [Trial ${i}] Hybrid Wireless-only (A, Real+Virtual): ${a_val} Mbps"

            # 2. Wired-only speed (B): PC
            local pc_out="${SCENARIO_TMP_DIR}/iperf_pc_${i}.json"
            ip netns exec "${PC_NS:-ns-pc}" iperf3 -c "${WAN_SERVER_IP:-10.10.0.1}" -p 5201 -t "${duration}" -J > "${pc_out}" 2>&1 || true
            sleep 0.2
            local b_val
            b_val="$("${tools_dir}/metric_parser.py" sum-mbps "${pc_out}")"
            b_trials+=("${b_val}")
            log_info "  [Trial ${i}] Wired-only (B, 1G LAN): ${b_val} Mbps"

            # 3. Simultaneous speed (C): PC + Real Wi-Fi + Virtual netns
            local sim_pc_out="${SCENARIO_TMP_DIR}/iperf_sim_pc_${i}.json"
            local sim_hw_wifi_out="${SCENARIO_TMP_DIR}/iperf_sim_hw_wifi_${i}.json"
            local sim_vir_w2g_out="${SCENARIO_TMP_DIR}/iperf_sim_vir_w2g_${i}.json"
            local sim_vir_w6g_out="${SCENARIO_TMP_DIR}/iperf_sim_vir_w6g_${i}.json"

            ip netns exec "${PC_NS:-ns-pc}" iperf3 -c "${WAN_SERVER_IP:-10.10.0.1}" -p 5201 -t "${duration}" -J > "${sim_pc_out}" 2>&1 &
            local hsp0=$!
            iperf3 -c "${WAN_SERVER_IP:-10.10.0.1}" --bind-dev "${DETECTED_WIFI_IF}" -p 5202 -t "${duration}" -J > "${sim_hw_wifi_out}" 2>&1 &
            local hsp1=$!
            ip netns exec "${WLAN2G_NS:-ns-wlan2g}" iperf3 -c "${WAN_SERVER_IP:-10.10.0.1}" -p 5203 -t "${duration}" -J > "${sim_vir_w2g_out}" 2>&1 &
            local hsp2=$!
            ip netns exec "${WLAN6G_NS:-ns-wlan6g}" iperf3 -c "${WAN_SERVER_IP:-10.10.0.1}" -p 5204 -t "${duration}" -J > "${sim_vir_w6g_out}" 2>&1 &
            local hsp3=$!
            wait "${hsp0}" "${hsp1}" "${hsp2}" "${hsp3}" || true
            sleep 0.2

            local c_val
            c_val="$("${tools_dir}/metric_parser.py" sum-mbps "${sim_pc_out}" "${sim_hw_wifi_out}" "${sim_vir_w2g_out}" "${sim_vir_w6g_out}")"
            c_trials+=("${c_val}")
            log_info "  [Trial ${i}] Simultaneous (C): ${c_val} Mbps"

        else
            # emulated or default multi-netns
            # 1. Measure Wireless-only speed (A): 2.4G + 5G + 6G in parallel
            local w2g_out="${SCENARIO_TMP_DIR}/iperf_w2g_${i}.json"
            local w5g_out="${SCENARIO_TMP_DIR}/iperf_w5g_${i}.json"
            local w6g_out="${SCENARIO_TMP_DIR}/iperf_w6g_${i}.json"

            ip netns exec "${WLAN2G_NS:-ns-wlan2g}" iperf3 -c "${WAN_SERVER_IP:-10.10.0.1}" -p 5201 -t "${duration}" -J > "${w2g_out}" 2>&1 &
            local p1=$!
            ip netns exec "${WLAN5G_NS:-ns-wlan5g}" iperf3 -c "${WAN_SERVER_IP:-10.10.0.1}" -p 5202 -t "${duration}" -J > "${w5g_out}" 2>&1 &
            local p2=$!
            ip netns exec "${WLAN6G_NS:-ns-wlan6g}" iperf3 -c "${WAN_SERVER_IP:-10.10.0.1}" -p 5203 -t "${duration}" -J > "${w6g_out}" 2>&1 &
            local p3=$!
            wait "${p1}" "${p2}" "${p3}" || true
            sleep 0.2

            local a_val
            a_val="$("${tools_dir}/metric_parser.py" sum-mbps "${w2g_out}" "${w5g_out}" "${w6g_out}")"
            a_trials+=("${a_val}")
            log_info "  [Trial ${i}] Wireless-only (A): ${a_val} Mbps"

            # 2. Measure Wired-only speed (B): PC
            local pc_out="${SCENARIO_TMP_DIR}/iperf_pc_${i}.json"
            ip netns exec "${PC_NS:-ns-pc}" iperf3 -c "${WAN_SERVER_IP:-10.10.0.1}" -p 5201 -t "${duration}" -J > "${pc_out}" 2>&1 || true
            sleep 0.2
            local b_val
            b_val="$("${tools_dir}/metric_parser.py" sum-mbps "${pc_out}")"
            b_trials+=("${b_val}")
            log_info "  [Trial ${i}] Wired-only (B): ${b_val} Mbps"

            # 3. Measure Simultaneous speed (C): PC + 2.4G + 5G + 6G in parallel
            local sim_pc_out="${SCENARIO_TMP_DIR}/iperf_sim_pc_${i}.json"
            local sim_w2g_out="${SCENARIO_TMP_DIR}/iperf_sim_w2g_${i}.json"
            local sim_w5g_out="${SCENARIO_TMP_DIR}/iperf_sim_w5g_${i}.json"
            local sim_w6g_out="${SCENARIO_TMP_DIR}/iperf_sim_w6g_${i}.json"

            ip netns exec "${PC_NS:-ns-pc}" iperf3 -c "${WAN_SERVER_IP:-10.10.0.1}" -p 5201 -t "${duration}" -J > "${sim_pc_out}" 2>&1 &
            local sp0=$!
            ip netns exec "${WLAN2G_NS:-ns-wlan2g}" iperf3 -c "${WAN_SERVER_IP:-10.10.0.1}" -p 5202 -t "${duration}" -J > "${sim_w2g_out}" 2>&1 &
            local sp1=$!
            ip netns exec "${WLAN5G_NS:-ns-wlan5g}" iperf3 -c "${WAN_SERVER_IP:-10.10.0.1}" -p 5203 -t "${duration}" -J > "${sim_w5g_out}" 2>&1 &
            local sp2=$!
            ip netns exec "${WLAN6G_NS:-ns-wlan6g}" iperf3 -c "${WAN_SERVER_IP:-10.10.0.1}" -p 5204 -t "${duration}" -J > "${sim_w6g_out}" 2>&1 &
            local sp3=$!

            wait "${sp0}" "${sp1}" "${sp2}" "${sp3}" || true
            sleep 0.2

            local c_val
            c_val="$("${tools_dir}/metric_parser.py" sum-mbps "${sim_pc_out}" "${sim_w2g_out}" "${sim_w5g_out}" "${sim_w6g_out}")"
            c_trials+=("${c_val}")
            log_info "  [Trial ${i}] Simultaneous (C): ${c_val} Mbps"
        fi
    done

    ip netns exec "${WAN_NS:-ns-wan}" pkill -TERM iperf3 2>/dev/null || true

    local a_str b_str c_str
    a_str="$(IFS=,; echo "${a_trials[*]}")"
    b_str="$(IFS=,; echo "${b_trials[*]}")"
    c_str="$(IFS=,; echo "${c_trials[*]}")"

    local eval_cmd=(
        "${tools_dir}/metric_parser.py" eval-simultaneous
        "--trials-a" "${a_str}"
        "--trials-b" "${b_str}"
        "--trials-c" "${c_str}"
        "--mode" "${eff_mode}"
        "--tolerance" "${THROUGHPUT_DROP_TOLERANCE_PCT:-1.0}"
        "--output" "${sim_json}"
    )

    "${eval_cmd[@]}"
}

# ------------------------------------------------------------------------------
# Phase 5: Voice QoS Isolation (TC-QOS-01)
# ------------------------------------------------------------------------------
run_phase_voice_qos() {
    log_step "[TC-QOS-01] Wired PC Throughput with 2 Active Wi-Fi Phone Calls"
    local tools_dir="${LAB_DIR}/tools"
    local voice_json="${LOG_DIR}/voice_pc_qos.json"
    local call_duration="${CUSTOM_DURATION:-${VOIP_CALL_DURATION_SEC:-20}}"

    # 1. Engine Detection
    local engine="${CUSTOM_VOIP_ENGINE:-${VOIP_ENGINE:-auto}}"
    local pjsua_bin="${tools_dir}/bin/pjsua"
    local sipp_bin="${tools_dir}/bin/sipp"
    if [[ ! -x "${sipp_bin}" ]] && command -v sipp >/dev/null 2>&1; then
        sipp_bin="$(command -v sipp)"
    fi

    if [[ "${engine}" == "auto" ]]; then
        if [[ -x "${pjsua_bin}" ]]; then
            engine="pjsua"
        elif command -v pjsua >/dev/null 2>&1; then
            pjsua_bin="$(command -v pjsua)"
            engine="pjsua"
        elif [[ -x "${sipp_bin}" ]]; then
            engine="sipp"
        else
            engine="python"
        fi
    elif [[ "${engine}" == "pjsua" ]]; then
        if [[ ! -x "${pjsua_bin}" ]] && ! command -v pjsua >/dev/null 2>&1; then
            log_warn "pjsua requested but binary not found. Run ./scripts/install_pjsip.sh to build it. Falling back to sipp/python."
            if [[ -x "${sipp_bin}" ]]; then
                engine="sipp"
            else
                engine="python"
            fi
        fi
    elif [[ "${engine}" == "sipp" ]]; then
        if [[ ! -x "${sipp_bin}" ]]; then
            log_warn "sipp requested but binary not found. Run ./scripts/install_sipp.sh to install it. Falling back to python."
            engine="python"
        fi
    fi

    # 2. Topology Mode Detection
    local env_dump
    env_dump="$("${tools_dir}/wifi_inspector.py" export-env --check-ping "${DUT_LAN_IP:-192.168.1.1}" 2>/dev/null || true)"
    eval "${env_dump}"

    local eff_mode="${CUSTOM_WIFI_MODE:-auto}"
    if [[ "${eff_mode}" == "auto" ]]; then
        if [[ "${TOPOLOGY_MODE:-virtual}" == "virtual" ]]; then
            eff_mode="virtual"
        elif (( ${WIFI_CARD_COUNT:-0} == 0 )); then
            eff_mode="virtual"
        elif [[ -z "${DETECTED_WIFI_SSID:-}" ]]; then
            log_warn "Physical Wi-Fi card detected (${DETECTED_WIFI_IF}) but not connected to SSID. Falling back to virtual netns."
            eff_mode="virtual"
        elif [[ -n "${REMOTE_CLIENT_HOST:-}" ]] && "${SCRIPT_DIR}/remote_client.sh" test-connection >/dev/null 2>&1; then
            eff_mode="distributed"
        else
            eff_mode="physical_single"
        fi
    elif [[ "${eff_mode}" == "real_single" || "${eff_mode}" == "real_single_band" ]]; then
        eff_mode="physical_single"
    elif [[ "${eff_mode}" == "remote" || "${eff_mode}" == "tri_station" ]]; then
        eff_mode="distributed"
    elif [[ "${eff_mode}" == "emulated" ]]; then
        eff_mode="virtual"
    fi

    local wifi_ip="${DETECTED_WIFI_IP:-}"
    if [[ -z "${wifi_ip}" && ( "${eff_mode}" == "physical_single" || "${eff_mode}" == "distributed" ) ]]; then
        wifi_ip="$(ip -4 -o addr show dev "${DETECTED_WIFI_IF:-wlp3s0}" 2>/dev/null | awk '{print $4}' | cut -d/ -f1 || true)"
    fi

    # In distributed mode, query remote client Wi-Fi connection state
    if [[ "${eff_mode}" == "distributed" ]]; then
        local remote_env_dump
        remote_env_dump="$("${SCRIPT_DIR}/remote_client.sh" wifi-env --check-ping "${DUT_LAN_IP:-192.168.1.1}" 2>/dev/null || true)"
        eval "${remote_env_dump}"
    fi

    log_info "VoIP QoS Test Mode : [${eff_mode^^}] | Engine: [${engine^^}]"
    if [[ "${eff_mode}" == "physical_single" || "${eff_mode}" == "distributed" ]]; then
        local local_status="${DETECTED_WIFI_STATUS:-DISCONNECTED}"
        log_info "  -> Local Wi-Fi Adapter    : ${DETECTED_WIFI_IF:-none} [${local_status}] (SSID: '${DETECTED_WIFI_SSID:-DUT}', IP: ${wifi_ip:-unknown}, Band: ${DETECTED_WIFI_BAND:-unknown}, Signal: ${DETECTED_WIFI_SIGNAL:-unknown})"
        if [[ "${DETECTED_WIFI_PING_OK:-0}" == "1" ]]; then
            log_pass "     * Local DUT Reachability : OK (Ping to ${DUT_LAN_IP:-192.168.1.1}: ${DETECTED_WIFI_PING_RTT})"
        else
            log_warn "     * Local DUT Reachability : FAILED (Cannot ping gateway ${DUT_LAN_IP:-192.168.1.1})"
        fi

        if [[ "${eff_mode}" == "distributed" ]]; then
            local remote_status="${REMOTE_WIFI_STATUS:-DISCONNECTED}"
            log_info "  -> Remote Wi-Fi Station   : ${REMOTE_CLIENT_HOST} (via SSH)"
            log_info "     * Interface & Status   : ${REMOTE_WIFI_IF:-none} [${remote_status}] (MAC: ${REMOTE_WIFI_MAC:-none})"
            log_info "     * Target SSID & Band   : '${REMOTE_WIFI_SSID:-none}' (${REMOTE_WIFI_BAND:-none} / Ch ${REMOTE_WIFI_CHANNEL:-?}, Width: ${REMOTE_WIFI_WIDTH:-?})"
            log_info "     * Signal & Bitrate     : ${REMOTE_WIFI_SIGNAL:-none} (Tx: ${REMOTE_WIFI_BITRATE:-none})"
            log_info "     * Station IPv4 Address : ${REMOTE_WIFI_IP:-none} (Gateway: ${REMOTE_WIFI_GATEWAY:-none})"
            if [[ "${REMOTE_WIFI_PING_OK:-0}" == "1" ]]; then
                log_pass "     * Remote DUT Reachability: OK (Ping to ${DUT_LAN_IP:-192.168.1.1}: ${REMOTE_WIFI_PING_RTT})"
            else
                log_warn "     * Remote DUT Reachability: FAILED (Cannot ping gateway ${DUT_LAN_IP:-192.168.1.1})"
                log_warn "     * Please ensure Remote PC is connected to DUT SSID ('${DUT_SSID_2G:-DUT}' / '${DUT_SSID_5G:-DUT}')."
            fi
        fi
    fi
    log_info "  -> Wired PC Adapter       : ${PC_IF:-enx6c1ff76608e2} (ns-pc: 1 Gbps LAN)"
    log_info "  -> Upstream WAN Endpoint  : ${WAN_SERVER_IP:-10.10.0.1}"
    log_info "  -> QoS Marking            : DSCP 46 (EF / TOS 0xb8 = 184) -> Wi-Fi WMM Voice (AC_VO)"

    if (( DRY_RUN == 1 )); then
        log_info "[DRY-RUN] Would test PC throughput with and without 2 active VoIP calls using ${engine^^} under mode ${eff_mode}."
        log_info "[DRY-RUN] Acceptance: |A - B| / A <= ${VOIP_IMPACT_TOLERANCE_PCT:-1.0}%"
        return 0
    fi

    # 3. Network routing & DSCP preparation for physical Wi-Fi
    local added_wifi_route=0
    local added_mangle_rule=0
    if [[ "${eff_mode}" == "physical_single" || "${eff_mode}" == "distributed" ]]; then
        if [[ -n "${DETECTED_WIFI_IF:-}" && -n "${wifi_ip:-}" ]]; then
            # Ensure host route for WAN_SERVER_IP points via DUT gateway over physical Wi-Fi
            ip route replace "${WAN_SERVER_IP:-10.10.0.1}" via "${DUT_LAN_IP:-192.168.1.1}" dev "${DETECTED_WIFI_IF}" 2>/dev/null || true
            CLEANUP_WIFI_ROUTE="${WAN_SERVER_IP:-10.10.0.1} via ${DUT_LAN_IP:-192.168.1.1} dev ${DETECTED_WIFI_IF}"
            added_wifi_route=1

            # Ensure DSCP 46 (EF = 0xb8) marking on outgoing UDP voice packets for WMM Voice mapping
            iptables -t mangle -A POSTROUTING -o "${DETECTED_WIFI_IF}" -p udp -m multiport --dports 5060,5062,5064,10000,10002,10004 -j DSCP --set-dscp 46 2>/dev/null || true
            CLEANUP_IPTABLES_MANGLE="iptables -t mangle -D POSTROUTING -o ${DETECTED_WIFI_IF} -p udp -m multiport --dports 5060,5062,5064,10000,10002,10004 -j DSCP --set-dscp 46"
            added_mangle_rule=1
        fi
    fi

    # 4. Start iperf3 server in ns-wan
    ip netns exec "${WAN_NS:-ns-wan}" pkill -TERM iperf3 2>/dev/null || true
    sleep 0.2
    ip netns exec "${WAN_NS:-ns-wan}" iperf3 -s -p 5201 -D >/dev/null 2>&1
    sleep 0.3

    # Step 1: Baseline PC Throughput (A)
    log_info "Measuring baseline PC throughput without VoIP calls (A)..."
    local pc_base_out="${SCENARIO_TMP_DIR}/iperf_pc_base.json"
    ip netns exec "${PC_NS:-ns-pc}" iperf3 -c "${WAN_SERVER_IP:-10.10.0.1}" -p 5201 -t 4 -J > "${pc_base_out}" 2>&1
    local a_mbps
    a_mbps="$("${tools_dir}/metric_parser.py" sum-mbps "${pc_base_out}")"
    log_info "  Baseline PC throughput (A): ${a_mbps} Mbps"

    # Step 2: Start VoIP server and 2 Wi-Fi phone calls
    log_info "Starting VoIP media server and 2 active Wi-Fi phone calls using [${engine^^}]..."
    log_info "  -> Media Server (UAS)  : ns-wan:5060 (Listening for incoming SIP/RTP media)"
    if [[ "${eff_mode}" == "physical_single" ]]; then
        log_info "  -> Phone 1 (Physical)  : ${DETECTED_WIFI_IF} (${wifi_ip}:5062 -> RTP 10000 -> ${WAN_SERVER_IP:-10.10.0.1}:5060)"
        log_info "  -> Phone 2 (Physical)  : ${DETECTED_WIFI_IF} (${wifi_ip}:5064 -> RTP 10002 -> ${WAN_SERVER_IP:-10.10.0.1}:5060)"
    elif [[ "${eff_mode}" == "distributed" ]]; then
        log_info "  -> Phone 1 (Local Wi-Fi): ${DETECTED_WIFI_IF} (${wifi_ip}:5062 -> RTP 10000 -> ${WAN_SERVER_IP:-10.10.0.1}:5060)"
        log_info "  -> Phone 2 (Remote Wi-Fi): ${REMOTE_CLIENT_HOST} (${REMOTE_WIFI_IF:-wlan0}:${REMOTE_WIFI_IP:-unknown}:5064 -> RTP 10002 -> ${WAN_SERVER_IP:-10.10.0.1}:5060)"
    else
        log_info "  -> Phone 1 (Virtual)   : ns-phone1 (5060 -> RTP 10000 -> ${WAN_SERVER_IP:-10.10.0.1}:5060)"
        log_info "  -> Phone 2 (Virtual)   : ns-phone2 (5062 -> RTP 10002 -> ${WAN_SERVER_IP:-10.10.0.1}:5060)"
    fi
    local voip_srv_pid=""
    local phone1_pid=""
    local phone2_pid=""

    if [[ "${engine}" == "pjsua" ]]; then
        # Server UAS in ns-wan (auto-answers all incoming calls with 200 OK)
        ip netns exec "${WAN_NS:-ns-wan}" "${pjsua_bin}" \
            --local-port=5060 --null-audio --auto-answer=200 --no-cli-console --app-log-level=0 >/dev/null 2>&1 &
        voip_srv_pid=$!
        ACTIVE_BG_PIDS+=("${voip_srv_pid}")
        sleep 0.5

        if [[ "${eff_mode}" == "physical_single" ]]; then
            "${pjsua_bin}" --local-port=5062 --rtp-port=10000 --null-audio \
                --ip-addr="${wifi_ip}" --bound-addr="${wifi_ip}" \
                --duration="${call_duration}" --set-qos --no-cli-console --app-log-level=0 "sip:${WAN_SERVER_IP:-10.10.0.1}:5060" >/dev/null 2>&1 &
            phone1_pid=$!
            ACTIVE_BG_PIDS+=("${phone1_pid}")

            "${pjsua_bin}" --local-port=5064 --rtp-port=10002 --null-audio \
                --ip-addr="${wifi_ip}" --bound-addr="${wifi_ip}" \
                --duration="${call_duration}" --set-qos --no-cli-console --app-log-level=0 "sip:${WAN_SERVER_IP:-10.10.0.1}:5060" >/dev/null 2>&1 &
            phone2_pid=$!
            ACTIVE_BG_PIDS+=("${phone2_pid}")

        elif [[ "${eff_mode}" == "distributed" ]]; then
            "${pjsua_bin}" --local-port=5062 --rtp-port=10000 --null-audio \
                --ip-addr="${wifi_ip}" --bound-addr="${wifi_ip}" \
                --duration="${call_duration}" --set-qos --no-cli-console --app-log-level=0 "sip:${WAN_SERVER_IP:-10.10.0.1}:5060" >/dev/null 2>&1 &
            phone1_pid=$!
            ACTIVE_BG_PIDS+=("${phone1_pid}")

            "${SCRIPT_DIR}/remote_client.sh" run-voip \
                --engine "pjsua" \
                --server-ip "${WAN_SERVER_IP:-10.10.0.1}" \
                --server-port 5060 \
                --local-port 5064 \
                --rtp-port 10002 \
                --duration "${call_duration}" \
                --phone-id "phone-2" || true

        else
            ip netns exec "${PHONE1_NS:-ns-phone1}" "${pjsua_bin}" \
                --local-port=5060 --rtp-port=10000 --null-audio \
                --duration="${call_duration}" --set-qos --no-cli-console --app-log-level=0 "sip:${WAN_SERVER_IP:-10.10.0.1}:5060" >/dev/null 2>&1 &
            phone1_pid=$!
            ACTIVE_BG_PIDS+=("${phone1_pid}")

            ip netns exec "${PHONE2_NS:-ns-phone2}" "${pjsua_bin}" \
                --local-port=5062 --rtp-port=10002 --null-audio \
                --duration="${call_duration}" --set-qos --no-cli-console --app-log-level=0 "sip:${WAN_SERVER_IP:-10.10.0.1}:5060" >/dev/null 2>&1 &
            phone2_pid=$!
            ACTIVE_BG_PIDS+=("${phone2_pid}")
        fi

    elif [[ "${engine}" == "sipp" ]]; then
        # Server UAS in ns-wan
        ip netns exec "${WAN_NS:-ns-wan}" "${sipp_bin}" -sn uas -p 5060 -nostdin >/dev/null 2>&1 &
        voip_srv_pid=$!
        ACTIVE_BG_PIDS+=("${voip_srv_pid}")
        sleep 0.5

        local sipp_dur_ms=$(( call_duration * 1000 ))
        if [[ "${eff_mode}" == "physical_single" ]]; then
            "${sipp_bin}" -sn uac "${WAN_SERVER_IP:-10.10.0.1}:5060" -i "${wifi_ip}" -p 5062 -mp 10000 -m 1 -d "${sipp_dur_ms}" -nostdin >/dev/null 2>&1 &
            phone1_pid=$!
            ACTIVE_BG_PIDS+=("${phone1_pid}")

            "${sipp_bin}" -sn uac "${WAN_SERVER_IP:-10.10.0.1}:5060" -i "${wifi_ip}" -p 5064 -mp 10002 -m 1 -d "${sipp_dur_ms}" -nostdin >/dev/null 2>&1 &
            phone2_pid=$!
            ACTIVE_BG_PIDS+=("${phone2_pid}")

        elif [[ "${eff_mode}" == "distributed" ]]; then
            "${sipp_bin}" -sn uac "${WAN_SERVER_IP:-10.10.0.1}:5060" -i "${wifi_ip}" -p 5062 -mp 10000 -m 1 -d "${sipp_dur_ms}" -nostdin >/dev/null 2>&1 &
            phone1_pid=$!
            ACTIVE_BG_PIDS+=("${phone1_pid}")

            "${SCRIPT_DIR}/remote_client.sh" run-voip \
                --engine "sipp" \
                --server-ip "${WAN_SERVER_IP:-10.10.0.1}" \
                --server-port 5060 \
                --local-port 5064 \
                --rtp-port 10002 \
                --duration "${call_duration}" \
                --phone-id "phone-2" || true

        else
            ip netns exec "${PHONE1_NS:-ns-phone1}" "${sipp_bin}" -sn uac "${WAN_SERVER_IP:-10.10.0.1}:5060" \
                -p 5060 -mp 10000 -m 1 -d "${sipp_dur_ms}" -nostdin >/dev/null 2>&1 &
            phone1_pid=$!
            ACTIVE_BG_PIDS+=("${phone1_pid}")

            ip netns exec "${PHONE2_NS:-ns-phone2}" "${sipp_bin}" -sn uac "${WAN_SERVER_IP:-10.10.0.1}:5060" \
                -p 5062 -mp 10002 -m 1 -d "${sipp_dur_ms}" -nostdin >/dev/null 2>&1 &
            phone2_pid=$!
            ACTIVE_BG_PIDS+=("${phone2_pid}")
        fi

    else
        # Native Python G.711 RTP Simulator
        ip netns exec "${WAN_NS:-ns-wan}" "${tools_dir}/voip_call_simulator.py" server \
            --ports "10000,10002" --duration "$(( call_duration + 10 ))" >/dev/null 2>&1 &
        voip_srv_pid=$!
        ACTIVE_BG_PIDS+=("${voip_srv_pid}")
        sleep 0.3

        if [[ "${eff_mode}" == "physical_single" ]]; then
            "${tools_dir}/voip_call_simulator.py" client \
                --server-ip "${WAN_SERVER_IP:-10.10.0.1}" --server-port 10000 \
                --bind-ip "${wifi_ip}" --bind-port 10000 \
                --duration "${call_duration}" --phone-id "phone-1" >/dev/null 2>&1 &
            phone1_pid=$!
            ACTIVE_BG_PIDS+=("${phone1_pid}")

            "${tools_dir}/voip_call_simulator.py" client \
                --server-ip "${WAN_SERVER_IP:-10.10.0.1}" --server-port 10002 \
                --bind-ip "${wifi_ip}" --bind-port 10002 \
                --duration "${call_duration}" --phone-id "phone-2" >/dev/null 2>&1 &
            phone2_pid=$!
            ACTIVE_BG_PIDS+=("${phone2_pid}")

        elif [[ "${eff_mode}" == "distributed" ]]; then
            "${tools_dir}/voip_call_simulator.py" client \
                --server-ip "${WAN_SERVER_IP:-10.10.0.1}" --server-port 10000 \
                --bind-ip "${wifi_ip}" --bind-port 10000 \
                --duration "${call_duration}" --phone-id "phone-1" >/dev/null 2>&1 &
            phone1_pid=$!
            ACTIVE_BG_PIDS+=("${phone1_pid}")

            "${SCRIPT_DIR}/remote_client.sh" run-voip \
                --engine "python" \
                --server-ip "${WAN_SERVER_IP:-10.10.0.1}" \
                --server-port 10002 \
                --duration "${call_duration}" \
                --phone-id "phone-2" || true

        else
            ip netns exec "${PHONE1_NS:-ns-phone1}" "${tools_dir}/voip_call_simulator.py" client \
                --server-ip "${WAN_SERVER_IP:-10.10.0.1}" --server-port 10000 \
                --duration "${call_duration}" --phone-id "phone-1" >/dev/null 2>&1 &
            phone1_pid=$!
            ACTIVE_BG_PIDS+=("${phone1_pid}")

            ip netns exec "${PHONE2_NS:-ns-phone2}" "${tools_dir}/voip_call_simulator.py" client \
                --server-ip "${WAN_SERVER_IP:-10.10.0.1}" --server-port 10002 \
                --duration "${call_duration}" --phone-id "phone-2" >/dev/null 2>&1 &
            phone2_pid=$!
            ACTIVE_BG_PIDS+=("${phone2_pid}")
        fi
    fi

    log_pass "VoIP call media streams active on Wi-Fi client stations."
    sleep 1.0 # Allow calls to establish and stabilize

    # Step 3: Measure PC Throughput during active calls (B)
    log_info "Measuring PC throughput during 2 active Wi-Fi phone calls (B)..."
    local pc_call_out="${SCENARIO_TMP_DIR}/iperf_pc_call.json"
    ip netns exec "${PC_NS:-ns-pc}" iperf3 -c "${WAN_SERVER_IP:-10.10.0.1}" -p 5201 -t 4 -J > "${pc_call_out}" 2>&1
    local b_mbps
    b_mbps="$("${tools_dir}/metric_parser.py" sum-mbps "${pc_call_out}")"
    log_info "  Concurrent PC throughput (B): ${b_mbps} Mbps"

    # Clean up background VoIP processes and iperf server
    if [[ -n "${phone1_pid}" ]]; then kill "${phone1_pid}" 2>/dev/null || true; fi
    if [[ -n "${phone2_pid}" ]]; then kill "${phone2_pid}" 2>/dev/null || true; fi
    if [[ -n "${voip_srv_pid}" ]]; then kill "${voip_srv_pid}" 2>/dev/null || true; fi
    if [[ "${eff_mode}" == "distributed" ]]; then
        "${SCRIPT_DIR}/remote_client.sh" clean >/dev/null 2>&1 || true
    fi
    ip netns exec "${WAN_NS:-ns-wan}" pkill -TERM iperf3 2>/dev/null || true

    # Clean up physical Wi-Fi route and iptables rule
    if (( added_wifi_route == 1 )); then
        ip route del "${WAN_SERVER_IP:-10.10.0.1}" via "${DUT_LAN_IP:-192.168.1.1}" dev "${DETECTED_WIFI_IF}" 2>/dev/null || true
        CLEANUP_WIFI_ROUTE=""
    fi
    if (( added_mangle_rule == 1 )); then
        iptables -t mangle -D POSTROUTING -o "${DETECTED_WIFI_IF}" -p udp -m multiport --dports 5060,5062,5064,10000,10002,10004 -j DSCP --set-dscp 46 2>/dev/null || true
        CLEANUP_IPTABLES_MANGLE=""
    fi

    "${tools_dir}/metric_parser.py" eval-qos \
        --baseline "${a_mbps}" \
        --during "${b_mbps}" \
        --mode "${eff_mode}" \
        --engine "${engine}" \
        --wifi-if "${DETECTED_WIFI_IF:-}" \
        --wifi-ssid "${DETECTED_WIFI_SSID:-}" \
        --calls 2 \
        --tolerance "${VOIP_IMPACT_TOLERANCE_PCT:-1.0}" \
        --output "${voice_json}"
}

# ------------------------------------------------------------------------------
# Dispatcher for Individual & Composite Scenarios
# ------------------------------------------------------------------------------
execute_scenario() {
    local scn="$1"
    case "${scn}" in
        unicast|tc_wr_01)
            run_with_dual_capture "tc_wr_01_unicast" "${PC_NS:-ns-pc}" "udp port 5002" run_subphase_unicast
            ;;
        multicast|tc_wr_02)
            run_with_dual_capture "tc_wr_02_multicast" "${STB_NS:-ns-stb}" "udp port 5003" run_subphase_multicast
            ;;
        wire_rate)
            run_with_dual_capture "tc_wr_01_unicast" "${PC_NS:-ns-pc}" "udp port 5002" run_subphase_unicast
            run_with_dual_capture "tc_wr_02_multicast" "${STB_NS:-ns-stb}" "udp port 5003" run_subphase_multicast
            ;;
        burst_case1|tc_rm_01)
            run_with_dual_capture "tc_rm_01_burst53" "${STB_NS:-ns-stb}" "udp port 5001" run_subphase_burst_case1
            ;;
        burst_case2|tc_rm_02)
            run_with_dual_capture "tc_rm_02_burst100" "${STB_NS:-ns-stb}" "udp port 5001" run_subphase_burst_case2
            ;;
        rate_mismatch)
            run_with_dual_capture "tc_rm_01_burst53" "${STB_NS:-ns-stb}" "udp port 5001" run_subphase_burst_case1
            run_with_dual_capture "tc_rm_02_burst100" "${STB_NS:-ns-stb}" "udp port 5001" run_subphase_burst_case2
            ;;
        geforce|tc_app_01)
            run_with_dual_capture "tc_app_01_geforce" "${STB_NS:-ns-stb}" "udp port 5004" run_subphase_geforce
            ;;
        vod|tc_app_02)
            run_with_dual_capture "tc_app_02_vod" "${STB_NS:-ns-stb}" "udp port 5005" run_subphase_vod
            ;;
        real_world_stb)
            run_with_dual_capture "tc_app_01_geforce" "${STB_NS:-ns-stb}" "udp port 5004" run_subphase_geforce
            run_with_dual_capture "tc_app_02_vod" "${STB_NS:-ns-stb}" "udp port 5005" run_subphase_vod
            ;;
        simultaneous|tc_sim_01)
            run_with_dual_capture "tc_sim_01_simultaneous" "${PC_NS:-ns-pc}" "tcp port 5201 or tcp port 5202 or tcp port 5203 or tcp port 5204" run_phase_simultaneous
            ;;
        sequential|tc_sim_seq|multiband)
            CUSTOM_WIFI_MODE="sequential"
            run_with_dual_capture "tc_sim_01_simultaneous" "${PC_NS:-ns-pc}" "tcp port 5201 or tcp port 5202 or tcp port 5203 or tcp port 5204" run_phase_simultaneous
            ;;
        remote|tc_sim_remote|distributed)
            CUSTOM_WIFI_MODE="remote"
            run_with_dual_capture "tc_sim_01_simultaneous" "${PC_NS:-ns-pc}" "tcp port 5201 or tcp port 5202 or tcp port 5203 or tcp port 5204" run_phase_simultaneous
            ;;
        tri_station|tri_stream|concurrent|tc_sim_tri|distributed_3way)
            CUSTOM_WIFI_MODE="tri_station"
            run_with_dual_capture "tc_sim_01_simultaneous" "${PC_NS:-ns-pc}" "tcp port 5201 or tcp port 5202 or tcp port 5203 or tcp port 5204" run_phase_simultaneous
            ;;
        voice_qos|tc_qos_01)
            run_with_dual_capture "tc_qos_01_voice" "${PC_NS:-ns-pc}" "tcp port 5201 or udp port 10000 or udp port 10002 or udp port 10004 or udp port 5060 or udp port 5062 or udp port 5064" run_phase_voice_qos
            ;;
        all)
            run_with_dual_capture "tc_wr_01_unicast" "${PC_NS:-ns-pc}" "udp port 5002" run_subphase_unicast
            run_with_dual_capture "tc_wr_02_multicast" "${STB_NS:-ns-stb}" "udp port 5003" run_subphase_multicast
            run_with_dual_capture "tc_rm_01_burst53" "${STB_NS:-ns-stb}" "udp port 5001" run_subphase_burst_case1
            run_with_dual_capture "tc_rm_02_burst100" "${STB_NS:-ns-stb}" "udp port 5001" run_subphase_burst_case2
            run_with_dual_capture "tc_app_01_geforce" "${STB_NS:-ns-stb}" "udp port 5004" run_subphase_geforce
            run_with_dual_capture "tc_app_02_vod" "${STB_NS:-ns-stb}" "udp port 5005" run_subphase_vod
            run_with_dual_capture "tc_sim_01_simultaneous" "${PC_NS:-ns-pc}" "tcp port 5201 or tcp port 5202 or tcp port 5203 or tcp port 5204" run_phase_simultaneous
            run_with_dual_capture "tc_qos_01_voice" "${PC_NS:-ns-pc}" "tcp port 5201 or udp port 10000 or udp port 10002 or udp port 10004 or udp port 5060 or udp port 5062 or udp port 5064" run_phase_voice_qos
            ;;
        *)
            die "Unknown scenario: ${scn}"
            ;;
    esac
}

main() {
    local scenario="all"
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --dry-run|-n)
                DRY_RUN=1
                shift
                ;;
            --no-capture|-C)
                NO_CAPTURE=1
                shift
                ;;
            --duration|-d)
                [[ $# -ge 2 ]] || die "Option --duration requires a seconds argument"
                CUSTOM_DURATION="$2"
                shift 2
                ;;
            --wifi-mode|-W)
                [[ $# -ge 2 ]] || die "Option --wifi-mode requires a mode argument (auto, real_single, sequential, remote, tri_station, hybrid, emulated)"
                CUSTOM_WIFI_MODE="$2"
                shift 2
                ;;
            --voip-engine|-E)
                [[ $# -ge 2 ]] || die "Option --voip-engine requires an engine argument (auto, pjsua, sipp, python)"
                CUSTOM_VOIP_ENGINE="$2"
                shift 2
                ;;
            --stability|--soak)
                NO_CAPTURE=1
                CUSTOM_DURATION="${CUSTOM_DURATION:-60}"
                shift
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            unicast|tc_wr_01|multicast|tc_wr_02|wire_rate|burst_case1|tc_rm_01|burst_case2|tc_rm_02|rate_mismatch|geforce|tc_app_01|vod|tc_app_02|real_world_stb|simultaneous|tc_sim_01|sequential|tc_sim_seq|multiband|remote|tc_sim_remote|distributed|tri_station|tri_stream|concurrent|tc_sim_tri|distributed_3way|voice_qos|tc_qos_01|all)
                scenario="$1"
                shift
                ;;
            *)
                log_error "Unknown option or scenario: $1"
                usage
                exit 1
                ;;
        esac
    done

    load_config "${LAB_DIR}/config.env"
    if [[ -f "${STATE_DIR}/topology_state.env" ]]; then
        # shellcheck disable=SC1090
        source "${STATE_DIR}/topology_state.env"
    fi

    if (( DRY_RUN == 0 )); then
        require_root
        require_command ip
        require_command python3
        require_command iperf3
    fi

    ensure_runtime_dirs
    SCENARIO_TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/gw_perf_scenario.XXXXXX")"
    trap cleanup_scenario_trap EXIT INT TERM ERR

    print_header "STARTING GATEWAY PERFORMANCE TEST: [${scenario^^}]"

    if (( DRY_RUN == 0 )); then
        if ns_exists "${WAN_NS:-ns-wan}"; then
            ip -n "${WAN_NS:-ns-wan}" route replace "${DUT_LAN_IP:-192.168.1.1}/${LAN_PREFIX:-24}" via "${DUT_WAN_IP:-10.10.0.100}" dev eth0 2>/dev/null || true
            ip -n "${WAN_NS:-ns-wan}" route replace default via "${DUT_WAN_IP:-10.10.0.100}" dev eth0 2>/dev/null || true
            ip -n "${WAN_NS:-ns-wan}" route replace 224.0.0.0/4 dev eth0 2>/dev/null || true
        fi
        if ns_exists "${DUT_NS:-ns-dut}"; then
            ip netns exec "${DUT_NS:-ns-dut}" iptables -P FORWARD ACCEPT 2>/dev/null || true
            ip netns exec "${DUT_NS:-ns-dut}" iptables -A FORWARD -j ACCEPT 2>/dev/null || true
            ip -n "${DUT_NS:-ns-dut}" route replace 224.0.0.0/4 dev br-lan 2>/dev/null || true
        fi
    fi

    execute_scenario "${scenario}"

    log_success "Scenario run complete. Summary logs generated in ${LOG_DIR}/."
    printf '\nSuggested next steps:\n'
    printf '  - Run compliance verifier: ./scripts/verify_compliance.sh\n'
    printf '  - Inspect captures:        ./scripts/capture.sh status\n'
    printf '  - Audit dual captures:     ./scripts/capture.sh compare\n'
}

main "$@"
