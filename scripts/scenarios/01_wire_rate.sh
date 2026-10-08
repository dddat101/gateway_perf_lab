#!/usr/bin/env bash
# ==============================================================================
# SCENARIO MODULE: WIRE-RATE FORWARDING
# [TC-WR-01] 1024B Bidirectional Unicast Wire-Rate (950 Mbps)
# [TC-WR-02] 1024B Multicast IPTV Forwarding (80 Mbps)
# Refactored with Defensive Bash Programming Patterns
# ==============================================================================

# Canonical constants
readonly WR_DEFAULT_DURATION=10
readonly WR_DEFAULT_BITRATE="950M"
readonly WR_DEFAULT_OMIT=2
readonly WR_DEFAULT_SOCK_BUF="4M"
readonly WR_DEFAULT_FWD_PORT=5002
readonly WR_DEFAULT_REV_PORT=5012
readonly WR_DEFAULT_MCAST_PORT=5003
readonly WR_DEFAULT_MCAST_GROUP="239.255.0.1"
readonly WR_DEFAULT_MCAST_RATE="80.0"
readonly WR_DEFAULT_MCAST_PACKETS=2000

usage_block_wr01() {
    cat <<'EOF'
+------------------------------------------------------------------+
| [TC-WR-01] 1024B BIDIRECTIONAL UNICAST WIRE-RATE                 |
+------------------------------------------------------------------+
  Scenario Aliases : unicast, tc_wr_01
  Objective        : Bidirectional wire-rate forwarding between WAN & LAN
  Traffic Profile  : 1024-byte UDP (L4 payload: 982B) @ 950 Mbps wire-rate
  Pass Criteria    : 0% frame loss across both directions (Zero Packet Loss)

  Supported Options:
    --bitrate, -b <rate>     Target bitrate (default: 950M, e.g. 950M, 475M)
    --duration, -d <sec>     Test stream duration in seconds (default: 10)
    --omit, -O <sec>         Warm-up omit seconds for flow learning (default: 2)
    --unicast-mode, -U <m>   Execution mode: 'sequential' (default) or 'concurrent'
    --remote, -R             Execute LAN client on Remote PC (Dual-PC Gigabit topology, e.g. via eno1)
    --remote-dev <dev>       LAN interface on Remote PC (default: eno1)
    --debug, -v              Show exact commands executed at each step
    --snaplen, -s <bytes>    Packet capture snaplen in bytes (default: 96)
    --no-capture, -C         Disable packet capture during test
    --collect-artifacts, -A  Package run deliverables into artifacts/
    --log, -l [file]         Mirror console output to a log file
    --dry-run, -n            Preview parameters without sending traffic

  Examples:
    sudo ./scripts/scenario.sh unicast
    sudo ./scripts/scenario.sh -R unicast
    sudo ./scripts/scenario.sh --remote --remote-dev eno1 unicast
    sudo ./scripts/scenario.sh -b 475M unicast
    sudo ./scripts/scenario.sh -b 950M -d 10 -O 2 unicast
    sudo ./scripts/scenario.sh -C -d 10 unicast
    sudo ./scripts/scenario.sh -U concurrent -d 15 unicast

EOF
}

usage_block_wr02() {
    cat <<'EOF'
+------------------------------------------------------------------+
| [TC-WR-02] 1024B MULTICAST 80 MBPS FORWARDING                    |
+------------------------------------------------------------------+
  Scenario Aliases : multicast, tc_wr_02
  Objective        : Validate IPTV Multicast forwarding (WAN -> STB LAN)
  Multicast Group  : 239.255.0.1:5003 @ 80 Mbps, 1024B UDP frames
  Pass Criteria    : 0% multicast frame loss forwarded across DUT bridge

  Supported Options:
    --debug, -v              Show exact commands executed at each step
    --snaplen, -s <bytes>    Packet capture snaplen in bytes (default: 96)
    --no-capture, -C         Disable packet capture during test
    --collect-artifacts, -A  Package run deliverables into artifacts/
    --log, -l [file]         Mirror console output to a log file
    --dry-run, -n            Preview parameters without sending traffic

  Examples:
    sudo ./scripts/scenario.sh multicast
    sudo ./scripts/scenario.sh -s 96 -A tc_wr_02
    sudo ./scripts/scenario.sh -C multicast

EOF
}

# ------------------------------------------------------------------------------
# Modular Helper: Terminate PIDs safely with escalation (TERM -> KILL)
# ------------------------------------------------------------------------------
_wr_terminate_pids() {
    local -a pids=("$@")
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
# Sub-phase 1A: Bidirectional 1024-byte Unicast (TC-WR-01)
# ------------------------------------------------------------------------------
run_subphase_unicast() {
    log_step "[TC-WR-01] Bidirectional Unicast 1024B Wire-Rate Forwarding"
    local tools_dir="${LAB_DIR}/tools"
    local uni_json="${LOG_DIR}/unicast_result.json"

    # Validate parameters defensively
    local duration="${CUSTOM_DURATION:-${WR_DEFAULT_DURATION}}"
    if [[ ! "${duration}" =~ ^[0-9]+$ || "${duration}" -le 0 ]]; then
        log_warn "Invalid duration '${duration}'. Defaulting to ${WR_DEFAULT_DURATION}s."
        duration="${WR_DEFAULT_DURATION}"
    fi

    local unicast_rate="${CUSTOM_UNICAST_RATE:-${UNICAST_TARGET_RATE:-${WR_DEFAULT_BITRATE}}}"
    local unicast_mode="${CUSTOM_UNICAST_MODE:-${UNICAST_MODE:-sequential}}"
    local omit_sec="${CUSTOM_UNICAST_OMIT:-${UNICAST_OMIT_SEC:-${WR_DEFAULT_OMIT}}}"
    if [[ ! "${omit_sec}" =~ ^[0-9]+$ || "${omit_sec}" -lt 0 ]]; then
        omit_sec="${WR_DEFAULT_OMIT}"
    fi

    local sock_buf="${UNICAST_SOCKET_BUFFER:-${WR_DEFAULT_SOCK_BUF}}"
    local fwd_port="${UNICAST_FORWARD_PORT:-${WR_DEFAULT_FWD_PORT}}"
    local rev_port="${UNICAST_REVERSE_PORT:-${WR_DEFAULT_REV_PORT}}"

    # Compute expected packet rate dynamically based on target rate and 1024B frame size
    local rate_clean="${unicast_rate%[Bb/s]*}"
    local rate_num="${rate_clean%[MmKkGg]*}"
    local rate_unit="${rate_clean: -1}"
    local rate_bps=0
    case "${rate_unit^^}" in
        G) rate_bps=$(( rate_num * 1000000000 )) ;;
        M) rate_bps=$(( rate_num * 1000000 )) ;;
        K) rate_bps=$(( rate_num * 1000 )) ;;
        *) rate_bps=$(( rate_num )) ;;
    esac
    local pps=$(( rate_bps / (1024 * 8) ))
    local pps_k=$(( (pps + 500) / 1000 ))
    local pps_str="~${pps_k}k PPS"

    local is_remote=0
    if [[ "${CUSTOM_CLIENT_MODE:-}" == "remote" || "${CUSTOM_WIFI_MODE:-}" =~ remote.* || "${REMOTE_UNICAST:-0}" == "1" ]]; then
        is_remote=1
    fi

    local remote_script="${SCRIPT_DIR}/remote_client.sh"
    local rem_dev="${CUSTOM_REMOTE_DEV:-${REMOTE_LAN_IF:-${REMOTE_CLIENT_LAN_IF:-eno1}}}"
    local rem_host="${REMOTE_CLIENT_HOST:-}"

    if (( DRY_RUN == 1 )); then
        if (( is_remote == 1 )); then
            log_info "[DRY-RUN] Would test 1024B bidirectional unicast (${unicast_mode}) at ${unicast_rate} (${pps_str}, -w ${sock_buf}, ${duration}s, omit ${omit_sec}s) between Local PC (WAN) and Remote PC [${rem_host}:${rem_dev}]"
        else
            log_info "[DRY-RUN] Would test 1024B bidirectional unicast (${unicast_mode}) at ${unicast_rate} (${pps_str}, -w ${sock_buf}, ${duration}s, omit ${omit_sec}s) between ns-wan and ns-pc"
        fi
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

    # Optimize kernel socket buffer thresholds to prevent host-side queue drops
    log_cmd "sysctl -w net.core.rmem_max=67108864"
    sysctl -w net.core.rmem_max=67108864 >/dev/null 2>&1 || true
    log_cmd "sysctl -w net.core.wmem_max=67108864"
    sysctl -w net.core.wmem_max=67108864 >/dev/null 2>&1 || true

    if [[ "${engine}" == "iperf3" ]]; then
        log_info "Using high-performance C-based engine: iperf3 UDP (-l 982, -w ${sock_buf}, ${unicast_rate}, ${pps_str})..."
        local fwd_out="${SCENARIO_TMP_DIR}/iperf_uni_fwd.json"
        local rev_out="${SCENARIO_TMP_DIR}/iperf_uni_rev.json"

        if (( is_remote == 1 )); then
            if ! "${remote_script}" test >/dev/null 2>&1; then
                die "Remote client (${rem_host}) is unreachable. Check REMOTE_CLIENT_HOST and SSH keys in config.env"
            fi

            log_info "Dual-PC Wire-Rate Forwarding Topology Active:"
            log_info "  -> WAN Server (Upstream) : Local PC (${WAN_SERVER_IP:-10.10.0.1})"
            log_info "  -> LAN Client (Receiver) : Remote PC [${rem_host}:${rem_dev}]"
            log_info "  -> Bitrate Target        : ${unicast_rate} (${pps_str})"
            log_info "  -> Execution Mode        : ${unicast_mode^^}"
        fi

        if (( is_remote == 1 && "${unicast_mode}" == "concurrent" )); then
            log_info "Executing CONCURRENT Full-Duplex Forward (port ${fwd_port}) + Reverse (port ${rev_port}) for ${duration}s (omit ${omit_sec}s warm-up) on Remote PC [${rem_dev}]..."
            log_cmd "ip netns exec ${WAN_NS:-ns-wan} pkill -TERM -x iperf3"
            ip netns exec "${WAN_NS:-ns-wan}" pkill -TERM -x iperf3 2>/dev/null || true
            log_cmd "ip netns exec ${WAN_NS:-ns-wan} iperf3 -s -p ${fwd_port} -D"
            ip netns exec "${WAN_NS:-ns-wan}" iperf3 -s -p "${fwd_port}" -D >/dev/null 2>&1
            log_cmd "ip netns exec ${WAN_NS:-ns-wan} iperf3 -s -p ${rev_port} -D"
            ip netns exec "${WAN_NS:-ns-wan}" iperf3 -s -p "${rev_port}" -D >/dev/null 2>&1
            sleep 0.4

            log_cmd "${remote_script} run-iperf -c ${WAN_SERVER_IP:-10.10.0.1} --bind-dev ${rem_dev} -u -p ${fwd_port} -b ${unicast_rate} -l 982 -w ${sock_buf} -t ${duration} -O ${omit_sec} -R -J > ${fwd_out} 2>&1 &"
            "${remote_script}" run-iperf -c "${WAN_SERVER_IP:-10.10.0.1}" --bind-dev "${rem_dev}" -u -p "${fwd_port}" -b "${unicast_rate}" -l 982 -w "${sock_buf}" -t "${duration}" -O "${omit_sec}" -R -J > "${fwd_out}" 2>&1 &
            local fwd_pid=$!
            ACTIVE_BG_PIDS+=("${fwd_pid}")

            log_cmd "${remote_script} run-iperf -c ${WAN_SERVER_IP:-10.10.0.1} --bind-dev ${rem_dev} -u -p ${rev_port} -b ${unicast_rate} -l 982 -w ${sock_buf} -t ${duration} -O ${omit_sec} -J > ${rev_out} 2>&1 &"
            "${remote_script}" run-iperf -c "${WAN_SERVER_IP:-10.10.0.1}" --bind-dev "${rem_dev}" -u -p "${rev_port}" -b "${unicast_rate}" -l 982 -w "${sock_buf}" -t "${duration}" -O "${omit_sec}" -J > "${rev_out}" 2>&1 &
            local rev_pid=$!
            ACTIVE_BG_PIDS+=("${rev_pid}")

            wait "${fwd_pid}" "${rev_pid}" 2>/dev/null || true
            ip netns exec "${WAN_NS:-ns-wan}" pkill -TERM -x iperf3 2>/dev/null || true

        elif [[ "${unicast_mode}" == "concurrent" ]]; then
            log_info "Executing CONCURRENT Full-Duplex Forward (port ${fwd_port}) + Reverse (port ${rev_port}) for ${duration}s (omit ${omit_sec}s warm-up)..."
            log_cmd "ip netns exec ${WAN_NS:-ns-wan} pkill -TERM -x iperf3"
            ip netns exec "${WAN_NS:-ns-wan}" pkill -TERM -x iperf3 2>/dev/null || true
            log_cmd "ip netns exec ${WAN_NS:-ns-wan} iperf3 -s -p ${fwd_port} -D"
            ip netns exec "${WAN_NS:-ns-wan}" iperf3 -s -p "${fwd_port}" -D >/dev/null 2>&1
            log_cmd "ip netns exec ${WAN_NS:-ns-wan} iperf3 -s -p ${rev_port} -D"
            ip netns exec "${WAN_NS:-ns-wan}" iperf3 -s -p "${rev_port}" -D >/dev/null 2>&1
            sleep 0.4

            log_cmd "ip netns exec ${PC_NS:-ns-pc} iperf3 -c ${WAN_SERVER_IP:-10.10.0.1} -u -p ${fwd_port} -b ${unicast_rate} -l 982 -w ${sock_buf} -t ${duration} -O ${omit_sec} -R -J > ${fwd_out} 2>&1 &"
            ip netns exec "${PC_NS:-ns-pc}" iperf3 -c "${WAN_SERVER_IP:-10.10.0.1}" -u -p "${fwd_port}" -b "${unicast_rate}" -l 982 -w "${sock_buf}" -t "${duration}" -O "${omit_sec}" -R -J > "${fwd_out}" 2>&1 &
            local fwd_pid=$!
            ACTIVE_BG_PIDS+=("${fwd_pid}")

            log_cmd "ip netns exec ${PC_NS:-ns-pc} iperf3 -c ${WAN_SERVER_IP:-10.10.0.1} -u -p ${rev_port} -b ${unicast_rate} -l 982 -w ${sock_buf} -t ${duration} -O ${omit_sec} -J > ${rev_out} 2>&1 &"
            ip netns exec "${PC_NS:-ns-pc}" iperf3 -c "${WAN_SERVER_IP:-10.10.0.1}" -u -p "${rev_port}" -b "${unicast_rate}" -l 982 -w "${sock_buf}" -t "${duration}" -O "${omit_sec}" -J > "${rev_out}" 2>&1 &
            local rev_pid=$!
            ACTIVE_BG_PIDS+=("${rev_pid}")

            wait "${fwd_pid}" "${rev_pid}" 2>/dev/null || true
            ip netns exec "${WAN_NS:-ns-wan}" pkill -TERM -x iperf3 2>/dev/null || true

        elif (( is_remote == 1 )); then
            log_info "Executing SEQUENTIAL Bidirectional Wire-rate (Forward then Reverse) for ${duration}s each on Remote PC [${rem_dev}]..."
            # 1. Forward Path (WAN -> Remote LAN PC via Reverse -R)
            ip netns exec "${WAN_NS:-ns-wan}" pkill -TERM -x iperf3 2>/dev/null || true
            log_cmd "ip netns exec ${WAN_NS:-ns-wan} iperf3 -s -p ${fwd_port} -D"
            ip netns exec "${WAN_NS:-ns-wan}" iperf3 -s -p "${fwd_port}" -D >/dev/null 2>&1
            sleep 0.4
            log_step "Step 1/2: Forward Path (WAN -> Remote LAN PC [${rem_dev}]) at ${unicast_rate} (${pps_str})..."
            "${remote_script}" run-iperf -c "${WAN_SERVER_IP:-10.10.0.1}" --bind-dev "${rem_dev}" -u -p "${fwd_port}" -b "${unicast_rate}" -l 982 -w "${sock_buf}" -t "${duration}" -O "${omit_sec}" -R -J > "${fwd_out}" 2>&1 || true
            ip netns exec "${WAN_NS:-ns-wan}" pkill -TERM -x iperf3 2>/dev/null || true
            sleep 0.4

            # 2. Reverse Path (Remote LAN PC [${rem_dev}] -> WAN)
            log_cmd "ip netns exec ${WAN_NS:-ns-wan} iperf3 -s -p ${fwd_port} -D"
            ip netns exec "${WAN_NS:-ns-wan}" iperf3 -s -p "${fwd_port}" -D >/dev/null 2>&1
            sleep 0.4
            log_step "Step 2/2: Reverse Path (Remote LAN PC [${rem_dev}] -> WAN) at ${unicast_rate} (${pps_str})..."
            "${remote_script}" run-iperf -c "${WAN_SERVER_IP:-10.10.0.1}" --bind-dev "${rem_dev}" -u -p "${fwd_port}" -b "${unicast_rate}" -l 982 -w "${sock_buf}" -t "${duration}" -O "${omit_sec}" -J > "${rev_out}" 2>&1 || true
            ip netns exec "${WAN_NS:-ns-wan}" pkill -TERM -x iperf3 2>/dev/null || true

        else
            log_info "Executing SEQUENTIAL Bidirectional Wire-rate (Forward then Reverse) for ${duration}s each (omit ${omit_sec}s warm-up)..."
            # 1. Forward Path (WAN -> LAN PC via Reverse -R)
            ip netns exec "${WAN_NS:-ns-wan}" pkill -TERM -x iperf3 2>/dev/null || true
            log_cmd "ip netns exec ${WAN_NS:-ns-wan} iperf3 -s -p ${fwd_port} -D"
            ip netns exec "${WAN_NS:-ns-wan}" iperf3 -s -p "${fwd_port}" -D >/dev/null 2>&1
            sleep 0.4
            log_step "Step 1/2: Forward Path (WAN -> LAN PC) at ${unicast_rate} (${pps_str})..."
            ip netns exec "${PC_NS:-ns-pc}" iperf3 -c "${WAN_SERVER_IP:-10.10.0.1}" -u -p "${fwd_port}" -b "${unicast_rate}" -l 982 -w "${sock_buf}" -t "${duration}" -O "${omit_sec}" -R -J > "${fwd_out}" 2>&1 || true
            ip netns exec "${WAN_NS:-ns-wan}" pkill -TERM -x iperf3 2>/dev/null || true
            sleep 0.4

            # 2. Reverse Path (LAN PC -> WAN)
            log_cmd "ip netns exec ${WAN_NS:-ns-wan} iperf3 -s -p ${fwd_port} -D"
            ip netns exec "${WAN_NS:-ns-wan}" iperf3 -s -p "${fwd_port}" -D >/dev/null 2>&1
            sleep 0.4
            log_step "Step 2/2: Reverse Path (LAN PC -> WAN) at ${unicast_rate} (${pps_str})..."
            ip netns exec "${PC_NS:-ns-pc}" iperf3 -c "${WAN_SERVER_IP:-10.10.0.1}" -u -p "${fwd_port}" -b "${unicast_rate}" -l 982 -w "${sock_buf}" -t "${duration}" -O "${omit_sec}" -J > "${rev_out}" 2>&1 || true
            ip netns exec "${WAN_NS:-ns-wan}" pkill -TERM -x iperf3 2>/dev/null || true
        fi

        # Preserve raw iperf3 trial outputs for audit & compliance
        mkdir -p "${LOG_DIR}/raw_iperf" 2>/dev/null || true
        cp -f "${fwd_out}" "${LOG_DIR}/raw_iperf/iperf_uni_fwd.json" 2>/dev/null || true
        cp -f "${rev_out}" "${LOG_DIR}/raw_iperf/iperf_uni_rev.json" 2>/dev/null || true
        chmod 0666 "${LOG_DIR}/raw_iperf"/iperf_uni_*.json 2>/dev/null || true

        # Consolidate bidirectional results into standard schema
        log_cmd "${tools_dir}/metric_parser.py consolidate-iperf-bidi --forward ${fwd_out} --reverse ${rev_out} --mode ${unicast_mode} --output ${uni_json}"
        "${tools_dir}/metric_parser.py" consolidate-iperf-bidi \
            --forward "${fwd_out}" \
            --reverse "${rev_out}" \
            --mode "${unicast_mode}" \
            --output "${uni_json}"
    else
        log_info "Using native zero-allocation Python engine: traffic_generator.py..."
        local py_dur=$(( duration > 4 ? duration : 4 ))
        log_cmd "ip netns exec ${PC_NS:-ns-pc} ${tools_dir}/traffic_generator.py unicast-recv --bind-ip ${PC_IP:-192.168.1.10} --bind-port 5002 --server-ip ${WAN_SERVER_IP:-10.10.0.1} --server-port 5002 --duration $(( py_dur + 2 )) --output-json ${uni_json} &"
        ip netns exec "${PC_NS:-ns-pc}" "${tools_dir}/traffic_generator.py" unicast-recv \
            --bind-ip "${PC_IP:-192.168.1.10}" --bind-port 5002 \
            --server-ip "${WAN_SERVER_IP:-10.10.0.1}" --server-port 5002 \
            --duration $(( py_dur + 2 )) \
            --output-json "${uni_json}" >/dev/null 2>&1 &
        local rx_pid=$!
        ACTIVE_BG_PIDS+=("${rx_pid}")
        sleep 0.2

        log_cmd "ip netns exec ${WAN_NS:-ns-wan} ${tools_dir}/traffic_generator.py unicast-send --dest-ip ${PC_IP:-192.168.1.10} --dest-port 5002 --wait-handshake --packet-size ${UNICAST_PACKET_SIZE:-1024} --duration ${py_dur} --rate-mbps 950.0"
        ip netns exec "${WAN_NS:-ns-wan}" "${tools_dir}/traffic_generator.py" unicast-send \
            --dest-ip "${PC_IP:-192.168.1.10}" --dest-port 5002 \
            --wait-handshake \
            --packet-size "${UNICAST_PACKET_SIZE:-1024}" --duration "${py_dur}" --rate-mbps 950.0

        wait "${rx_pid}" 2>/dev/null || true
        if [[ -f "${uni_json}" ]]; then
            log_cmd "${tools_dir}/metric_parser.py format-card ${uni_json}"
            "${tools_dir}/metric_parser.py" format-card "${uni_json}"
        fi
    fi
}

# ------------------------------------------------------------------------------
# Sub-phase 1B: Multicast Forwarding 1024B (TC-WR-02)
# ------------------------------------------------------------------------------
run_subphase_multicast() {
    local mcast_group="${MULTICAST_GROUP:-${WR_DEFAULT_MCAST_GROUP}}"
    log_step "[TC-WR-02] Multicast Forwarding 1024B (Group: ${mcast_group})"
    local tools_dir="${LAB_DIR}/tools"
    local mcast_json="${LOG_DIR}/multicast_result.json"

    if (( DRY_RUN == 1 )); then
        log_info "[DRY-RUN] Would test 1024B multicast forwarding (${WR_DEFAULT_MCAST_PACKETS} packets) to group ${mcast_group}"
        return 0
    fi

    # Start IGMP proxy forwarder in DUT namespace if simulated
    local mcast_fwd_pid=""
    if ns_exists "${DUT_NS:-ns-dut}"; then
        log_cmd "ip netns exec ${DUT_NS:-ns-dut} ${tools_dir}/mcast_forwarder.py --group-ip ${mcast_group} --port ${WR_DEFAULT_MCAST_PORT} --wan-if-ip ${DUT_WAN_IP:-10.10.0.100} --lan-if-ip ${DUT_LAN_IP:-192.168.1.1} --duration 12.0 >/dev/null 2>&1 &"
        ip netns exec "${DUT_NS:-ns-dut}" "${tools_dir}/mcast_forwarder.py" \
            --group-ip "${mcast_group}" --port "${WR_DEFAULT_MCAST_PORT}" \
            --wan-if-ip "${DUT_WAN_IP:-10.10.0.100}" --lan-if-ip "${DUT_LAN_IP:-192.168.1.1}" \
            --duration 12.0 >/dev/null 2>&1 &
        mcast_fwd_pid=$!
        ACTIVE_BG_PIDS+=("${mcast_fwd_pid}")
        sleep 0.2
    fi

    # Start multicast receiver in STB namespace
    log_cmd "ip netns exec ${STB_NS:-ns-stb} ${tools_dir}/traffic_generator.py mcast-recv --group-ip ${mcast_group} --port ${WR_DEFAULT_MCAST_PORT} --expected-packets ${WR_DEFAULT_MCAST_PACKETS} --timeout 5.0 --output-json ${mcast_json} >/dev/null 2>&1 &"
    ip netns exec "${STB_NS:-ns-stb}" "${tools_dir}/traffic_generator.py" mcast-recv \
        --group-ip "${mcast_group}" --port "${WR_DEFAULT_MCAST_PORT}" \
        --expected-packets "${WR_DEFAULT_MCAST_PACKETS}" --timeout 5.0 --output-json "${mcast_json}" >/dev/null 2>&1 &
    local mcast_rx_pid=$!
    ACTIVE_BG_PIDS+=("${mcast_rx_pid}")
    sleep 1.0

    # Start multicast sender in WAN namespace with warmup burst to trigger HW flow cache
    log_cmd "ip netns exec ${WAN_NS:-ns-wan} ${tools_dir}/traffic_generator.py mcast-send --group-ip ${mcast_group} --port ${WR_DEFAULT_MCAST_PORT} --packet-size ${MULTICAST_PACKET_SIZE:-1024} --packets ${WR_DEFAULT_MCAST_PACKETS} --rate-mbps ${WR_DEFAULT_MCAST_RATE} --warmup-packets 30"
    ip netns exec "${WAN_NS:-ns-wan}" "${tools_dir}/traffic_generator.py" mcast-send \
        --group-ip "${mcast_group}" --port "${WR_DEFAULT_MCAST_PORT}" \
        --packet-size "${MULTICAST_PACKET_SIZE:-1024}" --packets "${WR_DEFAULT_MCAST_PACKETS}" \
        --rate-mbps "${WR_DEFAULT_MCAST_RATE}" \
        --warmup-packets 30

    wait "${mcast_rx_pid}" 2>/dev/null || true

    if [[ -n "${mcast_fwd_pid}" ]]; then
        _wr_terminate_pids "${mcast_fwd_pid}"
    fi

    if [[ -f "${mcast_json}" ]]; then
        log_cmd "${tools_dir}/metric_parser.py format-card ${mcast_json}"
        "${tools_dir}/metric_parser.py" format-card "${mcast_json}"
    fi
}
