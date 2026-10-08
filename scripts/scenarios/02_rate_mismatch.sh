#!/usr/bin/env bash
# ==============================================================================
# SCENARIO MODULE: RATE MISMATCH BURSTS
# [TC-RM-01] Burst Case 1: 1500B, 50% Load, >= 53 Frames (Switch Buffer Test)
# [TC-RM-02] Burst Case 2: 1500B, 16% Load, 100 Frames (Switch Buffer Test)
# Includes Automated Physical Link Speed Adaptation (1G -> 100M Full-Duplex)
# Refactored with Defensive Bash Programming Patterns
# ==============================================================================

# Canonical constants
readonly RM_DEFAULT_TARGET_SPEED=100
readonly RM_DEFAULT_GIGABIT_SPEED=1000
readonly RM_DEFAULT_BURST_CASE1_FRAMES=53
readonly RM_DEFAULT_BURST_CASE1_LOAD="50.0"
readonly RM_DEFAULT_BURST_CASE2_FRAMES=100
readonly RM_DEFAULT_BURST_CASE2_LOAD="16.0"
readonly RM_DEFAULT_BURST_COUNT=20
readonly RM_DEFAULT_PACKET_SIZE=1500
readonly RM_DEFAULT_RATE_MBPS="1000.0"
readonly RM_DEFAULT_TIMEOUT="5.0"
readonly RM_DEFAULT_RX_PORT=5001
readonly RM_DEFAULT_TX_PORT=5000

usage_block_rm01() {
    cat <<'EOF'
+------------------------------------------------------------------+
| [TC-RM-01] RATE MISMATCH BURST CASE 1 (50% LOAD)                 |
+------------------------------------------------------------------+
  Scenario Aliases : burst_case1, tc_rm_01
  Objective        : Evaluate switch buffer absorptivity (1G WAN -> 100M LAN)
  Burst Profile    : 1500-byte frames, burst size = 53 frames @ 50% load (500 Mbps)
  Repetitions      : 20 bursts (total 1,060 packets)
  Pass Criteria    : 0% packet loss across all burst cycles

  Supported Options:
    --no-adapt-speed         Do not alter physical NIC speed before test
    --debug, -v              Show exact commands executed at each step
    --snaplen, -s <bytes>    Packet capture snaplen in bytes (default: 96)
    --no-capture, -C         Disable packet capture during test
    --collect-artifacts, -A  Package run deliverables into artifacts/
    --log, -l [file]         Mirror console output to a log file
    --dry-run, -n            Preview parameters without sending traffic

  Examples:
    sudo ./scripts/scenario.sh burst_case1
    sudo ./scripts/scenario.sh --no-adapt-speed tc_rm_01
    sudo ./scripts/scenario.sh -v -A burst_case1

EOF
}

usage_block_rm02() {
    cat <<'EOF'
+------------------------------------------------------------------+
| [TC-RM-02] RATE MISMATCH BURST CASE 2 (16% LOAD)                 |
+------------------------------------------------------------------+
  Scenario Aliases : burst_case2, tc_rm_02
  Objective        : Evaluate switch buffer absorptivity under moderate load
  Burst Profile    : 1500-byte frames, burst size = 100 frames @ 16% load (160 Mbps)
  Repetitions      : 20 bursts (total 2,000 packets)
  Pass Criteria    : 0% packet loss across all burst cycles

  Supported Options:
    --no-adapt-speed         Do not alter physical NIC speed before test
    --debug, -v              Show exact commands executed at each step
    --snaplen, -s <bytes>    Packet capture snaplen in bytes (default: 96)
    --no-capture, -C         Disable packet capture during test
    --collect-artifacts, -A  Package run deliverables into artifacts/
    --log, -l [file]         Mirror console output to a log file
    --dry-run, -n            Preview parameters without sending traffic

  Examples:
    sudo ./scripts/scenario.sh burst_case2
    sudo ./scripts/scenario.sh -C tc_rm_02
    sudo ./scripts/scenario.sh -v burst_case2

EOF
}

# ------------------------------------------------------------------------------
# Process Termination Helper (Escalating SIGTERM -> SIGKILL)
# ------------------------------------------------------------------------------
_rm_terminate_pids() {
    local pids=("$@")
    if (( ${#pids[@]} == 0 )); then
        return 0
    fi

    for pid in "${pids[@]}"; do
        if [[ -n "${pid}" && "${pid}" =~ ^[0-9]+$ ]] && kill -0 "${pid}" 2>/dev/null; then
            kill -TERM "${pid}" 2>/dev/null || true
        fi
    done

    sleep 0.2

    for pid in "${pids[@]}"; do
        if [[ -n "${pid}" && "${pid}" =~ ^[0-9]+$ ]] && kill -0 "${pid}" 2>/dev/null; then
            kill -KILL "${pid}" 2>/dev/null || true
        fi
    done
}

# ------------------------------------------------------------------------------
# Automated Physical Link Speed Adaptation for Rate Mismatch Bursts
# In physical topology without dedicated STB_IF, throttles the shared LAN adapter
# from 1 Gbps to 100 Mbps so that the DUT switch buffer is genuinely stressed.
# ------------------------------------------------------------------------------
adapt_burst_physical_speed() {
    local target_speed="${1:-${RM_DEFAULT_TARGET_SPEED}}"
    if [[ ! "${target_speed}" =~ ^[0-9]+$ || "${target_speed}" -le 0 ]]; then
        target_speed="${RM_DEFAULT_TARGET_SPEED}"
    fi

    if (( AUTO_ADAPT_BURST_SPEED == 0 )); then
        log_info "Automatic physical link speed adaptation disabled by flag."
        return 0
    fi

    if [[ "${TOPOLOGY_MODE:-virtual}" != "physical" ]]; then
        return 0
    fi

    local phy_if="${STB_IF:-${PC_IF:-${LAN_IF:-}}}"
    if [[ -z "${phy_if}" ]] || [[ ! -e "/sys/class/net/${phy_if}" ]]; then
        return 0
    fi

    # Must be a real physical NIC backed by a hardware device in sysfs
    if [[ ! -d "/sys/class/net/${phy_if}/device" ]]; then
        return 0
    fi

    if ! command -v ethtool >/dev/null 2>&1; then
        log_warn "ethtool not available; cannot adapt physical link speed on ${phy_if}."
        return 0
    fi

    local current_speed
    current_speed="$(ethtool "${phy_if}" 2>/dev/null | awk '/Speed:/ {print $2}' | tr -dc '0-9' || true)"
    if [[ -z "${current_speed}" || ! "${current_speed}" =~ ^[0-9]+$ ]]; then
        current_speed="${RM_DEFAULT_GIGABIT_SPEED}"
    fi

    if (( current_speed == target_speed )); then
        log_info "Physical LAN interface [${phy_if}] is already negotiated at ${target_speed} Mbps."
        return 0
    fi

    log_info "Physical Link Speed Adaptation: Adjusting [${phy_if}] link speed: ${current_speed}M -> ${target_speed}M Full-Duplex..."
    ADAPTED_NIC="${phy_if}"
    ORIGINAL_NIC_SPEED="${current_speed}"

    if (( DRY_RUN == 1 )); then
        log_info "[DRY-RUN] Would adapt physical link speed on [${phy_if}]: ${current_speed}M -> ${target_speed}M Full-Duplex"
        return 0
    fi

    log_cmd "ethtool -s ${phy_if} speed ${target_speed} duplex full autoneg on"
    if ! ethtool -s "${phy_if}" speed "${target_speed}" duplex full autoneg on 2>/dev/null; then
        log_cmd "ethtool -s ${phy_if} speed ${target_speed} duplex full autoneg off"
        ethtool -s "${phy_if}" speed "${target_speed}" duplex full autoneg off 2>/dev/null || true
    fi

    log_info "Waiting for physical link carrier re-negotiation on ${phy_if} (${target_speed}M)..."
    local count=0
    local link_up=0
    local now_speed=""
    local carrier=0
    while (( count < 35 )); do
        sleep 0.4
        carrier=0
        if [[ -f "/sys/class/net/${phy_if}/carrier" ]]; then
            carrier="$(cat "/sys/class/net/${phy_if}/carrier" 2>/dev/null || echo 0)"
        fi
        now_speed="$(ethtool "${phy_if}" 2>/dev/null | awk '/Speed:/ {print $2}' | tr -dc '0-9' || true)"
        if [[ "${carrier}" == "1" && "${now_speed}" == "${target_speed}" ]]; then
            link_up=1
            break
        fi
        if (( count >= 15 )) && [[ "${now_speed}" != "${target_speed}" ]]; then
            ethtool -s "${phy_if}" speed "${target_speed}" duplex full autoneg off 2>/dev/null || true
        fi
        count=$(( count + 1 ))
    done

    if (( link_up == 1 )); then
        log_pass "Physical LAN link successfully negotiated at ${target_speed} Mbps Full-Duplex on ${phy_if}."
    else
        local actual_spd
        actual_spd="$(ethtool "${phy_if}" 2>/dev/null | awk '/Speed:/ {print $2}' || echo unknown)"
        log_warn "Physical link state on ${phy_if}: speed=${actual_spd} (Carrier: ${carrier}). Proceeding with test..."
    fi

    # Warm up ARP table and verify reachability to DUT gateway
    sleep 0.5
    if ns_exists "${STB_NS:-ns-stb}"; then
        ip netns exec "${STB_NS:-ns-stb}" ping -c 1 -W 2 "${DUT_LAN_IP:-192.168.1.1}" >/dev/null 2>&1 || true
    fi
}

restore_burst_physical_speed() {
    if [[ -z "${ADAPTED_NIC:-}" ]]; then
        return 0
    fi

    local phy_if="${ADAPTED_NIC}"
    local restore_spd="${ORIGINAL_NIC_SPEED:-${RM_DEFAULT_GIGABIT_SPEED}}"
    ADAPTED_NIC=""
    ORIGINAL_NIC_SPEED=""

    log_info "Restoring physical LAN adapter [${phy_if}] link speed to ${restore_spd} Mbps (Gigabit Auto-Negotiation)..."

    if (( DRY_RUN == 1 )); then
        log_info "[DRY-RUN] Would restore physical link speed on [${phy_if}]: 100M -> ${restore_spd}M (Gigabit Auto-Negotiation)"
        return 0
    fi

    log_cmd "ethtool -s ${phy_if} autoneg on"
    ethtool -s "${phy_if}" autoneg on 2>/dev/null || ethtool -s "${phy_if}" speed "${restore_spd}" duplex full autoneg on 2>/dev/null || true

    log_info "Waiting for physical link carrier re-negotiation on ${phy_if} (${restore_spd}M)..."
    local count=0
    local link_up=0
    local now_speed=""
    local carrier=0
    while (( count < 35 )); do
        sleep 0.4
        carrier=0
        if [[ -f "/sys/class/net/${phy_if}/carrier" ]]; then
            carrier="$(cat "/sys/class/net/${phy_if}/carrier" 2>/dev/null || echo 0)"
        fi
        now_speed="$(ethtool "${phy_if}" 2>/dev/null | awk '/Speed:/ {print $2}' | tr -dc '0-9' || true)"
        if [[ "${carrier}" == "1" && -n "${now_speed}" && "${now_speed}" -ge 1000 ]]; then
            link_up=1
            break
        fi
        count=$(( count + 1 ))
    done

    if (( link_up == 1 )); then
        log_pass "Physical LAN link restored to Gigabit (${now_speed} Mbps) on ${phy_if}."
    else
        local actual_spd
        actual_spd="$(ethtool "${phy_if}" 2>/dev/null | awk '/Speed:/ {print $2}' || echo unknown)"
        log_warn "Physical link state on ${phy_if}: speed=${actual_spd}."
    fi

    # Warm up ARP table for Gigabit PC endpoint
    sleep 0.5
    if ns_exists "${PC_NS:-ns-pc}"; then
        ip netns exec "${PC_NS:-ns-pc}" ping -c 1 -W 2 "${DUT_LAN_IP:-192.168.1.1}" >/dev/null 2>&1 || true
    fi
}

# ------------------------------------------------------------------------------
# Sub-phase 2A: Burst Case 1 (1500B, 50% Load, >=53 Frames) (TC-RM-01)
# ------------------------------------------------------------------------------
run_subphase_burst_case1() {
    log_step "[TC-RM-01] WAN-to-LAN Rate Mismatch Burst Case 1 (1500B, 50% Load, >=53 Frames)"
    local tools_dir="${LAB_DIR}/tools"

    # Validate burst parameters defensively
    local c1_frames="${BURST_CASE1_FRAMES:-${RM_DEFAULT_BURST_CASE1_FRAMES}}"
    if [[ ! "${c1_frames}" =~ ^[0-9]+$ || "${c1_frames}" -le 0 ]]; then
        log_warn "Invalid BURST_CASE1_FRAMES '${c1_frames}'. Using default ${RM_DEFAULT_BURST_CASE1_FRAMES}."
        c1_frames="${RM_DEFAULT_BURST_CASE1_FRAMES}"
    fi

    local c1_load="${BURST_CASE1_LOAD:-${RM_DEFAULT_BURST_CASE1_LOAD}}"
    local c1_count="${BURST_COUNT:-${RM_DEFAULT_BURST_COUNT}}"
    if [[ ! "${c1_count}" =~ ^[0-9]+$ || "${c1_count}" -le 0 ]]; then
        log_warn "Invalid BURST_COUNT '${c1_count}'. Using default ${RM_DEFAULT_BURST_COUNT}."
        c1_count="${RM_DEFAULT_BURST_COUNT}"
    fi

    local pkt_size="${BURST_PACKET_SIZE:-${RM_DEFAULT_PACKET_SIZE}}"
    if [[ ! "${pkt_size}" =~ ^[0-9]+$ || "${pkt_size}" -le 0 ]]; then
        pkt_size="${RM_DEFAULT_PACKET_SIZE}"
    fi

    local c1_expected=$(( c1_frames * c1_count ))
    local c1_json="${LOG_DIR}/burst_case1.json"

    if (( DRY_RUN == 1 )); then
        log_info "[DRY-RUN] Would test Burst Case 1: ${pkt_size}B, Length=${c1_frames} frames, Load=${c1_load}%, Total=${c1_expected} frames"
        return 0
    fi

    ensure_client_endpoint "${STB_NS:-ns-stb}" "${STB_IP:-192.168.1.20}"
    local c1_rx_log="${SCENARIO_TMP_DIR}/burst_c1_rx.log"

    log_cmd "ip netns exec ${STB_NS:-ns-stb} ${tools_dir}/traffic_generator.py burst-recv --bind-ip 0.0.0.0 --bind-port ${RM_DEFAULT_RX_PORT} --server-ip ${WAN_SERVER_IP:-10.10.0.1} --server-port ${RM_DEFAULT_TX_PORT} --expected-packets ${c1_expected} --timeout ${RM_DEFAULT_TIMEOUT} --output-json ${c1_json} > ${c1_rx_log} 2>&1 &"
    ip netns exec "${STB_NS:-ns-stb}" "${tools_dir}/traffic_generator.py" burst-recv \
        --bind-ip "0.0.0.0" --bind-port "${RM_DEFAULT_RX_PORT}" \
        --server-ip "${WAN_SERVER_IP:-10.10.0.1}" --server-port "${RM_DEFAULT_TX_PORT}" \
        --expected-packets "${c1_expected}" --timeout "${RM_DEFAULT_TIMEOUT}" \
        --output-json "${c1_json}" > "${c1_rx_log}" 2>&1 &
    local c1_rx_pid=$!
    ACTIVE_BG_PIDS+=("${c1_rx_pid}")
    sleep 0.3

    log_cmd "ip netns exec ${WAN_NS:-ns-wan} ${tools_dir}/traffic_generator.py burst-send --dest-ip ${STB_IP:-192.168.1.20} --dest-port ${RM_DEFAULT_RX_PORT} --bind-port ${RM_DEFAULT_TX_PORT} --wait-handshake --packet-size ${pkt_size} --burst-length ${c1_frames} --burst-load ${c1_load} --burst-count ${c1_count} --rate-mbps ${RM_DEFAULT_RATE_MBPS}"
    ip netns exec "${WAN_NS:-ns-wan}" "${tools_dir}/traffic_generator.py" burst-send \
        --dest-ip "${STB_IP:-192.168.1.20}" --dest-port "${RM_DEFAULT_RX_PORT}" \
        --bind-port "${RM_DEFAULT_TX_PORT}" --wait-handshake \
        --packet-size "${pkt_size}" --burst-length "${c1_frames}" \
        --burst-load "${c1_load}" --burst-count "${c1_count}" --rate-mbps "${RM_DEFAULT_RATE_MBPS}" || true

    wait "${c1_rx_pid}" 2>/dev/null || true
    _rm_terminate_pids "${c1_rx_pid}"

    if [[ -f "${c1_json}" ]]; then
        log_cmd "${tools_dir}/metric_parser.py format-card ${c1_json}"
        "${tools_dir}/metric_parser.py" format-card "${c1_json}"
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

    # Validate burst parameters defensively
    local c2_frames="${BURST_CASE2_FRAMES:-${RM_DEFAULT_BURST_CASE2_FRAMES}}"
    if [[ ! "${c2_frames}" =~ ^[0-9]+$ || "${c2_frames}" -le 0 ]]; then
        log_warn "Invalid BURST_CASE2_FRAMES '${c2_frames}'. Using default ${RM_DEFAULT_BURST_CASE2_FRAMES}."
        c2_frames="${RM_DEFAULT_BURST_CASE2_FRAMES}"
    fi

    local c2_load="${BURST_CASE2_LOAD:-${RM_DEFAULT_BURST_CASE2_LOAD}}"
    local c2_count="${BURST_COUNT:-${RM_DEFAULT_BURST_COUNT}}"
    if [[ ! "${c2_count}" =~ ^[0-9]+$ || "${c2_count}" -le 0 ]]; then
        log_warn "Invalid BURST_COUNT '${c2_count}'. Using default ${RM_DEFAULT_BURST_COUNT}."
        c2_count="${RM_DEFAULT_BURST_COUNT}"
    fi

    local pkt_size="${BURST_PACKET_SIZE:-${RM_DEFAULT_PACKET_SIZE}}"
    if [[ ! "${pkt_size}" =~ ^[0-9]+$ || "${pkt_size}" -le 0 ]]; then
        pkt_size="${RM_DEFAULT_PACKET_SIZE}"
    fi

    local c2_expected=$(( c2_frames * c2_count ))
    local c2_json="${LOG_DIR}/burst_case2.json"

    if (( DRY_RUN == 1 )); then
        log_info "[DRY-RUN] Would test Burst Case 2: ${pkt_size}B, Length=${c2_frames} frames, Load=${c2_load}%, Total=${c2_expected} frames"
        return 0
    fi

    ensure_client_endpoint "${STB_NS:-ns-stb}" "${STB_IP:-192.168.1.20}"
    local c2_rx_log="${SCENARIO_TMP_DIR}/burst_c2_rx.log"

    log_cmd "ip netns exec ${STB_NS:-ns-stb} ${tools_dir}/traffic_generator.py burst-recv --bind-ip 0.0.0.0 --bind-port ${RM_DEFAULT_RX_PORT} --server-ip ${WAN_SERVER_IP:-10.10.0.1} --server-port ${RM_DEFAULT_TX_PORT} --expected-packets ${c2_expected} --timeout ${RM_DEFAULT_TIMEOUT} --output-json ${c2_json} > ${c2_rx_log} 2>&1 &"
    ip netns exec "${STB_NS:-ns-stb}" "${tools_dir}/traffic_generator.py" burst-recv \
        --bind-ip "0.0.0.0" --bind-port "${RM_DEFAULT_RX_PORT}" \
        --server-ip "${WAN_SERVER_IP:-10.10.0.1}" --server-port "${RM_DEFAULT_TX_PORT}" \
        --expected-packets "${c2_expected}" --timeout "${RM_DEFAULT_TIMEOUT}" \
        --output-json "${c2_json}" > "${c2_rx_log}" 2>&1 &
    local c2_rx_pid=$!
    ACTIVE_BG_PIDS+=("${c2_rx_pid}")
    sleep 0.3

    log_cmd "ip netns exec ${WAN_NS:-ns-wan} ${tools_dir}/traffic_generator.py burst-send --dest-ip ${STB_IP:-192.168.1.20} --dest-port ${RM_DEFAULT_RX_PORT} --bind-port ${RM_DEFAULT_TX_PORT} --wait-handshake --packet-size ${pkt_size} --burst-length ${c2_frames} --burst-load ${c2_load} --burst-count ${c2_count} --rate-mbps ${RM_DEFAULT_RATE_MBPS}"
    ip netns exec "${WAN_NS:-ns-wan}" "${tools_dir}/traffic_generator.py" burst-send \
        --dest-ip "${STB_IP:-192.168.1.20}" --dest-port "${RM_DEFAULT_RX_PORT}" \
        --bind-port "${RM_DEFAULT_TX_PORT}" --wait-handshake \
        --packet-size "${pkt_size}" --burst-length "${c2_frames}" \
        --burst-load "${c2_load}" --burst-count "${c2_count}" --rate-mbps "${RM_DEFAULT_RATE_MBPS}" || true

    wait "${c2_rx_pid}" 2>/dev/null || true
    _rm_terminate_pids "${c2_rx_pid}"

    if [[ -f "${c2_json}" ]]; then
        log_cmd "${tools_dir}/metric_parser.py format-card ${c2_json}"
        "${tools_dir}/metric_parser.py" format-card "${c2_json}"
    else
        log_warn "Burst receiver log output:"
        cat "${c2_rx_log}" 2>/dev/null || true
    fi
}
