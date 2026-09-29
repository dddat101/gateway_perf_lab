#!/usr/bin/env bash
# ==============================================================================
# SCENARIO MODULE: VOICE QOS & WIRED PC ISOLATION
# [TC-QOS-01] Wired PC Throughput with 2 Active Wi-Fi Phone Calls
# Supports: PJSUA, SIPp, and Python VoIP Engines with DSCP 46 EF
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
readonly VOIP_DEFAULT_CONCURRENT_DURATION=4
readonly VOIP_DEFAULT_BASELINE_DURATION=4
readonly VOIP_DEFAULT_BASELINE_EXTENDED=5
readonly VOIP_DEFAULT_TOLERANCE="1.0"
readonly VOIP_DSCP_MARK=46
readonly VOIP_PORTS_LIST="5060,5062,5064,10000,10002,10004"

readonly VOIP_PORT_SIP_SERVER=5060
readonly VOIP_PORT_SIP_PHONE1=5062
readonly VOIP_PORT_SIP_PHONE2=5064
readonly VOIP_PORT_RTP_PHONE1=10000
readonly VOIP_PORT_RTP_PHONE2=10002
readonly VOIP_PORT_IPERF=5201

usage_block_qos01() {
    cat <<'EOF'
+------------------------------------------------------------------+
| [TC-QOS-01] WI-FI PHONE VOIP QOS & WIRED PC ISOLATION            |
+------------------------------------------------------------------+
  Scenario Aliases : voice_qos, tc_qos_01
  Objective        : Validate 2 Wi-Fi phone calls quality (SIP/RTP, DSCP EF)
                     during concurrent saturated Wired PC throughput
  Traffic Profile  : 2 VoIP calls (G.711, 64 kbps, DSCP 46) + Wired PC TCP load
  Pass Criteria    : VoIP packet loss < 1%, jitter < 20ms, no call drops
                     Wired PC throughput maintains fair baseline isolation

  Supported Options:
    --voip-engine, -E <eng>  Select VoIP test generator engine:
                             - auto   : Auto-select best engine available (default)
                             - pjsua  : Production PJSUA SIP user agent
                             - sipp   : SIPp protocol traffic generator
                             - python : Embedded pure-Python RTP/SIP generator
    --wifi-mode, -W <mode>   Wi-Fi mode (auto, real_single, remote, remote_only, etc.)
    --remote-only, -R        Run VoIP calls exclusively on Remote Client PC
    --duration, -d <sec>     VoIP test duration in seconds (default: 30)
    --debug, -v              Show exact commands executed at each step
    --snaplen, -s <bytes>    Packet capture snaplen in bytes (default: 96)
    --no-capture, -C         Disable packet capture during test
    --collect-artifacts, -A  Package run deliverables into artifacts/
    --log, -l [file]         Mirror console output to a log file
    --dry-run, -n            Preview parameters without sending traffic

  Examples:
    sudo ./scripts/scenario.sh voice_qos
    sudo ./scripts/scenario.sh -E pjsua voice_qos
    sudo ./scripts/scenario.sh -W remote -E python tc_qos_01
    sudo ./scripts/scenario.sh -d 45 -C -A voice_qos
    sudo ./scripts/scenario.sh -R -E auto voice_qos

EOF
}

# ------------------------------------------------------------------------------
# Process Supervision & Network Helpers (Traffic Orchestrator Adapters)
# ------------------------------------------------------------------------------
_voip_terminate_pids() {
    traffic_stop_group "$@"
}

_voip_cleanup_network() {
    station_adapter_release

    if [[ -n "${CLEANUP_WAN_MANGLE:-}" ]]; then
        eval "${CLEANUP_WAN_MANGLE}" 2>/dev/null || true
        CLEANUP_WAN_MANGLE=""
    fi
}

run_phase_voice_qos() {
    log_step "[TC-QOS-01] Wired PC Throughput with 2 Active Wi-Fi Phone Calls"
    local tools_dir="${LAB_DIR}/tools"
    local voice_json="${LOG_DIR}/voice_pc_qos.json"
    rm -f "${voice_json}" "${LOG_DIR}/voice_qos_audit.json" 2>/dev/null || true

    local pc_concurrent_dur="${CUSTOM_DURATION:-${VOIP_DEFAULT_CONCURRENT_DURATION}}"
    if [[ ! "${pc_concurrent_dur}" =~ ^[0-9]+$ || "${pc_concurrent_dur}" -le 0 ]]; then
        pc_concurrent_dur="${VOIP_DEFAULT_CONCURRENT_DURATION}"
    fi

    local pc_baseline_dur="${VOIP_DEFAULT_BASELINE_DURATION}"
    if (( pc_concurrent_dur > 10 )); then
        pc_baseline_dur="${VOIP_DEFAULT_BASELINE_EXTENDED}"
    fi
    local call_duration=$(( pc_concurrent_dur + 8 ))

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

    # 2. Topology Mode Detection via Running Context Resolver
    orchestrator_resolve_context
    local eff_mode="${PLAN_VOIP_MODE:-virtual}"
    orchestrator_show_plan "TC-QOS-01 VoIP QoS Isolation"

    local wifi_ip="${DETECTED_WIFI_IP:-}"
    if [[ -z "${wifi_ip}" && ( "${eff_mode}" == "physical_single" || "${eff_mode}" == "distributed" ) ]]; then
        wifi_ip="$(ip -4 -o addr show dev "${DETECTED_WIFI_IF:-wlp3s0}" 2>/dev/null | awk '{print $4}' | cut -d/ -f1 || true)"
    fi

    # In remote_only or distributed mode, query remote client Wi-Fi connection state
    if [[ "${eff_mode}" == "remote_only" || "${eff_mode}" == "distributed" ]]; then
        local remote_env_dump
        remote_env_dump="$("${SCRIPT_DIR}/remote_client.sh" wifi-env --check-ping "${DUT_LAN_IP:-192.168.1.1}" 2>/dev/null || true)"
        eval "${remote_env_dump}"
    fi

    log_info "VoIP QoS Test Mode : [${eff_mode^^}] | Engine: [${engine^^}]"
    if [[ "${eff_mode}" == "remote_only" ]]; then
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
        log_info "  -> Local Wi-Fi Adapter    : BYPASSED (Exclusively using Remote Wi-Fi Station)"
    elif [[ "${eff_mode}" == "physical_single" || "${eff_mode}" == "distributed" ]]; then
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
        log_info "[DRY-RUN] Acceptance: |A - B| / A <= ${VOIP_IMPACT_TOLERANCE_PCT:-${VOIP_DEFAULT_TOLERANCE}}%"
        return 0
    fi

    # 3. Ensure client endpoints and routes in virtual mode
    if [[ "${eff_mode}" == "virtual" ]]; then
        ensure_client_endpoint "${PC_NS:-ns-pc}" "${PC_IP:-192.168.1.10}"
        ensure_client_endpoint "${PHONE1_NS:-ns-phone1}" "${PHONE1_IP:-192.168.1.41}"
        ensure_client_endpoint "${PHONE2_NS:-ns-phone2}" "${PHONE2_IP:-192.168.1.42}"
    fi

    # Network routing & DSCP preparation for physical Wi-Fi
    if [[ "${eff_mode}" == "physical_single" || "${eff_mode}" == "distributed" ]]; then
        if [[ -n "${DETECTED_WIFI_IF:-}" && -n "${wifi_ip:-}" ]]; then
            # Ensure host route for WAN_SERVER_IP points via DUT gateway over physical Wi-Fi
            station_adapter_bind_route "${DETECTED_WIFI_IF}" "${WAN_SERVER_IP:-10.10.0.1}" "${DUT_LAN_IP:-192.168.1.1}"
            station_adapter_apply_mangle "${DETECTED_WIFI_IF}" "${VOIP_PORTS_LIST}" "${VOIP_DSCP_MARK}"
        fi

        if [[ ( "${eff_mode}" == "remote_only" || "${eff_mode}" == "distributed" ) && -n "${REMOTE_WIFI_IF:-}" ]]; then
            local remote_gw="${REMOTE_WIFI_GATEWAY:-${DUT_LAN_IP:-192.168.1.1}}"
            "${SCRIPT_DIR}/remote_client.sh" exec "sudo -n ip route replace '${WAN_SERVER_IP:-10.10.0.1}' via '${remote_gw}' dev '${REMOTE_WIFI_IF}' 2>/dev/null || true; sudo -n iptables -t mangle -C POSTROUTING -o '${REMOTE_WIFI_IF}' -p udp -m multiport --dports ${VOIP_PORTS_LIST} -j DSCP --set-dscp ${VOIP_DSCP_MARK} 2>/dev/null || sudo -n iptables -t mangle -A POSTROUTING -o '${REMOTE_WIFI_IF}' -p udp -m multiport --dports ${VOIP_PORTS_LIST} -j DSCP --set-dscp ${VOIP_DSCP_MARK} 2>/dev/null || true; sudo -n iptables -t mangle -C POSTROUTING -o '${REMOTE_WIFI_IF}' -p udp -m multiport --sports ${VOIP_PORTS_LIST} -j DSCP --set-dscp ${VOIP_DSCP_MARK} 2>/dev/null || sudo -n iptables -t mangle -A POSTROUTING -o '${REMOTE_WIFI_IF}' -p udp -m multiport --sports ${VOIP_PORTS_LIST} -j DSCP --set-dscp ${VOIP_DSCP_MARK} 2>/dev/null || true" >/dev/null 2>&1 || true
        fi
    elif [[ "${eff_mode}" == "remote_only" && -n "${REMOTE_WIFI_IF:-}" ]]; then
        local remote_gw="${REMOTE_WIFI_GATEWAY:-${DUT_LAN_IP:-192.168.1.1}}"
        "${SCRIPT_DIR}/remote_client.sh" exec "sudo -n ip route replace '${WAN_SERVER_IP:-10.10.0.1}' via '${remote_gw}' dev '${REMOTE_WIFI_IF}' 2>/dev/null || true; sudo -n iptables -t mangle -C POSTROUTING -o '${REMOTE_WIFI_IF}' -p udp -m multiport --dports ${VOIP_PORTS_LIST} -j DSCP --set-dscp ${VOIP_DSCP_MARK} 2>/dev/null || sudo -n iptables -t mangle -A POSTROUTING -o '${REMOTE_WIFI_IF}' -p udp -m multiport --dports ${VOIP_PORTS_LIST} -j DSCP --set-dscp ${VOIP_DSCP_MARK} 2>/dev/null || true; sudo -n iptables -t mangle -C POSTROUTING -o '${REMOTE_WIFI_IF}' -p udp -m multiport --sports ${VOIP_PORTS_LIST} -j DSCP --set-dscp ${VOIP_DSCP_MARK} 2>/dev/null || sudo -n iptables -t mangle -A POSTROUTING -o '${REMOTE_WIFI_IF}' -p udp -m multiport --sports ${VOIP_PORTS_LIST} -j DSCP --set-dscp ${VOIP_DSCP_MARK} 2>/dev/null || true" >/dev/null 2>&1 || true
    fi

    # 4. Ensure Downlink VoIP packets leaving WAN server (ns-wan) are marked DSCP 46 (EF = 0xb8)
    log_cmd "ip netns exec ${WAN_NS:-ns-wan} iptables -t mangle -A POSTROUTING -p udp -m multiport --sports ${VOIP_PORTS_LIST} -j DSCP --set-dscp ${VOIP_DSCP_MARK}"
    ip netns exec "${WAN_NS:-ns-wan}" iptables -t mangle -A POSTROUTING -p udp -m multiport --sports "${VOIP_PORTS_LIST}" -j DSCP --set-dscp "${VOIP_DSCP_MARK}" 2>/dev/null || true
    log_cmd "ip netns exec ${WAN_NS:-ns-wan} iptables -t mangle -A POSTROUTING -p udp -m multiport --dports ${VOIP_PORTS_LIST} -j DSCP --set-dscp ${VOIP_DSCP_MARK}"
    ip netns exec "${WAN_NS:-ns-wan}" iptables -t mangle -A POSTROUTING -p udp -m multiport --dports "${VOIP_PORTS_LIST}" -j DSCP --set-dscp "${VOIP_DSCP_MARK}" 2>/dev/null || true
    CLEANUP_WAN_MANGLE="ip netns exec ${WAN_NS:-ns-wan} iptables -t mangle -D POSTROUTING -p udp -m multiport --sports ${VOIP_PORTS_LIST} -j DSCP --set-dscp ${VOIP_DSCP_MARK} 2>/dev/null || true; ip netns exec ${WAN_NS:-ns-wan} iptables -t mangle -D POSTROUTING -p udp -m multiport --dports ${VOIP_PORTS_LIST} -j DSCP --set-dscp ${VOIP_DSCP_MARK} 2>/dev/null || true"

    # 5. Start iperf3 server in ns-wan
    log_cmd "ip netns exec ${WAN_NS:-ns-wan} pkill -TERM -x iperf3"
    ip netns exec "${WAN_NS:-ns-wan}" pkill -TERM -x iperf3 2>/dev/null || true
    sleep 0.2
    log_cmd "ip netns exec ${WAN_NS:-ns-wan} iperf3 -s -p ${VOIP_PORT_IPERF} -D"
    ip netns exec "${WAN_NS:-ns-wan}" iperf3 -s -p "${VOIP_PORT_IPERF}" -D >/dev/null 2>&1
    sleep 0.3

    # Step 1: Baseline PC Throughput (A)
    log_info "Measuring baseline PC throughput without VoIP calls (A, duration: ${pc_baseline_dur}s)..."
    local pc_base_out="${SCENARIO_TMP_DIR}/iperf_pc_base.json"
    log_cmd "ip netns exec ${PC_NS:-ns-pc} iperf3 -c ${WAN_SERVER_IP:-10.10.0.1} -p ${VOIP_PORT_IPERF} -t ${pc_baseline_dur} -J > ${pc_base_out}"
    ip netns exec "${PC_NS:-ns-pc}" iperf3 -c "${WAN_SERVER_IP:-10.10.0.1}" -p "${VOIP_PORT_IPERF}" -t "${pc_baseline_dur}" -J > "${pc_base_out}" 2>&1 || true
    local a_mbps
    a_mbps="$("${tools_dir}/metric_parser.py" sum-mbps "${pc_base_out}")"
    log_info "  Baseline PC throughput (A): ${a_mbps} Mbps"

    # Step 2: Start VoIP server and 2 Wi-Fi phone calls
    log_info "Starting VoIP media server and 2 active Wi-Fi phone calls using [${engine^^}]..."
    log_info "  -> Media Server (UAS)  : ns-wan:5060 (Listening for incoming SIP/RTP media, Downlink QoS: DSCP 46)"
    if [[ "${eff_mode}" == "physical_single" ]]; then
        log_info "  -> Phone 1 (Physical)  : ${DETECTED_WIFI_IF} (${wifi_ip}:${VOIP_PORT_SIP_PHONE1} -> RTP ${VOIP_PORT_RTP_PHONE1} -> ${WAN_SERVER_IP:-10.10.0.1}:${VOIP_PORT_SIP_SERVER})"
        log_info "  -> Phone 2 (Physical)  : ${DETECTED_WIFI_IF} (${wifi_ip}:${VOIP_PORT_SIP_PHONE2} -> RTP ${VOIP_PORT_RTP_PHONE2} -> ${WAN_SERVER_IP:-10.10.0.1}:${VOIP_PORT_SIP_SERVER})"
    elif [[ "${eff_mode}" == "remote_only" ]]; then
        log_info "  -> Phone 1 (Remote Wi-Fi): ${REMOTE_CLIENT_HOST} (${REMOTE_WIFI_IF:-wlp3s0}:${REMOTE_WIFI_IP:-unknown}:${VOIP_PORT_SIP_PHONE1} -> RTP ${VOIP_PORT_RTP_PHONE1} -> ${WAN_SERVER_IP:-10.10.0.1}:${VOIP_PORT_SIP_SERVER})"
        log_info "  -> Phone 2 (Remote Wi-Fi): ${REMOTE_CLIENT_HOST} (${REMOTE_WIFI_IF:-wlp3s0}:${REMOTE_WIFI_IP:-unknown}:${VOIP_PORT_SIP_PHONE2} -> RTP ${VOIP_PORT_RTP_PHONE2} -> ${WAN_SERVER_IP:-10.10.0.1}:${VOIP_PORT_SIP_SERVER})"
    elif [[ "${eff_mode}" == "distributed" ]]; then
        log_info "  -> Phone 1 (Local Wi-Fi): ${DETECTED_WIFI_IF} (${wifi_ip}:${VOIP_PORT_SIP_PHONE1} -> RTP ${VOIP_PORT_RTP_PHONE1} -> ${WAN_SERVER_IP:-10.10.0.1}:${VOIP_PORT_SIP_SERVER})"
        log_info "  -> Phone 2 (Remote Wi-Fi): ${REMOTE_CLIENT_HOST} (${REMOTE_WIFI_IF:-wlan0}:${REMOTE_WIFI_IP:-unknown}:${VOIP_PORT_SIP_PHONE2} -> RTP ${VOIP_PORT_RTP_PHONE2} -> ${WAN_SERVER_IP:-10.10.0.1}:${VOIP_PORT_SIP_SERVER})"
    else
        log_info "  -> Phone 1 (Virtual)   : ns-phone1 (${VOIP_PORT_SIP_SERVER} -> RTP ${VOIP_PORT_RTP_PHONE1} -> ${WAN_SERVER_IP:-10.10.0.1}:${VOIP_PORT_SIP_SERVER})"
        log_info "  -> Phone 2 (Virtual)   : ns-phone2 (${VOIP_PORT_SIP_PHONE1} -> RTP ${VOIP_PORT_RTP_PHONE2} -> ${WAN_SERVER_IP:-10.10.0.1}:${VOIP_PORT_SIP_SERVER})"
    fi
    local voip_srv_pid=""
    local phone1_pid=""
    local phone2_pid=""

    local ts_voip
    ts_voip="$(date +%Y%m%d_%H%M%S)"
    local phone1_pcap="${CAPTURE_DIR}/tc_qos_01_voice_${ts_voip}_phone1_wifi.pcap"
    local phone2_pcap="${CAPTURE_DIR}/tc_qos_01_voice_${ts_voip}_phone2_wifi.pcap"
    if [[ "${eff_mode}" == "remote_only" ]]; then
        phone2_pcap="${CAPTURE_DIR}/tc_qos_01_voice_${ts_voip}_remote_wifi.pcap"
        phone1_pcap="${phone2_pcap}"
    elif [[ "${eff_mode}" == "physical_single" ]]; then
        phone2_pcap="${phone1_pcap}"
    fi
    local phone1_cap_pid=""
    local phone2_cap_pid=""
    local remote_cap_active=0

    rm -f "${STATE_DIR}/latest_phone1_pcap.txt" "${STATE_DIR}/latest_phone2_pcap.txt" "${STATE_DIR}/latest_voip_mode.txt" 2>/dev/null || true
    echo "${eff_mode}" > "${STATE_DIR}/latest_voip_mode.txt"

    # Start Targeted Station Packet Captures (LAN / Wi-Fi side)
    if (( NO_CAPTURE == 0 && DRY_RUN == 0 )); then
        local voice_bpf="udp port 5060 or udp port 5062 or udp port 5064 or udp portrange 10000-10004"
        if [[ "${eff_mode}" == "remote_only" ]]; then
            local rem_dir="${REMOTE_CLIENT_DIR:-/home/network/workspace/gwlab}"
            local rem_pcap="${rem_dir}/captures/tc_qos_01_phone2.pcap"
            log_info "  -> Remote Wi-Fi VoIP capture: [${REMOTE_CLIENT_HOST}:${REMOTE_WIFI_IF:-wlp3s0}] => ${rem_pcap}"
            "${SCRIPT_DIR}/remote_client.sh" start-capture "${REMOTE_WIFI_IF:-wlp3s0}" "${voice_bpf}" "${rem_pcap}" "${CAPTURE_SNAPLEN:-96}" >/dev/null 2>&1 || true
            remote_cap_active=1
        elif [[ "${eff_mode}" == "physical_single" || "${eff_mode}" == "distributed" ]]; then
            if [[ -n "${DETECTED_WIFI_IF:-}" ]]; then
                log_info "  -> Local Wi-Fi VoIP capture : [${DETECTED_WIFI_IF}] => ${phone1_pcap} (snaplen: ${CAPTURE_SNAPLEN:-96}B)"
                log_cmd "tcpdump -ni ${DETECTED_WIFI_IF} -s ${CAPTURE_SNAPLEN:-96} -U -w ${phone1_pcap} ${voice_bpf} &"
                tcpdump -ni "${DETECTED_WIFI_IF}" -s "${CAPTURE_SNAPLEN:-96}" -U -w "${phone1_pcap}" ${voice_bpf} >/dev/null 2>&1 &
                phone1_cap_pid=$!
                ACTIVE_BG_PIDS+=("${phone1_cap_pid}")
                echo "${phone1_pcap}" > "${STATE_DIR}/latest_phone1_pcap.txt"
                if [[ "${eff_mode}" == "physical_single" ]]; then
                    echo "${phone1_pcap}" > "${STATE_DIR}/latest_phone2_pcap.txt"
                fi
            fi
            if [[ "${eff_mode}" == "distributed" ]]; then
                local rem_dir="${REMOTE_CLIENT_DIR:-/home/network/workspace/gwlab}"
                local rem_pcap="${rem_dir}/captures/tc_qos_01_phone2.pcap"
                log_info "  -> Remote Wi-Fi VoIP capture: [${REMOTE_CLIENT_HOST}:${REMOTE_WIFI_IF:-wlp3s0}] => ${rem_pcap}"
                "${SCRIPT_DIR}/remote_client.sh" start-capture "${REMOTE_WIFI_IF:-wlp3s0}" "${voice_bpf}" "${rem_pcap}" "${CAPTURE_SNAPLEN:-96}" >/dev/null 2>&1 || true
                remote_cap_active=1
            fi
        elif [[ "${eff_mode}" == "virtual" ]]; then
            if ns_exists "${PHONE1_NS:-ns-phone1}"; then
                log_cmd "ip netns exec ${PHONE1_NS:-ns-phone1} tcpdump -ni eth0 -s ${CAPTURE_SNAPLEN:-96} -U -w ${phone1_pcap} ${voice_bpf} &"
                ip netns exec "${PHONE1_NS:-ns-phone1}" tcpdump -ni eth0 -s "${CAPTURE_SNAPLEN:-96}" -U -w "${phone1_pcap}" ${voice_bpf} >/dev/null 2>&1 &
                phone1_cap_pid=$!
                ACTIVE_BG_PIDS+=("${phone1_cap_pid}")
                echo "${phone1_pcap}" > "${STATE_DIR}/latest_phone1_pcap.txt"
            fi
            if ns_exists "${PHONE2_NS:-ns-phone2}"; then
                log_cmd "ip netns exec ${PHONE2_NS:-ns-phone2} tcpdump -ni eth0 -s ${CAPTURE_SNAPLEN:-96} -U -w ${phone2_pcap} ${voice_bpf} &"
                ip netns exec "${PHONE2_NS:-ns-phone2}" tcpdump -ni eth0 -s "${CAPTURE_SNAPLEN:-96}" -U -w "${phone2_pcap}" ${voice_bpf} >/dev/null 2>&1 &
                phone2_cap_pid=$!
                ACTIVE_BG_PIDS+=("${phone2_cap_pid}")
                echo "${phone2_pcap}" > "${STATE_DIR}/latest_phone2_pcap.txt"
            fi
        fi
    fi

    if [[ "${engine}" == "pjsua" ]]; then
        # Server UAS in ns-wan (auto-answers all incoming calls with 200 OK, loops media back, and sets DSCP 46)
        log_cmd "ip netns exec ${WAN_NS:-ns-wan} ${pjsua_bin} --local-port=${VOIP_PORT_SIP_SERVER} --null-audio --auto-answer=200 --auto-loop --no-vad --set-qos --use-cli --no-cli-console --app-log-level=0 < /dev/null &"
        ip netns exec "${WAN_NS:-ns-wan}" "${pjsua_bin}" \
            --local-port="${VOIP_PORT_SIP_SERVER}" --null-audio --auto-answer=200 --auto-loop --no-vad --set-qos --use-cli --no-cli-console --app-log-level=0 < /dev/null >/dev/null 2>&1 &
        voip_srv_pid=$!
        ACTIVE_BG_PIDS+=("${voip_srv_pid}")
        sleep 0.5

        if [[ "${eff_mode}" == "physical_single" ]]; then
            log_cmd "${pjsua_bin} --local-port=${VOIP_PORT_SIP_PHONE1} --rtp-port=${VOIP_PORT_RTP_PHONE1} --null-audio --no-vad --ip-addr=${wifi_ip} --bound-addr=${wifi_ip} --duration=${call_duration} --set-qos --use-cli --no-cli-console --app-log-level=0 sip:${WAN_SERVER_IP:-10.10.0.1}:${VOIP_PORT_SIP_SERVER} &"
            "${pjsua_bin}" --local-port="${VOIP_PORT_SIP_PHONE1}" --rtp-port="${VOIP_PORT_RTP_PHONE1}" --null-audio --no-vad \
                --ip-addr="${wifi_ip}" --bound-addr="${wifi_ip}" \
                --duration="${call_duration}" --set-qos --use-cli --no-cli-console --app-log-level=0 "sip:${WAN_SERVER_IP:-10.10.0.1}:${VOIP_PORT_SIP_SERVER}" < /dev/null >/dev/null 2>&1 &
            phone1_pid=$!
            ACTIVE_BG_PIDS+=("${phone1_pid}")

            log_cmd "${pjsua_bin} --local-port=${VOIP_PORT_SIP_PHONE2} --rtp-port=${VOIP_PORT_RTP_PHONE2} --null-audio --no-vad --ip-addr=${wifi_ip} --bound-addr=${wifi_ip} --duration=${call_duration} --set-qos --use-cli --no-cli-console --app-log-level=0 sip:${WAN_SERVER_IP:-10.10.0.1}:${VOIP_PORT_SIP_SERVER} &"
            "${pjsua_bin}" --local-port="${VOIP_PORT_SIP_PHONE2}" --rtp-port="${VOIP_PORT_RTP_PHONE2}" --null-audio --no-vad \
                --ip-addr="${wifi_ip}" --bound-addr="${wifi_ip}" \
                --duration="${call_duration}" --set-qos --use-cli --no-cli-console --app-log-level=0 "sip:${WAN_SERVER_IP:-10.10.0.1}:${VOIP_PORT_SIP_SERVER}" < /dev/null >/dev/null 2>&1 &
            phone2_pid=$!
            ACTIVE_BG_PIDS+=("${phone2_pid}")

        elif [[ "${eff_mode}" == "remote_only" ]]; then
            "${SCRIPT_DIR}/remote_client.sh" run-voip \
                --engine "pjsua" \
                --server-ip "${WAN_SERVER_IP:-10.10.0.1}" \
                --server-port "${VOIP_PORT_SIP_SERVER}" \
                --local-port "${VOIP_PORT_SIP_PHONE1}" \
                --rtp-port "${VOIP_PORT_RTP_PHONE1}" \
                --duration "${call_duration}" \
                --phone-id "phone-1" || true

            "${SCRIPT_DIR}/remote_client.sh" run-voip \
                --engine "pjsua" \
                --server-ip "${WAN_SERVER_IP:-10.10.0.1}" \
                --server-port "${VOIP_PORT_SIP_SERVER}" \
                --local-port "${VOIP_PORT_SIP_PHONE2}" \
                --rtp-port "${VOIP_PORT_RTP_PHONE2}" \
                --duration "${call_duration}" \
                --phone-id "phone-2" || true

        elif [[ "${eff_mode}" == "distributed" ]]; then
            log_cmd "${pjsua_bin} --local-port=${VOIP_PORT_SIP_PHONE1} --rtp-port=${VOIP_PORT_RTP_PHONE1} --null-audio --no-vad --ip-addr=${wifi_ip} --bound-addr=${wifi_ip} --duration=${call_duration} --set-qos --use-cli --no-cli-console --app-log-level=0 sip:${WAN_SERVER_IP:-10.10.0.1}:${VOIP_PORT_SIP_SERVER} &"
            "${pjsua_bin}" --local-port="${VOIP_PORT_SIP_PHONE1}" --rtp-port="${VOIP_PORT_RTP_PHONE1}" --null-audio --no-vad \
                --ip-addr="${wifi_ip}" --bound-addr="${wifi_ip}" \
                --duration="${call_duration}" --set-qos --use-cli --no-cli-console --app-log-level=0 "sip:${WAN_SERVER_IP:-10.10.0.1}:${VOIP_PORT_SIP_SERVER}" < /dev/null >/dev/null 2>&1 &
            phone1_pid=$!
            ACTIVE_BG_PIDS+=("${phone1_pid}")

            "${SCRIPT_DIR}/remote_client.sh" run-voip \
                --engine "pjsua" \
                --server-ip "${WAN_SERVER_IP:-10.10.0.1}" \
                --server-port "${VOIP_PORT_SIP_SERVER}" \
                --local-port "${VOIP_PORT_SIP_PHONE2}" \
                --rtp-port "${VOIP_PORT_RTP_PHONE2}" \
                --duration "${call_duration}" \
                --phone-id "phone-2" || true

        else
            log_cmd "ip netns exec ${PHONE1_NS:-ns-phone1} ${pjsua_bin} --local-port=${VOIP_PORT_SIP_SERVER} --rtp-port=${VOIP_PORT_RTP_PHONE1} --null-audio --no-vad --duration=${call_duration} --set-qos --use-cli --no-cli-console --app-log-level=0 sip:${WAN_SERVER_IP:-10.10.0.1}:${VOIP_PORT_SIP_SERVER} &"
            ip netns exec "${PHONE1_NS:-ns-phone1}" "${pjsua_bin}" \
                --local-port="${VOIP_PORT_SIP_SERVER}" --rtp-port="${VOIP_PORT_RTP_PHONE1}" --null-audio --no-vad \
                --duration="${call_duration}" --set-qos --use-cli --no-cli-console --app-log-level=0 "sip:${WAN_SERVER_IP:-10.10.0.1}:${VOIP_PORT_SIP_SERVER}" < /dev/null >/dev/null 2>&1 &
            phone1_pid=$!
            ACTIVE_BG_PIDS+=("${phone1_pid}")

            log_cmd "ip netns exec ${PHONE2_NS:-ns-phone2} ${pjsua_bin} --local-port=${VOIP_PORT_SIP_PHONE1} --rtp-port=${VOIP_PORT_RTP_PHONE2} --null-audio --no-vad --duration=${call_duration} --set-qos --use-cli --no-cli-console --app-log-level=0 sip:${WAN_SERVER_IP:-10.10.0.1}:${VOIP_PORT_SIP_SERVER} &"
            ip netns exec "${PHONE2_NS:-ns-phone2}" "${pjsua_bin}" \
                --local-port="${VOIP_PORT_SIP_PHONE1}" --rtp-port="${VOIP_PORT_RTP_PHONE2}" --null-audio --no-vad \
                --duration="${call_duration}" --set-qos --use-cli --no-cli-console --app-log-level=0 "sip:${WAN_SERVER_IP:-10.10.0.1}:${VOIP_PORT_SIP_SERVER}" < /dev/null >/dev/null 2>&1 &
            phone2_pid=$!
            ACTIVE_BG_PIDS+=("${phone2_pid}")
        fi

    elif [[ "${engine}" == "sipp" ]]; then
        local uac_tpl_src="${PROJECT_ROOT}/templates/sipp_uac_pcap.xml"
        local uas_tpl_src="${PROJECT_ROOT}/templates/sipp_uas_pcap.xml"
        local pcap_media="${PROJECT_ROOT}/templates/g711a_voice.pcap"
        if [[ ! -f "${pcap_media}" ]]; then
            if [[ -f "${PROJECT_ROOT}/templates/g711a_20s.pcap" ]]; then
                pcap_media="${PROJECT_ROOT}/templates/g711a_20s.pcap"
            elif [[ -x "${PROJECT_ROOT}/tools/generate_g711_pcap.py" ]]; then
                python3 "${PROJECT_ROOT}/tools/generate_g711_pcap.py" --output "${pcap_media}" --duration 30.0 >/dev/null 2>&1 || true
            fi
        fi
        local sipp_dur_ms=$(( call_duration * 1000 ))

        local uac_tpl="${SCENARIO_TMP_DIR}/sipp_uac_pcap.xml"
        local uas_tpl="${SCENARIO_TMP_DIR}/sipp_uas_pcap.xml"
        if [[ -f "${uac_tpl_src}" && -f "${uas_tpl_src}" ]]; then
            sed "s|__PCAP_FILE__|${pcap_media}|g" "${uac_tpl_src}" > "${uac_tpl}"
            sed "s|__PCAP_FILE__|${pcap_media}|g" "${uas_tpl_src}" > "${uas_tpl}"
        fi
        ln -sf "${pcap_media}" "${PROJECT_ROOT}/g711a_voice.pcap" 2>/dev/null || true

        if [[ -f "${uac_tpl}" && -f "${pcap_media}" ]]; then
            # Continuous G.711 RTP media playback at 50 PPS (20ms interval) via XML scenario
            log_cmd "ip netns exec ${WAN_NS:-ns-wan} ${sipp_bin} -sf ${uas_tpl} -i ${WAN_SERVER_IP:-10.10.0.1} -mi ${WAN_SERVER_IP:-10.10.0.1} -p ${VOIP_PORT_SIP_SERVER} -mp ${VOIP_PORT_RTP_PHONE1} -nostdin > ${LOG_DIR}/sipp_uas.log 2>&1 &"
            ip netns exec "${WAN_NS:-ns-wan}" "${sipp_bin}" \
                -sf "${uas_tpl}" \
                -i "${WAN_SERVER_IP:-10.10.0.1}" \
                -mi "${WAN_SERVER_IP:-10.10.0.1}" \
                -p "${VOIP_PORT_SIP_SERVER}" -mp "${VOIP_PORT_RTP_PHONE1}" -nostdin > "${LOG_DIR}/sipp_uas.log" 2>&1 &
            voip_srv_pid=$!
            ACTIVE_BG_PIDS+=("${voip_srv_pid}")
            sleep 0.5

            if [[ "${eff_mode}" == "physical_single" ]]; then
                log_cmd "${sipp_bin} -sf ${uac_tpl} ${WAN_SERVER_IP:-10.10.0.1}:${VOIP_PORT_SIP_SERVER} -i ${wifi_ip} -mi ${wifi_ip} -p ${VOIP_PORT_SIP_PHONE1} -mp ${VOIP_PORT_RTP_PHONE1} -m 1 -d ${sipp_dur_ms} -nostdin > ${LOG_DIR}/sipp_phone1.log 2>&1 &"
                "${sipp_bin}" -sf "${uac_tpl}" "${WAN_SERVER_IP:-10.10.0.1}:${VOIP_PORT_SIP_SERVER}" \
                    -i "${wifi_ip}" -mi "${wifi_ip}" -p "${VOIP_PORT_SIP_PHONE1}" -mp "${VOIP_PORT_RTP_PHONE1}" -m 1 -d "${sipp_dur_ms}" -nostdin > "${LOG_DIR}/sipp_phone1.log" 2>&1 &
                phone1_pid=$!
                ACTIVE_BG_PIDS+=("${phone1_pid}")

                log_cmd "${sipp_bin} -sf ${uac_tpl} ${WAN_SERVER_IP:-10.10.0.1}:${VOIP_PORT_SIP_SERVER} -i ${wifi_ip} -mi ${wifi_ip} -p ${VOIP_PORT_SIP_PHONE2} -mp ${VOIP_PORT_RTP_PHONE2} -m 1 -d ${sipp_dur_ms} -nostdin > ${LOG_DIR}/sipp_phone2.log 2>&1 &"
                "${sipp_bin}" -sf "${uac_tpl}" "${WAN_SERVER_IP:-10.10.0.1}:${VOIP_PORT_SIP_SERVER}" \
                    -i "${wifi_ip}" -mi "${wifi_ip}" -p "${VOIP_PORT_SIP_PHONE2}" -mp "${VOIP_PORT_RTP_PHONE2}" -m 1 -d "${sipp_dur_ms}" -nostdin > "${LOG_DIR}/sipp_phone2.log" 2>&1 &
                phone2_pid=$!
                ACTIVE_BG_PIDS+=("${phone2_pid}")

            elif [[ "${eff_mode}" == "remote_only" ]]; then
                "${SCRIPT_DIR}/remote_client.sh" run-voip \
                    --engine "sipp" \
                    --server-ip "${WAN_SERVER_IP:-10.10.0.1}" \
                    --server-port "${VOIP_PORT_SIP_SERVER}" \
                    --local-port "${VOIP_PORT_SIP_PHONE1}" \
                    --rtp-port "${VOIP_PORT_RTP_PHONE1}" \
                    --duration "${call_duration}" \
                    --phone-id "phone-1" || true

                "${SCRIPT_DIR}/remote_client.sh" run-voip \
                    --engine "sipp" \
                    --server-ip "${WAN_SERVER_IP:-10.10.0.1}" \
                    --server-port "${VOIP_PORT_SIP_SERVER}" \
                    --local-port "${VOIP_PORT_SIP_PHONE2}" \
                    --rtp-port "${VOIP_PORT_RTP_PHONE2}" \
                    --duration "${call_duration}" \
                    --phone-id "phone-2" || true

            elif [[ "${eff_mode}" == "distributed" ]]; then
                log_cmd "${sipp_bin} -sf ${uac_tpl} ${WAN_SERVER_IP:-10.10.0.1}:${VOIP_PORT_SIP_SERVER} -i ${wifi_ip} -mi ${wifi_ip} -p ${VOIP_PORT_SIP_PHONE1} -mp ${VOIP_PORT_RTP_PHONE1} -m 1 -d ${sipp_dur_ms} -nostdin > ${LOG_DIR}/sipp_phone1.log 2>&1 &"
                "${sipp_bin}" -sf "${uac_tpl}" "${WAN_SERVER_IP:-10.10.0.1}:${VOIP_PORT_SIP_SERVER}" \
                    -i "${wifi_ip}" -mi "${wifi_ip}" -p "${VOIP_PORT_SIP_PHONE1}" -mp "${VOIP_PORT_RTP_PHONE1}" -m 1 -d "${sipp_dur_ms}" -nostdin > "${LOG_DIR}/sipp_phone1.log" 2>&1 &
                phone1_pid=$!
                ACTIVE_BG_PIDS+=("${phone1_pid}")

                "${SCRIPT_DIR}/remote_client.sh" run-voip \
                    --engine "sipp" \
                    --server-ip "${WAN_SERVER_IP:-10.10.0.1}" \
                    --server-port "${VOIP_PORT_SIP_SERVER}" \
                    --local-port "${VOIP_PORT_SIP_PHONE2}" \
                    --rtp-port "${VOIP_PORT_RTP_PHONE2}" \
                    --duration "${call_duration}" \
                    --phone-id "phone-2" || true

            else
                log_cmd "ip netns exec ${PHONE1_NS:-ns-phone1} ${sipp_bin} -sf ${uac_tpl} ${WAN_SERVER_IP:-10.10.0.1}:${VOIP_PORT_SIP_SERVER} -i ${PHONE1_IP:-192.168.1.41} -mi ${PHONE1_IP:-192.168.1.41} -p ${VOIP_PORT_SIP_SERVER} -mp ${VOIP_PORT_RTP_PHONE1} -m 1 -d ${sipp_dur_ms} -nostdin > ${LOG_DIR}/sipp_phone1.log 2>&1 &"
                ip netns exec "${PHONE1_NS:-ns-phone1}" "${sipp_bin}" -sf "${uac_tpl}" "${WAN_SERVER_IP:-10.10.0.1}:${VOIP_PORT_SIP_SERVER}" \
                    -i "${PHONE1_IP:-192.168.1.41}" -mi "${PHONE1_IP:-192.168.1.41}" -p "${VOIP_PORT_SIP_SERVER}" -mp "${VOIP_PORT_RTP_PHONE1}" -m 1 -d "${sipp_dur_ms}" -nostdin > "${LOG_DIR}/sipp_phone1.log" 2>&1 &
                phone1_pid=$!
                ACTIVE_BG_PIDS+=("${phone1_pid}")

                log_cmd "ip netns exec ${PHONE2_NS:-ns-phone2} ${sipp_bin} -sf ${uac_tpl} ${WAN_SERVER_IP:-10.10.0.1}:${VOIP_PORT_SIP_SERVER} -i ${PHONE2_IP:-192.168.1.42} -mi ${PHONE2_IP:-192.168.1.42} -p ${VOIP_PORT_SIP_PHONE1} -mp ${VOIP_PORT_RTP_PHONE2} -m 1 -d ${sipp_dur_ms} -nostdin > ${LOG_DIR}/sipp_phone2.log 2>&1 &"
                ip netns exec "${PHONE2_NS:-ns-phone2}" "${sipp_bin}" -sf "${uac_tpl}" "${WAN_SERVER_IP:-10.10.0.1}:${VOIP_PORT_SIP_SERVER}" \
                    -i "${PHONE2_IP:-192.168.1.42}" -mi "${PHONE2_IP:-192.168.1.42}" -p "${VOIP_PORT_SIP_PHONE1}" -mp "${VOIP_PORT_RTP_PHONE2}" -m 1 -d "${sipp_dur_ms}" -nostdin > "${LOG_DIR}/sipp_phone2.log" 2>&1 &
                phone2_pid=$!
                ACTIVE_BG_PIDS+=("${phone2_pid}")
            fi

        else
            # Standard SIP signaling fallback
            log_cmd "ip netns exec ${WAN_NS:-ns-wan} ${sipp_bin} -sn uas -i ${WAN_SERVER_IP:-10.10.0.1} -mi ${WAN_SERVER_IP:-10.10.0.1} -p ${VOIP_PORT_SIP_SERVER} -mp ${VOIP_PORT_RTP_PHONE1} -nostdin > ${LOG_DIR}/sipp_uas.log 2>&1 &"
            ip netns exec "${WAN_NS:-ns-wan}" "${sipp_bin}" -sn uas \
                -i "${WAN_SERVER_IP:-10.10.0.1}" -mi "${WAN_SERVER_IP:-10.10.0.1}" \
                -p "${VOIP_PORT_SIP_SERVER}" -mp "${VOIP_PORT_RTP_PHONE1}" -nostdin > "${LOG_DIR}/sipp_uas.log" 2>&1 &
            voip_srv_pid=$!
            ACTIVE_BG_PIDS+=("${voip_srv_pid}")
            sleep 0.5

            if [[ "${eff_mode}" == "physical_single" ]]; then
                log_cmd "${sipp_bin} -sn uac ${WAN_SERVER_IP:-10.10.0.1}:${VOIP_PORT_SIP_SERVER} -i ${wifi_ip} -mi ${wifi_ip} -p ${VOIP_PORT_SIP_PHONE1} -mp ${VOIP_PORT_RTP_PHONE1} -m 1 -d ${sipp_dur_ms} -nostdin > ${LOG_DIR}/sipp_phone1.log 2>&1 &"
                "${sipp_bin}" -sn uac "${WAN_SERVER_IP:-10.10.0.1}:${VOIP_PORT_SIP_SERVER}" \
                    -i "${wifi_ip}" -mi "${wifi_ip}" -p "${VOIP_PORT_SIP_PHONE1}" -mp "${VOIP_PORT_RTP_PHONE1}" -m 1 -d "${sipp_dur_ms}" -nostdin > "${LOG_DIR}/sipp_phone1.log" 2>&1 &
                phone1_pid=$!
                ACTIVE_BG_PIDS+=("${phone1_pid}")

                log_cmd "${sipp_bin} -sn uac ${WAN_SERVER_IP:-10.10.0.1}:${VOIP_PORT_SIP_SERVER} -i ${wifi_ip} -mi ${wifi_ip} -p ${VOIP_PORT_SIP_PHONE2} -mp ${VOIP_PORT_RTP_PHONE2} -m 1 -d ${sipp_dur_ms} -nostdin > ${LOG_DIR}/sipp_phone2.log 2>&1 &"
                "${sipp_bin}" -sn uac "${WAN_SERVER_IP:-10.10.0.1}:${VOIP_PORT_SIP_SERVER}" \
                    -i "${wifi_ip}" -mi "${wifi_ip}" -p "${VOIP_PORT_SIP_PHONE2}" -mp "${VOIP_PORT_RTP_PHONE2}" -m 1 -d "${sipp_dur_ms}" -nostdin > "${LOG_DIR}/sipp_phone2.log" 2>&1 &
                phone2_pid=$!
                ACTIVE_BG_PIDS+=("${phone2_pid}")

            elif [[ "${eff_mode}" == "remote_only" ]]; then
                "${SCRIPT_DIR}/remote_client.sh" run-voip \
                    --engine "sipp" \
                    --server-ip "${WAN_SERVER_IP:-10.10.0.1}" \
                    --server-port "${VOIP_PORT_SIP_SERVER}" \
                    --local-port "${VOIP_PORT_SIP_PHONE1}" \
                    --rtp-port "${VOIP_PORT_RTP_PHONE1}" \
                    --duration "${call_duration}" \
                    --phone-id "phone-1" || true

                "${SCRIPT_DIR}/remote_client.sh" run-voip \
                    --engine "sipp" \
                    --server-ip "${WAN_SERVER_IP:-10.10.0.1}" \
                    --server-port "${VOIP_PORT_SIP_SERVER}" \
                    --local-port "${VOIP_PORT_SIP_PHONE2}" \
                    --rtp-port "${VOIP_PORT_RTP_PHONE2}" \
                    --duration "${call_duration}" \
                    --phone-id "phone-2" || true

            elif [[ "${eff_mode}" == "distributed" ]]; then
                log_cmd "${sipp_bin} -sn uac ${WAN_SERVER_IP:-10.10.0.1}:${VOIP_PORT_SIP_SERVER} -i ${wifi_ip} -mi ${wifi_ip} -p ${VOIP_PORT_SIP_PHONE1} -mp ${VOIP_PORT_RTP_PHONE1} -m 1 -d ${sipp_dur_ms} -nostdin > ${LOG_DIR}/sipp_phone1.log 2>&1 &"
                "${sipp_bin}" -sn uac "${WAN_SERVER_IP:-10.10.0.1}:${VOIP_PORT_SIP_SERVER}" \
                    -i "${wifi_ip}" -mi "${wifi_ip}" -p "${VOIP_PORT_SIP_PHONE1}" -mp "${VOIP_PORT_RTP_PHONE1}" -m 1 -d "${sipp_dur_ms}" -nostdin > "${LOG_DIR}/sipp_phone1.log" 2>&1 &
                phone1_pid=$!
                ACTIVE_BG_PIDS+=("${phone1_pid}")

                "${SCRIPT_DIR}/remote_client.sh" run-voip \
                    --engine "sipp" \
                    --server-ip "${WAN_SERVER_IP:-10.10.0.1}" \
                    --server-port "${VOIP_PORT_SIP_SERVER}" \
                    --local-port "${VOIP_PORT_SIP_PHONE2}" \
                    --rtp-port "${VOIP_PORT_RTP_PHONE2}" \
                    --duration "${call_duration}" \
                    --phone-id "phone-2" || true

            else
                log_cmd "ip netns exec ${PHONE1_NS:-ns-phone1} ${sipp_bin} -sn uac ${WAN_SERVER_IP:-10.10.0.1}:${VOIP_PORT_SIP_SERVER} -i ${PHONE1_IP:-192.168.1.41} -mi ${PHONE1_IP:-192.168.1.41} -p ${VOIP_PORT_SIP_SERVER} -mp ${VOIP_PORT_RTP_PHONE1} -m 1 -d ${sipp_dur_ms} -nostdin >/dev/null 2>&1 &"
                ip netns exec "${PHONE1_NS:-ns-phone1}" "${sipp_bin}" -sn uac "${WAN_SERVER_IP:-10.10.0.1}:${VOIP_PORT_SIP_SERVER}" \
                    -i "${PHONE1_IP:-192.168.1.41}" -mi "${PHONE1_IP:-192.168.1.41}" -p "${VOIP_PORT_SIP_SERVER}" -mp "${VOIP_PORT_RTP_PHONE1}" -m 1 -d "${sipp_dur_ms}" -nostdin >/dev/null 2>&1 &
                phone1_pid=$!
                ACTIVE_BG_PIDS+=("${phone1_pid}")

                log_cmd "ip netns exec ${PHONE2_NS:-ns-phone2} ${sipp_bin} -sn uac ${WAN_SERVER_IP:-10.10.0.1}:${VOIP_PORT_SIP_SERVER} -i ${PHONE2_IP:-192.168.1.42} -mi ${PHONE2_IP:-192.168.1.42} -p ${VOIP_PORT_SIP_PHONE1} -mp ${VOIP_PORT_RTP_PHONE2} -m 1 -d ${sipp_dur_ms} -nostdin >/dev/null 2>&1 &"
                ip netns exec "${PHONE2_NS:-ns-phone2}" "${sipp_bin}" -sn uac "${WAN_SERVER_IP:-10.10.0.1}:${VOIP_PORT_SIP_SERVER}" \
                    -i "${PHONE2_IP:-192.168.1.42}" -mi "${PHONE2_IP:-192.168.1.42}" -p "${VOIP_PORT_SIP_PHONE1}" -mp "${VOIP_PORT_RTP_PHONE2}" -m 1 -d "${sipp_dur_ms}" -nostdin >/dev/null 2>&1 &
                phone2_pid=$!
                ACTIVE_BG_PIDS+=("${phone2_pid}")
            fi
        fi

    else
        # Native Python G.711 RTP Simulator
        log_cmd "ip netns exec ${WAN_NS:-ns-wan} ${tools_dir}/voip_call_simulator.py server --ports ${VOIP_PORT_RTP_PHONE1},${VOIP_PORT_RTP_PHONE2} --duration $(( call_duration + 10 )) &"
        ip netns exec "${WAN_NS:-ns-wan}" "${tools_dir}/voip_call_simulator.py" server \
            --ports "${VOIP_PORT_RTP_PHONE1},${VOIP_PORT_RTP_PHONE2}" --duration "$(( call_duration + 10 ))" >/dev/null 2>&1 &
        voip_srv_pid=$!
        ACTIVE_BG_PIDS+=("${voip_srv_pid}")
        sleep 0.3

        if [[ "${eff_mode}" == "physical_single" ]]; then
            log_cmd "${tools_dir}/voip_call_simulator.py client --server-ip ${WAN_SERVER_IP:-10.10.0.1} --server-port ${VOIP_PORT_RTP_PHONE1} --bind-ip ${wifi_ip} --bind-port ${VOIP_PORT_RTP_PHONE1} --duration ${call_duration} --phone-id phone-1 &"
            "${tools_dir}/voip_call_simulator.py" client \
                --server-ip "${WAN_SERVER_IP:-10.10.0.1}" --server-port "${VOIP_PORT_RTP_PHONE1}" \
                --bind-ip "${wifi_ip}" --bind-port "${VOIP_PORT_RTP_PHONE1}" \
                --duration "${call_duration}" --phone-id "phone-1" >/dev/null 2>&1 &
            phone1_pid=$!
            ACTIVE_BG_PIDS+=("${phone1_pid}")

            log_cmd "${tools_dir}/voip_call_simulator.py client --server-ip ${WAN_SERVER_IP:-10.10.0.1} --server-port ${VOIP_PORT_RTP_PHONE2} --bind-ip ${wifi_ip} --bind-port ${VOIP_PORT_RTP_PHONE2} --duration ${call_duration} --phone-id phone-2 &"
            "${tools_dir}/voip_call_simulator.py" client \
                --server-ip "${WAN_SERVER_IP:-10.10.0.1}" --server-port "${VOIP_PORT_RTP_PHONE2}" \
                --bind-ip "${wifi_ip}" --bind-port "${VOIP_PORT_RTP_PHONE2}" \
                --duration "${call_duration}" --phone-id "phone-2" >/dev/null 2>&1 &
            phone2_pid=$!
            ACTIVE_BG_PIDS+=("${phone2_pid}")

        elif [[ "${eff_mode}" == "remote_only" ]]; then
            "${SCRIPT_DIR}/remote_client.sh" run-voip \
                --engine "python" \
                --server-ip "${WAN_SERVER_IP:-10.10.0.1}" \
                --server-port "${VOIP_PORT_RTP_PHONE1}" \
                --duration "${call_duration}" \
                --phone-id "phone-1" || true

            "${SCRIPT_DIR}/remote_client.sh" run-voip \
                --engine "python" \
                --server-ip "${WAN_SERVER_IP:-10.10.0.1}" \
                --server-port "${VOIP_PORT_RTP_PHONE2}" \
                --duration "${call_duration}" \
                --phone-id "phone-2" || true

        elif [[ "${eff_mode}" == "distributed" ]]; then
            log_cmd "${tools_dir}/voip_call_simulator.py client --server-ip ${WAN_SERVER_IP:-10.10.0.1} --server-port ${VOIP_PORT_RTP_PHONE1} --bind-ip ${wifi_ip} --bind-port ${VOIP_PORT_RTP_PHONE1} --duration ${call_duration} --phone-id phone-1 &"
            "${tools_dir}/voip_call_simulator.py" client \
                --server-ip "${WAN_SERVER_IP:-10.10.0.1}" --server-port "${VOIP_PORT_RTP_PHONE1}" \
                --bind-ip "${wifi_ip}" --bind-port "${VOIP_PORT_RTP_PHONE1}" \
                --duration "${call_duration}" --phone-id "phone-1" >/dev/null 2>&1 &
            phone1_pid=$!
            ACTIVE_BG_PIDS+=("${phone1_pid}")

            "${SCRIPT_DIR}/remote_client.sh" run-voip \
                --engine "python" \
                --server-ip "${WAN_SERVER_IP:-10.10.0.1}" \
                --server-port "${VOIP_PORT_RTP_PHONE2}" \
                --duration "${call_duration}" \
                --phone-id "phone-2" || true

        else
            traffic_run_bg --job "phone1" --netns "${PHONE1_NS:-ns-phone1}" \
                "${tools_dir}/voip_call_simulator.py" client \
                --server-ip "${WAN_SERVER_IP:-10.10.0.1}" --server-port "${VOIP_PORT_RTP_PHONE1}" \
                --duration "${call_duration}" --phone-id "phone-1"
            phone1_pid="${TRAFFIC_LAST_PID}"

            traffic_run_bg --job "phone2" --netns "${PHONE2_NS:-ns-phone2}" \
                "${tools_dir}/voip_call_simulator.py" client \
                --server-ip "${WAN_SERVER_IP:-10.10.0.1}" --server-port "${VOIP_PORT_RTP_PHONE2}" \
                --duration "${call_duration}" --phone-id "phone-2"
            phone2_pid="${TRAFFIC_LAST_PID}"
        fi
    fi

    log_pass "VoIP call media streams active on Wi-Fi client stations."
    sleep 1.0 # Allow calls to establish and stabilize

    # Ensure iperf3 server in ns-wan is ready for concurrent measurement
    if ns_exists "${WAN_NS:-ns-wan}"; then
        ip netns exec "${WAN_NS:-ns-wan}" pkill -TERM -x iperf3 2>/dev/null || true
        sleep 0.2
        ip netns exec "${WAN_NS:-ns-wan}" iperf3 -s -p "${VOIP_PORT_IPERF}" -D >/dev/null 2>&1
        sleep 0.2
    fi

    # Step 3: Measure PC Throughput during active calls (B)
    log_info "Measuring PC throughput during 2 active Wi-Fi phone calls (B, duration: ${pc_concurrent_dur}s)..."
    local pc_call_out="${SCENARIO_TMP_DIR}/iperf_pc_call.json"
    log_cmd "ip netns exec ${PC_NS:-ns-pc} iperf3 -c ${WAN_SERVER_IP:-10.10.0.1} -p ${VOIP_PORT_IPERF} -t ${pc_concurrent_dur} -J > ${pc_call_out}"
    ip netns exec "${PC_NS:-ns-pc}" iperf3 -c "${WAN_SERVER_IP:-10.10.0.1}" -p "${VOIP_PORT_IPERF}" -t "${pc_concurrent_dur}" -J > "${pc_call_out}" 2>&1 || true
    local b_mbps
    b_mbps="$("${tools_dir}/metric_parser.py" sum-mbps "${pc_call_out}")"
    log_info "  Concurrent PC throughput (B): ${b_mbps} Mbps"

    # Verify that calls were actually running and did not terminate prematurely
    local verified_calls=2
    if [[ "${eff_mode}" == "remote_only" ]]; then
        local r1_alive r2_alive
        r1_alive="$("${SCRIPT_DIR}/remote_client.sh" is-voip-running "phone-1" 2>/dev/null | tr -d '\r\n ' || echo 0)"
        r2_alive="$("${SCRIPT_DIR}/remote_client.sh" is-voip-running "phone-2" 2>/dev/null | tr -d '\r\n ' || echo 0)"
        if [[ "${r1_alive}" != "1" ]]; then
            log_error "Remote Phone 1 VoIP client terminated prematurely or failed during the test!"
            verified_calls=$(( verified_calls - 1 ))
        fi
        if [[ "${r2_alive}" != "1" ]]; then
            log_error "Remote Phone 2 VoIP client terminated prematurely or failed during the test!"
            verified_calls=$(( verified_calls - 1 ))
        fi
    elif [[ "${eff_mode}" == "distributed" ]]; then
        if [[ -n "${phone1_pid}" ]] && ! kill -0 "${phone1_pid}" 2>/dev/null; then
            log_error "Phone 1 VoIP client terminated prematurely during the test!"
            verified_calls=$(( verified_calls - 1 ))
        fi
        local remote_alive
        remote_alive="$("${SCRIPT_DIR}/remote_client.sh" is-voip-running "phone-2" 2>/dev/null | tr -d '\r\n ' || echo 0)"
        if [[ "${remote_alive}" != "1" ]]; then
            log_error "Remote Phone 2 VoIP client terminated prematurely or failed during the test!"
            verified_calls=$(( verified_calls - 1 ))
        fi
    else
        if [[ -n "${phone1_pid}" ]] && ! kill -0 "${phone1_pid}" 2>/dev/null; then
            log_error "Phone 1 VoIP client terminated prematurely during the test!"
            verified_calls=$(( verified_calls - 1 ))
        fi
        if [[ -n "${phone2_pid}" ]] && ! kill -0 "${phone2_pid}" 2>/dev/null; then
            log_error "Phone 2 VoIP client terminated prematurely during the test!"
            verified_calls=$(( verified_calls - 1 ))
        fi
    fi

    if (( verified_calls < 2 )); then
        log_error "VoIP load generator verification FAILED: Only ${verified_calls}/2 calls active."
    else
        log_pass "Both VoIP calls verified continuously active throughout throughput test."
    fi

    # Clean up background VoIP processes
    local pids_to_kill=()
    if [[ -n "${phone1_pid}" ]]; then pids_to_kill+=("${phone1_pid}"); fi
    if [[ -n "${phone2_pid}" ]]; then pids_to_kill+=("${phone2_pid}"); fi
    if [[ -n "${voip_srv_pid}" ]]; then pids_to_kill+=("${voip_srv_pid}"); fi
    traffic_stop_group "${pids_to_kill[@]}"

    # Stop Targeted Station Packet Captures (LAN / Wi-Fi side)
    local caps_to_kill=()
    if [[ -n "${phone1_cap_pid}" ]]; then caps_to_kill+=("${phone1_cap_pid}"); fi
    if [[ -n "${phone2_cap_pid}" ]]; then caps_to_kill+=("${phone2_cap_pid}"); fi
    traffic_stop_group "${caps_to_kill[@]}"

    if [[ -f "${phone1_pcap}" ]]; then chmod 0666 "${phone1_pcap}" 2>/dev/null || true; fi
    if [[ -f "${phone2_pcap}" ]]; then chmod 0666 "${phone2_pcap}" 2>/dev/null || true; fi

    if (( remote_cap_active == 1 )); then
        local rem_dir="${REMOTE_CLIENT_DIR:-/home/network/workspace/gwlab}"
        local rem_pcap="${rem_dir}/captures/tc_qos_01_phone2.pcap"
        "${SCRIPT_DIR}/remote_client.sh" stop-capture "${rem_pcap}" >/dev/null 2>&1 || true
        "${SCRIPT_DIR}/remote_client.sh" fetch-capture "${rem_pcap}" "${phone2_pcap}" >/dev/null 2>&1 || true
        chmod 0666 "${phone2_pcap}" 2>/dev/null || true
        echo "${phone2_pcap}" > "${STATE_DIR}/latest_phone2_pcap.txt"
        if [[ "${eff_mode}" == "remote_only" ]]; then
            echo "${phone2_pcap}" > "${STATE_DIR}/latest_phone1_pcap.txt"
            phone1_pcap="${phone2_pcap}"
        fi
    fi

    if [[ "${eff_mode}" == "remote_only" || "${eff_mode}" == "distributed" ]]; then
        "${SCRIPT_DIR}/remote_client.sh" clean >/dev/null 2>&1 || true
    fi

    log_cmd "ip netns exec ${WAN_NS:-ns-wan} pkill -TERM -x iperf3"
    ip netns exec "${WAN_NS:-ns-wan}" pkill -TERM -x iperf3 2>/dev/null || true

    # Clean up physical Wi-Fi route and iptables rules
    _voip_cleanup_network

    local wifi_if_rep="${DETECTED_WIFI_IF:-}"
    local wifi_ssid_rep="${DETECTED_WIFI_SSID:-}"
    if [[ "${eff_mode}" == "remote_only" ]]; then
        wifi_if_rep="${REMOTE_WIFI_IF:-wlp3s0}"
        wifi_ssid_rep="${REMOTE_WIFI_SSID:-DUT}"
    fi

    local eval_cmd=(
        "${tools_dir}/metric_parser.py" eval-qos
        --baseline "${a_mbps}"
        --during "${b_mbps}"
        --mode "${eff_mode}"
        --engine "${engine}"
        --wifi-if "${wifi_if_rep}"
        --wifi-ssid "${wifi_ssid_rep}"
        --calls 2
        --verified-calls "${verified_calls}"
        --tolerance "${VOIP_IMPACT_TOLERANCE_PCT:-${VOIP_DEFAULT_TOLERANCE}}"
        --output "${voice_json}"
    )
    log_cmd "${eval_cmd[*]}"
    "${eval_cmd[@]}" || true
}
