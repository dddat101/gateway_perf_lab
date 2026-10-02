#!/usr/bin/env bash
# ==============================================================================
# GATEWAY PERFORMANCE LAB - REMOTE PC CLIENT MANAGER
# Manages secondary test PC over SSH for distributed multi-station benchmarking
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
CLI_DIR=""
WITH_CONFIG=0
SILENT=0

usage() {
    cat <<'EOF'
==================================================================
  Gateway Performance Lab - Remote PC Client Manager
==================================================================

Description:
  Orchestrates a secondary/remote client PC over SSH to perform
  distributed multi-station benchmarking (e.g. concurrent 2.4GHz +
  5GHz physical Wi-Fi stations or multi-PC wired + wireless load).
  The remote PC is assumed to host a clone of this repository.

Usage:
  ./scripts/remote_client.sh [COMMAND] [OPTIONS]

Commands:
  test, ping         Verify SSH connectivity and validate remote toolchain
                     (python3, iperf3, iw, nmcli, sudo rights).
  sync, deploy       Synchronize lab codebase to remote PC using rsync
                     (excludes .git, logs, captures, state).
  status             Query remote PC network interfaces and Wi-Fi state.
  wifi-connect <bnd> Connect remote PC to DUT SSID (2g, 5g, 6g).
  wifi-status, info  Query remote PC Wi-Fi connection, SSID, Band, Signal, IP, and DUT reachability.
  wifi-env [opts]    Export remote PC Wi-Fi environment variables suitable for eval / source.
  wifi-ip            Query and print remote PC active Wi-Fi IPv4 address.
  run-iperf [args]   Execute iperf3 client on remote PC towards WAN server.
  run-voip [opts]    Execute VoIP call client (pjsua, sipp, python) on remote PC.
  exec <cmd...>      Run an arbitrary command in remote lab directory.
  clean, stop        Terminate lingering test tasks (iperf3, voip, tcpdump) on remote.

Options:
  -H, --host <host>  Remote PC hostname or IP address (overrides config.env).
  -u, --user <user>  SSH username on remote PC (overrides config.env).
  -p, --port <port>  SSH port (default: 22).
  -i, --key <path>   Path to SSH private key.
  -d, --dir <path>   Absolute path to lab directory on remote PC.
  --with-config      Also sync local config.env during 'sync' command.
  -s, --silent       Suppress non-essential progress logging.
  -h, --help         Show this help message and exit.

Examples:
  ./scripts/remote_client.sh test
  ./scripts/remote_client.sh sync --with-config
  ./scripts/remote_client.sh status
  ./scripts/remote_client.sh wifi-connect 2g
  ./scripts/remote_client.sh run-iperf -c 10.10.0.1 -p 5202 -t 5
  ./scripts/remote_client.sh exec uname -a
==================================================================
EOF
}

resolve_config() {
    load_config "${LAB_DIR}/config.env"

    TARGET_HOST="${CLI_HOST:-${REMOTE_CLIENT_HOST:-}}"
    TARGET_USER="${CLI_USER:-${REMOTE_CLIENT_USER:-${USER}}}"
    TARGET_PORT="${CLI_PORT:-${REMOTE_CLIENT_PORT:-22}}"
    TARGET_KEY="${CLI_KEY:-${REMOTE_CLIENT_KEY:-}}"
    TARGET_DIR="${CLI_DIR:-${REMOTE_CLIENT_DIR:-${LAB_DIR}}}"
    SSH_OPTS_STR="${REMOTE_CLIENT_SSH_OPTS:--o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new}"

    # Auto-detect SSH private key when running under sudo or standard user
    if [[ -z "${TARGET_KEY}" && -n "${SUDO_USER:-}" ]]; then
        for k in "/home/${SUDO_USER}/.ssh/id_ed25519" "/home/${SUDO_USER}/.ssh/id_rsa"; do
            if [[ -f "${k}" ]]; then
                TARGET_KEY="${k}"
                break
            fi
        done
    fi
    if [[ -z "${TARGET_KEY}" && -n "${HOME:-}" ]]; then
        for k in "${HOME}/.ssh/id_ed25519" "${HOME}/.ssh/id_rsa"; do
            if [[ -f "${k}" ]]; then
                TARGET_KEY="${k}"
                break
            fi
        done
    fi

    if [[ -z "${TARGET_HOST}" ]]; then
        log_error "Remote client host not specified."
        log_error "Set REMOTE_CLIENT_HOST in config.env or provide -H <ip_or_host>."
        exit 1
    fi
}

get_ssh_cmd() {
    local cmd=("ssh")
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

remote_ssh_exec() {
    local -a ssh_base=()
    while IFS= read -r -d '' arg; do
        ssh_base+=("${arg}")
    done < <(get_ssh_cmd)

    local remote_cmd="$1"
    "${ssh_base[@]}" "bash -c 'cd \"${TARGET_DIR}\" && ${remote_cmd}'"
}

remote_ssh_raw() {
    local -a ssh_base=()
    while IFS= read -r -d '' arg; do
        ssh_base+=("${arg}")
    done < <(get_ssh_cmd)

    local raw_cmd="$1"
    "${ssh_base[@]}" "bash -c '${raw_cmd}'"
}

cmd_test() {
    print_header "REMOTE CLIENT CONNECTIVITY & TOOLCHAIN PROBE"
    log_info "Target Endpoint : ${TARGET_USER}@${TARGET_HOST}:${TARGET_PORT}"
    log_info "Remote Lab Path : ${TARGET_DIR}"

    # 1. Test basic SSH connectivity
    log_info "Testing SSH authentication and shell access..."
    local remote_uname
    if ! remote_uname="$(remote_ssh_raw 'uname -srm 2>/dev/null')"; then
        log_error "Failed to connect to ${TARGET_USER}@${TARGET_HOST} via SSH."
        log_error "Please verify:"
        log_error "  1. Remote host is powered on and reachable via ping: 'ping -c 2 ${TARGET_HOST}'"
        log_error "  2. SSH public key is installed on remote: 'ssh-copy-id -p ${TARGET_PORT} ${TARGET_USER}@${TARGET_HOST}'"
        log_error "  3. Correct SSH user/key is set in config.env or command line."
        return 1
    fi
    log_success "SSH Connection OK. Remote OS: ${remote_uname}"

    # 2. Check remote directory
    log_info "Checking remote lab directory..."
    if remote_ssh_raw "[[ -d \"${TARGET_DIR}\" ]]"; then
        log_success "Remote lab directory exists: ${TARGET_DIR}"
    else
        log_warn "Remote directory does not exist: ${TARGET_DIR}"
        log_info "Run './scripts/remote_client.sh sync' to deploy the workspace."
    fi

    # 3. Check remote tools
    log_info "Probing remote toolchain availability..."
    local check_script='
        tools=(python3 iperf3 iw nmcli ip sudo)
        for t in "${tools[@]}"; do
            if command -v "$t" >/dev/null 2>&1; then
                echo "TOOL:$t:OK:$(command -v "$t")"
            else
                echo "TOOL:$t:MISSING"
            fi
        done
        if sudo -n true 2>/dev/null; then
            echo "SUDO:PASSWORDLESS"
        else
            echo "SUDO:NEEDS_PASSWORD"
        fi
    '
    local remote_probe
    remote_probe="$(remote_ssh_raw "${check_script}" 2>/dev/null || true)"

    while IFS= read -r line; do
        if [[ "${line}" =~ ^TOOL:([^:]+):OK:(.*)$ ]]; then
            log_success "  -> Remote binary: ${BASH_REMATCH[1]} (${BASH_REMATCH[2]})"
        elif [[ "${line}" =~ ^TOOL:([^:]+):MISSING$ ]]; then
            log_warn "  -> Missing remote binary: ${BASH_REMATCH[1]}"
        elif [[ "${line}" == "SUDO:PASSWORDLESS" ]]; then
            log_success "  -> Remote Sudo: Passwordless sudo enabled (ideal for automated test suite)"
        elif [[ "${line}" == "SUDO:NEEDS_PASSWORD" ]]; then
            log_warn "  -> Remote Sudo: Interactive password required (sudo without password recommended)"
        fi
    done <<< "${remote_probe}"

    # 4. Check remote Wi-Fi hardware
    log_info "Probing remote Wi-Fi adapters..."
    local wifi_info
    wifi_info="$(remote_ssh_raw 'iw dev 2>/dev/null | awk "/Interface/ {print \$2}" | tr "\n" " " || true')"
    if [[ -n "${wifi_info// /}" ]]; then
        log_success "Remote Wi-Fi interface(s) detected: ${wifi_info}"
    else
        log_warn "No physical wireless interfaces detected via iw on remote PC."
    fi

    print_section "REMOTE PROBE COMPLETE"
    return 0
}

cmd_sync() {
    print_header "SYNCHRONIZING CODEBASE TO REMOTE CLIENT"
    log_info "Source      : ${LAB_DIR}/"
    log_info "Destination : ${TARGET_USER}@${TARGET_HOST}:${TARGET_DIR}/"

    # Ensure remote directory exists
    remote_ssh_raw "mkdir -p \"${TARGET_DIR}\""

    local -a rsync_cmd=(
        "rsync" "-avz" "--delete"
        "--exclude=.git"
        "--exclude=logs/*"
        "--exclude=captures/*"
        "--exclude=state/*"
        "--exclude=.venv"
        "--exclude=__pycache__"
        "--exclude=*.pyc"
    )

    if (( WITH_CONFIG == 0 )); then
        rsync_cmd+=("--exclude=config.env")
    else
        log_info "Including config.env in sync (--with-config set)"
    fi

    local ssh_r_opt="ssh"
    if [[ -n "${TARGET_PORT}" && "${TARGET_PORT}" != "22" ]]; then
        ssh_r_opt+=" -p ${TARGET_PORT}"
    fi
    if [[ -n "${TARGET_KEY}" && -f "${TARGET_KEY}" ]]; then
        ssh_r_opt+=" -i ${TARGET_KEY}"
    fi
    # shellcheck disable=SC2086
    ssh_r_opt+=" ${SSH_OPTS_STR}"

    rsync_cmd+=("-e" "${ssh_r_opt}")
    rsync_cmd+=("${LAB_DIR}/" "${TARGET_USER}@${TARGET_HOST}:${TARGET_DIR}/")

    log_info "Executing rsync..."
    "${rsync_cmd[@]}"

    # Ensure remote script permissions
    remote_ssh_raw "chmod +x \"${TARGET_DIR}\"/scripts/*.sh \"${TARGET_DIR}\"/tools/*.py 2>/dev/null || true"
    log_success "Codebase synchronized successfully to ${TARGET_HOST}:${TARGET_DIR}."
}

cmd_status() {
    print_header "REMOTE CLIENT SYSTEM & WI-FI STATUS"
    log_info "Target Endpoint: ${TARGET_USER}@${TARGET_HOST}"

    if remote_ssh_raw "[[ -f \"${TARGET_DIR}/scripts/show_state.sh\" ]]"; then
        remote_ssh_exec "./scripts/show_state.sh || true"
    else
        log_warn "Remote show_state.sh not found. Running basic hardware inspection..."
        remote_ssh_raw "
            echo '--- Host Interfaces ---'
            ip -brief addr show
            echo '--- Wi-Fi Interfaces ---'
            iw dev 2>/dev/null || echo 'iw not available'
        "
    fi
}

cmd_wifi_connect() {
    local band="${1:-}"
    if [[ -z "${band}" ]]; then
        die "Subcommand 'wifi-connect' requires band argument: 2g, 5g, or 6g"
    fi

    print_header "CONNECTING REMOTE CLIENT WI-FI TO BAND [${band^^}]"
    log_info "Target Endpoint : ${TARGET_USER}@${TARGET_HOST}"
    log_info "Remote Command  : ./scripts/wifi_connect.sh connect ${band} --force"

    remote_ssh_exec "./scripts/wifi_connect.sh connect \"${band}\" --force"
    log_success "Remote Wi-Fi connection triggered successfully."
}

cmd_run_iperf() {
    local -a iperf_args=("$@")
    if (( ${#iperf_args[@]} == 0 )); then
        iperf_args=("-c" "${WAN_SERVER_IP:-10.10.0.1}" "-p" "5202" "-t" "5")
    fi

    # Join arguments with spaces to prevent IFS newline splitting
    local iperf_cmd
    iperf_cmd="iperf3 $(IFS=' '; echo "${iperf_args[*]}")"
    remote_ssh_raw "${iperf_cmd}"
}

cmd_get_wifi_env() {
    local -a extra_args=("$@")
    local remote_cmd="python3 tools/wifi_inspector.py export-env --prefix REMOTE_"
    if (( ${#extra_args[@]} > 0 )); then
        remote_cmd+=" $(IFS=' '; echo "${extra_args[*]}")"
    fi
    remote_ssh_exec "${remote_cmd}"
}

cmd_wifi_status() {
    print_header "REMOTE CLIENT WI-FI CONNECTION STATUS"
    log_info "Target Endpoint : ${TARGET_USER}@${TARGET_HOST}"

    local env_dump
    env_dump="$(cmd_get_wifi_env --check-ping "${DUT_LAN_IP:-192.168.1.1}" 2>/dev/null || true)"
    eval "${env_dump}"

    local status_label="${REMOTE_WIFI_STATUS:-DISCONNECTED}"
    log_info "  -> Remote Interface : ${REMOTE_WIFI_IF:-none} [${status_label}] (MAC: ${REMOTE_WIFI_MAC:-none})"
    log_info "  -> Target SSID      : '${REMOTE_WIFI_SSID:-none}' (BSSID: ${REMOTE_WIFI_BSSID:-none})"
    log_info "  -> Band & Frequency : ${REMOTE_WIFI_BAND:-none} (Ch: ${REMOTE_WIFI_CHANNEL:-none}, Width: ${REMOTE_WIFI_WIDTH:-none})"
    log_info "  -> Signal & Bitrate : ${REMOTE_WIFI_SIGNAL:-none} (Tx: ${REMOTE_WIFI_BITRATE:-none})"
    log_info "  -> Station IP (DHCP): ${REMOTE_WIFI_IP:-none} (Gateway: ${REMOTE_WIFI_GATEWAY:-none})"
    if [[ "${REMOTE_WIFI_PING_OK:-0}" == "1" ]]; then
        log_success "  -> DUT Reachability : REACHABLE (Ping RTT: ${REMOTE_WIFI_PING_RTT:-<1ms})"
    else
        log_warn "  -> DUT Reachability : UNREACHABLE (Failed ping to ${DUT_LAN_IP:-192.168.1.1})"
    fi
    print_section "STATUS QUERY COMPLETE"
}

cmd_get_wifi_ip() {
    local env_dump
    env_dump="$(cmd_get_wifi_env 2>/dev/null || true)"
    eval "${env_dump}"
    echo "${REMOTE_WIFI_IP:-}"
}

cmd_run_voip() {
    local engine="auto"
    local server_ip="${WAN_SERVER_IP:-10.10.0.1}"
    local server_port=5060
    local local_port=5064
    local rtp_port=10002
    local duration="${VOIP_CALL_DURATION_SEC:-20}"
    local phone_id="phone-2"

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --engine|-E) engine="$2"; shift 2 ;;
            --server-ip) server_ip="$2"; shift 2 ;;
            --server-port) server_port="$2"; shift 2 ;;
            --local-port) local_port="$2"; shift 2 ;;
            --rtp-port) rtp_port="$2"; shift 2 ;;
            --duration|-d) duration="$2"; shift 2 ;;
            --phone-id) phone_id="$2"; shift 2 ;;
            *) shift ;;
        esac
    done

    # Probe remote Wi-Fi status & IP
    local env_dump
    env_dump="$(cmd_get_wifi_env 2>/dev/null || true)"
    eval "${env_dump}"
    local remote_wifi_ip="${REMOTE_WIFI_IP:-}"
    local remote_wifi_if="${REMOTE_WIFI_IF:-wlan0}"
    local remote_ssid="${REMOTE_WIFI_SSID:-none}"
    local remote_status="${REMOTE_WIFI_STATUS:-DISCONNECTED}"

    local remote_cmd=""
    if [[ "${engine}" == "pjsua" || "${engine}" == "auto" ]]; then
        local has_pjsua
        has_pjsua="$(remote_ssh_raw "export PATH=\"${TARGET_DIR}/tools/bin:\$PATH\"; command -v pjsua >/dev/null && echo 1 || echo 0" 2>/dev/null | tr -d '\r\n ')"
        if [[ "${has_pjsua}" == "1" ]]; then
            engine="pjsua"
        elif [[ "${engine}" == "auto" ]]; then
            local has_sipp
            has_sipp="$(remote_ssh_raw "export PATH=\"${TARGET_DIR}/tools/bin:\$PATH\"; command -v sipp >/dev/null && echo 1 || echo 0" 2>/dev/null | tr -d '\r\n ')"
            if [[ "${has_sipp}" == "1" ]]; then
                engine="sipp"
            else
                engine="python"
            fi
        fi
    fi

    local log_file="/tmp/voip_${phone_id}.log"
    local env_prefix="export PATH=\"./tools/bin:\$PATH\"; export LD_LIBRARY_PATH=\"\${PWD}/tools/lib:\$LD_LIBRARY_PATH\";"
    if [[ "${engine}" == "pjsua" ]]; then
        local ip_opt=""
        if [[ -n "${remote_wifi_ip}" ]]; then
            ip_opt="--ip-addr=${remote_wifi_ip} --bound-addr=${remote_wifi_ip}"
        fi
        remote_cmd="${env_prefix} nohup pjsua --local-port=${local_port} --rtp-port=${rtp_port} --null-audio ${ip_opt} --duration=${duration} --set-qos --no-cli-console --app-log-level=0 'sip:${server_ip}:${server_port}' > \"${log_file}\" 2>&1 < /dev/null & echo \$!"

    elif [[ "${engine}" == "sipp" ]]; then
        local ip_opt=""
        if [[ -n "${remote_wifi_ip}" ]]; then
            ip_opt="-i ${remote_wifi_ip}"
        fi
        local sipp_dur_ms=$(( duration * 1000 ))
        remote_cmd="${env_prefix} nohup sipp -sn uac '${server_ip}:${server_port}' ${ip_opt} -p ${local_port} -mp ${rtp_port} -m 1 -d ${sipp_dur_ms} -nostdin > \"${log_file}\" 2>&1 < /dev/null & echo \$!"

    else
        local ip_opt=""
        if [[ -n "${remote_wifi_ip}" ]]; then
            ip_opt="--bind-ip ${remote_wifi_ip}"
        fi
        remote_cmd="${env_prefix} nohup python3 tools/voip_call_simulator.py client --server-ip ${server_ip} --server-port ${rtp_port} ${ip_opt} --duration ${duration} --phone-id ${phone_id} > \"${log_file}\" 2>&1 < /dev/null & echo \$!"
    fi

    log_info "Launching remote Phone 2 VoIP client on ${TARGET_HOST}..."
    log_info "  -> Remote Wi-Fi Link : ${remote_wifi_if} [${remote_status}] (SSID: '${remote_ssid}', IP: ${remote_wifi_ip:-unknown})"
    log_info "  -> VoIP Engine       : [${engine^^}] | Server: ${server_ip}:${server_port} | RTP: ${rtp_port} | Duration: ${duration}s"

    local spawned_pid
    spawned_pid="$(remote_ssh_exec "${remote_cmd}" 2>/dev/null | tr -d '\r\n ' || true)"

    # Verify process actually started and is running
    local is_alive=0
    local log_snippet=""
    if [[ -n "${spawned_pid}" && "${spawned_pid}" =~ ^[0-9]+$ ]]; then
        sleep 0.5
        is_alive="$(remote_ssh_raw "kill -0 ${spawned_pid} 2>/dev/null && echo 1 || echo 0" 2>/dev/null | tr -d '\r\n ' || true)"
    fi

    if [[ "${is_alive}" == "1" ]]; then
        log_success "Remote VoIP client [${phone_id}] active on ${TARGET_HOST} (PID: ${spawned_pid}, Log: ${log_file})."
        return 0
    else
        log_snippet="$(remote_ssh_raw "cat ${log_file} 2>/dev/null | tr '\n' ' ' | head -c 200" 2>/dev/null || true)"
        log_error "Remote VoIP client [${phone_id}] FAILED to run on ${TARGET_HOST}!"
        if [[ -n "${log_snippet}" ]]; then
            log_error "  Remote error log: ${log_snippet}"
        fi
        return 1
    fi
}

cmd_clean() {
    print_header "CLEANING LINGERING PROCESSES ON REMOTE CLIENT"
    log_info "Target Endpoint: ${TARGET_USER}@${TARGET_HOST}"

    local clean_script='
        for proc in iperf3 pjsua sipp; do
            pkill -TERM -x "${proc}" 2>/dev/null || true
        done
        pkill -TERM -f "[t]raffic_generator.py" 2>/dev/null || true
        pkill -TERM -f "[v]oip_call_simulator.py" 2>/dev/null || true
        pkill -TERM -f "[t]cpdump -i" 2>/dev/null || true
        sleep 0.2
        for proc in iperf3 pjsua sipp; do
            pkill -KILL -x "${proc}" 2>/dev/null || true
        done
        pkill -KILL -f "[t]raffic_generator.py" 2>/dev/null || true
        pkill -KILL -f "[v]oip_call_simulator.py" 2>/dev/null || true
        echo "Remote processes cleaned."
    '
    remote_ssh_raw "${clean_script}"
    log_success "Cleanup complete on remote client."
}

cmd_exec() {
    local remote_cmd
    remote_cmd="$(IFS=' '; echo "$*")"
    if [[ -z "${remote_cmd}" ]]; then
        die "Subcommand 'exec' requires a command string to execute."
    fi
    remote_ssh_exec "${remote_cmd}"
}

main() {
    local action=""
    local -a extra_args=()

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--help)
                usage
                exit 0
                ;;
            -H|--host)
                [[ $# -ge 2 ]] || die "Option $1 requires a host argument"
                CLI_HOST="$2"
                shift 2
                ;;
            -u|--user)
                [[ $# -ge 2 ]] || die "Option $1 requires a username argument"
                CLI_USER="$2"
                shift 2
                ;;
            -p|--port)
                [[ $# -ge 2 ]] || die "Option $1 requires a port argument"
                CLI_PORT="$2"
                shift 2
                ;;
            -i|--key)
                [[ $# -ge 2 ]] || die "Option $1 requires a key path argument"
                CLI_KEY="$2"
                shift 2
                ;;
            -d|--dir)
                [[ $# -ge 2 ]] || die "Option $1 requires a path argument"
                CLI_DIR="$2"
                shift 2
                ;;
            --with-config)
                WITH_CONFIG=1
                shift
                ;;
            -s|--silent)
                SILENT=1
                shift
                ;;
            test|ping|probe|test-connection)
                action="test"
                shift
                ;;
            sync|deploy)
                action="sync"
                shift
                ;;
            status|show)
                action="status"
                shift
                ;;
            wifi-connect)
                action="wifi-connect"
                shift
                if [[ $# -gt 0 && ! "$1" =~ ^- ]]; then
                    extra_args+=("$1")
                    shift
                fi
                ;;
            wifi-status|status-wifi|wifi-info)
                action="wifi-status"
                shift
                ;;
            wifi-env)
                action="wifi-env"
                shift
                extra_args+=("$@")
                break
                ;;
            wifi-ip|get-wifi-ip)
                action="wifi-ip"
                shift
                ;;
            run-iperf)
                action="run-iperf"
                shift
                extra_args+=("$@")
                break
                ;;
            run-voip|voip)
                action="run-voip"
                shift
                extra_args+=("$@")
                break
                ;;
            clean|stop)
                action="clean"
                shift
                ;;
            exec)
                action="exec"
                shift
                extra_args+=("$@")
                break
                ;;
            *)
                die "Unknown option or command: $1 (Run with --help for usage)"
                ;;
        esac
    done

    resolve_config

    case "${action:-test}" in
        test)
            cmd_test
            ;;
        sync)
            cmd_sync
            ;;
        status)
            cmd_status
            ;;
        wifi-connect)
            cmd_wifi_connect "${extra_args[@]:-}"
            ;;
        wifi-status)
            cmd_wifi_status
            ;;
        wifi-env)
            cmd_get_wifi_env "${extra_args[@]:-}"
            ;;
        wifi-ip)
            cmd_get_wifi_ip
            ;;
        run-iperf)
            cmd_run_iperf "${extra_args[@]}"
            ;;
        run-voip)
            cmd_run_voip "${extra_args[@]}"
            ;;
        clean)
            cmd_clean
            ;;
        exec)
            cmd_exec "${extra_args[@]}"
            ;;
        *)
            usage
            exit 1
            ;;
    esac
}

main "$@"
