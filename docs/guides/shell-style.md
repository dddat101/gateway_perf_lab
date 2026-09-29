# Shell Scripting & Defensive Programming Standards

This test lab strictly adheres to production-grade Bash Defensive Patterns to ensure reliability, idempotency, safety, and cross-platform predictability.

---

## 1. Core Defensive Rules & Patterns

| # | Defensive Pattern | Implementation in `gwlab` |
| :- | :--- | :--- |
| 1 | **Strict Execution Mode** | `set -Eeuo pipefail` and `IFS=$'\n\t'` are enforced on line 7-8 of every script. |
| 2 | **Variable Quoting** | All parameter expansions and array elements are quoted: `"${array[@]}"`, `"${file}"`. |
| 3 | **Modern Conditionals** | Exclusively use `[[ ... ]]` compound conditions instead of legacy `[ ... ]` test commands. |
| 4 | **Robust Error Traps** | `setup.sh` uses `trap 'rollback_setup $? ${LINENO}' ERR`. `scenario.sh` uses `trap cleanup_scenario_trap EXIT INT TERM ERR`. |
| 5 | **Strict Input Validation** | Mandatory verification of parameters, network interfaces, IP addresses, and file accessibility. |
| 6 | **Modular Function Design** | Standard function naming conventions: `clean_*`, `setup_*`, `run_phase_*`, `parse_*`. |
| 7 | **Structured Diagnostic Logging** | Standard color-coded log helpers: `log_info`, `log_step`, `log_warn`, `log_error`, `log_success`. |
| 8 | **Non-Destructive Dry-Run** | `setup.sh --dry-run` and `scenario.sh --dry-run` preview actions without root or network mutations. |
| 9 | **Isolated Temp Management** | `scenario.sh` isolates all intermediate output in `mktemp -d` and cleans up on `EXIT`. |
| 10 | **Idempotent Topology Setup** | `clean_stale_interfaces` removes pre-existing veths/bridges before creation to prevent `File exists` errors. |
| 11 | **Toolchain Pre-flight Checks** | `diagnose.sh` verifies toolchains (`ip`, `tc`, `iptables`, `iperf3`, `tcpdump`, `python3`) and tool execution bits. |
| 12 | **Safe Python Subprocess Invocation** | Pass file paths and parameters as `sys.argv` arguments rather than shell string interpolation. |
| 13 | **Safe Binary Resolution** | Always use `command -v <tool>` rather than non-standard `which`. |
| 14 | **Predictable Output** | Prefer `printf` over `echo` to avoid option/escape divergence across shells. |
| 15 | **SIGPIPE 141 Protection** | Pipeline commands wrapped in subshells with fallback: `(( (tshark ... || true) \| head -n 35 ) 2>/dev/null \|\| true)`. |
| 16 | **Atomic File Writes** | Write state files to temporary file (`.tmp.$$`) before moving: `mv -f "${tmp}" "${dest}"`. |
| 17 | **Zero Inline Python Scripts** | Prohibit inline `python3 -c '...'` in shell scripts. Use native bash loops/integer arithmetic or delegate parsing to modular CLI tools under `tools/`. |

---

## 2. Verification Commands

```bash
# Validate syntax across all scripts
for f in scripts/*.sh scripts/lib/*.sh; do bash -n "$f"; done

# Validate pre-flight environment
./scripts/diagnose.sh

# Validate dry-run capabilities (Non-Root)
./scripts/setup.sh --dry-run
./scripts/scenario.sh --dry-run all
./scripts/verify_compliance.sh -h
```
