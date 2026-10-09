#!/usr/bin/env bash
# ==============================================================================
# SCENARIO MODULE: SIMULTANEOUS THROUGHPUT & MULTI-BAND BENCHMARK
# [TC-SIM-01] Simultaneous Wired & Wireless Download Benchmark (5 Trials)
# Supports: Sequential Multi-Band, Remote Client, 3-Way Concurrent, Real Single-Band
# Refactored with Defensive Bash Programming Patterns
# ==============================================================================

# Defensive bootstrap: auto-source scenario_common.sh if running in standalone test harness
if ! declare -F terminate_bg_pids >/dev/null 2>&1; then
    _scn_common_lib="$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" 2>/dev/null && pwd)/scenario_common.sh"
    if [[ -f "${_scn_common_lib}" ]]; then
        source "${_scn_common_lib}"
    fi
    unset _scn_common_lib
fi

# Canonical constants
readonly SIM_DEFAULT_TRIALS=5
readonly SIM_DEFAULT_DURATION="3"
readonly SIM_DEFAULT_TOLERANCE="1.0"
readonly SIM_PORT_WIRED=5201
readonly SIM_PORT_WIFI1=5202
readonly SIM_PORT_WIFI2=5203
readonly SIM_PORT_WIFI3=5204
readonly SIM_SERVER_PORTS=(5201 5202 5203 5204)

usage_block_sim01() {
    cat <<'EOF'
+------------------------------------------------------------------+
| [TC-SIM-01] SIMULTANEOUS & MULTI-BAND BENCHMARK (5 TRIALS)       |
+------------------------------------------------------------------+
  Scenario Aliases : simultaneous, tc_sim_01, sequential, tc_sim_seq,
  Objective        : Multi-station aggregate throughput benchmark
  Architecture     : Wired LAN client + Wi-Fi bands (2.4GHz / 5GHz / 6GHz)
  Pass Criteria    : 5 of 5 consecutive trials meet aggregate throughput targets

  Execution Flavors / Sub-scenarios:
    sequential, tc_sim_seq   Sequential isolated benchmarks (5GHz then 2.4GHz)
    simultaneous, tc_sim_01  Simultaneous concurrent traffic (Wired + Tri-Band)
    remote, tc_sim_remote    Distributed execution via Remote Client PC (SSH)
    tri_station, tc_sim_tri  3-way physical concurrency: Wired PC + 5GHz + 2.4GHz

  Supported Options:
    --wifi-mode, -W <mode>   Adaptive Wi-Fi deployment mode:
                             - auto        : Auto-detect NICs & remote PC (default)
                             - real_single : Local physical Wi-Fi NIC (wlan0)
                             - remote      : Remote PC client via SSH
                             - remote_only : Exclusively run on Remote Client PC
                             - distributed : Hybrid local + remote multi-station
                             - tri_station : 3 physical stations (local + remote)
                             - emulated    : mac80211_hwsim virtual Wi-Fi
    --remote-only, -R        Run Wi-Fi traffic exclusively on Remote Client PC
    --duration, -d <sec>     Duration per trial in seconds (default: 10)
    --debug, -v              Show exact commands executed at each step
    --snaplen, -s <bytes>    Packet capture snaplen in bytes (default: 96)
    --no-capture, -C         Disable packet capture during test
    --collect-artifacts, -A  Package run deliverables into artifacts/
    --log, -l [file]         Mirror console output to a log file
    --dry-run, -n            Preview parameters without sending traffic

  Examples:
    sudo ./scripts/scenario.sh sequential
    sudo ./scripts/scenario.sh simultaneous
    sudo ./scripts/scenario.sh tri_station
    sudo ./scripts/scenario.sh -W remote simultaneous
    sudo ./scripts/scenario.sh -R -d 15 -A sequential
    sudo ./scripts/scenario.sh -s 96 -A tc_sim_01

EOF
}

# ------------------------------------------------------------------------------
# Process Supervision & Server Helpers (Traffic Orchestrator Adapters)
# ------------------------------------------------------------------------------
_sim_terminate_pids() {
    traffic_stop_group "$@"
}

_sim_stop_servers() {
    traffic_clean_stale --netns "${WAN_NS:-ns-wan}" "iperf3"
}

_sim_start_servers() {
    local ports=("$@")
    if (( ${#ports[@]} == 0 )); then
        ports=("${SIM_SERVER_PORTS[@]}")
    fi

    _sim_stop_servers
    sleep 0.2

    for port in "${ports[@]}"; do
        log_cmd "ip netns exec ${WAN_NS:-ns-wan} iperf3 -s -p ${port} -D"
        ip netns exec "${WAN_NS:-ns-wan}" iperf3 -s -p "${port}" -D >/dev/null 2>&1 || true
    done
    sleep 0.5
}

# ------------------------------------------------------------------------------
# Helper: Run N trials of Simultaneous Benchmark for a single Wi-Fi band
# (A: Wireless, B: Wired, C: Simultaneous)
# ------------------------------------------------------------------------------
run_single_band_trials() {
    local band_tag="$1"
    local band_name="$2"
    local target_ssid="$3"
    local wifi_if="$4"
    local out_json="$5"
    local tools_dir="${LAB_DIR}/tools"

    local trials="${BENCHMARK_TRIALS:-${SIM_DEFAULT_TRIALS}}"
    if [[ ! "${trials}" =~ ^[0-9]+$ || "${trials}" -le 0 ]]; then
        trials="${SIM_DEFAULT_TRIALS}"
    fi

    local duration="${CUSTOM_DURATION:-${BENCHMARK_DURATION_SEC:-${SIM_DEFAULT_DURATION}}}"
    if [[ ! "${duration}" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
        duration="${SIM_DEFAULT_DURATION}"
    fi

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
        log_cmd "iperf3 -c ${WAN_SERVER_IP:-10.10.0.1} --bind-dev ${wifi_if} -p ${SIM_PORT_WIFI1} -t ${duration} -J > ${wifi_out}"
        iperf3 -c "${WAN_SERVER_IP:-10.10.0.1}" --bind-dev "${wifi_if}" -p "${SIM_PORT_WIFI1}" -t "${duration}" -J > "${wifi_out}" 2>&1 || true
        sleep 0.2
        local a_val
        a_val="$("${tools_dir}/metric_parser.py" sum-mbps "${wifi_out}")"
        a_trials+=("${a_val}")
        log_info "  [Trial ${i}] Real Wireless-only (A, ${band_name}): ${a_val} Mbps"

        # 2. Wired-only speed (B): PC via ns-pc
        local pc_out="${SCENARIO_TMP_DIR}/iperf_pc_${band_tag}_${i}.json"
        log_cmd "ip netns exec ${PC_NS:-ns-pc} iperf3 -c ${WAN_SERVER_IP:-10.10.0.1} -p ${SIM_PORT_WIRED} -t ${duration} -J > ${pc_out}"
        ip netns exec "${PC_NS:-ns-pc}" iperf3 -c "${WAN_SERVER_IP:-10.10.0.1}" -p "${SIM_PORT_WIRED}" -t "${duration}" -J > "${pc_out}" 2>&1 || true
        sleep 0.2
        local b_val
        b_val="$("${tools_dir}/metric_parser.py" sum-mbps "${pc_out}")"
        b_trials+=("${b_val}")
        log_info "  [Trial ${i}] Wired-only (B, 1G LAN): ${b_val} Mbps"

        # 3. Simultaneous speed (C): Wired PC + Real Wi-Fi concurrently
        local sim_pc_out="${SCENARIO_TMP_DIR}/iperf_sim_pc_${band_tag}_${i}.json"
        local sim_wifi_out="${SCENARIO_TMP_DIR}/iperf_sim_wifi_${band_tag}_${i}.json"

        traffic_run_bg --job "sp0" --netns "${PC_NS:-ns-pc}" --out "${sim_pc_out}" \
            iperf3 -c "${WAN_SERVER_IP:-10.10.0.1}" -p "${SIM_PORT_WIRED}" -t "${duration}" -J
        traffic_run_bg --job "sp1" --out "${sim_wifi_out}" \
            iperf3 -c "${WAN_SERVER_IP:-10.10.0.1}" --bind-dev "${wifi_if}" -p "${SIM_PORT_WIFI1}" -t "${duration}" -J

        traffic_wait_all "sp0" "sp1"
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
        "--mode" "real_single_band_${band_tag}"
        "--tolerance" "${THROUGHPUT_DROP_TOLERANCE_PCT:-${SIM_DEFAULT_TOLERANCE}}"
        "--output" "${out_json}"
        "--wifi-if" "${wifi_if}"
        "--wifi-band" "${band_name}"
        "--wifi-ssid" "${target_ssid}"
        "--trials-c-wired" "${c_wired_str}"
        "--trials-c-wifi" "${c_wifi_str}"
    )
    "${eval_cmd[@]}" || true
}

# ------------------------------------------------------------------------------
# Helper: Run N trials of Simultaneous Benchmark with a Remote PC Client over SSH
# ------------------------------------------------------------------------------
run_remote_station_trials() {
    local tools_dir="${LAB_DIR}/tools"
    local sim_json="${LOG_DIR}/simultaneous_benchmark.json"
    local remote_host="${REMOTE_CLIENT_HOST:-}"
    local remote_script="${SCRIPT_DIR}/remote_client.sh"

    local trials="${BENCHMARK_TRIALS:-${SIM_DEFAULT_TRIALS}}"
    if [[ ! "${trials}" =~ ^[0-9]+$ || "${trials}" -le 0 ]]; then
        trials="${SIM_DEFAULT_TRIALS}"
    fi

    local duration="${CUSTOM_DURATION:-${BENCHMARK_DURATION_SEC:-${SIM_DEFAULT_DURATION}}}"
    if [[ ! "${duration}" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
        duration="${SIM_DEFAULT_DURATION}"
    fi

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
        log_cmd "${remote_script} run-iperf -c ${WAN_SERVER_IP:-10.10.0.1} ${bind_opt[*]} -p ${SIM_PORT_WIFI1} -t ${duration} -J > ${wifi_out}"
        "${remote_script}" run-iperf -c "${WAN_SERVER_IP:-10.10.0.1}" "${bind_opt[@]}" -p "${SIM_PORT_WIFI1}" -t "${duration}" -J > "${wifi_out}" 2>&1 || true
        sleep 0.2
        local a_val
        a_val="$("${tools_dir}/metric_parser.py" sum-mbps "${wifi_out}")"
        a_trials+=("${a_val}")
        log_info "  [Trial ${i}] Remote Wireless-only (A, Remote PC): ${a_val} Mbps"

        # 2. Local Wired-only speed (B): Local PC via ns-pc
        local pc_out="${SCENARIO_TMP_DIR}/iperf_pc_remote_${i}.json"
        log_cmd "ip netns exec ${PC_NS:-ns-pc} iperf3 -c ${WAN_SERVER_IP:-10.10.0.1} -p ${SIM_PORT_WIRED} -t ${duration} -J > ${pc_out}"
        ip netns exec "${PC_NS:-ns-pc}" iperf3 -c "${WAN_SERVER_IP:-10.10.0.1}" -p "${SIM_PORT_WIRED}" -t "${duration}" -J > "${pc_out}" 2>&1 || true
        sleep 0.2
        local b_val
        b_val="$("${tools_dir}/metric_parser.py" sum-mbps "${pc_out}")"
        b_trials+=("${b_val}")
        log_info "  [Trial ${i}] Local Wired-only (B, 1G LAN): ${b_val} Mbps"

        # 3. Simultaneous speed (C): Local Wired PC + Remote Wi-Fi concurrently
        local sim_pc_out="${SCENARIO_TMP_DIR}/iperf_sim_pc_remote_${i}.json"
        local sim_wifi_out="${SCENARIO_TMP_DIR}/iperf_sim_wifi_remote_${i}.json"

        traffic_run_bg --job "sp0" --netns "${PC_NS:-ns-pc}" --out "${sim_pc_out}" \
            iperf3 -c "${WAN_SERVER_IP:-10.10.0.1}" -p "${SIM_PORT_WIRED}" -t "${duration}" -J
        traffic_run_bg --job "sp1" --out "${sim_wifi_out}" \
            "${remote_script}" run-iperf -c "${WAN_SERVER_IP:-10.10.0.1}" "${bind_opt[@]}" -p "${SIM_PORT_WIFI1}" -t "${duration}" -J

        traffic_wait_all "sp0" "sp1"
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
        "--tolerance" "${THROUGHPUT_DROP_TOLERANCE_PCT:-${SIM_DEFAULT_TOLERANCE}}"
        "--output" "${sim_json}"
        "--wifi-if" "remote_pc"
        "--wifi-band" "Remote-WiFi"
        "--wifi-ssid" "${remote_host}"
        "--trials-c-wired" "${c_wired_str}"
        "--trials-c-wifi" "${c_wifi_str}"
    )
    "${eval_cmd[@]}" || true
}

# ------------------------------------------------------------------------------
# Helper: Run N trials of 3-Way Concurrent Benchmark
# (Wired 1G + Local Wi-Fi 5GHz + Remote Wi-Fi 2.4GHz)
# ------------------------------------------------------------------------------
run_tri_station_trials() {
    local tools_dir="${LAB_DIR}/tools"
    local sim_json="${LOG_DIR}/simultaneous_benchmark.json"
    local remote_host="${REMOTE_CLIENT_HOST:-}"
    local remote_script="${SCRIPT_DIR}/remote_client.sh"
    local local_wifi_if="${DETECTED_WIFI_IF:-wlp3s0}"

    local trials="${BENCHMARK_TRIALS:-${SIM_DEFAULT_TRIALS}}"
    if [[ ! "${trials}" =~ ^[0-9]+$ || "${trials}" -le 0 ]]; then
        trials="${SIM_DEFAULT_TRIALS}"
    fi

    local duration="${CUSTOM_DURATION:-${BENCHMARK_DURATION_SEC:-${SIM_DEFAULT_DURATION}}}"
    if [[ ! "${duration}" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
        duration="${SIM_DEFAULT_DURATION}"
    fi

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

        traffic_run_bg --job "ap0" --out "${w5g_out}" \
            iperf3 -c "${WAN_SERVER_IP:-10.10.0.1}" --bind-dev "${local_wifi_if}" -p "${SIM_PORT_WIFI1}" -t "${duration}" -J
        traffic_run_bg --job "ap1" --out "${w2g_out}" \
            "${remote_script}" run-iperf -c "${WAN_SERVER_IP:-10.10.0.1}" "${bind_opt[@]}" -p "${SIM_PORT_WIFI2}" -t "${duration}" -J

        traffic_wait_all "ap0" "ap1"
        sleep 0.2

        local a5g_val a2g_val a_sum
        a5g_val="$("${tools_dir}/metric_parser.py" sum-mbps "${w5g_out}")"
        a2g_val="$("${tools_dir}/metric_parser.py" sum-mbps "${w2g_out}")"
        a_sum="$(awk -v a="${a5g_val:-0}" -v b="${a2g_val:-0}" 'BEGIN { printf "%.2f", a + b }')"
        a_trials+=("${a_sum}")
        log_info "  [Trial ${i}] Wireless-only (A, 5G+2.4G): ${a_sum} Mbps (Local 5G: ${a5g_val} Mbps, Remote 2.4G: ${a2g_val} Mbps)"

        # 2. Local Wired-only speed (B): Local PC via ns-pc
        local pc_out="${SCENARIO_TMP_DIR}/iperf_pc_b_${i}.json"
        log_cmd "ip netns exec ${PC_NS:-ns-pc} iperf3 -c ${WAN_SERVER_IP:-10.10.0.1} -p ${SIM_PORT_WIRED} -t ${duration} -J > ${pc_out}"
        ip netns exec "${PC_NS:-ns-pc}" iperf3 -c "${WAN_SERVER_IP:-10.10.0.1}" -p "${SIM_PORT_WIRED}" -t "${duration}" -J > "${pc_out}" 2>&1 || true
        sleep 0.2
        local b_val
        b_val="$("${tools_dir}/metric_parser.py" sum-mbps "${pc_out}")"
        b_trials+=("${b_val}")
        log_info "  [Trial ${i}] Local Wired-only (B, 1G LAN): ${b_val} Mbps"

        # 3. Simultaneous speed (C): Local Wired PC + Local Wi-Fi 5G + Remote Wi-Fi 2.4G concurrently!
        local sim_pc_out="${SCENARIO_TMP_DIR}/iperf_sim_pc_${i}.json"
        local sim_w5g_out="${SCENARIO_TMP_DIR}/iperf_sim_w5g_${i}.json"
        local sim_w2g_out="${SCENARIO_TMP_DIR}/iperf_sim_w2g_${i}.json"

        traffic_run_bg --job "sp0" --netns "${PC_NS:-ns-pc}" --out "${sim_pc_out}" \
            iperf3 -c "${WAN_SERVER_IP:-10.10.0.1}" -p "${SIM_PORT_WIRED}" -t "${duration}" -J
        traffic_run_bg --job "sp1" --out "${sim_w5g_out}" \
            iperf3 -c "${WAN_SERVER_IP:-10.10.0.1}" --bind-dev "${local_wifi_if}" -p "${SIM_PORT_WIFI1}" -t "${duration}" -J
        traffic_run_bg --job "sp2" --out "${sim_w2g_out}" \
            "${remote_script}" run-iperf -c "${WAN_SERVER_IP:-10.10.0.1}" "${bind_opt[@]}" -p "${SIM_PORT_WIFI2}" -t "${duration}" -J

        traffic_wait_all "sp0" "sp1" "sp2"
        sleep 0.2

        local c_wired c_w5g c_w2g c_wifi_tot c_val
        c_wired="$("${tools_dir}/metric_parser.py" sum-mbps "${sim_pc_out}")"
        c_w5g="$("${tools_dir}/metric_parser.py" sum-mbps "${sim_w5g_out}")"
        c_w2g="$("${tools_dir}/metric_parser.py" sum-mbps "${sim_w2g_out}")"
        c_wifi_tot="$(awk -v a="${c_w5g:-0}" -v b="${c_w2g:-0}" 'BEGIN { printf "%.2f", a + b }')"
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
        "--tolerance" "${THROUGHPUT_DROP_TOLERANCE_PCT:-${SIM_DEFAULT_TOLERANCE}}"
        "--output" "${sim_json}"
        "--wifi-if" "${local_wifi_if}+${remote_wifi_if}"
        "--wifi-band" "5GHz(Local)+2.4GHz(Remote)"
        "--wifi-ssid" "${DETECTED_WIFI_SSID:-${DUT_SSID_5G:-DUT_5G}}+${DUT_SSID_2G:-DUT_2G}"
        "--trials-c-wired" "${c_wired_str}"
        "--trials-c-wifi" "${c_wifi_str}"
    )
    log_cmd "${eval_cmd[*]}"
    "${eval_cmd[@]}" || true
}

# ------------------------------------------------------------------------------
# Phase 4: Simultaneous Wired & Wireless Use (TC-SIM-01)
# ------------------------------------------------------------------------------
run_phase_simultaneous() {
    local tools_dir="${LAB_DIR}/tools"
    local sim_json="${LOG_DIR}/simultaneous_benchmark.json"

    local trials="${BENCHMARK_TRIALS:-${SIM_DEFAULT_TRIALS}}"
    if [[ ! "${trials}" =~ ^[0-9]+$ || "${trials}" -le 0 ]]; then
        trials="${SIM_DEFAULT_TRIALS}"
    fi

    local duration="${CUSTOM_DURATION:-${BENCHMARK_DURATION_SEC:-${SIM_DEFAULT_DURATION}}}"
    if [[ ! "${duration}" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
        duration="${SIM_DEFAULT_DURATION}"
    fi

    # Step 0: Resolve canonical execution plan via Running Context Resolver
    orchestrator_resolve_context
    local eff_mode="${PLAN_SIM_MODE:-emulated}"
    orchestrator_show_plan "TC-SIM-01 Simultaneous Download"

    _sim_setup_wifi_route() {
        if (( DRY_RUN == 1 )); then return 0; fi
        station_adapter_acquire
    }

    _sim_cleanup_wifi_route() {
        station_adapter_release
    }

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
            log_info "[DRY-RUN] Acceptance: Degradation <= ${THROUGHPUT_DROP_TOLERANCE_PCT:-${SIM_DEFAULT_TOLERANCE}}% across all bands"
            return 0
        fi

        _sim_start_servers
        _sim_setup_wifi_route

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
                log_cmd "${SCRIPT_DIR}/wifi_connect.sh connect ${b_tag} --force"
                "${SCRIPT_DIR}/wifi_connect.sh" connect "${b_tag}" --force
                _sim_setup_wifi_route
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
        log_cmd "${SCRIPT_DIR}/wifi_connect.sh connect 5g --force"
        "${SCRIPT_DIR}/wifi_connect.sh" connect 5g --force >/dev/null 2>&1 || true

        _sim_stop_servers
        _sim_cleanup_wifi_route

        # Consolidate results across all tested bands
        local seq_json="${LOG_DIR}/simultaneous_sequential_benchmark.json"
        local seq_cmd=(
            "${tools_dir}/metric_parser.py" eval-sequential
            "${band_json_files[@]}"
            --tolerance "${THROUGHPUT_DROP_TOLERANCE_PCT:-${SIM_DEFAULT_TOLERANCE}}"
            --output "${seq_json}"
        )
        log_cmd "${seq_cmd[*]}"
        "${seq_cmd[@]}" || true

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
            log_info "[DRY-RUN] Acceptance: Degradation <= ${THROUGHPUT_DROP_TOLERANCE_PCT:-${SIM_DEFAULT_TOLERANCE}}%"
            return 0
        fi

        if [[ -z "${REMOTE_CLIENT_HOST:-}" ]]; then
            die "REMOTE_CLIENT_HOST is not set in config.env. Configure remote client or run ./scripts/remote_client.sh --help"
        fi

        _sim_start_servers
        run_remote_station_trials
        _sim_stop_servers
        return 0
    fi

    # --------------------------------------------------------------------------
    # Case 3: 3-Way Concurrent Physical Testing (Wired 1G + Local 5G + Remote 2.4G)
    # --------------------------------------------------------------------------
    if [[ "${eff_mode}" == "tri_station" ]]; then
        log_step "[TC-SIM-01] 3-Way Concurrent Physical Benchmark (Wired 1G + Local 5G + Remote 2.4G)"
        log_info "Simultaneous Benchmark Mode: [TRI_STATION_CONCURRENT] | Trials: ${trials} | Duration: ${duration}s"
        log_info "  -> Local Wired Adapter    : ${PC_IF:-enx6c1ff76608e2} (ns-pc: 1 Gbps LAN)"
        log_info "  -> Local Wi-Fi Adapter    : ${DETECTED_WIFI_IF:-wlp3s0} (OTA 5GHz: '${DETECTED_WIFI_SSID:-${DUT_SSID_5G:-DUT_5G}}')"
        log_info "  -> Remote Wi-Fi Station   : ${REMOTE_CLIENT_HOST:-not_configured} (OTA 2.4GHz: '${DUT_SSID_2G:-DUT_2G}')"
        log_info "  -> Upstream WAN Endpoint  : ${WAN_SERVER_IP:-10.10.0.1}"

        if (( DRY_RUN == 1 )); then
            log_info "[DRY-RUN] Would run ${trials} benchmark trials measuring A (5G+2.4G Wireless), B (Wired 1G), C (Simultaneous 3-Way)"
            log_info "[DRY-RUN] Acceptance: Degradation <= ${THROUGHPUT_DROP_TOLERANCE_PCT:-${SIM_DEFAULT_TOLERANCE}}%"
            return 0
        fi

        if [[ -z "${REMOTE_CLIENT_HOST:-}" ]]; then
            die "REMOTE_CLIENT_HOST is not set in config.env. Configure remote client or run ./scripts/remote_client.sh --help"
        fi

        _sim_start_servers
        _sim_setup_wifi_route
        run_tri_station_trials
        _sim_stop_servers
        _sim_cleanup_wifi_route
        return 0
    fi

    # --------------------------------------------------------------------------
    # Case 4: Real Single-Band Testing (Single Active Band)
    # --------------------------------------------------------------------------
    if [[ "${eff_mode}" == "real_single_band" ]]; then
        log_step "[TC-SIM-01] Simultaneous Wired & Wireless Download Benchmark (5 Trials)"
        log_info "Simultaneous Benchmark Mode: [REAL_SINGLE_BAND] | Trials: ${trials} | Duration: ${duration}s"
        log_info "  -> Physical Wi-Fi Adapter : ${DETECTED_WIFI_IF:-none} (OTA Band: ${DETECTED_WIFI_BAND:-5GHz}, SSID: '${DETECTED_WIFI_SSID:-DUT}')"
        log_info "  -> Wired PC Adapter       : ${PC_IF:-enx6c1ff76608e2} (ns-pc: 1 Gbps LAN)"
        log_info "  -> Upstream WAN Endpoint  : ${WAN_SERVER_IP:-10.10.0.1}"

        if (( DRY_RUN == 1 )); then
            log_info "[DRY-RUN] Would run ${trials} benchmark trials measuring A (WLAN), B (Wired), C (Simultaneous) under mode: real_single_band"
            log_info "[DRY-RUN] Acceptance: Degradation <= ${THROUGHPUT_DROP_TOLERANCE_PCT:-${SIM_DEFAULT_TOLERANCE}}%"
            return 0
        fi

        _sim_start_servers
        _sim_setup_wifi_route
        run_single_band_trials "single" "${DETECTED_WIFI_BAND:-5GHz}" "${DETECTED_WIFI_SSID:-DUT}" "${DETECTED_WIFI_IF}" "${sim_json}"
        _sim_stop_servers
        _sim_cleanup_wifi_route
        return 0
    fi

    # --------------------------------------------------------------------------
    # Case 5: Hybrid / Emulated Multi-Netns Testing
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
        log_info "[DRY-RUN] Acceptance: Degradation <= ${THROUGHPUT_DROP_TOLERANCE_PCT:-${SIM_DEFAULT_TOLERANCE}}%"
        return 0
    fi

    _sim_start_servers
    if [[ "${eff_mode}" == "hybrid" ]]; then
        _sim_setup_wifi_route
    fi

    local a_trials=()
    local b_trials=()
    local c_trials=()
    local c_wired_trials=()
    local c_wifi_trials=()

    log_info "Executing ${trials} measurement trials..."
    for (( i=1; i<=trials; i++ )); do
        log_info "--- Trial ${i}/${trials} ---"

        if [[ "${eff_mode}" == "hybrid" ]]; then
            # 1. Hybrid Wireless-only speed (A): Real active band + Virtual netns for remaining bands
            local hw_wifi_out="${SCENARIO_TMP_DIR}/iperf_hw_wifi_${i}.json"
            local vir_w2g_out="${SCENARIO_TMP_DIR}/iperf_vir_w2g_${i}.json"
            local vir_w6g_out="${SCENARIO_TMP_DIR}/iperf_vir_w6g_${i}.json"

            traffic_run_bg --job "hp1" --out "${hw_wifi_out}" \
                iperf3 -c "${WAN_SERVER_IP:-10.10.0.1}" --bind-dev "${DETECTED_WIFI_IF}" -p "${SIM_PORT_WIFI1}" -t "${duration}" -J
            traffic_run_bg --job "hp2" --netns "${WLAN2G_NS:-ns-wlan2g}" --out "${vir_w2g_out}" \
                iperf3 -c "${WAN_SERVER_IP:-10.10.0.1}" -p "${SIM_PORT_WIFI2}" -t "${duration}" -J
            traffic_run_bg --job "hp3" --netns "${WLAN6G_NS:-ns-wlan6g}" --out "${vir_w6g_out}" \
                iperf3 -c "${WAN_SERVER_IP:-10.10.0.1}" -p "${SIM_PORT_WIFI3}" -t "${duration}" -J

            traffic_wait_all "hp1" "hp2" "hp3"
            sleep 0.2

            local a_val
            a_val="$("${tools_dir}/metric_parser.py" sum-mbps "${hw_wifi_out}" "${vir_w2g_out}" "${vir_w6g_out}")"
            a_trials+=("${a_val}")
            log_info "  [Trial ${i}] Hybrid Wireless-only (A, Real+Virtual): ${a_val} Mbps"

            # 2. Wired-only speed (B): PC
            local pc_out="${SCENARIO_TMP_DIR}/iperf_pc_${i}.json"
            log_cmd "ip netns exec ${PC_NS:-ns-pc} iperf3 -c ${WAN_SERVER_IP:-10.10.0.1} -p ${SIM_PORT_WIRED} -t ${duration} -J > ${pc_out}"
            ip netns exec "${PC_NS:-ns-pc}" iperf3 -c "${WAN_SERVER_IP:-10.10.0.1}" -p "${SIM_PORT_WIRED}" -t "${duration}" -J > "${pc_out}" 2>&1 || true
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

            traffic_run_bg --job "hsp0" --netns "${PC_NS:-ns-pc}" --out "${sim_pc_out}" \
                iperf3 -c "${WAN_SERVER_IP:-10.10.0.1}" -p "${SIM_PORT_WIRED}" -t "${duration}" -J
            traffic_run_bg --job "hsp1" --out "${sim_hw_wifi_out}" \
                iperf3 -c "${WAN_SERVER_IP:-10.10.0.1}" --bind-dev "${DETECTED_WIFI_IF}" -p "${SIM_PORT_WIFI1}" -t "${duration}" -J
            traffic_run_bg --job "hsp2" --netns "${WLAN2G_NS:-ns-wlan2g}" --out "${sim_vir_w2g_out}" \
                iperf3 -c "${WAN_SERVER_IP:-10.10.0.1}" -p "${SIM_PORT_WIFI2}" -t "${duration}" -J
            traffic_run_bg --job "hsp3" --netns "${WLAN6G_NS:-ns-wlan6g}" --out "${sim_vir_w6g_out}" \
                iperf3 -c "${WAN_SERVER_IP:-10.10.0.1}" -p "${SIM_PORT_WIFI3}" -t "${duration}" -J

            traffic_wait_all "hsp0" "hsp1" "hsp2" "hsp3"
            sleep 0.2

            local c_wired c_wifi c_val
            c_wired="$("${tools_dir}/metric_parser.py" sum-mbps "${sim_pc_out}")"
            c_wifi="$("${tools_dir}/metric_parser.py" sum-mbps "${sim_hw_wifi_out}" "${sim_vir_w2g_out}" "${sim_vir_w6g_out}")"
            c_val="$("${tools_dir}/metric_parser.py" sum-mbps "${sim_pc_out}" "${sim_hw_wifi_out}" "${sim_vir_w2g_out}" "${sim_vir_w6g_out}")"
            c_trials+=("${c_val}")
            c_wired_trials+=("${c_wired}")
            c_wifi_trials+=("${c_wifi}")
            log_info "  [Trial ${i}] Simultaneous (C): ${c_val} Mbps (Wired: ${c_wired} Mbps, Wi-Fi: ${c_wifi} Mbps)"

        else
            # emulated or default multi-netns
            # 1. Measure Wireless-only speed (A): 2.4G + 5G + 6G in parallel
            local w2g_out="${SCENARIO_TMP_DIR}/iperf_w2g_${i}.json"
            local w5g_out="${SCENARIO_TMP_DIR}/iperf_w5g_${i}.json"
            local w6g_out="${SCENARIO_TMP_DIR}/iperf_w6g_${i}.json"

            traffic_run_bg --job "p1" --netns "${WLAN2G_NS:-ns-wlan2g}" --out "${w2g_out}" \
                iperf3 -c "${WAN_SERVER_IP:-10.10.0.1}" -p "${SIM_PORT_WIRED}" -t "${duration}" -J
            traffic_run_bg --job "p2" --netns "${WLAN5G_NS:-ns-wlan5g}" --out "${w5g_out}" \
                iperf3 -c "${WAN_SERVER_IP:-10.10.0.1}" -p "${SIM_PORT_WIFI1}" -t "${duration}" -J
            traffic_run_bg --job "p3" --netns "${WLAN6G_NS:-ns-wlan6g}" --out "${w6g_out}" \
                iperf3 -c "${WAN_SERVER_IP:-10.10.0.1}" -p "${SIM_PORT_WIFI2}" -t "${duration}" -J

            traffic_wait_all "p1" "p2" "p3"
            sleep 0.2

            local a_val
            a_val="$("${tools_dir}/metric_parser.py" sum-mbps "${w2g_out}" "${w5g_out}" "${w6g_out}")"
            a_trials+=("${a_val}")
            log_info "  [Trial ${i}] Wireless-only (A): ${a_val} Mbps"

            # 2. Measure Wired-only speed (B): PC
            local pc_out="${SCENARIO_TMP_DIR}/iperf_pc_${i}.json"
            log_cmd "ip netns exec ${PC_NS:-ns-pc} iperf3 -c ${WAN_SERVER_IP:-10.10.0.1} -p ${SIM_PORT_WIRED} -t ${duration} -J > ${pc_out}"
            ip netns exec "${PC_NS:-ns-pc}" iperf3 -c "${WAN_SERVER_IP:-10.10.0.1}" -p "${SIM_PORT_WIRED}" -t "${duration}" -J > "${pc_out}" 2>&1 || true
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

            traffic_run_bg --job "sp0" --netns "${PC_NS:-ns-pc}" --out "${sim_pc_out}" \
                iperf3 -c "${WAN_SERVER_IP:-10.10.0.1}" -p "${SIM_PORT_WIRED}" -t "${duration}" -J
            traffic_run_bg --job "sp1" --netns "${WLAN2G_NS:-ns-wlan2g}" --out "${sim_w2g_out}" \
                iperf3 -c "${WAN_SERVER_IP:-10.10.0.1}" -p "${SIM_PORT_WIFI1}" -t "${duration}" -J
            traffic_run_bg --job "sp2" --netns "${WLAN5G_NS:-ns-wlan5g}" --out "${sim_w5g_out}" \
                iperf3 -c "${WAN_SERVER_IP:-10.10.0.1}" -p "${SIM_PORT_WIFI2}" -t "${duration}" -J
            traffic_run_bg --job "sp3" --netns "${WLAN6G_NS:-ns-wlan6g}" --out "${sim_w6g_out}" \
                iperf3 -c "${WAN_SERVER_IP:-10.10.0.1}" -p "${SIM_PORT_WIFI3}" -t "${duration}" -J

            traffic_wait_all "sp0" "sp1" "sp2" "sp3"
            sleep 0.2

            local c_wired c_wifi c_val
            c_wired="$("${tools_dir}/metric_parser.py" sum-mbps "${sim_pc_out}")"
            c_wifi="$("${tools_dir}/metric_parser.py" sum-mbps "${sim_w2g_out}" "${sim_w5g_out}" "${sim_w6g_out}")"
            c_val="$("${tools_dir}/metric_parser.py" sum-mbps "${sim_pc_out}" "${sim_w2g_out}" "${sim_w5g_out}" "${sim_w6g_out}")"
            c_trials+=("${c_val}")
            c_wired_trials+=("${c_wired}")
            c_wifi_trials+=("${c_wifi}")
            log_info "  [Trial ${i}] Simultaneous (C): ${c_val} Mbps (Wired: ${c_wired} Mbps, Wi-Fi: ${c_wifi} Mbps)"
        fi
    done

    _sim_stop_servers
    _sim_cleanup_wifi_route

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
        "--mode" "${eff_mode}"
        "--tolerance" "${THROUGHPUT_DROP_TOLERANCE_PCT:-${SIM_DEFAULT_TOLERANCE}}"
        "--output" "${sim_json}"
        "--trials-c-wired" "${c_wired_str}"
        "--trials-c-wifi" "${c_wifi_str}"
    )

    log_cmd "${eval_cmd[*]}"
    "${eval_cmd[@]}" || true
}
