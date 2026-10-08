#!/usr/bin/env bash
# ==============================================================================
# GATEWAY PERFORMANCE LAB - DEVICE UNDER TEST (DUT) COLLECTOR
# Connects to DUT over SSH to inspect, extract, and collect diagnostic artifacts
# ==============================================================================

set -Eeuo pipefail
IFS=$'\n\t'

readonly SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
readonly LAB_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd -P)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

CLI_HOST=""
CLI_USER=""
CLI_PORT=""
CLI_KEY=""
CLI_PASS=""
CLI_OUT_DIR=""
CLI_CATEGORY="all"
CLI_WIFI_IF=""
CLI_VERBOSE=0
SILENT=0

usage() {
    cat <<'EOF'
==================================================================
  Gateway Performance Lab - Device Under Test (DUT) Collector
==================================================================

Description:
  Automates SSH connectivity and diagnostic artifact collection from
  the physical or virtual Device Under Test (DUT / Gateway Router / AP).
  Captures system metrics, interface drop counters (ethtool / ip -s),
  QoS qdisc states (tc), firewall rules, WMM EDCA configurations,
  and kernel ring buffer logs for compliance reporting.

Usage:
  ./scripts/dut_collector.sh [COMMAND] [OPTIONS]

Commands:
  test, ping         Verify DUT reachability (ICMP ping + SSH authentication)
                     and probe supported toolchain (ip, tc, ethtool, wl, iw).
  exec <cmd...>      Execute arbitrary command on the DUT and print output.
  collect [opts]     Collect complete diagnostic artifact bundle from DUT
                     into a timestamped directory (artifacts/dut_<timestamp>).
  wmm [opts]         Extract AP-side WMM EDCA parameters from DUT (via wl or
                     hostapd) and generate ap_edca.json for QoS audit tools.
  stats <action>     Snapshot and compute interface traffic/drop counter deltas.
                     Actions: start (baseline), stop (after test), diff (delta).
  fetch <rem> [loc]  Download a file or log artifact from DUT to local path.
  push <loc> [rem]   Upload a file from local host to DUT.
  status             Query quick overview of DUT uptime, interfaces, and loads.

Options:
  -H, --host <host>  DUT IP or hostname (defaults to DUT_SSH_HOST or DUT_LAN_IP).
  -u, --user <user>  SSH username on DUT (default: root).
  -p, --port <port>  SSH port on DUT (default: 22).
  -i, --key <path>   Path to SSH private key for DUT authentication.
  -P, --pass <pass>  SSH password for DUT (utilizes sshpass if available).
  -o, --out-dir <dir>Output directory for artifact bundle (default: artifacts/dut_<ts>).
  -c, --category <c> Target category for collect: all, sys, net, qos, wifi, logs (default: all).
  -w, --wifi-if <if> Target Wi-Fi interface name on DUT (e.g. wl0, wlan0; default: auto).
  -v, --verbose      Show exact remote commands executed at each step.
  -s, --silent       Suppress non-essential progress logging.
  -h, --help         Show this help message and exit.

Examples:
  ./scripts/dut_collector.sh test
  ./scripts/dut_collector.sh exec "uptime; free -m"
  ./scripts/dut_collector.sh collect
  ./scripts/dut_collector.sh collect --category qos,net -o ./artifacts/tc_wqos_dut
  ./scripts/dut_collector.sh wmm --out state/ap_edca.json
  ./scripts/dut_collector.sh stats start
  ./scripts/dut_collector.sh stats diff
  ./scripts/dut_collector.sh fetch /var/log/messages ./logs/dut_messages.log
==================================================================
EOF
}

resolve_config() {
    load_config "${LAB_DIR}/config.env"

    TARGET_HOST="${CLI_HOST:-${DUT_SSH_HOST:-${DUT_LAN_IP:-192.168.1.1}}}"
    TARGET_USER="${CLI_USER:-${DUT_SSH_USER:-root}}"
    TARGET_PORT="${CLI_PORT:-${DUT_SSH_PORT:-22}}"
    TARGET_KEY="${CLI_KEY:-${DUT_SSH_KEY:-}}"
    TARGET_PASS="${CLI_PASS:-${DUT_SSH_PASS:-}}"
    SSH_OPTS_STR="${DUT_SSH_OPTS:--o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new}"

    # Resolve tilde (~) expansion under sudo or standard user
    if [[ "${TARGET_KEY}" =~ ^~(/.*)?$ ]]; then
        local base_home=""
        if [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != "root" ]]; then
            base_home="$(getent passwd "${SUDO_USER}" 2>/dev/null | cut -d: -f6 || true)"
            if [[ -z "${base_home}" ]]; then
                base_home="/home/${SUDO_USER}"
            fi
        else
            base_home="${HOME:-/root}"
        fi
        TARGET_KEY="${base_home}${BASH_REMATCH[1]}"
    fi

    # Switch .pub path to private key counterpart if specified
    if [[ "${TARGET_KEY}" == *.pub && -f "${TARGET_KEY%.pub}" ]]; then
        TARGET_KEY="${TARGET_KEY%.pub}"
    fi

    # Auto-detect default private key if key not explicitly given and password not provided
    if [[ -z "${TARGET_KEY}" && -z "${TARGET_PASS}" ]]; then
        local candidates=()
        if [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != "root" ]]; then
            local sudo_home
            sudo_home="$(getent passwd "${SUDO_USER}" 2>/dev/null | cut -d: -f6 || echo "/home/${SUDO_USER}")"
            candidates+=("${sudo_home}/.ssh/id_ed25519" "${sudo_home}/.ssh/id_rsa")
        fi
        candidates+=("${HOME:-/root}/.ssh/id_ed25519" "${HOME:-/root}/.ssh/id_rsa")
        for k in "${candidates[@]}"; do
            if [[ -f "${k}" ]]; then
                TARGET_KEY="${k}"
                break
            fi
        done
    fi

    if [[ -z "${TARGET_HOST}" ]]; then
        die "DUT host address not specified. Set DUT_SSH_HOST / DUT_LAN_IP in config.env or provide -H <ip>."
    fi

    # Defensive: Prevent hanging on interactive password prompt in automated test mode
    if [[ -z "${TARGET_PASS}" && ! "${SSH_OPTS_STR}" =~ BatchMode ]]; then
        SSH_OPTS_STR="${SSH_OPTS_STR} -o BatchMode=yes"
    fi
}

get_ssh_cmd() {
    local -a cmd=()
    if [[ -n "${TARGET_PASS}" ]] && command -v sshpass >/dev/null 2>&1; then
        cmd+=("sshpass" "-p" "${TARGET_PASS}")
    fi

    cmd+=("ssh")
    if [[ -n "${TARGET_PORT}" && "${TARGET_PORT}" != "22" ]]; then
        cmd+=("-p" "${TARGET_PORT}")
    fi
    if [[ -n "${TARGET_KEY}" && -f "${TARGET_KEY}" ]]; then
        cmd+=("-i" "${TARGET_KEY}")
    fi
    if [[ -n "${SSH_OPTS_STR}" ]]; then
        local -a parsed_opts=()
        IFS=" " read -r -a parsed_opts <<< "${SSH_OPTS_STR}"
        cmd+=("${parsed_opts[@]}")
    fi
    cmd+=("${TARGET_USER}@${TARGET_HOST}")
    printf '%s\0' "${cmd[@]}"
}

get_scp_cmd() {
    local -a cmd=()
    if [[ -n "${TARGET_PASS}" ]] && command -v sshpass >/dev/null 2>&1; then
        cmd+=("sshpass" "-p" "${TARGET_PASS}")
    fi

    cmd+=("scp")
    if [[ -n "${TARGET_PORT}" && "${TARGET_PORT}" != "22" ]]; then
        cmd+=("-P" "${TARGET_PORT}")
    fi
    if [[ -n "${TARGET_KEY}" && -f "${TARGET_KEY}" ]]; then
        cmd+=("-i" "${TARGET_KEY}")
    fi
    if [[ -n "${SSH_OPTS_STR}" ]]; then
        local -a parsed_opts=()
        IFS=" " read -r -a parsed_opts <<< "${SSH_OPTS_STR}"
        cmd+=("${parsed_opts[@]}")
    fi
    printf '%s\0' "${cmd[@]}"
}

dut_ssh_raw() {
    local -a ssh_base=()
    while IFS= read -r -d '' arg; do
        ssh_base+=("${arg}")
    done < <(get_ssh_cmd)

    local raw_script="$1"
    if (( CLI_VERBOSE == 1 )); then
        log_cmd "${ssh_base[*]} <<< [$(echo "${raw_script}" | wc -l) lines]"
    fi

    local start_marker="__DUT_RAW_START__"
    local end_marker="__DUT_RAW_END__"

    # Wrap script to break out of embedded router shells (e.g. vendor management CLI menus; "sh" drops to a POSIX shell),
    # set standard binary PATH, define has_cmd, and isolate payload output between delimiter markers.
    local wrapped_payload
    wrapped_payload="$(cat <<EOF
sh
export PATH=/bin:/sbin:/usr/bin:/usr/sbin:/home/bin:/home/scripts:/opt/scripts:\$PATH
has_cmd() { which "\$1" >/dev/null 2>&1 || type "\$1" >/dev/null 2>&1 || command -v "\$1" >/dev/null 2>&1; }
echo "${start_marker}"
${raw_script}
echo "${end_marker}"
exit
exit
EOF
)"

    printf '%s\n' "${wrapped_payload}" | "${ssh_base[@]}" 2>/dev/null | \
        sed -n "/${start_marker}/,/${end_marker}/{ /${start_marker}/d; /${end_marker}/d; p; }"
}

dut_ssh_exec() {
    local cmd_str="$*"
    if (( CLI_VERBOSE == 1 )); then
        log_cmd "dut_ssh_exec \"${cmd_str}\""
    fi
    dut_ssh_raw "${cmd_str}"
}

cmd_test() {
    print_header "DUT CONNECTIVITY & ENVIRONMENT PROBE"
    log_info "Target Endpoint : ${TARGET_USER}@${TARGET_HOST}:${TARGET_PORT}"

    # 1. ICMP Ping check
    log_info "Testing ICMP reachability to DUT (${TARGET_HOST})..."
    local ping_rtt=""
    if ping -c 1 -W 2 "${TARGET_HOST}" >/dev/null 2>&1; then
        ping_rtt="$(ping -c 2 -W 2 "${TARGET_HOST}" 2>/dev/null | awk -F'/' '/rtt/ {print $5}')"
        log_pass "DUT ICMP Ping OK (RTT: ${ping_rtt:-<1} ms)"
    else
        log_warn "DUT ICMP Ping FAILED (device may have ICMP echo disabled or link is down)."
    fi

    # 2. SSH Connection check
    log_info "Testing SSH authentication..."
    local probe_script='
        echo "AUTH:OK"
        echo "UNAME:$(uname -srm 2>/dev/null || echo "unknown")"
        echo "HOSTNAME:$(hostname 2>/dev/null || echo "unknown")"
        echo "UPTIME:$(uptime 2>/dev/null || echo "unknown")"

        # Check OS release
        os_name="Generic Linux"
        if [ -f /etc/openwrt_release ]; then
            os_name="OpenWrt"
        elif [ -f /etc/os-release ]; then
            os_name="$(grep "^PRETTY_NAME=" /etc/os-release 2>/dev/null | cut -d= -f2 | tr -d "\"")"
        fi
        echo "OS_NAME:${os_name}"

        # Probe networking & QoS tools
        for tool in ip tc ethtool brctl bridge iptables nft uci wl iw hostapd_cli; do
            if has_cmd "$tool"; then
                tool_path="$(which "$tool" 2>/dev/null || echo "$tool")"
                echo "TOOL:${tool}:AVAILABLE:${tool_path}"
            else
                echo "TOOL:${tool}:MISSING"
            fi
        done
    '

    local probe_output=""
    if ! probe_output="$(dut_ssh_raw "${probe_script}" 2>/dev/null)"; then
        log_error "SSH authentication to DUT failed!"
        log_error "Please verify DUT IP (${TARGET_HOST}), credentials, or SSH key configuration."
        if [[ -z "${TARGET_KEY}" && -z "${TARGET_PASS}" ]]; then
            log_info "Tip: Provide password via -P <password> or configure DUT_SSH_PASS in config.env."
        fi
        return 1
    fi

    local os_detected="" uname_str="" host_str=""
    local -a tools_avail=() tools_miss=()

    while IFS= read -r line; do
        if [[ "${line}" =~ ^UNAME:(.*)$ ]]; then
            uname_str="${BASH_REMATCH[1]}"
        elif [[ "${line}" =~ ^HOSTNAME:(.*)$ ]]; then
            host_str="${BASH_REMATCH[1]}"
        elif [[ "${line}" =~ ^OS_NAME:(.*)$ ]]; then
            os_detected="${BASH_REMATCH[1]}"
        elif [[ "${line}" =~ ^TOOL:([^:]+):AVAILABLE:(.*)$ ]]; then
            tools_avail+=("${BASH_REMATCH[1]}")
        elif [[ "${line}" =~ ^TOOL:([^:]+):MISSING$ ]]; then
            tools_miss+=("${BASH_REMATCH[1]}")
        fi
    done <<< "${probe_output}"

    local IFS=" "
    log_pass "SSH Connection OK. Target: ${host_str:-DUT} [${os_detected:-Linux}] (${uname_str})"
    log_info "Available Tools  : ${tools_avail[*]:-none}"
    if (( ${#tools_miss[@]} > 0 )); then
        log_info "Missing Tools    : ${tools_miss[*]}"
    fi
    printf '\n--- [DUT PROBE COMPLETE: READY] ---\n\n'
    return 0
}

cmd_status() {
    print_header "DUT RUNTIME STATUS OVERVIEW"
    log_info "Target Endpoint: ${TARGET_USER}@${TARGET_HOST}"

    local status_script='
        echo "=== [SYSTEM & UPTIME] ==="
        uptime 2>/dev/null || true
        free -m 2>/dev/null || free 2>/dev/null || true
        echo ""
        echo "=== [NETWORK INTERFACES] ==="
        ip -d link show 2>/dev/null | grep -E "^[0-9]+: " | awk "{print \$2}" | tr -d ":" || true
        echo ""
        echo "=== [WIRELESS SUBSYSTEM] ==="
        if has_cmd wl; then
            echo "Wireless Driver: wl CLI detected"
            for wlif in wl1 wl0 wl2; do
                if wl -i "$wlif" status >/dev/null 2>&1; then
                    echo "--- Interface: $wlif ---"
                    wl -i "$wlif" status 2>/dev/null | grep -E "SSID:|Channel:|Mode:|BSSID:|QBSS" || true
                fi
            done
        elif has_cmd iw; then
            echo "Wireless Driver: nl80211 (iw) detected"
            iw dev 2>/dev/null || true
        else
            echo "No standard wireless CLI (wl / iw) detected."
        fi
        echo ""
        echo "=== [QOS & TC QDISC] ==="
        if has_cmd tc; then
            tc -s qdisc show 2>/dev/null || true
        else
            echo "tc tool not found on DUT."
        fi
    '
    dut_ssh_raw "${status_script}"
}

cmd_exec() {
    if [[ $# -eq 0 ]]; then
        die "Subcommand 'exec' requires command arguments (e.g. ./scripts/dut_collector.sh exec 'uptime')."
    fi
    dut_ssh_exec "$@"
}

cmd_wmm() {
    local target_out="${STATE_DIR}/ap_edca.json"
    local specified_if="${CLI_WIFI_IF:-}"
    local want_bssid=""
    local want_band=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --out|-o)
                target_out="$2"
                shift 2
                ;;
            --iface|-i)
                specified_if="$2"
                shift 2
                ;;
            --bssid|-b)
                want_bssid="${2,,}"
                shift 2
                ;;
            --band)
                want_band="${2^^}"
                shift 2
                ;;
            *)
                shift
                ;;
        esac
    done

    # Input sanitization (values are injected into the remote shell script)
    if [[ -n "${specified_if}" && ! "${specified_if}" =~ ^[A-Za-z0-9._-]+$ ]]; then
        die "Invalid DUT Wi-Fi interface name: '${specified_if}'"
    fi
    if [[ -n "${want_bssid}" && ! "${want_bssid}" =~ ^([0-9a-f]{2}:){5}[0-9a-f]{2}$ ]]; then
        log_warn "Ignoring malformed BSSID filter: '${want_bssid}'"
        want_bssid=""
    fi
    local band_token=""
    case "${want_band}" in
        2.4G|2G|24G) band_token="2.4GHz" ;;
        5G)          band_token="5GHz" ;;
        6G)          band_token="6GHz" ;;
        ""|AUTO)     band_token="" ;;
        *)           log_warn "Ignoring unknown band filter: '${want_band}'" ;;
    esac

    print_header "QUERYING DUT AP-SIDE WMM EDCA PARAMETERS"
    log_info "Target Endpoint: ${TARGET_USER}@${TARGET_HOST}"
    log_info "Radio Selector : iface=${specified_if:-auto} bssid=${want_bssid:-any} band=${band_token:-any}"

    local wmm_extract_script
    wmm_extract_script="$(cat <<'REMOTE_EOF'
        sel_if="__SEL_IF__"
        want_bssid="__WANT_BSSID__"
        want_band="__WANT_BAND__"

        if has_cmd wl; then
            cands=""
            for c in wl0 wl1 wl2 wl3; do
                if wl -i "$c" status >/dev/null 2>&1; then cands="$cands $c"; fi
            done

            radio_bssid() {
                wl -i "$1" status 2>/dev/null | sed -n "s/.*BSSID: \([0-9A-Fa-f:]*\).*/\1/p" | sed -n 1p | tr "A-F" "a-f"
            }

            # Selection priority: explicit iface > BSSID match > band match > first active radio
            if [ -z "$sel_if" ] && [ -n "$want_bssid" ]; then
                for c in $cands; do
                    if [ "$(radio_bssid "$c")" = "$want_bssid" ]; then sel_if="$c"; echo "MATCH:bssid"; break; fi
                done
            fi
            if [ -z "$sel_if" ] && [ -n "$want_band" ]; then
                for c in $cands; do
                    if wl -i "$c" status 2>/dev/null | grep -q "Chanspec: ${want_band}"; then sel_if="$c"; echo "MATCH:band"; break; fi
                done
            fi
            if [ -z "$sel_if" ]; then
                for c in $cands; do sel_if="$c"; echo "MATCH:first_active"; break; done
            fi
            [ -z "$sel_if" ] && { echo "DRIVER:NO_ACTIVE_RADIO"; exit 0; }

            echo "DRIVER:WL_CLI"
            echo "INTERFACE:${sel_if}"
            echo "BSSID:$(radio_bssid "$sel_if")"
            echo "CHANSPEC:$(wl -i "$sel_if" status 2>/dev/null | sed -n "s/^[[:space:]]*Chanspec: //p" | sed -n 1p)"
            echo "--- AP_EDCA ---"
            wl -i "${sel_if}" wme_ac ap 2>/dev/null || true
            echo "--- STA_EDCA ---"
            wl -i "${sel_if}" wme_ac sta 2>/dev/null || true
            exit 0
        fi

        if has_cmd hostapd_cli; then
            echo "DRIVER:HOSTAPD_UNSUPPORTED"
            exit 0
        fi

        echo "DRIVER:UNKNOWN"
REMOTE_EOF
)"
    wmm_extract_script="${wmm_extract_script//__SEL_IF__/${specified_if}}"
    wmm_extract_script="${wmm_extract_script//__WANT_BSSID__/${want_bssid}}"
    wmm_extract_script="${wmm_extract_script//__WANT_BAND__/${band_token}}"

    local wmm_out
    wmm_out="$(dut_ssh_raw "${wmm_extract_script}" 2>/dev/null | tr -d '\r' || true)"

    local detected_driver="" detected_if="" detected_bssid="" detected_chanspec="" match_rule=""
    local -A edca=()
    local in_ap=0 cur_ac="" line

    while IFS= read -r line; do
        if [[ "${line}" =~ ^DRIVER:(.*)$ ]]; then
            detected_driver="${BASH_REMATCH[1]}"
        elif [[ "${line}" =~ ^INTERFACE:(.*)$ ]]; then
            detected_if="${BASH_REMATCH[1]}"
        elif [[ "${line}" =~ ^BSSID:(.*)$ ]]; then
            detected_bssid="${BASH_REMATCH[1]}"
        elif [[ "${line}" =~ ^CHANSPEC:(.*)$ ]]; then
            detected_chanspec="${BASH_REMATCH[1]}"
        elif [[ "${line}" =~ ^MATCH:(.*)$ ]]; then
            match_rule="${BASH_REMATCH[1]}"
        elif [[ "${line}" =~ ^---[[:space:]]*AP_EDCA ]]; then
            in_ap=1
        elif [[ "${line}" =~ ^---[[:space:]]*STA_EDCA ]]; then
            in_ap=0
        elif (( in_ap == 1 )); then
            # Verbose format:
            #   AC_VO: raw: ACI 0x61 ECW 0x32 TXOP 0x2f
            #          dec: aci 3 acm 0 aifsn 1 ecwmin 2 ecwmax 3 txop 0x2f
            #          eff: CWmin 3 CWmax 7 TXop 1504usec
            if [[ "${line}" =~ (AC_VO|AC_VI|AC_BE|AC_BK) ]]; then
                cur_ac="${BASH_REMATCH[1]}"
            fi
            [[ -z "${cur_ac}" ]] && continue
            if [[ "${line}" =~ aifsn[[:space:]]+([0-9]+) ]]; then
                edca["${cur_ac}_aifsn"]="${BASH_REMATCH[1]}"
            fi
            if [[ "${line}" =~ CWmin[[:space:]]+([0-9]+)[[:space:]]+CWmax[[:space:]]+([0-9]+)[[:space:]]+TXop[[:space:]]+([0-9]+)usec ]]; then
                edca["${cur_ac}_cwmin"]="${BASH_REMATCH[1]}"
                edca["${cur_ac}_cwmax"]="${BASH_REMATCH[2]}"
                edca["${cur_ac}_txop"]="${BASH_REMATCH[3]}"
            fi
        fi
    done <<< "${wmm_out}"

    # Strict validation: never emit synthetic/default values as DUT evidence
    local ac missing=()
    for ac in AC_VO AC_VI AC_BE AC_BK; do
        local k
        for k in aifsn cwmin cwmax txop; do
            [[ -n "${edca[${ac}_${k}]:-}" ]] || missing+=("${ac}.${k}")
        done
    done
    if [[ -z "${wmm_out}" ]]; then
        log_error "No response from DUT while querying WMM EDCA parameters."
        return 1
    fi
    if [[ "${detected_driver}" != "WL_CLI" ]]; then
        log_error "Unsupported or unavailable DUT wireless CLI (driver=${detected_driver:-none}); AP EDCA not exported."
        return 1
    fi
    if (( ${#missing[@]} > 0 )); then
        local IFS=" "
        log_error "Incomplete AP EDCA parse on ${detected_if}; missing fields: ${missing[*]}"
        return 1
    fi

    mkdir -p "$(dirname "${target_out}")" 2>/dev/null || true
    cat <<EOF > "${target_out}"
{
  "source": "DUT wl CLI [${detected_if}]",
  "dut_host": "${TARGET_HOST}",
  "interface": "${detected_if}",
  "bssid": "${detected_bssid}",
  "chanspec": "${detected_chanspec}",
  "selection_rule": "${match_rule:-explicit}",
  "collected_at": "$(date -u +'%Y-%m-%dT%H:%M:%SZ')",
  "AC_VO": {
    "aifsn": ${edca[AC_VO_aifsn]},
    "cwmin": ${edca[AC_VO_cwmin]},
    "cwmax": ${edca[AC_VO_cwmax]},
    "txop_limit_us": ${edca[AC_VO_txop]}
  },
  "AC_VI": {
    "aifsn": ${edca[AC_VI_aifsn]},
    "cwmin": ${edca[AC_VI_cwmin]},
    "cwmax": ${edca[AC_VI_cwmax]},
    "txop_limit_us": ${edca[AC_VI_txop]}
  },
  "AC_BE": {
    "aifsn": ${edca[AC_BE_aifsn]},
    "cwmin": ${edca[AC_BE_cwmin]},
    "cwmax": ${edca[AC_BE_cwmax]},
    "txop_limit_us": ${edca[AC_BE_txop]}
  },
  "AC_BK": {
    "aifsn": ${edca[AC_BK_aifsn]},
    "cwmin": ${edca[AC_BK_cwmin]},
    "cwmax": ${edca[AC_BK_cwmax]},
    "txop_limit_us": ${edca[AC_BK_txop]}
  }
}
EOF

    chmod 0666 "${target_out}" 2>/dev/null || true
    log_pass "AP-side WMM EDCA parameters saved to: ${target_out}"

    # Print summary table
    local sep='--------------------------------------------------------------------------------'
    printf '\n%s\n' "${sep}"
    printf '  DUT AP-SIDE EDCA PARAMETERS (%s, BSSID %s, %s)\n' "${detected_if}" "${detected_bssid:-?}" "${detected_chanspec:-?}"
    printf '%s\n' "${sep}"
    printf '%-18s %-8s %-8s %-8s %-18s\n' "ACCESS CATEGORY" "AIFSN" "CWmin" "CWmax" "TXOP (us / 32us)"
    printf '%s\n' "${sep}"
    local label
    for ac in AC_VO AC_VI AC_BE AC_BK; do
        case "${ac}" in
            AC_VO) label="Voice (AC_VO)" ;;
            AC_VI) label="Video (AC_VI)" ;;
            AC_BE) label="BestEff (AC_BE)" ;;
            AC_BK) label="Backgrd (AC_BK)" ;;
        esac
        printf '%-18s %-8s %-8s %-8s %-18s\n' "${label}" "${edca[${ac}_aifsn]}" "${edca[${ac}_cwmin]}" "${edca[${ac}_cwmax]}" \
            "${edca[${ac}_txop]} ($(( edca[${ac}_txop] / 32 )))"
    done
    printf '%s\n\n' "${sep}"
}

cmd_stats() {
    local action="${1:-diff}"
    local state_start="${STATE_DIR}/dut_stats_start.txt"
    local state_stop="${STATE_DIR}/dut_stats_stop.txt"

    mkdir -p "${STATE_DIR}" 2>/dev/null || true

    local stats_script='
        # Snapshot /proc/net/dev counters
        awk '\''NR > 2 {
            iface=$1; sub(":", "", iface);
            rx_b=$2; rx_p=$3; rx_err=$4; rx_drp=$5;
            tx_b=$10; tx_p=$11; tx_err=$12; tx_drp=$13;
            print iface, rx_p, rx_b, rx_drp, rx_err, tx_p, tx_b, tx_drp, tx_err;
        }'\'' /proc/net/dev 2>/dev/null || true
    '

    case "${action}" in
        start|baseline)
            print_header "RECORDING DUT INTERFACE COUNTERS (BASELINE)"
            dut_ssh_raw "${stats_script}" > "${state_start}"
            log_pass "DUT baseline counters recorded to: ${state_start}"
            ;;
        stop|snapshot)
            print_header "RECORDING DUT INTERFACE COUNTERS (AFTER TEST)"
            dut_ssh_raw "${stats_script}" > "${state_stop}"
            log_pass "DUT post-test counters recorded to: ${state_stop}"
            ;;
        diff|delta)
            if [[ ! -f "${state_start}" || ! -f "${state_stop}" ]]; then
                log_warn "Missing start or stop snapshot. Taking current snapshot to compare with baseline..."
                if [[ ! -f "${state_start}" ]]; then
                    die "No baseline found. Run './scripts/dut_collector.sh stats start' before running traffic."
                fi
                dut_ssh_raw "${stats_script}" > "${state_stop}"
            fi

            print_header "DUT INTERFACE TRAFFIC & DROP COUNTER DELTAS"
            printf '%-14s | %-12s | %-12s | %-10s | %-12s | %-12s | %-10s\n' \
                "INTERFACE" "RX PACKETS" "RX BYTES" "RX DROPS" "TX PACKETS" "TX BYTES" "TX DROPS"
            printf '%s\n' "--------------------------------------------------------------------------------------------------"

            while read -r iface rx_p1 rx_b1 rx_drp1 rx_err1 tx_p1 tx_b1 tx_drp1 tx_err1; do
                local stop_line
                stop_line="$(grep -E "^${iface} " "${state_stop}" || true)"
                if [[ -n "${stop_line}" ]]; then
                    read -r _ rx_p2 rx_b2 rx_drp2 rx_err2 tx_p2 tx_b2 tx_drp2 tx_err2 <<< "${stop_line}"
                    local d_rx_p=$(( rx_p2 - rx_p1 ))
                    local d_rx_b=$(( rx_b2 - rx_b1 ))
                    local d_rx_drp=$(( rx_drp2 - rx_drp1 ))
                    local d_tx_p=$(( tx_p2 - tx_p1 ))
                    local d_tx_b=$(( tx_b2 - tx_b1 ))
                    local d_tx_drp=$(( tx_drp2 - tx_drp1 ))

                    if (( d_rx_p > 0 || d_tx_p > 0 || d_rx_drp > 0 || d_tx_drp > 0 )); then
                        printf '%-14s | %-12d | %-12d | %-10d | %-12d | %-12d | %-10d\n' \
                            "${iface}" "${d_rx_p}" "${d_rx_b}" "${d_rx_drp}" "${d_tx_p}" "${d_tx_b}" "${d_tx_drp}"
                    fi
                fi
            done < "${state_start}"
            printf '\n'
            ;;
        *)
            die "Unknown stats action '${action}'. Supported: start, stop, diff."
            ;;
    esac
}

cmd_fetch() {
    local remote_src="${1:-/var/log/messages}"
    local local_dst="${2:-./logs/dut_artifact.log}"

    mkdir -p "$(dirname "${local_dst}")" 2>/dev/null || true
    log_info "Fetching ${TARGET_USER}@${TARGET_HOST}:${remote_src} -> ${local_dst}..."

    # Stream file via xxd hex encoding to avoid SCP banner / interactive prompt corruption
    dut_ssh_raw "xxd -p '${remote_src}' 2>/dev/null || cat '${remote_src}' 2>/dev/null" | xxd -r -p > "${local_dst}" 2>/dev/null || true
    if [[ ! -s "${local_dst}" ]]; then
        dut_ssh_raw "cat '${remote_src}' 2>/dev/null || true" > "${local_dst}"
    fi

    if [[ -s "${local_dst}" ]]; then
        chmod 0666 "${local_dst}" 2>/dev/null || true
        log_pass "Fetched successfully: ${local_dst} ($(ls -lh "${local_dst}" 2>/dev/null | awk '{print $5}'))"
    else
        log_warn "Failed to fetch remote file: ${remote_src}"
        return 1
    fi
}

cmd_push() {
    local local_src="${1:-}"
    local remote_dst="${2:-/tmp/}"

    if [[ -z "${local_src}" || ! -f "${local_src}" ]]; then
        die "Subcommand 'push' requires valid local source file: $1"
    fi

    log_info "Pushing ${local_src} -> ${TARGET_USER}@${TARGET_HOST}:${remote_dst}..."
    local hex_data
    hex_data="$(xxd -p "${local_src}")"
    dut_ssh_raw "printf '%s' '${hex_data}' | xxd -r -p > '${remote_dst}'"
    log_pass "Push completed."
}

cmd_collect() {
    local wmm_if_args=()
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -o|--out-dir) CLI_OUT_DIR="$2"; shift 2 ;;
            -c|--category) CLI_CATEGORY="$2"; shift 2 ;;
            --iface|-w|--wifi-if) wmm_if_args+=(--iface "$2"); shift 2 ;;
            --bssid) wmm_if_args+=(--bssid "$2"); shift 2 ;;
            --band) wmm_if_args+=(--band "$2"); shift 2 ;;
            *) shift ;;
        esac
    done

    local ts
    ts="$(date +%Y%m%d_%H%M%S)"
    local out_dir="${CLI_OUT_DIR:-${LAB_DIR}/artifacts/dut_${ts}}"
    mkdir -p "${out_dir}" 2>/dev/null || true

    print_header "COLLECTING DUT DIAGNOSTIC ARTIFACT BUNDLE"
    log_info "Target Endpoint : ${TARGET_USER}@${TARGET_HOST}"
    log_info "Output Bundle   : ${out_dir}"
    log_info "Scope Categories: ${CLI_CATEGORY}"

    local col_script='
        rm -rf /tmp/dut_artifacts && mkdir -p /tmp/dut_artifacts

        run_save() {
            fname="/tmp/dut_artifacts/$1"
            shift
            echo "=== [COMMAND: $*] ===" > "$fname"
            "$@" >> "$fname" 2>&1 || true
        }

        # 1. System Overview
        run_save dut_01_system.txt uname -a
        run_save dut_02_uptime.txt uptime
        run_save dut_03_memory.txt free -m
        run_save dut_04_cpuinfo.txt cat /proc/cpuinfo
        run_save dut_05_version.txt cat /proc/version

        # 2. Network & Interfaces
        run_save dut_06_ip_links.txt ip -d link show
        run_save dut_07_ip_addrs.txt ip addr show
        run_save dut_08_ip_routes.txt ip route show
        run_save dut_09_ip_routes6.txt ip -6 route show
        run_save dut_10_ip_neigh.txt ip neigh show
        run_save dut_11_arp_table.txt cat /proc/net/arp
        run_save dut_12_bridge_fdb.txt bridge fdb show
        run_save dut_13_bridge_link.txt bridge link show

        # 3. Drops & Statistics
        run_save dut_14_link_stats.txt ip -s link show
        run_save dut_15_proc_net_dev.txt cat /proc/net/dev

        # Ethtool hardware drop/pause inspection
        if has_cmd ethtool; then
            for iface in eth0 eth1 eth2 eth3 eth4 br0 wl0 wl1 wl2; do
                run_save "dut_16_ethtool_${iface}.txt" ethtool -S "$iface"
                run_save "dut_17_ethtool_drv_${iface}.txt" ethtool -i "$iface"
            done
        fi

        # 4. QoS & Traffic Control
        if has_cmd tc; then
            run_save dut_18_tc_qdisc.txt tc -s qdisc show
            run_save dut_19_tc_class.txt tc -s class show
            run_save dut_20_tc_filter.txt tc -s filter show
        fi
        if has_cmd iptables-save; then
            run_save dut_21_iptables_save.txt iptables-save
        fi
        if has_cmd iptables; then
            run_save dut_22_iptables_mangle.txt iptables -t mangle -nvL
            run_save dut_23_iptables_nat.txt iptables -t nat -nvL
        fi
        if has_cmd nft; then
            run_save dut_23_nft_ruleset.txt nft list ruleset
        fi

        # 5. Conntrack & Buffers
        if [ -f /proc/sys/net/netfilter/nf_conntrack_count ]; then
            run_save dut_24_conntrack_count.txt cat /proc/sys/net/netfilter/nf_conntrack_count
            run_save dut_25_conntrack_max.txt cat /proc/sys/net/netfilter/nf_conntrack_max
        fi
        run_save dut_26_sysctl_net.txt sysctl net

        # 6. Wireless Subsystem
        if has_cmd wl; then
            for wlif in wl0 wl1 wl2; do
                if wl -i "$wlif" status >/dev/null 2>&1; then
                    run_save "dut_27_${wlif}_status.txt" wl -i "$wlif" status
                    run_save "dut_28_${wlif}_assoclist.txt" wl -i "$wlif" assoclist
                    run_save "dut_29_${wlif}_counters.txt" wl -i "$wlif" counters
                    run_save "dut_30_${wlif}_wme_ap.txt" wl -i "$wlif" wme_ac ap
                    run_save "dut_31_${wlif}_wme_sta.txt" wl -i "$wlif" wme_ac sta
                fi
            done
        elif has_cmd iw; then
            run_save dut_27_iw_dev.txt iw dev
            run_save dut_28_iw_phy.txt iw phy
        fi

        # 7. Logs
        run_save dut_32_dmesg.log dmesg
        if has_cmd logread; then
            run_save dut_33_logread.log logread
        elif [ -f /var/log/messages ]; then
            run_save dut_33_messages.log cat /var/log/messages
        elif [ -f /tmp/log/messages ]; then
            run_save dut_33_messages.log cat /tmp/log/messages
        fi

        # Package artifacts into compressed tarball and stream via xxd
        tar -czf /tmp/dut_artifacts.tar.gz -C /tmp/dut_artifacts .
        xxd -p /tmp/dut_artifacts.tar.gz
        rm -rf /tmp/dut_artifacts /tmp/dut_artifacts.tar.gz
    '

    log_info "Executing remote collection suite and streaming artifacts from DUT..."
    dut_ssh_raw "${col_script}" | xxd -r -p | tar -xzf - -C "${out_dir}" 2>/dev/null || true

    # Extract AP-side WMM parameters to ap_edca.json inside the bundle
    cmd_wmm --out "${out_dir}/ap_edca.json" "${wmm_if_args[@]}" >/dev/null 2>&1 || true

    # Count retrieved artifacts
    local file_count
    file_count="$(find "${out_dir}" -type f | wc -l || echo "0")"
    local total_bytes
    total_bytes="$(du -sh "${out_dir}" 2>/dev/null | cut -f1 || echo "0B")"

    # Generate Manifest JSON
    cat <<EOF > "${out_dir}/manifest.json"
{
  "artifact_bundle": "dut_diagnostics",
  "collected_at": "$(date -u +'%Y-%m-%dT%H:%M:%SZ')",
  "dut_host": "${TARGET_HOST}",
  "dut_user": "${TARGET_USER}",
  "total_files": ${file_count},
  "total_size": "${total_bytes}"
}
EOF

    # Generate Summary Markdown
    {
        printf "# Device Under Test (DUT) - Diagnostic Artifact Snapshot\n\n"
        printf "* **DUT Target Host:** \`%s\` (User: \`%s\`)\n" "${TARGET_HOST}" "${TARGET_USER}"
        printf "* **Collection Time:** %s\n" "$(date +'%Y-%m-%d %H:%M:%S %Z')"
        printf "* **Total Files Collected:** %d (%s)\n\n" "${file_count}" "${total_bytes}"
        printf "## Collected Diagnostics Inventory\n\n"
        printf "| Category | Key Files | Description |\n"
        printf "| :--- | :--- | :--- |\n"
        printf "| **System & OS** | \`dut_01_system.txt\`, \`dut_03_memory.txt\` | Kernel version, CPU architecture, memory utilization |\n"
        printf "| **Network & Links** | \`dut_06_ip_links.txt\`, \`dut_08_ip_routes.txt\` | VLAN trunking, interface states, routing tables |\n"
        printf "| **Drop Counters** | \`dut_14_link_stats.txt\`, \`dut_16_ethtool_*.txt\` | Hardware MAC drops, FIFO buffer overruns, pause frames |\n"
        printf "| **QoS & Traffic Control** | \`dut_18_tc_qdisc.txt\`, \`dut_22_iptables_mangle.txt\` | Kernel qdisc queues, DiffServ mangle rules |\n"
        printf "| **Wireless Subsystem** | \`dut_27_wl_*.txt\`, \`ap_edca.json\` | Radio status, association list, AP WMM EDCA params |\n"
        printf "| **Kernel & System Logs** | \`dut_32_dmesg.log\`, \`dut_33_*.log\` | Kernel ring buffer dmesg and system daemon logs |\n"
    } > "${out_dir}/SUMMARY.md"

    chmod -R 0666 "${out_dir}"/* 2>/dev/null || true
    chmod 0777 "${out_dir}" 2>/dev/null || true

    log_pass "DUT artifact bundle successfully packaged: ${out_dir} (${file_count} files, ${total_bytes})"
}

main() {
    local cmd="test"
    local -a extra_args=()

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -H|--host)
                CLI_HOST="$2"
                shift 2
                ;;
            -u|--user)
                CLI_USER="$2"
                shift 2
                ;;
            -p|--port)
                CLI_PORT="$2"
                shift 2
                ;;
            -i|--key)
                CLI_KEY="$2"
                shift 2
                ;;
            -P|--pass|--password)
                CLI_PASS="$2"
                shift 2
                ;;
            -o|--out-dir)
                CLI_OUT_DIR="$2"
                shift 2
                ;;
            -c|--category)
                CLI_CATEGORY="$2"
                shift 2
                ;;
            -w|--wifi-if)
                CLI_WIFI_IF="$2"
                shift 2
                ;;
            -v|--verbose)
                CLI_VERBOSE=1
                shift
                ;;
            -s|--silent)
                SILENT=1
                shift
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            test|ping|probe)
                cmd="test"
                shift
                extra_args+=("$@")
                break
                ;;
            status|info)
                cmd="status"
                shift
                ;;
            exec)
                cmd="exec"
                shift
                extra_args+=("$@")
                break
                ;;
            collect|bundle)
                cmd="collect"
                shift
                extra_args+=("$@")
                break
                ;;
            wmm|wme|edca)
                cmd="wmm"
                shift
                extra_args+=("$@")
                break
                ;;
            stats|counters)
                cmd="stats"
                shift
                extra_args+=("$@")
                break
                ;;
            fetch|get)
                cmd="fetch"
                shift
                extra_args+=("$@")
                break
                ;;
            push|put)
                cmd="push"
                shift
                extra_args+=("$@")
                break
                ;;
            *)
                die "Unknown command or option: $1 (Run with --help for usage)"
                ;;
        esac
    done

    resolve_config

    case "${cmd}" in
        test)
            cmd_test
            ;;
        status)
            cmd_status
            ;;
        exec)
            cmd_exec "${extra_args[@]}"
            ;;
        collect)
            cmd_collect "${extra_args[@]}"
            ;;
        wmm)
            cmd_wmm "${extra_args[@]}"
            ;;
        stats)
            cmd_stats "${extra_args[@]}"
            ;;
        fetch)
            cmd_fetch "${extra_args[@]}"
            ;;
        push)
            cmd_push "${extra_args[@]}"
            ;;
        *)
            usage
            exit 1
            ;;
    esac
}

main "$@"
