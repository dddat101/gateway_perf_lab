#!/usr/bin/env bash
# ==============================================================================
# NETWORK TEST LAB - PACKET CAPTURE MANAGER
# Supports Single & Dual-sided Concurrent Captures (WAN & LAN)
# Prioritizes tcpdump (-U -s 0) to avoid dumpcap privilege drop issues
# ==============================================================================

set -Eeuo pipefail
IFS=$'\n\t'

readonly SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
readonly SCRIPT_NAME="$(basename -- "${BASH_SOURCE[0]}")"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

usage() {
    cat <<'USAGE'
==================================================================
  Gateway Performance Lab - Packet Capture Manager
==================================================================

Description:
  Manages background packet captures (tcpdump / tshark) on WAN and LAN.
  Supports simultaneous dual-sided captures to prove 0% packet loss
  across the DUT with side-by-side WAN vs. LAN evidence.

Usage:
  sudo ./scripts/capture.sh start [target_ns] [target_if] [bpf_filter]
  sudo ./scripts/capture.sh start_dual <test_tag> [lan_ns] [bpf_filter]
  sudo ./scripts/capture.sh stop
  ./scripts/capture.sh compare <wan_pcap> <lan_pcap> [display_filter]
  ./scripts/capture.sh status
  ./scripts/capture.sh clean
  ./scripts/capture.sh -h | --help

Commands:
  start [ns] [if] [filter]         Start single background packet capture
  start_dual <tag> [lan_ns] [flt]  Start simultaneous dual captures on WAN and LAN
  stop                             Stop all active background captures and report audit
  compare <wan> <lan> [filter]     Compare packet counts between WAN and LAN PCAPs
  status                           Display capture status, active PIDs, and PCAP details
  clean                            Stop active capture and purge old files in captures/
  -h, --help                       Show this help message

Examples:
  sudo ./scripts/capture.sh start_dual tc_wr_02_multicast ns-stb "udp port 5003"
  sudo ./scripts/capture.sh start_dual tc_wr_01_unicast ns-pc "udp port 5002"
  sudo ./scripts/capture.sh stop
  ./scripts/capture.sh compare captures/wan.pcap captures/lan.pcap "ip.dst == 239.255.0.1"
==================================================================
USAGE
}

start_capture() {
    require_root
    stop_capture

    local target_ns="${DUT_NS:-ns-dut}"
    local target_if="any"
    local bpf_filter="${CAPTURE_FILTER:-}"
    local custom_pcap=""

    if [[ $# -gt 0 ]]; then
        if [[ "$1" == *.pcap || "$1" == *.pcapng || "$1" == */* ]]; then
            custom_pcap="$1"
            shift
            if [[ $# -gt 0 ]]; then target_ns="$1"; shift; fi
            if [[ $# -gt 0 ]]; then target_if="$1"; shift; fi
            if [[ $# -gt 0 ]]; then bpf_filter="$1"; shift; fi
        else
            target_ns="$1"; shift
            if [[ $# -gt 0 ]]; then target_if="$1"; shift; fi
            if [[ $# -gt 0 ]]; then bpf_filter="$1"; shift; fi
            if [[ $# -gt 0 ]]; then custom_pcap="$1"; shift; fi
        fi
    fi

    # Fallback namespace if target does not exist
    if ! ns_exists "${target_ns}"; then
        if ns_exists "${WAN_NS:-ns-wan}"; then
            target_ns="${WAN_NS:-ns-wan}"
            target_if="eth0"
        elif ns_exists "${PC_NS:-ns-pc}"; then
            target_ns="${PC_NS:-ns-pc}"
            target_if="eth0"
        fi
    fi

    local timestamp ext cap_tool pcap_file pid_file log_file
    timestamp="$(date +%Y%m%d_%H%M%S)"
    pid_file="${STATE_DIR}/capture.pid"
    log_file="${LOG_DIR}/capture_${timestamp}.log"

    if command -v "${TCPDUMP_BIN:-tcpdump}" >/dev/null 2>&1; then
        cap_tool="tcpdump"; ext="pcap"
    elif command -v "${TSHARK_BIN:-tshark}" >/dev/null 2>&1; then
        cap_tool="tshark"; ext="pcapng"
    else
        die "Neither tcpdump nor tshark is installed."
    fi

    if [[ -n "${custom_pcap}" ]]; then
        pcap_file="${custom_pcap}"
    else
        pcap_file="${CAPTURE_DIR}/capture_${timestamp}.${ext}"
    fi
    ensure_runtime_dirs

    local cap_cmd=()
    if [[ "${cap_tool}" == "tcpdump" ]]; then
        cap_cmd=("tcpdump" "-ni" "${target_if}" "-s" "0" "-U" "-w" "${pcap_file}")
        if [[ -n "${bpf_filter}" ]]; then
            local -a filter_parts=()
            read -r -a filter_parts <<< "${bpf_filter}"
            cap_cmd+=("${filter_parts[@]}")
        fi
    else
        cap_cmd=("tshark" "-i" "${target_if}" "-l" "-w" "${pcap_file}")
        if [[ -n "${bpf_filter}" ]]; then
            cap_cmd+=("-f" "${bpf_filter}")
        fi
    fi

    local exec_prefix=()
    if ns_exists "${target_ns}"; then
        exec_prefix=("ip" "netns" "exec" "${target_ns}")
    fi

    log_info "Starting packet capture on ${target_ns}:${target_if} (${cap_tool})..."
    "${exec_prefix[@]}" nohup "${cap_cmd[@]}" > "${log_file}" 2>&1 &
    local cap_pid=$!
    echo "${cap_pid}" > "${pid_file}"
    chmod 0666 "${pid_file}" "${log_file}" 2>/dev/null || true

    write_state_env "${STATE_DIR}/last_capture.env" \
        LAST_PCAP="${pcap_file}" \
        CAPTURE_TIMESTAMP="$(date -Iseconds)" \
        CAPTURE_TOOL="${cap_tool}" \
        CAPTURE_NS="${target_ns}" \
        CAPTURE_IF="${target_if}"
    echo "${pcap_file}" > "${STATE_DIR}/latest_capture.txt"

    sleep 0.5
    if ! is_pidfile_running "${pid_file}"; then
        log_error "Capture failed to start. Log output:"
        tail -n 20 "${log_file}" >&2 || true
        die "Failed to start capture process."
    fi

    log_success "Capture active: ${pcap_file} (PID: ${cap_pid})"
}

start_dual_capture() {
    require_root
    stop_capture

    local test_tag="${1:-perf_test}"
    local lan_ns="${2:-${PC_NS:-ns-pc}}"
    local bpf_filter="${3:-}"

    local timestamp ext cap_tool
    timestamp="$(date +%Y%m%d_%H%M%S)"

    if command -v "${TCPDUMP_BIN:-tcpdump}" >/dev/null 2>&1; then
        cap_tool="tcpdump"; ext="pcap"
    elif command -v "${TSHARK_BIN:-tshark}" >/dev/null 2>&1; then
        cap_tool="tshark"; ext="pcapng"
    else
        die "Neither tcpdump nor tshark is installed."
    fi

    ensure_runtime_dirs
    local pcap_wan="${CAPTURE_DIR}/${test_tag}_${timestamp}_wan.${ext}"
    local pcap_lan="${CAPTURE_DIR}/${test_tag}_${timestamp}_lan.${ext}"

    local wan_ns="${WAN_NS:-ns-wan}"
    local wan_if="eth0"
    if ! ns_exists "${wan_ns}"; then
        wan_if="${WAN_BRIDGE:-br-test-wan}"
    fi

    local lan_if="eth0"
    if ! ns_exists "${lan_ns}"; then
        lan_if="${LAN_BRIDGE:-br-test-lan}"
    fi

    local pid_wan_file="${STATE_DIR}/capture_wan.pid"
    local pid_lan_file="${STATE_DIR}/capture_lan.pid"
    local log_wan_file="${LOG_DIR}/capture_${test_tag}_${timestamp}_wan.log"
    local log_lan_file="${LOG_DIR}/capture_${test_tag}_${timestamp}_lan.log"

    # WAN capture process
    local exec_wan=()
    if ns_exists "${wan_ns}"; then
        exec_wan=("ip" "netns" "exec" "${wan_ns}")
    fi
    local cap_cmd_wan=("tcpdump" "-ni" "${wan_if}" "-s" "0" "-U" "-w" "${pcap_wan}")
    if [[ -n "${bpf_filter}" ]]; then
        local -a filter_parts_wan=()
        read -r -a filter_parts_wan <<< "${bpf_filter}"
        cap_cmd_wan+=("${filter_parts_wan[@]}")
    fi

    # LAN capture process
    local exec_lan=()
    if ns_exists "${lan_ns}"; then
        exec_lan=("ip" "netns" "exec" "${lan_ns}")
    fi
    local cap_cmd_lan=("tcpdump" "-ni" "${lan_if}" "-s" "0" "-U" "-w" "${pcap_lan}")
    if [[ -n "${bpf_filter}" ]]; then
        local -a filter_parts_lan=()
        read -r -a filter_parts_lan <<< "${bpf_filter}"
        cap_cmd_lan+=("${filter_parts_lan[@]}")
    fi

    log_info "Starting Dual-side Packet Capture [${test_tag}]:"
    log_info "  -> WAN Interface: [${wan_ns}:${wan_if}] => ${pcap_wan}"
    log_info "  -> LAN Interface: [${lan_ns}:${lan_if}] => ${pcap_lan}"

    "${exec_wan[@]}" nohup "${cap_cmd_wan[@]}" > "${log_wan_file}" 2>&1 &
    local pid_wan=$!
    echo "${pid_wan}" > "${pid_wan_file}"

    "${exec_lan[@]}" nohup "${cap_cmd_lan[@]}" > "${log_lan_file}" 2>&1 &
    local pid_lan=$!
    echo "${pid_lan}" > "${pid_lan_file}"

    chmod 0666 "${pid_wan_file}" "${pid_lan_file}" "${log_wan_file}" "${log_lan_file}" 2>/dev/null || true

    write_state_env "${STATE_DIR}/last_capture_dual.env" \
        LAST_TEST_TAG="${test_tag}" \
        LAST_PCAP_WAN="${pcap_wan}" \
        LAST_PCAP_LAN="${pcap_lan}" \
        LAST_LAN_NS="${lan_ns}" \
        CAPTURE_TIMESTAMP="$(date -Iseconds)" \
        CAPTURE_TOOL="${cap_tool}"
    echo "${pcap_wan}" > "${STATE_DIR}/latest_wan_pcap.txt"
    echo "${pcap_lan}" > "${STATE_DIR}/latest_lan_pcap.txt"
    echo "${pcap_wan}" > "${STATE_DIR}/latest_capture.txt"
    echo "${pid_wan}" > "${STATE_DIR}/capture.pid"

    sleep 0.5
    if ! is_pidfile_running "${pid_wan_file}" || ! is_pidfile_running "${pid_lan_file}"; then
        log_error "One or both dual captures failed to start. Logs:"
        tail -n 10 "${log_wan_file}" "${log_lan_file}" >&2 || true
        die "Dual capture initialization failed."
    fi

    log_success "Dual captures active: WAN (PID ${pid_wan}) | LAN (PID ${pid_lan})"
}

stop_capture() {
    require_root
    local pids_to_kill=()
    local files_to_clean=()

    # Collect running capture PIDs first so we can signal them simultaneously
    for pidfile in "${STATE_DIR}/capture_wan.pid" "${STATE_DIR}/capture_lan.pid" "${STATE_DIR}/capture.pid"; do
        if [[ -f "${pidfile}" ]]; then
            local pid
            pid="$(cat "${pidfile}" 2>/dev/null || true)"
            if [[ -n "${pid}" ]] && kill -0 "${pid}" 2>/dev/null; then
                local already=0
                for p in "${pids_to_kill[@]:-}"; do
                    if [[ "${p}" == "${pid}" ]]; then already=1; break; fi
                done
                if (( already == 0 )); then
                    pids_to_kill+=("${pid}")
                fi
            fi
            files_to_clean+=("${pidfile}")
        fi
    done

    if (( ${#pids_to_kill[@]} > 0 )); then
        # Send SIGTERM in parallel to close capture windows at the exact same instant
        log_info "Stopping capture processes simultaneously (PIDs: ${pids_to_kill[*]:-})..."
        kill -TERM "${pids_to_kill[@]}" 2>/dev/null || true
        for pid in "${pids_to_kill[@]}"; do
            local count=0
            while kill -0 "${pid}" 2>/dev/null && (( count < 30 )); do
                sleep 0.1
                count=$((count + 1))
            done
            if kill -0 "${pid}" 2>/dev/null; then
                kill -KILL "${pid}" 2>/dev/null || true
            fi
        done
        stopped_any=1
    fi

    for pf in "${files_to_clean[@]}"; do
        rm -f "${pf}" 2>/dev/null || true
    done

    # Ensure all PCAP files have non-root read permissions for Wireshark
    find "${CAPTURE_DIR}" -maxdepth 1 -name '*.pcap*' -type f -exec chmod 0666 {} + 2>/dev/null || true

    # Audit dual captures if active
    if [[ -f "${STATE_DIR}/last_capture_dual.env" ]]; then
        # shellcheck disable=SC1090
        source "${STATE_DIR}/last_capture_dual.env"
        if [[ -f "${LAST_PCAP_WAN:-}" && -f "${LAST_PCAP_LAN:-}" ]]; then
            compare_captures "${LAST_PCAP_WAN}" "${LAST_PCAP_LAN}" "${LAST_TEST_TAG:-test}"
        fi
        rm -f "${STATE_DIR}/last_capture_dual.env" 2>/dev/null || true
    fi
}

compare_captures() {
    local wan_pcap="${1:-}"
    local lan_pcap="${2:-}"
    local tag="AUDIT"
    local filter=""

    if [[ $# -ge 4 ]]; then
        tag="$3"
        filter="$4"
    elif [[ $# -eq 3 ]]; then
        if [[ "$3" =~ (==|port|ip|udp|tcp|icmp|len|arp|vlan) ]]; then
            filter="$3"
        else
            tag="$3"
        fi
    fi

    if [[ -z "${wan_pcap}" || ! -f "${wan_pcap}" ]]; then
        wan_pcap="$(cat "${STATE_DIR}/latest_wan_pcap.txt" 2>/dev/null || true)"
    fi
    if [[ -z "${lan_pcap}" || ! -f "${lan_pcap}" ]]; then
        lan_pcap="$(cat "${STATE_DIR}/latest_lan_pcap.txt" 2>/dev/null || true)"
    fi

    if [[ ! -f "${wan_pcap}" || ! -f "${lan_pcap}" ]]; then
        log_warn "Missing PCAP files for comparison: WAN='${wan_pcap}' LAN='${lan_pcap}'"
        return 0
    fi

    local size_wan size_lan
    size_wan="$(du -h "${wan_pcap}" 2>/dev/null | cut -f1 || echo "0")"
    size_lan="$(du -h "${lan_pcap}" 2>/dev/null | cut -f1 || echo "0")"

    printf '\n==================================================================\n'
    printf '  DUAL-SIDED CAPTURE EVIDENCE AUDIT: [%s]\n' "${tag^^}"
    printf '==================================================================\n'
    printf '  WAN Capture: %s (%s)\n' "${wan_pcap}" "${size_wan}"
    printf '  LAN Capture: %s (%s)\n' "${lan_pcap}" "${size_lan}"
    printf '  ------------------------------------------------------------------\n'

    if command -v "${TSHARK_BIN:-tshark}" >/dev/null 2>&1; then
        local tshark_args=()
        if [[ -n "${filter}" ]]; then
            tshark_args+=("-Y" "${filter}")
            printf '  Applied Filter            : %s\n' "${filter}"
        fi

        local count_wan count_lan
        count_wan="$( (cat "${wan_pcap}" 2>/dev/null | tshark -r - "${tshark_args[@]}" 2>/dev/null | wc -l) || echo "0" )"
        count_lan="$( (cat "${lan_pcap}" 2>/dev/null | tshark -r - "${tshark_args[@]}" 2>/dev/null | wc -l) || echo "0" )"

        printf '  WAN Side Traffic Recorded : %s frames\n' "${count_wan}"
        printf '  LAN Side Traffic Received : %s frames\n' "${count_lan}"

        if [[ "${count_wan}" =~ ^[0-9]+$ ]] && [[ "${count_lan}" =~ ^[0-9]+$ ]] && (( count_wan > 0 )); then
            local diff=$(( count_wan > count_lan ? count_wan - count_lan : count_lan - count_wan ))
            if (( diff == 0 )); then
                printf '  Verdict                   : \e[1;32m100%% MATCH (0%% Packet Loss across DUT)\e[0m\n'
            else
                printf '  Verdict                   : \e[1;33mDifference: %d frames\e[0m\n' "${diff}"
            fi
        fi
    else
        log_info "Install tshark to enable automated frame count comparison."
    fi
    printf '==================================================================\n\n'
}

show_status() {
    print_header "CAPTURE STATUS"
    local running=0

    if is_pidfile_running "${STATE_DIR}/capture_wan.pid" && is_pidfile_running "${STATE_DIR}/capture_lan.pid"; then
        printf 'Dual Capture: \e[1;32mRUNNING\e[0m (WAN PID: %s | LAN PID: %s)\n' \
            "$(cat "${STATE_DIR}/capture_wan.pid")" "$(cat "${STATE_DIR}/capture_lan.pid")"
        running=1
    elif is_pidfile_running "${STATE_DIR}/capture.pid"; then
        printf 'Single Capture: \e[1;32mRUNNING\e[0m (PID: %s)\n' "$(cat "${STATE_DIR}/capture.pid")"
        running=1
    else
        printf 'Status: \e[1;33mSTOPPED\e[0m\n'
    fi

    if [[ -f "${STATE_DIR}/last_capture_dual.env" ]]; then
        # shellcheck disable=SC1090
        source "${STATE_DIR}/last_capture_dual.env"
        printf '\nLatest Dual Capture:\n'
        printf '  Test Tag: %s\n' "${LAST_TEST_TAG:-<none>}"
        printf '  WAN File: %s\n' "${LAST_PCAP_WAN:-<none>}"
        printf '  LAN File: %s\n' "${LAST_PCAP_LAN:-<none>}"
    elif [[ -f "${STATE_DIR}/last_capture.env" ]]; then
        # shellcheck disable=SC1090
        source "${STATE_DIR}/last_capture.env"
        printf '\nLatest Single Capture: %s\n' "${LAST_PCAP:-<none>}"
    fi
}

main() {
    for arg in "$@"; do
        if [[ "${arg}" == "-h" || "${arg}" == "--help" ]]; then
            usage
            exit 0
        fi
    done

    load_config "${LAB_DIR:-$(pwd)}/config.env"
    case "${1:-status}" in
        start)       shift; start_capture "$@" ;;
        start_dual)  shift; start_dual_capture "$@" ;;
        stop)        stop_capture ;;
        compare)     shift; compare_captures "$@" ;;
        status)      show_status ;;
        clean)       stop_capture; clean_captures ;;
        *)           usage; exit 2 ;;
    esac
}

main "$@"
