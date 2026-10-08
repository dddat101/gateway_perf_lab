# gwlab Documentation Hub

Welcome to the `gwlab` documentation hub. This directory contains architectural specifications, test plans, scenario technical designs, operational runbooks, and engineering references for the Gateway Test & Automation framework.

---

## 1. Documentation Taxonomy & Directory Layout

To support the continuous evolution of `gwlab` as a general-purpose testing framework, documentation is organized into clear functional domains:

```text
docs/
├── README.md                      # Documentation hub index & contribution guidelines (this file)
├── architecture/                  # System, network topologies & hardware/virtual models
│   └── topology.md                # Physical DUT wiring & virtual netns interconnects
├── test-plans/                    # Master test plans, matrices & acceptance criteria
│   └── gateway-performance.md     # Baseline gateway verification & performance test plan
├── scenarios/                     # In-depth design & technical specs for test scenarios
│   ├── rate-mismatch-burst.md     # RFC 2544 / switch buffer absorption design (TC-RM)
│   └── real-world-streaming.md    # Cloud gaming (GeForce NOW) & 4K VOD streaming (TC-APP)
├── guides/                        # Operational runbooks & engineering guidelines
│   ├── troubleshooting.md         # Diagnostic runbook, error resolutions & gotchas
│   └── shell-style.md             # Bash defensive programming & scripting standards
└── references/                    # Deep-dive research, benchmark engine analysis & standards
    └── iperf-capabilities.md      # Analysis of iperf2/iperf3 pacing, batching & limitations
```

---

## 2. File Naming & Organization Conventions

All documentation in `gwlab` follows strict naming rules to maintain consistency, ensure instant CLI searchability, and prevent cross-platform filename conflicts:

### 2.1 Rules

1. **Strict Lowercase (`[a-z0-9-]`)**:
   - Filenames must use only lowercase alphanumeric characters and hyphens.
   - ❌ `RATE_MISMATCH_BURST_DESIGN.md`, `TestPlan.md`
   - ✅ `rate-mismatch-burst.md`, `test-plan.md`

2. **Kebab-Case Word Separation (`-`)**:
   - Words are separated exclusively by hyphens (`-`).
   - Underscores (`_`) are reserved for script sub-modules in `scripts/scenarios/` (e.g. `02_rate_mismatch.sh`), while Markdown documentation uses kebab-case (`rate-mismatch-burst.md`).

3. **Domain-Specific Scoping (No Redundant Prefixes)**:
   - Because folders provide context (`scenarios/`, `guides/`), avoid redundant prefixes inside filenames.
   - ❌ `docs/scenarios/scenario-rate-mismatch.md`
   - ✅ `docs/scenarios/rate-mismatch-burst.md`

4. **Self-Contained Navigation**:
   - Use relative Markdown links so documents render properly in Git web viewers (GitHub/GitLab) and local IDEs without depending on absolute machine paths.

### 2.2 CLI Quick Search Tips

With this standardized naming scheme, you can locate documents instantly using standard Unix tools:

```bash
# Find all scenario specifications
find docs/scenarios/ -type f -name "*.md"

# Search for any topic across documentation
find docs/ -name "*qos*.md"
find docs/ -name "*burst*.md"

# Full-text grep within all documentation
grep -rn "bufferbloat" docs/
```

---

## 3. How to Document a New Scenario

As `gwlab` evolves and new test scenarios are added during the project lifecycle:

1. **Add Scenario Implementation**: Place the runner sub-module in `scripts/scenarios/<number>_<scenario_name>.sh` (e.g., `scripts/scenarios/07_wifi_mesh.sh`).
2. **Add Scenario Specification**: Create a design document in `docs/scenarios/<scenario-name>.md` (e.g., `docs/scenarios/wifi-mesh.md`):
   - Background & Network Problem statement
   - Traffic profile (frame sizes, rates, protocols, DSCP/TOS flags)
   - Pass/Fail acceptance criteria
   - CLI invocation examples
3. **Update Test Matrix**: If introducing new compliance criteria, add an entry to [`docs/test-plans/gateway-performance.md`](test-plans/gateway-performance.md).
4. **Register in Index**: Link the new document in Section 4 below and in the root [`README.md`](../README.md).

---

## 4. Documentation Index

| Category | Document | Description |
| :--- | :--- | :--- |
| **Architecture** | [`architecture/topology.md`](architecture/topology.md) | Physical testbed wiring, multi-netns virtual topology, addressing, and VLAN mapping |
| **Test Plans** | [`test-plans/gateway-performance.md`](test-plans/gateway-performance.md) | Quantitative test methodology, acceptance criteria matrix, and metrics definition |
| **Scenarios** | [`scenarios/rate-mismatch-burst.md`](scenarios/rate-mismatch-burst.md) | 1 Gbps WAN to 100 Mbps LAN switch buffer burst absorption (TC-RM-01, TC-RM-02) |
| **Scenarios** | [`scenarios/real-world-streaming.md`](scenarios/real-world-streaming.md) | GeForce NOW Cloud Gaming (UDP) and 4K UHD 1.2x VOD streaming QoE (TC-APP-01, TC-APP-02) |
| **Guides** | [`guides/troubleshooting.md`](guides/troubleshooting.md) | Diagnostic runbook, NetworkManager safety, Kea DHCP sandbox traps, USB PHY bottlenecks |
| **Guides** | [`guides/shell-style.md`](guides/shell-style.md) | Bash defensive programming standards (`set -Eeuo pipefail`, trap handling, dry-run) |
| **References** | [`references/iperf-capabilities.md`](references/iperf-capabilities.md) | Deep analysis of iperf2 vs iperf3 pacing, batching behaviors, socket options, and limitations |
