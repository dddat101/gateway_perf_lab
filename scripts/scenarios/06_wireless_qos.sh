#!/usr/bin/env bash
# ==============================================================================
# SCENARIO MODULE: WIRELESS WMM QOS & DSCP MAPPING
# [TC-WQOS-01] Wireless QoS: Voice (EF) & Video (AF41) vs Best Effort Congestion
# Supports: Local Physical Wi-Fi, Virtual Netns, and Remote Client Station
# Refactored with Defensive Bash Programming Patterns
# ==============================================================================

# Canonical constants
readonly WQOS_PORT_VOICE=10000
readonly WQOS_PORT_VIDEO=5005
readonly WQOS_PORT_BE=5201
readonly WQOS_DSCP_VOICE=46      # 0xb8 = 184 (EF -> WMM AC_VO / TID 6 or 7)
readonly WQOS_DSCP_VIDEO=34      # 0x88 = 136 (AF41 -> WMM AC_VI / TID 4 or 5)
readonly WQOS_DEFAULT_DURATION=10
readonly WQOS_DEFAULT_BE_PROTO="tcp"
readonly WQOS_DEFAULT_BE_BITRATE="auto"
readonly WQOS_DEFAULT_BE_PARALLEL=4
readonly WQOS_DEFAULT_CONGESTION_SOURCE="wifi"
readonly WQOS_DEFAULT_BE_DIRECTION="downlink"

usage_block_wqos() {
    cat <<'EOF'
+------------------------------------------------------------------+
| [TC-WQOS-01] WIRELESS QOS: IEEE 802.11e WMM & DSCP MAPPING       |
+------------------------------------------------------------------+
  Scenario Aliases : wireless_qos, tc_wqos_01, wmm_qos, wmm_dscp
  Objective        : Validate IEEE 802.11e WMM parameters & DSCP mapping:
                     - Voice Service : DSCP 46 (0xb8 / EF) -> AC_VO (TID 6/7)
                     - Video Service : DSCP 34 (0x88 / AF41) -> AC_VI (TID 4/5)
                     - Best Effort   : DSCP 0 (0x00 / CS0) -> AC_BE (TID 0/3)
  Traffic Profile  : Concurrent Voice + Video over Wi-Fi under heavy
                     Best Effort in-band Wi-Fi airtime link congestion.
  Pass Criteria    : Voice/Video packet loss <= 1.0%, DSCP preservation >= 95%,
                     Voice/Video packet jitter < 20ms,
                     AP TX EDCA and OTA AC/TID evidence filtered by MAC.
                     Practical audit does not require OTA decryption or radio telemetry.
                     Missing evidence returns INVALID or INCONCLUSIVE.

  Supported Options:
    --duration, -d <sec>     Test duration in seconds (default: 10)
    --be-proto <tcp|udp>     Best Effort transport protocol: tcp (default) or udp (buffer overflow drop)
    --be-rate, -b <rate>     Congestion Best-Effort rate (default: auto [scaled to Wi-Fi PHY], 0=unlimited)
    --congestion-source <src> Congestion domain: wifi (in-band airtime, default), wired (ns-pc)
    --wifi-mode, -W <mode>   Wi-Fi mode: auto, real_single, remote, remote_only, virtual
    --remote-only, -R        Run Wireless QoS clients exclusively on Remote Client PC
    --ota, --ota-capture     Enable Over-The-Air (OTA) 802.11 monitor capture on Remote PC
    --no-ota                 Disable Over-The-Air (OTA) monitor capture
    --merge-lan, -M          Merge LAN/Wi-Fi captures into unified timeline
    --deep-audit, -D         Deep packet-by-packet correlation
    --debug, -v              Show exact commands executed at each step
    --collect-artifacts, -A  Package run deliverables into artifacts/
    --dry-run, -n            Preview parameters without sending traffic

  Examples:
    sudo ./scripts/scenario.sh wireless_qos                      # Auto-adaptive Wi-Fi congestion
    sudo ./scripts/scenario.sh --ota wireless_qos                # Explicitly engage remote OTA monitor sniffer
    sudo ./scripts/scenario.sh -b 150M wireless_qos              # Explicit 150M Wi-Fi congestion rate
    sudo ./scripts/scenario.sh -b 0 wireless_qos                 # Unthrottled line-rate Wi-Fi saturation
    sudo ./scripts/scenario.sh --congestion-source wired wqos    # Cross-domain wired LAN congestion

EOF
}

# ------------------------------------------------------------------------------
# Modular Helper: Resolve Adaptive Bitrate based on Live Wi-Fi PHY Link Quality
# ------------------------------------------------------------------------------
_wqos_resolve_target_bitrate() {
    local requested="$1"
    local wifi_if="${2:-}"
    local cong_source="${3:-wifi}"
    local be_proto="${4:-tcp}"
    local eff_mode="${5:-physical_single}"

    # If user provided a specific non-auto rate (e.g. 150M, 500M, 0, unlimited), honor it
    if [[ -n "${requested}" && "${requested,,}" != "auto" ]]; then
        echo "${requested}"
        return 0
    fi

    # For wired-only congestion fallback
    if [[ "${cong_source}" == "wired" ]]; then
        echo "1G"
        return 0
    fi

    # Probe live PHY link bitrate from interface or environment
    local phy_num=""
    if [[ -n "${wifi_if}" && "${eff_mode}" != "remote_only" ]]; then
        local live_link
        live_link="$(iw dev "${wifi_if}" link 2>/dev/null || true)"
        phy_num="$(echo "${live_link}" | awk -F: '/rx bitrate/ {print $2}' | awk '{print $1}' | tr -cd '0-9.')"
        if [[ -z "${phy_num}" || "${phy_num}" == "0" ]]; then
            phy_num="$(echo "${live_link}" | awk -F: '/tx bitrate/ {print $2}' | awk '{print $1}' | tr -cd '0-9.')"
        fi
    fi
    if [[ -z "${phy_num}" || "${phy_num}" == "0" ]]; then
        local raw_str="${DETECTED_WIFI_BITRATE:-${REMOTE_WIFI_BITRATE:-}}"
        if [[ "${eff_mode}" == "remote_only" ]]; then raw_str="${REMOTE_WIFI_BITRATE:-}"; fi
        phy_num="$(echo "${raw_str}" | awk '{print $1}' | tr -cd '0-9.')"
    fi

    if [[ -n "${phy_num}" && "${phy_num}" != "0" ]]; then
        if [[ "${be_proto,,}" == "udp" ]]; then
            # Aggressive UDP over-saturation target: 150% of PHY rate (min 350M) as an offered-load estimate; drops alone do not locate the bottleneck
            awk -v phy="${phy_num}" 'BEGIN {
                rate = int(phy * 1.5);
                if (rate < 350) rate = 350;
                printf "%dM\n", rate;
            }'
            return 0
        else
            # Saturated airtime target: 85% of PHY rate as an offered-load estimate; verify the actual radio bottleneck
            awk -v phy="${phy_num}" 'BEGIN {
                rate = int(phy * 0.85);
                if (rate < 10) rate = 10;
                printf "%dM\n", rate;
            }'
            return 0
        fi
    fi

    # Safe fallback if virtual netns or rate unreadable
    if [[ "${be_proto,,}" == "udp" ]]; then
        echo "400M"
    else
        echo "200M"
    fi
}

# ------------------------------------------------------------------------------
# Modular Helper: Compute Per-Stream Bitrate for Multi-Stream iperf3
# ------------------------------------------------------------------------------
_wqos_calc_stream_bitrate() {
    local total="$1"
    local streams="${2:-${WQOS_DEFAULT_BE_PARALLEL}}"

    if [[ -z "${total}" || "${total}" == "0" || "${total,,}" == "unlimited" || "${total,,}" == "none" ]]; then
        echo "0"
        return 0
    fi

    local clean="${total^^}"
    clean="${clean%BPS}"
    clean="${clean%/S}"
    clean="${clean%B}"
    if [[ ! "${streams}" =~ ^[1-9][0-9]*$ || ! "${clean}" =~ ^([0-9]+([.][0-9]+)?)([KMG]?)$ ]]; then
        printf 'Invalid Best Effort rate or stream count: %s / %s\n' "${total}" "${streams}" >&2
        return 1
    fi
    local num="${BASH_REMATCH[1]}" unit="${BASH_REMATCH[3]}"
    awk -v num="${num}" -v unit="${unit}" -v streams="${streams}" 'BEGIN {
        factor = unit == "G" ? 1000000000 : unit == "M" ? 1000000 : unit == "K" ? 1000 : 1;
        rate = num * factor / streams;
        if (rate < 1) exit 1;
        printf "%.0f\n", rate;
    }'

}

# ------------------------------------------------------------------------------
# Modular Helper: Terminate PIDs safely with escalation (TERM -> KILL)
# ------------------------------------------------------------------------------
_wqos_terminate_pids() {
    local -a pids=("$@")
    if (( ${#pids[@]} == 0 )); then
        return 0
    fi

    # 1. Graceful SIGTERM
    for pid in "${pids[@]}"; do
        if [[ -n "${pid}" && "${pid}" =~ ^[0-9]+$ ]] && kill -0 "${pid}" 2>/dev/null; then
            kill -TERM "${pid}" 2>/dev/null || true
        fi
    done

    # 2. Brief grace period for socket/file buffer flush
    sleep 0.3

    # 3. Escalate to SIGKILL for any lingering processes
    for pid in "${pids[@]}"; do
        if [[ -n "${pid}" && "${pid}" =~ ^[0-9]+$ ]] && kill -0 "${pid}" 2>/dev/null; then
            kill -KILL "${pid}" 2>/dev/null || true
        fi
    done
}

# ------------------------------------------------------------------------------
# Modular Helper: Detect Topology Mode and Resolve Client Endpoints
# ------------------------------------------------------------------------------
_wqos_detect_endpoints() {
    local tools_dir="$1"
    local raw_mode="${CUSTOM_WIFI_MODE:-auto}"

    # 1. Inspect local host Wi-Fi interface and connectivity
    local env_dump
    env_dump="$("${tools_dir}/wifi_inspector.py" export-env --check-ping "${DUT_LAN_IP:-192.168.1.1}" 2>/dev/null || true)"
    eval "${env_dump}"

    local wifi_if="${DETECTED_WIFI_IF:-wlp3s0}"
    local wifi_ip="${DETECTED_WIFI_IP:-}"
    if [[ -z "${wifi_ip}" ]]; then
        wifi_ip="$(ip -4 -o addr show dev "${wifi_if}" 2>/dev/null | awk '{print $4}' | cut -d/ -f1 || true)"
    fi

    # 2. Mode resolution logic with fallback guarantees
    local eff_mode="${raw_mode}"
    if [[ "${eff_mode}" == "auto" ]]; then
        if [[ "${TOPOLOGY_MODE:-virtual}" == "virtual" ]]; then
            eff_mode="virtual"
        elif (( ${WIFI_CARD_COUNT:-0} == 0 )); then
            if [[ -n "${REMOTE_CLIENT_HOST:-}" ]] && "${SCRIPT_DIR}/remote_client.sh" test >/dev/null 2>&1; then
                eff_mode="remote_only"
            else
                eff_mode="virtual"
            fi
        elif [[ -z "${DETECTED_WIFI_SSID:-}" ]]; then
            local rem_ip=""
            if [[ -n "${REMOTE_CLIENT_HOST:-}" ]] && "${SCRIPT_DIR}/remote_client.sh" test >/dev/null 2>&1; then
                rem_ip="$("${SCRIPT_DIR}/remote_client.sh" wifi-ip 2>/dev/null || true)"
            fi
            if [[ -n "${rem_ip}" && "${rem_ip}" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
                eff_mode="remote_only"
            else
                log_warn "Physical Wi-Fi not connected on local or remote PC. Falling back to virtual netns."
                eff_mode="virtual"
            fi
        else
            eff_mode="physical_single"
        fi
    elif [[ "${eff_mode}" == "real_single" || "${eff_mode}" == "real_single_band" ]]; then
        eff_mode="physical_single"
    elif [[ "${eff_mode}" == "remote" || "${eff_mode}" == "remote_only" ]]; then
        eff_mode="remote_only"
    elif [[ "${eff_mode}" == "emulated" ]]; then
        eff_mode="virtual"
    fi

    # 3. Endpoint details extraction
    local eff_target_ip=""
    local eff_target_dev=""
    local is_virtual=0

    if [[ "${eff_mode}" == "remote_only" ]]; then
        local remote_env_dump
        remote_env_dump="$("${SCRIPT_DIR}/remote_client.sh" wifi-env --check-ping "${DUT_LAN_IP:-192.168.1.1}" 2>/dev/null || true)"
        eval "${remote_env_dump}"

        local remote_status="${REMOTE_WIFI_STATUS:-DISCONNECTED}"
        log_info "Wireless QoS Mode : [REMOTE] | Remote Endpoint: ${REMOTE_CLIENT_HOST}"
        log_info "  -> Remote Wi-Fi Adapter   : ${REMOTE_WIFI_IF:-none} [${remote_status}] (MAC: ${REMOTE_WIFI_MAC:-none})"
        log_info "  -> Target SSID & Band     : '${REMOTE_WIFI_SSID:-none}' (${REMOTE_WIFI_BAND:-none} / Ch ${REMOTE_WIFI_CHANNEL:-?})"
        log_info "  -> Signal & Bitrate       : ${REMOTE_WIFI_SIGNAL:-none} (Tx: ${REMOTE_WIFI_BITRATE:-none})"
        log_info "  -> Station IPv4 Address   : ${REMOTE_WIFI_IP:-none} (Gateway: ${REMOTE_WIFI_GATEWAY:-none})"
        if [[ "${REMOTE_WIFI_PING_OK:-0}" == "1" ]]; then
            log_pass "  -> Remote DUT Reachability: OK (Ping to ${DUT_LAN_IP:-192.168.1.1}: ${REMOTE_WIFI_PING_RTT})"
        else
            log_warn "  -> Remote DUT Reachability: FAILED (Cannot ping gateway ${DUT_LAN_IP:-192.168.1.1})"
            log_warn "  -> Please verify Remote PC is associated to DUT SSID."
        fi

        eff_target_ip="${REMOTE_WIFI_IP:-}"
        eff_target_dev="${REMOTE_WIFI_IF:-wlan0}"
        if [[ -z "${eff_target_ip}" ]]; then
            die "Remote PC has no active Wi-Fi IP address. Connect remote PC to DUT SSID first."
        fi
    elif [[ "${eff_mode}" == "physical_single" ]]; then
        eff_target_ip="${wifi_ip}"
        eff_target_dev="${wifi_if}"
        if [[ -z "${eff_target_ip}" ]]; then
            log_warn "No physical Wi-Fi IP detected. Falling back to ns-wlan5g / virtual Wi-Fi."
            eff_target_dev="eth0"
            eff_target_ip="${WLAN5G_IP:-192.168.1.50}"
            is_virtual=1
            eff_mode="virtual"
        fi
    else
        eff_target_dev="eth0"
        eff_target_ip="${WLAN5G_IP:-192.168.1.50}"
        is_virtual=1
        eff_mode="virtual"
    fi

    echo "${eff_mode}" > "${STATE_DIR}/latest_wqos_mode.txt"

    # Export resolved values to caller
    WQOS_EFF_MODE="${eff_mode}"
    WQOS_TARGET_IP="${eff_target_ip}"
    WQOS_TARGET_DEV="${eff_target_dev}"
    WQOS_WIFI_IF="${wifi_if}"
    WQOS_WIFI_IP="${wifi_ip}"
    WQOS_IS_VIRTUAL="${is_virtual}"
}

# ------------------------------------------------------------------------------
# Modular Helper: Apply QoS Mangle Rules & Routing
# ------------------------------------------------------------------------------
_wqos_setup_network_qos() {
    local eff_mode="$1"
    local wifi_if="$2"
    local wifi_ip="$3"

    if [[ "${eff_mode}" == "remote_only" ]]; then
        # The load generator starts before the application clients.
        "${SCRIPT_DIR}/remote_client.sh" exec "rm -f /tmp/wqos_voice.json /tmp/wqos_vod.json /tmp/wqos_iperf_be.json"
        "${SCRIPT_DIR}/remote_client.sh" exec "sudo -n ip route replace '${WAN_SERVER_IP:-10.10.0.1}' via '${REMOTE_WIFI_GATEWAY:-${DUT_LAN_IP:-192.168.1.1}}' dev '${REMOTE_WIFI_IF:-wlan0}'"
    fi

    # Uplink DSCP marking on local physical Wi-Fi adapter
    if [[ "${eff_mode}" == "physical_single" ]] && [[ -n "${wifi_if}" && -n "${wifi_ip}" ]]; then
        log_cmd "ip route replace ${WAN_SERVER_IP:-10.10.0.1} via ${DUT_LAN_IP:-192.168.1.1} dev ${wifi_if}"
        ip route replace "${WAN_SERVER_IP:-10.10.0.1}" via "${DUT_LAN_IP:-192.168.1.1}" dev "${wifi_if}" 2>/dev/null || true
        
        CLEANUP_WIFI_ROUTE="${WAN_SERVER_IP:-10.10.0.1} via ${DUT_LAN_IP:-192.168.1.1} dev ${wifi_if}"

        log_cmd "iptables -t mangle -A POSTROUTING -o ${wifi_if} -p udp --dport ${WQOS_PORT_VOICE} -j DSCP --set-dscp ${WQOS_DSCP_VOICE}"
        iptables -t mangle -A POSTROUTING -o "${wifi_if}" -p udp --dport "${WQOS_PORT_VOICE}" -j DSCP --set-dscp "${WQOS_DSCP_VOICE}" 2>/dev/null || true
        
        log_cmd "iptables -t mangle -A POSTROUTING -o ${wifi_if} -p udp --sport ${WQOS_PORT_VOICE} -j DSCP --set-dscp ${WQOS_DSCP_VOICE}"
        iptables -t mangle -A POSTROUTING -o "${wifi_if}" -p udp --sport "${WQOS_PORT_VOICE}" -j DSCP --set-dscp "${WQOS_DSCP_VOICE}" 2>/dev/null || true
        
        log_cmd "iptables -t mangle -A POSTROUTING -o ${wifi_if} -p udp --dport ${WQOS_PORT_VIDEO} -j DSCP --set-dscp ${WQOS_DSCP_VIDEO}"
        iptables -t mangle -A POSTROUTING -o "${wifi_if}" -p udp --dport "${WQOS_PORT_VIDEO}" -j DSCP --set-dscp "${WQOS_DSCP_VIDEO}" 2>/dev/null || true
        
        log_cmd "iptables -t mangle -A POSTROUTING -o ${wifi_if} -p udp --sport ${WQOS_PORT_VIDEO} -j DSCP --set-dscp ${WQOS_DSCP_VIDEO}"
        iptables -t mangle -A POSTROUTING -o "${wifi_if}" -p udp --sport "${WQOS_PORT_VIDEO}" -j DSCP --set-dscp "${WQOS_DSCP_VIDEO}" 2>/dev/null || true
        
        CLEANUP_IPTABLES_MANGLE="iptables -t mangle -D POSTROUTING -o ${wifi_if} -p udp --dport ${WQOS_PORT_VOICE} -j DSCP --set-dscp ${WQOS_DSCP_VOICE} 2>/dev/null || true; iptables -t mangle -D POSTROUTING -o ${wifi_if} -p udp --sport ${WQOS_PORT_VOICE} -j DSCP --set-dscp ${WQOS_DSCP_VOICE} 2>/dev/null || true; iptables -t mangle -D POSTROUTING -o ${wifi_if} -p udp --dport ${WQOS_PORT_VIDEO} -j DSCP --set-dscp ${WQOS_DSCP_VIDEO} 2>/dev/null || true; iptables -t mangle -D POSTROUTING -o ${wifi_if} -p udp --sport ${WQOS_PORT_VIDEO} -j DSCP --set-dscp ${WQOS_DSCP_VIDEO} 2>/dev/null || true"
    fi

    # Downlink DSCP marking in ns-wan (WAN -> Gateway -> Wi-Fi)
    log_cmd "ip netns exec ${WAN_NS:-ns-wan} iptables -t mangle -A POSTROUTING -p udp --dport ${WQOS_PORT_VOICE} -j DSCP --set-dscp ${WQOS_DSCP_VOICE}"
    ip netns exec "${WAN_NS:-ns-wan}" iptables -t mangle -A POSTROUTING -p udp --dport "${WQOS_PORT_VOICE}" -j DSCP --set-dscp "${WQOS_DSCP_VOICE}" 2>/dev/null || true
    
    log_cmd "ip netns exec ${WAN_NS:-ns-wan} iptables -t mangle -A POSTROUTING -p udp --sport ${WQOS_PORT_VOICE} -j DSCP --set-dscp ${WQOS_DSCP_VOICE}"
    ip netns exec "${WAN_NS:-ns-wan}" iptables -t mangle -A POSTROUTING -p udp --sport "${WQOS_PORT_VOICE}" -j DSCP --set-dscp "${WQOS_DSCP_VOICE}" 2>/dev/null || true
    
    log_cmd "ip netns exec ${WAN_NS:-ns-wan} iptables -t mangle -A POSTROUTING -p udp --dport ${WQOS_PORT_VIDEO} -j DSCP --set-dscp ${WQOS_DSCP_VIDEO}"
    ip netns exec "${WAN_NS:-ns-wan}" iptables -t mangle -A POSTROUTING -p udp --dport "${WQOS_PORT_VIDEO}" -j DSCP --set-dscp "${WQOS_DSCP_VIDEO}" 2>/dev/null || true
    
    log_cmd "ip netns exec ${WAN_NS:-ns-wan} iptables -t mangle -A POSTROUTING -p udp --sport ${WQOS_PORT_VIDEO} -j DSCP --set-dscp ${WQOS_DSCP_VIDEO}"
    ip netns exec "${WAN_NS:-ns-wan}" iptables -t mangle -A POSTROUTING -p udp --sport "${WQOS_PORT_VIDEO}" -j DSCP --set-dscp "${WQOS_DSCP_VIDEO}" 2>/dev/null || true
    
    CLEANUP_WAN_MANGLE="ip netns exec ${WAN_NS:-ns-wan} iptables -t mangle -D POSTROUTING -p udp --dport ${WQOS_PORT_VOICE} -j DSCP --set-dscp ${WQOS_DSCP_VOICE} 2>/dev/null || true; ip netns exec ${WAN_NS:-ns-wan} iptables -t mangle -D POSTROUTING -p udp --sport ${WQOS_PORT_VOICE} -j DSCP --set-dscp ${WQOS_DSCP_VOICE} 2>/dev/null || true; ip netns exec ${WAN_NS:-ns-wan} iptables -t mangle -D POSTROUTING -p udp --dport ${WQOS_PORT_VIDEO} -j DSCP --set-dscp ${WQOS_DSCP_VIDEO} 2>/dev/null || true; ip netns exec ${WAN_NS:-ns-wan} iptables -t mangle -D POSTROUTING -p udp --sport ${WQOS_PORT_VIDEO} -j DSCP --set-dscp ${WQOS_DSCP_VIDEO} 2>/dev/null || true"
}

# ------------------------------------------------------------------------------
# Modular Helper: Teardown QoS Mangle Rules & Routing
# ------------------------------------------------------------------------------
_wqos_teardown_network_qos() {
    if [[ -n "${CLEANUP_WIFI_ROUTE:-}" ]]; then
        ip route del ${CLEANUP_WIFI_ROUTE} 2>/dev/null || true
        CLEANUP_WIFI_ROUTE=""
    fi
    if [[ -n "${CLEANUP_IPTABLES_MANGLE:-}" ]]; then
        eval "${CLEANUP_IPTABLES_MANGLE}" 2>/dev/null || true
        CLEANUP_IPTABLES_MANGLE=""
    fi
    if [[ -n "${CLEANUP_WAN_MANGLE:-}" ]]; then
        eval "${CLEANUP_WAN_MANGLE}" 2>/dev/null || true
        CLEANUP_WAN_MANGLE=""
    fi
}

# ------------------------------------------------------------------------------
# [TC-WQOS-01] Wireless QoS: Main Phase Execution Function
# ------------------------------------------------------------------------------
run_phase_wireless_qos() {
    log_step "[TC-WQOS-01] Wireless QoS: Voice (EF) & Video (AF41) vs Best Effort Congestion"
    local tools_dir="${LAB_DIR}/tools"
    local wqos_json="${LOG_DIR}/wireless_qos_audit.json"

    # Validate input duration
    local duration="${CUSTOM_DURATION:-${WQOS_DEFAULT_DURATION}}"
    if [[ ! "${duration}" =~ ^[0-9]+$ || "${duration}" -le 0 ]]; then
        log_warn "Invalid duration '${duration}'. Defaulting to ${WQOS_DEFAULT_DURATION}s."
        duration="${WQOS_DEFAULT_DURATION}"
    fi

    # 1. Environment & Endpoint Resolution
    local WQOS_EFF_MODE="" WQOS_TARGET_IP="" WQOS_TARGET_DEV="" WQOS_WIFI_IF="" WQOS_WIFI_IP="" WQOS_IS_VIRTUAL=0
    _wqos_detect_endpoints "${tools_dir}"

    local eff_mode="${WQOS_EFF_MODE}"
    local eff_target_ip="${WQOS_TARGET_IP}"
    local eff_target_dev="${WQOS_TARGET_DEV}"
    local wifi_if="${WQOS_WIFI_IF}"
    local wifi_ip="${WQOS_WIFI_IP}"
    local station_mac="${DETECTED_WIFI_MAC:-}" target_bssid="${DETECTED_WIFI_BSSID:-}"
    if [[ "${eff_mode}" == "remote_only" ]]; then
        station_mac="${REMOTE_WIFI_MAC:-}"
        target_bssid="${REMOTE_WIFI_BSSID:-}"
    fi

    # Resolve Over-The-Air (OTA) 802.11 Monitor Sniffer configuration
    local ota_enabled=0
    local ota_cap_active=0
    local ota_pcap=""
    local rem_ota_pcap=""
    local ota_channel="" ota_freq="5180" ota_width="40" ota_center_freq="5190"
    local ota_bssid="${DETECTED_WIFI_BSSID:-}"

    if (( NO_CAPTURE == 0 )); then
        if [[ "${eff_mode}" == "virtual" ]]; then
            if [[ "${CUSTOM_OTA_CAPTURE:-}" == "1" ]]; then
                log_warn "OTA monitor capture requested but test is running in virtual mode (no RF airtime interface)."
            fi
            ota_enabled=0
        elif [[ "${CUSTOM_OTA_CAPTURE:-}" == "1" ]]; then
            if [[ "${eff_mode}" == "remote_only" ]]; then
                log_warn "Remote PC is acting as the active traffic endpoint; OTA monitor mode on the same remote radio is not supported simultaneously."
                ota_enabled=0
            else
                ota_enabled=1
            fi
        elif [[ "${CUSTOM_OTA_CAPTURE:-}" == "0" ]]; then
            ota_enabled=0
        elif [[ "${REMOTE_CLIENT_ENABLED:-0}" == "1" && "${eff_mode}" == "physical_single" ]]; then
            # Auto-enable OTA sniffer if secondary remote test PC is reachable
            if "${SCRIPT_DIR}/remote_client.sh" test >/dev/null 2>&1; then
                ota_enabled=1
            fi
        fi
    fi

    if (( ota_enabled == 1 )); then
        if [[ -n "${wifi_if}" ]]; then
            local live_info
            live_info="$(iw dev "${wifi_if}" info 2>/dev/null || true)"
            if [[ "${live_info}" =~ channel[[:space:]]+([0-9]+)[[:space:]]+\(([0-9]+)[[:space:]]+MHz\) ]]; then
                ota_channel="${BASH_REMATCH[1]}"
                ota_freq="${BASH_REMATCH[2]}"
            fi
            if [[ "${live_info}" =~ width:[[:space:]]*([0-9]+)[[:space:]]*MHz ]]; then
                ota_width="${BASH_REMATCH[1]}"
            fi
            if [[ "${live_info}" =~ center1:[[:space:]]*([0-9]+)[[:space:]]*MHz ]]; then
                ota_center_freq="${BASH_REMATCH[1]}"
            elif [[ "${ota_width}" == "20" ]]; then
                ota_center_freq="${ota_freq}"
            fi
            if [[ -z "${ota_bssid}" ]]; then
                local link_out
                link_out="$(iw dev "${wifi_if}" link 2>/dev/null || true)"
                if [[ "${link_out}" =~ Connected[[:space:]]+to[[:space:]]+([0-9a-fA-F:]{17}) ]]; then
                    ota_bssid="${BASH_REMATCH[1]}"
                fi
            fi
        fi
        log_info "  -> Remote OTA 802.11 Sniffer: ENABLED [${REMOTE_CLIENT_HOST}:mon0] (Ch ${ota_channel:-?} / ${ota_freq} MHz, Width: ${ota_width} MHz)"
    else
        log_info "  -> Remote OTA 802.11 Sniffer: DISABLED"
    fi

    # Resolve Best-Effort congestion protocol & domain
    local be_proto="${CUSTOM_BE_PROTO:-${WQOS_BE_PROTO:-${WQOS_DEFAULT_BE_PROTO}}}"
    be_proto="${be_proto,,}"
    if [[ "${be_proto}" != "tcp" && "${be_proto}" != "udp" ]]; then
        log_warn "Invalid Best Effort protocol '${be_proto}', defaulting to ${WQOS_DEFAULT_BE_PROTO}."
        be_proto="${WQOS_DEFAULT_BE_PROTO}"
    fi
    local cong_source="${CUSTOM_CONGESTION_SOURCE:-${WQOS_CONGESTION_SOURCE:-${WQOS_DEFAULT_CONGESTION_SOURCE}}}"

    # Resolve Best-Effort congestion target rate (adaptive to Wi-Fi PHY or explicit)
    local req_bitrate="${CUSTOM_BITRATE:-${CUSTOM_UNICAST_RATE:-${WQOS_BE_BITRATE:-${WQOS_DEFAULT_BE_BITRATE}}}}"
    local be_bitrate
    be_bitrate="$(_wqos_resolve_target_bitrate "${req_bitrate}" "${eff_target_dev}" "${cong_source}" "${be_proto}" "${eff_mode}")"
    local stream_rate
    stream_rate="$(_wqos_calc_stream_bitrate "${be_bitrate}" "${WQOS_DEFAULT_BE_PARALLEL}")"

    log_info "Wireless QoS Multi-Service Profile:"
    log_info "  -> Mode                    : [${eff_mode^^}]"
    log_info "  -> Service 1 (Voice)       : UDP port ${WQOS_PORT_VOICE} | DSCP ${WQOS_DSCP_VOICE} (0xb8 / EF)  -> WMM AC_VO (TID 6/7)"
    log_info "  -> Service 2 (Video)       : UDP port ${WQOS_PORT_VIDEO}  | DSCP ${WQOS_DSCP_VIDEO} (0x88 / AF41)-> WMM AC_VI (TID 4/5)"
    log_info "  -> Service 3 (Best Effort) : ${be_proto^^} port ${WQOS_PORT_BE}  | DSCP 0  (0x00 / CS0) -> WMM AC_BE (TID 0/3)"
    log_info "  -> Wi-Fi Target Client     : ${eff_target_dev} (${eff_target_ip})"
    local proto_desc="${be_proto^^}"
    if [[ "${cong_source}" == "wifi" ]]; then
        if [[ "${stream_rate}" == "0" ]]; then
            log_info "  -> Saturated Congestion    : Wi-Fi In-Band ${eff_target_dev} (unlimited ${proto_desc} iperf3, ${WQOS_DEFAULT_BE_PARALLEL} streams)"
        else
            log_info "  -> Saturated Congestion    : Wi-Fi In-Band ${eff_target_dev} (${be_bitrate} ${proto_desc} iperf3 [${WQOS_DEFAULT_BE_PARALLEL}x ${stream_rate}], adaptive to Wi-Fi PHY)"
        fi
    else
        if [[ "${stream_rate}" == "0" ]]; then
            log_info "  -> Saturated Congestion    : ns-pc (unlimited Wired LAN ${proto_desc} iperf3, ${WQOS_DEFAULT_BE_PARALLEL} streams)"
        else
            log_info "  -> Saturated Congestion    : ns-pc (${be_bitrate} Wired LAN ${proto_desc} iperf3 [${WQOS_DEFAULT_BE_PARALLEL}x ${stream_rate}])"
        fi
    fi
    log_info "  -> Upstream Server         : ns-wan (${WAN_SERVER_IP:-10.10.0.1})"
    log_info "  -> Test Duration           : ${duration}s"

    if (( DRY_RUN == 1 )); then
        if [[ "${eff_mode}" == "virtual" ]]; then
            log_warn "================================================================================"
            log_warn "  VIRTUAL MODE NOTICE: Hardware IEEE 802.11e Wireless QoS Cannot be Verified"
            log_warn "  - Test is executing over Linux network namespaces (ns-wlan5g) and veth pairs."
            log_warn "  - This validates IP DiffServ classification and software queuing only."
            log_warn "  - OTA 802.11e EDCA channel contention requires physical Wi-Fi station mode."
            log_warn "================================================================================"
            python3 "${tools_dir}/wireless_qos_audit.py" --audit-wmm --wifi-if "eth0" || true
        else
            log_info "[DRY-RUN] Auditing live AP WMM parameters without traffic injection..."
            python3 "${tools_dir}/wireless_qos_audit.py" --audit-wmm --wifi-if "${wifi_if:-wlp3s0}" || true
        fi
        if (( ota_enabled == 1 )); then
            log_info "[DRY-RUN] Remote PC (${REMOTE_CLIENT_HOST}) would sniff 802.11 frames on channel ${ota_channel:-auto} (${ota_freq} MHz)."
        fi
        log_info "[DRY-RUN] Would test concurrent Voice + Video under Best Effort saturation (${be_bitrate})."
        log_info "[DRY-RUN] Congestion injection domain: [${cong_source^^}]."
        log_info "[DRY-RUN] Acceptance: Voice/Video loss <= 1.0%, DSCP preservation >= 95%"
        return 0
    fi

    rm -f "${wqos_json}" "${LOG_DIR}/wireless_qos_client_audit.json" \
        "${STATE_DIR}/latest_ota_pcap.txt" "${STATE_DIR}/latest_wifi_pcap.txt" \
        "${STATE_DIR}/latest_wqos_context.json"

    # 2. Audit WMM EDCA Parameters & Field Values (IEEE 802.11e Specification)
    local wmm_json="${LOG_DIR:-${LAB_DIR}/logs}/wmm_field_values.json"
    local ap_edca_json="${LOG_DIR:-${LAB_DIR}/logs}/ap_edca.json"
    
    rm -f "${ap_edca_json}" "${wmm_json}"
    if [[ "${DUT_COLLECTOR_ENABLED:-0}" == "1" ]]; then
        log_info "Extracting AP EDCA parameters via DUT Collector..."
        "${SCRIPT_DIR}/dut_collector.sh" wmm --bssid "${target_bssid}" --out "${ap_edca_json}" >/dev/null 2>&1 || true
    fi

    if [[ "${eff_mode}" == "virtual" ]]; then
        log_warn "================================================================================"
        log_warn "  VIRTUAL MODE NOTICE: Hardware IEEE 802.11e Wireless QoS Cannot be Verified"
        log_warn "  - Test is executing over Linux network namespaces (ns-wlan5g) and veth pairs."
        log_warn "  - This validates IP DiffServ classification and software queuing only."
        log_warn "  - OTA 802.11e EDCA channel contention requires physical Wi-Fi station mode."
        log_warn "================================================================================"
        local wqos_cmd=(python3 "${tools_dir}/wireless_qos_audit.py" --audit-wmm --wifi-if "eth0" --wmm-json "${wmm_json}" --quiet)
        if [[ -f "${ap_edca_json}" ]]; then wqos_cmd+=(--ap-edca-json "${ap_edca_json}"); fi
        "${wqos_cmd[@]}" || true
    elif [[ "${eff_mode}" == "remote_only" ]]; then
        log_info "Remote station EDCA requires OTA evidence; local adapter is not the remote station."
    else
        log_step "Fetching WMM EDCA Parameters & Field Values (IEEE 802.11e Specification)"
        local wqos_cmd=(python3 "${tools_dir}/wireless_qos_audit.py" --audit-wmm --wifi-if "${wifi_if:-wlp3s0}" --wmm-json "${wmm_json}" --quiet)
        if [[ -f "${ap_edca_json}" ]]; then wqos_cmd+=(--ap-edca-json "${ap_edca_json}"); fi
        "${wqos_cmd[@]}" || true
    fi
    if [[ -f "${wmm_json}" && -n "${SCENARIO_TMP_DIR:-}" ]]; then
        cp -f "${wmm_json}" "${SCENARIO_TMP_DIR}/wmm_field_values.json" 2>/dev/null || true
    fi

    # 3. Network Routing & Mangle Preparation
    _wqos_setup_network_qos "${eff_mode}" "${wifi_if}" "${wifi_ip}"

    # 4. Start Dedicated Wi-Fi & OTA Monitor Captures
    local ts_wqos
    ts_wqos="$(date +%Y%m%d_%H%M%S)"
    local run_id="tc_wqos_01_${ts_wqos}_$$"
    local run_dir="${LOG_DIR}/${run_id}"
    mkdir -p "${run_dir}"
    log_info "Wireless QoS run ID: ${run_id} | Evidence: ${run_dir}"
    local wifi_pcap="${CAPTURE_DIR}/tc_wqos_01_${ts_wqos}_wifi.pcap"
    ota_pcap="${CAPTURE_DIR}/tc_wqos_01_${ts_wqos}_ota.pcap"
    local wifi_cap_pid=""
    local remote_cap_active=0

    if (( NO_CAPTURE == 0 && DRY_RUN == 0 )); then
        local wqos_bpf="udp port ${WQOS_PORT_VOICE} or udp port ${WQOS_PORT_VIDEO} or tcp port ${WQOS_PORT_BE} or udp port ${WQOS_PORT_BE}"
        if [[ "${eff_mode}" == "remote_only" ]]; then
            local rem_dir="${REMOTE_CLIENT_DIR:-/home/network/workspace/gateway_perf_lab}"
            local rem_wifi_pcap="${rem_dir}/captures/tc_wqos_01_${ts_wqos}_wifi.pcap"
            log_info "  -> Remote Wi-Fi capture :"
            log_info "     * Remote Host Endpoint : [${REMOTE_CLIENT_HOST}:${eff_target_dev}]"
            log_info "     * Remote PC Capture    : ${rem_wifi_pcap}"
            log_info "     * Local PC Sync Path   : ${wifi_pcap}"
            "${SCRIPT_DIR}/remote_client.sh" start-capture "${eff_target_dev}" "${wqos_bpf}" "${rem_wifi_pcap}" "${CAPTURE_SNAPLEN:-96}" >/dev/null 2>&1 || true
            remote_cap_active=1
        elif [[ "${eff_mode}" == "physical_single" ]] && [[ -n "${wifi_if}" ]]; then
            log_info "  -> Wi-Fi packet capture : [${wifi_if}] => ${wifi_pcap} (snaplen: ${CAPTURE_SNAPLEN:-96}B)"
            tcpdump -ni "${wifi_if}" -s "${CAPTURE_SNAPLEN:-96}" -U -w "${wifi_pcap}" ${wqos_bpf} >/dev/null 2>&1 &
            wifi_cap_pid=$!
            ACTIVE_BG_PIDS+=("${wifi_cap_pid}")
            echo "${wifi_pcap}" > "${STATE_DIR}/latest_wifi_pcap.txt"
        elif ns_exists "${WLAN5G_NS:-ns-wlan5g}"; then
            log_info "  -> Virtual Wi-Fi capture : [ns-wlan5g:eth0] => ${wifi_pcap}"
            ip netns exec "${WLAN5G_NS:-ns-wlan5g}" tcpdump -ni eth0 -s "${CAPTURE_SNAPLEN:-96}" -U -w "${wifi_pcap}" ${wqos_bpf} >/dev/null 2>&1 &
            wifi_cap_pid=$!
            ACTIVE_BG_PIDS+=("${wifi_cap_pid}")
            echo "${wifi_pcap}" > "${STATE_DIR}/latest_wifi_pcap.txt"
        fi

        # Start Remote Over-The-Air 802.11 Monitor Capture
        if (( ota_enabled == 1 )); then
            local rem_dir="${REMOTE_CLIENT_DIR:-/home/network/workspace/gateway_perf_lab}"
            rem_ota_pcap="${rem_dir}/captures/tc_wqos_01_${ts_wqos}_ota.pcap"
            log_info "  -> Remote OTA Sniffer   : [${REMOTE_CLIENT_HOST}:mon0] => ${ota_pcap}"
            log_info "     * Sniffer Tuning     : Ch ${ota_channel:-?} (${ota_freq} MHz, Width: ${ota_width} MHz${ota_center_freq:+, Center: ${ota_center_freq} MHz})"
            local -a ota_start_args=(
                start-ota-monitor
                --freq "${ota_freq}"
                --width "${ota_width}"
                ${ota_center_freq:+--center-freq "${ota_center_freq}"}
                --pcap "${rem_ota_pcap}"
            )
            if [[ -n "${ota_bssid}" ]]; then
                ota_start_args+=(--bssid "${ota_bssid}")
            fi
            "${SCRIPT_DIR}/remote_client.sh" "${ota_start_args[@]}" >/dev/null 2>&1 || true
            ota_cap_active=1
        fi
    fi

    # 4. Start Background Servers in ns-wan
    log_info "Starting upstream servers in ns-wan..."
    log_cmd "ip netns exec ${WAN_NS:-ns-wan} pkill -TERM -x iperf3 2>/dev/null || true"
    ip netns exec "${WAN_NS:-ns-wan}" pkill -TERM -x iperf3 2>/dev/null || true
    sleep 0.2
    log_cmd "ip netns exec ${WAN_NS:-ns-wan} iperf3 -s -p ${WQOS_PORT_BE} -D >/dev/null 2>&1"
    ip netns exec "${WAN_NS:-ns-wan}" iperf3 -s -p "${WQOS_PORT_BE}" -D >/dev/null 2>&1
    sleep 0.3

    local voice_srv_pid=""
    log_cmd "ip netns exec ${WAN_NS:-ns-wan} ${tools_dir}/voip_call_simulator.py server --ports ${WQOS_PORT_VOICE} --dscp ${WQOS_DSCP_VOICE} --duration $(( duration + 40 ))"
    ip netns exec "${WAN_NS:-ns-wan}" "${tools_dir}/voip_call_simulator.py" server \
        --ports "${WQOS_PORT_VOICE}" --dscp "${WQOS_DSCP_VOICE}" --duration "$(( duration + 40 ))" >/dev/null 2>&1 &
    voice_srv_pid=$!
    ACTIVE_BG_PIDS+=("${voice_srv_pid}")

    local video_srv_pid=""
    log_cmd "ip netns exec ${WAN_NS:-ns-wan} ${tools_dir}/vod_stream_tester.py server --dest-ip ${eff_target_ip} --dest-port ${WQOS_PORT_VIDEO} --bind-port ${WQOS_PORT_VIDEO} --wait-handshake --base-bitrate-mbps 20.0 --dscp ${WQOS_DSCP_VIDEO} --duration $(( duration + 1 ))"
    ip netns exec "${WAN_NS:-ns-wan}" "${tools_dir}/vod_stream_tester.py" server \
        --dest-ip "${eff_target_ip}" --dest-port "${WQOS_PORT_VIDEO}" --bind-port "${WQOS_PORT_VIDEO}" \
        --wait-handshake --handshake-timeout 40 --base-bitrate-mbps 20.0 \
        --dscp "${WQOS_DSCP_VIDEO}" --duration "$(( duration + 1 ))" >/dev/null 2>&1 &
    video_srv_pid=$!
    ACTIVE_BG_PIDS+=("${video_srv_pid}")
    sleep 0.5

    # 6. Inject Heavy Best-Effort Congestion Traffic
    local be_out="${SCENARIO_TMP_DIR}/wqos_iperf_be.json"
    # Keep BE active through client startup, measurement and final receive grace.
    local be_duration=$(( duration + 10 ))
    if [[ "${eff_mode}" == "remote_only" ]]; then be_duration=$(( duration + 30 )); fi
    local -a be_iperf_cmd=(
        iperf3
        -c "${WAN_SERVER_IP:-10.10.0.1}"
        -p "${WQOS_PORT_BE}"
        -t "${be_duration}"
        -P "${WQOS_DEFAULT_BE_PARALLEL}"
    )
    if [[ "${be_proto}" == "udp" ]]; then
        be_iperf_cmd+=("-u" "-l" "1470")
    fi
    be_iperf_cmd+=("-b" "${stream_rate}" "--dscp" "0")
    # Stress AP downstream WMM queues by default using Downlink (-R)
    if [[ "${WQOS_BE_DIRECTION:-${WQOS_DEFAULT_BE_DIRECTION}}" == "downlink" ]]; then
        be_iperf_cmd+=("-R")
    fi
    be_iperf_cmd+=("-J")

    if [[ "${cong_source}" == "wifi" ]]; then
        if [[ "${eff_mode}" == "remote_only" ]]; then
            be_iperf_cmd+=("-B" "${eff_target_ip}")
            log_cmd "ssh ${REMOTE_CLIENT_HOST} '${be_iperf_cmd[*]} > /tmp/wqos_iperf_be.json'"
            "${SCRIPT_DIR}/remote_client.sh" exec "${be_iperf_cmd[@]} > /tmp/wqos_iperf_be.json" > "${run_dir}/be_remote.log" 2>&1 &
        elif [[ "${eff_mode}" == "physical_single" ]]; then
            be_iperf_cmd+=("-B" "${eff_target_ip}")
            log_cmd "${be_iperf_cmd[*]} > ${be_out}"
            "${be_iperf_cmd[@]}" > "${be_out}" 2> "${run_dir}/be_stderr.log" &
        else
            log_cmd "ip netns exec ${WLAN5G_NS:-ns-wlan5g} ${be_iperf_cmd[*]} > ${be_out}"
            ip netns exec "${WLAN5G_NS:-ns-wlan5g}" "${be_iperf_cmd[@]}" > "${be_out}" 2> "${run_dir}/be_stderr.log" &
        fi
    else
        log_cmd "ip netns exec ${PC_NS:-ns-pc} ${be_iperf_cmd[*]} > ${be_out}"
        ip netns exec "${PC_NS:-ns-pc}" "${be_iperf_cmd[@]}" > "${be_out}" 2> "${run_dir}/be_stderr.log" &
    fi

    local be_cli_pid=$!
    ACTIVE_BG_PIDS+=("${be_cli_pid}")
    local traffic_error=""
    sleep 2
    if ! kill -0 "${be_cli_pid}" 2>/dev/null; then
        log_warn "Best Effort client stopped during warm-up; result will be INVALID."
        traffic_error="Best Effort stopped during warm-up"
    fi

    # 5. Start Clients on Wi-Fi Endpoint
    log_info "Starting concurrent clients on Wi-Fi endpoint (${eff_target_ip})..."
    local voice_cli_pid=""
    local video_cli_pid=""

    if [[ "${eff_mode}" == "remote_only" ]]; then
        log_cmd "ssh ${REMOTE_CLIENT_HOST} '${SCRIPT_DIR}/remote_client.sh run-wireless-qos --server-ip ${WAN_SERVER_IP:-10.10.0.1} --duration ${duration} --voice-dscp ${WQOS_DSCP_VOICE} --video-dscp ${WQOS_DSCP_VIDEO}'"
        "${SCRIPT_DIR}/remote_client.sh" run-wireless-qos \
            --server-ip "${WAN_SERVER_IP:-10.10.0.1}" \
            --duration "${duration}" \
            --voice-dscp "${WQOS_DSCP_VOICE}" \
            --video-dscp "${WQOS_DSCP_VIDEO}" || true
        sleep 0.8
        local rem_alive
        rem_alive="$("${SCRIPT_DIR}/remote_client.sh" is-wireless-qos-running 2>/dev/null || echo 0)"
        log_info "Remote Wireless QoS services verified: ${rem_alive}/2 active on remote client."
        if [[ "${rem_alive}" != "2" ]]; then traffic_error="Remote clients failed to start"; fi
    elif [[ "${eff_mode}" == "physical_single" ]]; then
        log_cmd "ip netns exec ${WAN_NS:-ns-wan} ${tools_dir}/vod_stream_tester.py client --bind-ip ${eff_target_ip} --bind-port ${WQOS_PORT_VIDEO} --server-ip ${WAN_SERVER_IP:-10.10.0.1} --server-port ${WQOS_PORT_VIDEO} --dscp ${WQOS_DSCP_VIDEO} --duration ${duration} --min-throughput-mbps 0 --max-loss-pct 1.0 --output-json ${SCENARIO_TMP_DIR}/wqos_vod.json"
        "${tools_dir}/vod_stream_tester.py" client \
            --bind-ip "${eff_target_ip}" --bind-port "${WQOS_PORT_VIDEO}" --server-ip "${WAN_SERVER_IP:-10.10.0.1}" \
            --server-port "${WQOS_PORT_VIDEO}" --dscp "${WQOS_DSCP_VIDEO}" --duration "${duration}" \
            --min-throughput-mbps 0 --max-loss-pct 1.0 \
            --output-json "${SCENARIO_TMP_DIR}/wqos_vod.json" >/dev/null 2>&1 &
        video_cli_pid=$!
        ACTIVE_BG_PIDS+=("${video_cli_pid}")

        log_cmd "ip netns exec ${WAN_NS:-ns-wan} ${tools_dir}/voip_call_simulator.py client --server-ip ${WAN_SERVER_IP:-10.10.0.1} --server-port ${WQOS_PORT_VOICE} --bind-ip ${eff_target_ip} --bind-port ${WQOS_PORT_VOICE} --dscp ${WQOS_DSCP_VOICE} --duration ${duration} --phone-id wqos-voice --output-json ${SCENARIO_TMP_DIR}/wqos_voice.json"
        "${tools_dir}/voip_call_simulator.py" client \
            --server-ip "${WAN_SERVER_IP:-10.10.0.1}" --server-port "${WQOS_PORT_VOICE}" \
            --bind-ip "${eff_target_ip}" --bind-port "${WQOS_PORT_VOICE}" --dscp "${WQOS_DSCP_VOICE}" \
            --duration "${duration}" --phone-id "wqos-voice" \
            --output-json "${SCENARIO_TMP_DIR}/wqos_voice.json" >/dev/null 2>&1 &
        voice_cli_pid=$!
        ACTIVE_BG_PIDS+=("${voice_cli_pid}")
    else
        log_cmd "ip netns exec ${WLAN5G_NS:-ns-wlan5g} ${tools_dir}/vod_stream_tester.py client --bind-ip ${eff_target_ip} --bind-port ${WQOS_PORT_VIDEO} --server-ip ${WAN_SERVER_IP:-10.10.0.1} --server-port ${WQOS_PORT_VIDEO} --dscp ${WQOS_DSCP_VIDEO} --duration ${duration} --min-throughput-mbps 0 --max-loss-pct 1.0 --output-json ${SCENARIO_TMP_DIR}/wqos_vod.json"
        ip netns exec "${WLAN5G_NS:-ns-wlan5g}" "${tools_dir}/vod_stream_tester.py" client \
            --bind-ip "${eff_target_ip}" --bind-port "${WQOS_PORT_VIDEO}" --server-ip "${WAN_SERVER_IP:-10.10.0.1}" \
            --server-port "${WQOS_PORT_VIDEO}" --dscp "${WQOS_DSCP_VIDEO}" --duration "${duration}" \
            --min-throughput-mbps 0 --max-loss-pct 1.0 \
            --output-json "${SCENARIO_TMP_DIR}/wqos_vod.json" >/dev/null 2>&1 &
        video_cli_pid=$!
        ACTIVE_BG_PIDS+=("${video_cli_pid}")

        log_cmd "ip netns exec ${WLAN5G_NS:-ns-wlan5g} ${tools_dir}/voip_call_simulator.py client --server-ip ${WAN_SERVER_IP:-10.10.0.1} --server-port ${WQOS_PORT_VOICE} --bind-ip ${eff_target_ip} --bind-port ${WQOS_PORT_VOICE} --dscp ${WQOS_DSCP_VOICE} --duration ${duration} --phone-id wqos-voice --output-json ${SCENARIO_TMP_DIR}/wqos_voice.json"
        ip netns exec "${WLAN5G_NS:-ns-wlan5g}" "${tools_dir}/voip_call_simulator.py" client \
            --server-ip "${WAN_SERVER_IP:-10.10.0.1}" --server-port "${WQOS_PORT_VOICE}" \
            --bind-ip "${eff_target_ip}" --bind-port "${WQOS_PORT_VOICE}" --dscp "${WQOS_DSCP_VOICE}" \
            --duration "${duration}" --phone-id "wqos-voice" \
            --output-json "${SCENARIO_TMP_DIR}/wqos_voice.json" >/dev/null 2>&1 &
        voice_cli_pid=$!
        ACTIVE_BG_PIDS+=("${voice_cli_pid}")
    fi

    log_info "Voice and Video clients launched under Best Effort load; evidence will verify overlap."

    if [[ "${eff_mode}" != "remote_only" ]]; then
        if [[ -n "${video_cli_pid}" ]]; then
            # A completed quality failure is evaluated from JSON; only startup
            # failures with no result are invalid traffic execution.
            wait "${video_cli_pid}" || true
            if [[ ! -s "${SCENARIO_TMP_DIR}/wqos_vod.json" ]]; then traffic_error="Video client failed to produce metrics"; fi
        fi
        if [[ -n "${voice_cli_pid}" ]]; then
            wait "${voice_cli_pid}" || traffic_error="Voice client failed"
        fi
    fi

    # Wait for the load generator to flush its final JSON before retrieving evidence.
    local be_exit=0
    wait "${be_cli_pid}" || be_exit=$?
    if (( be_exit != 0 )); then
        log_warn "Best Effort generator failed (exit ${be_exit})."
        traffic_error="Best Effort generator failed (exit ${be_exit})"
    fi
    if [[ "${eff_mode}" == "remote_only" ]]; then
        "${SCRIPT_DIR}/remote_client.sh" fetch-capture "/tmp/wqos_iperf_be.json" "${be_out}" >/dev/null 2>&1 || true
    fi

    # 7. Escalated Process Termination (TERM -> KILL)
    _wqos_terminate_pids "${voice_cli_pid}" "${video_cli_pid}" "${voice_srv_pid}" "${video_srv_pid}"
    ip netns exec "${WAN_NS:-ns-wan}" pkill -TERM -x iperf3 2>/dev/null || true

    if [[ -n "${wifi_cap_pid}" ]]; then
        _wqos_terminate_pids "${wifi_cap_pid}"
        chmod 0666 "${wifi_pcap}" 2>/dev/null || true
    fi

    # 8. Remote Capture, OTA Sniffer, & Metrics Retrieval
    if (( ota_cap_active == 1 )); then
        log_info "Stopping OTA monitor capture and retrieving over-the-air 802.11 PCAP..."
        "${SCRIPT_DIR}/remote_client.sh" stop-ota-monitor --pcap "${rem_ota_pcap}" --fetch "${ota_pcap}" >/dev/null 2>&1 || true
        if [[ -f "${ota_pcap}" && -s "${ota_pcap}" ]]; then
            chmod 0666 "${ota_pcap}" 2>/dev/null || true
            echo "${ota_pcap}" > "${STATE_DIR}/latest_ota_pcap.txt"
            local ota_size
            ota_size="$(ls -lh "${ota_pcap}" 2>/dev/null | awk '{print $5}')"
            log_pass "OTA 802.11 monitor capture retrieved successfully: ${ota_pcap} (${ota_size})"
        else
            log_warn "OTA monitor capture was not retrieved or is empty (${ota_pcap})."
            rm -f "${STATE_DIR}/latest_ota_pcap.txt" 2>/dev/null || true
        fi
    fi

    if (( remote_cap_active == 1 )); then
        log_info "Retrieving Wi-Fi packet capture from remote client..."
        local rem_dir="${REMOTE_CLIENT_DIR:-/home/network/workspace/gateway_perf_lab}"
        local rem_wifi_pcap="${rem_dir}/captures/tc_wqos_01_${ts_wqos}_wifi.pcap"
        "${SCRIPT_DIR}/remote_client.sh" stop-capture "${rem_wifi_pcap}" >/dev/null 2>&1 || true
        "${SCRIPT_DIR}/remote_client.sh" fetch-capture "${rem_wifi_pcap}" "${wifi_pcap}" >/dev/null 2>&1 || true
        chmod 0666 "${wifi_pcap}" 2>/dev/null || true
        echo "${wifi_pcap}" > "${STATE_DIR}/latest_wifi_pcap.txt"
    fi
    if [[ "${eff_mode}" == "remote_only" ]]; then
        # Metrics retrieval is independent of packet capture.
        "${SCRIPT_DIR}/remote_client.sh" fetch-capture "/tmp/wqos_vod.json" "${SCENARIO_TMP_DIR}/wqos_vod.json" >/dev/null 2>&1 || true
        "${SCRIPT_DIR}/remote_client.sh" fetch-capture "/tmp/wqos_voice.json" "${SCENARIO_TMP_DIR}/wqos_voice.json" >/dev/null 2>&1 || true
        "${SCRIPT_DIR}/remote_client.sh" stop-wireless-qos >/dev/null 2>&1 || true
    fi

    # 9. Teardown Network Routing & Mangle Rules
    _wqos_teardown_network_qos

    # 10. Metric Extraction & Evaluation
    local be_mbps
    be_mbps="$("${tools_dir}/metric_parser.py" sum-mbps "${be_out}" 2>/dev/null || echo "0.0")"
    log_info "Best-Effort Throughput Delivered during Congestion: ${be_mbps} Mbps"

    local voice_res="${SCENARIO_TMP_DIR}/wqos_voice.json"
    local vod_res="${SCENARIO_TMP_DIR}/wqos_vod.json"
    local client_audit="${run_dir}/client_audit.json"
    local -a eval_wqos_cmd=(
        "${tools_dir}/metric_parser.py" eval-wireless-qos
        "--mode" "${eff_mode}"
        "--voice-dscp" "${WQOS_DSCP_VOICE}"
        "--video-dscp" "${WQOS_DSCP_VIDEO}"
        "--be-proto" "${be_proto}"
        "--be-mbps" "${be_mbps}"
        "--traffic-error" "${traffic_error}"
        "--output" "${client_audit}"
    )
    for metric_file in "${voice_res}" "${vod_res}" "${be_out}"; do
        if [[ -f "${metric_file}" ]]; then cp "${metric_file}" "${run_dir}/"; fi
    done
    eval_wqos_cmd+=("--voice-json" "${run_dir}/wqos_voice.json" "--vod-json" "${run_dir}/wqos_vod.json"
                   "--be-json" "${run_dir}/wqos_iperf_be.json")

    # If capture was disabled, display client metrics audit table directly
    if (( NO_CAPTURE == 1 )); then
        "${eval_wqos_cmd[@]}" || true
    else
        # Keep client evidence separate from the later PCAP verdict.
        "${eval_wqos_cmd[@]}" --quiet || true
    fi
    cp "${client_audit}" "${LOG_DIR}/wireless_qos_client_audit.json"
    if (( NO_CAPTURE == 1 )); then cp "${client_audit}" "${wqos_json}"; fi
    python3 "${tools_dir}/wqos_measurement.py" \
        --output "${STATE_DIR}/latest_wqos_context.json" --run-id "${run_id}" \
        --mode "${eff_mode}" --duration "${duration}" --server-ip "${WAN_SERVER_IP:-10.10.0.1}" \
        --bssid "${target_bssid}" \
        --station-mac "${station_mac}" \
        --congestion-source "${cong_source}" --be-direction "${WQOS_BE_DIRECTION:-downlink}" \
        --congestion-evidence-json "${WQOS_CONGESTION_EVIDENCE_JSON:-}" \
        --audit-profile "${WQOS_AUDIT_PROFILE:-practical}" \
        --client-audit-json "${client_audit}"
    cp "${STATE_DIR}/latest_wqos_context.json" "${run_dir}/context.json"
}
