# Task: Proxmox-Based Internet Monitoring Server with Web Dashboard

## Implementation Readiness Review

This task is ready for implementation. The scope is clear, the architecture is practical, and the first release is intentionally limited to monitoring and diagnosis only. The design avoids unsafe automatic reboot behavior in the first version while still collecting the exact evidence needed to decide whether reboot automation is justified later.

**Revision 2 changes:** explicit quorum rules for "reachable/unreachable", state debouncing to prevent flapping, a `WAN_DOWN` fallback state for ISP modems that never answer (bridge mode), an installer check for ICMP in unprivileged LXC, CSRF/DNS-rebinding and path-traversal protections for the web endpoints, and a lock-out recovery procedure for bad bind/port changes.

### Ready-to-implement items

- Proxmox LXC target is clearly defined.
- Network topology and monitored targets are defined.
- Telemetry collection requirements are concrete.
- Monitoring traffic budget is specified so the telemetry service does not worsen outages.
- Failure classification rules are deterministic, with explicit quorum and debounce rules.
- Bridge-mode ISP modems (provider IP never answers) are handled via a dedicated fallback state.
- Web endpoints are hardened against CSRF, DNS rebinding, and log path traversal.
- Dashboard pages and API endpoints are specified.
- Persistent JSON configuration workflow is defined.
- Logging format and log rotation requirements are defined.
- systemd service behavior is defined.
- Acceptance tests are clear and executable.
- Future reboot-control safety rules are documented but kept out of first release.

### Implementation assumptions

- The Proxmox node is already connected behind the Dream Router on the home LAN.
- The monitoring container receives a static LAN IP.
- The dashboard is intended only for trusted LAN access.
- The provider router/modem may or may not answer on `192.168.100.1` depending on ISP device mode. If it never answers, classification falls back to the generic `WAN_DOWN` state (see 4.4.2). Reaching the modem subnet from the LAN may require a static route on the Dream Router; the troubleshooting guide shall mention this.
- ICMP ping is allowed by the LAN/router/firewall.
- Monitoring traffic must stay lightweight and must not overload the network, especially during degraded-speed conditions.
- No authentication is required for first release.

### Recommended implementation order

1. Build the Proxmox LXC installer script.
2. Implement the Python telemetry collector.
3. Add JSONL and CSV logging.
4. Add outage event tracking.
5. Add the web dashboard.
6. Add the configuration page and configuration file loading.
7. Add validation and restart workflow.
8. Add logrotate and systemd integration.
9. Run acceptance tests.
10. Collect several days of data before considering reboot automation.

### Main risk before implementation

The main risk is incorrect network IP configuration. To reduce this, the installer should print all configured IPs before creating the container and should require the user to edit the top configuration block before running. A secondary risk is accidentally creating too much monitoring traffic during an outage or speed drop; the implementation must enforce a strict monitoring traffic budget.

---

## 1. Goal

Create a lightweight monitoring server on a Proxmox node to continuously monitor home internet reliability, classify outages, log telemetry, and provide a local web dashboard for real-time status and historical analysis.

The monitoring server shall run inside a dedicated Debian LXC container on Proxmox and monitor the network path:

```text
Provider coax router/modem
    ↓
Dream Router 6
    ↓
Home LAN
    ↓
Proxmox node
    ↓
Monitoring LXC container
```

The system shall help identify whether slowdowns or outages are caused by:

```text
- Local LAN / Dream Router problem
- Provider router/modem lockup
- Coax / ISP upstream outage
- DNS failure
- High latency / degraded internet
- VM/LXC or Proxmox network issue
```

The first implementation shall be monitoring-only. It shall not reboot the provider router automatically.

---

## 2. Target Platform

### 2.1 Host

```text
Platform: Proxmox VE node
Network bridge: vmbr0 or user-selected bridge
Guest type: Debian LXC container
Container mode: unprivileged preferred
```

### 2.2 Container

```text
OS: Debian 12 or newer standard LXC template
CPU: 1 core
RAM: 512 MB
Swap: 256 MB
Disk: 8 GB
Static IP: required/recommended
Start at boot: enabled
```

Example:

```text
Hostname: internet-telemetry
IP:       192.168.1.20/24
Gateway:  192.168.1.1
DNS:      192.168.1.1
Web UI:   http://192.168.1.20:8080
```

---

## 3. Main Deliverables

Create a complete package containing:

```text
1. Proxmox host installation script
2. Python telemetry and dashboard application
3. systemd service file
4. logrotate configuration
5. README.md installation guide
6. Configuration section with user-editable IPs
7. Basic troubleshooting guide
8. Acceptance test procedure
9. Configuration web page
10. JSON-based persistent configuration file
11. Configuration validation and restart workflow
```

The main installer shall be a single shell script:

```text
create_internet_telemetry_dashboard_lxc.sh
```

The script shall create and configure the LXC container automatically.

---

## 4. Functional Requirements

### 4.1 Proxmox LXC Creation

The installer shall:

```text
- Check that it is running as root on the Proxmox host
- Check that pct and pveam are available
- Download Debian LXC template if missing
- Create a new LXC container
- Configure static IP, gateway, DNS, bridge, CPU, RAM, disk, and swap
- Enable container start on boot
- Start the container
- Install required packages inside the container
- Verify ICMP ping works inside the container and fail with a clear error if it does not
- Test-ping each configured provider router IP once and print an informational note if none answer (expected in ISP bridge mode, see 4.4)
```

Unprivileged LXC note: `ping` inside an unprivileged container requires `net.ipv4.ping_group_range` to cover the container's mapped GIDs. The installer shall run a test ping (for example `pct exec <CTID> -- ping -c1 <GATEWAY>`) and, on failure, print the exact sysctl remediation instead of leaving the collector to silently produce `COLLECTOR_ERROR` samples.

Required packages inside the container:

```text
python3
iputils-ping
iproute2
dnsutils
curl
ca-certificates
nano
logrotate
```

The installer shall expose these variables at the top of the script:

```bash
CTID
CT_HOSTNAME
TEMPLATE_STORAGE
ROOTFS_STORAGE
DISK_GB
CORES
MEMORY_MB
SWAP_MB
BRIDGE
LAN_IP_CIDR
GATEWAY
DNS_SERVER
DREAM_IP
PROVIDER_IPS
PUBLIC_PINGS
DNS_NAMES
TCP_TARGETS
INTERVAL_SEC
OUTAGE_AFTER_SEC
DASHBOARD_BIND
DASHBOARD_PORT
```

---

### 4.2 Telemetry Collection

The monitoring application shall collect one sample every configurable interval.

Default interval:

```text
10 seconds
```

Each sample shall include:

```text
- UTC timestamp
- Dream Router ping status and latency
- Provider router/modem ping status and latency
- Public internet ping status and latency
- DNS lookup status and timing
- TCP connection test status and timing
- Container hostname
- Container load average
- Container RAM usage
- Container disk usage
- Default route information
- Classified network state
- Estimated monitoring traffic per sample
- Estimated monitoring traffic per minute
- Monitoring traffic budget status
```

Default targets:

```text
Dream Router:
- 192.168.1.1

Provider router/modem:
- 192.168.100.1
- 192.168.0.1

Public ping:
- 1.1.1.1
- 8.8.8.8
- 9.9.9.9

DNS:
- google.com
- cloudflare.com
- ui.com

TCP:
- 1.1.1.1:443
- 8.8.8.8:53
- google.com:443
```

---

### 4.3 Monitoring Traffic Budget

The monitoring service shall be intentionally lightweight and shall not make an already slow or unstable internet connection worse.

Hard requirement:

```text
Monitoring-generated traffic shall stay below 3% of the configured minimum expected internet speed.
```

The 3% limit shall be calculated against the more restrictive configured link direction, normally the lower value of `minimum_expected_downlink_mbps` and `minimum_expected_uplink_mbps`. This prevents monitoring traffic from becoming a meaningful load when the internet connection slows down or partially degrades.

The service shall use only low-bandwidth health checks by default:

```text
- ICMP ping with one packet per target per sample
- DNS lookup for selected names
- TCP connect checks without downloading payload data
- Local dashboard API traffic only when a user opens the dashboard
```

The first version shall not run continuous speed tests, file downloads, large HTTP transfers, or repeated high-bandwidth probes.

Default monitoring traffic target:

```text
Normal operation: less than 0.5% of configured minimum link speed
Absolute limit:   less than 3.0% of configured minimum link speed
```

The configuration shall include:

```json
{
  "monitoring_traffic_limit_percent": 3.0,
  "minimum_expected_downlink_mbps": 10,
  "minimum_expected_uplink_mbps": 2,
  "adaptive_backoff_enabled": true
}
```

The implementation shall estimate monitoring traffic from configured probes and sampling interval. The estimate does not need to be exact byte-perfect, but it shall be conservative and visible in the dashboard. The user should configure conservative minimum speeds, not the advertised ISP plan speed, so the budget remains safe during speed drops.

The dashboard shall show:

```text
Estimated telemetry traffic, kbps
Traffic budget, kbps
Traffic budget usage, %
Budget status: OK/WARNING/EXCEEDED
```

If the estimated monitoring traffic exceeds the 3% limit, the application shall reject the configuration or show a blocking validation error.

During degraded network states such as `INTERNET_SLOW`, `ISP_OR_COAX_UPSTREAM_DOWN`, or `PROVIDER_ROUTER_OR_WAN_LINK_DOWN`, the service shall not increase probe frequency. If adaptive backoff is enabled, the service should reduce non-critical checks to lower monitoring traffic during unstable periods.

Recommended adaptive behavior:

```text
- Keep Dream Router ping active every interval
- Keep one provider-router probe active every interval
- Keep at least two public reachability checks active
- Reduce extra DNS/TCP targets during persistent outage
- Never run speed tests automatically during an outage
```

Manual or future throughput tests shall be disabled by default and shall include explicit rate limits.

---

### 4.4 Failure Classification

The monitoring application shall classify every sample into one of these states:

```text
OK
OK_PROVIDER_ROUTER_NOT_REACHABLE
LOCAL_LAN_OR_DREAM_ROUTER_DOWN
PROVIDER_ROUTER_OR_WAN_LINK_DOWN
ISP_OR_COAX_UPSTREAM_DOWN
WAN_DOWN
DNS_FAILURE
INTERNET_SLOW
UNKNOWN_FAILURE
COLLECTOR_ERROR
```

#### 4.4.1 Quorum definitions

The terms "reachable" and "unreachable" are defined per group as follows, evaluated within a single sample:

```text
dream_ok:         Dream Router answered its ping
provider_any_ok:  at least one configured provider IP answered
public_down:      TRUE only when ALL configured public ping targets failed
public_ok:        at least one public ping target answered
dns_any_ok:       at least one configured DNS lookup succeeded
tcp_any_ok:       at least one configured TCP connect succeeded
```

Using "all targets failed" for public reachability prevents a single lost packet to one target from being treated as an internet outage.

#### 4.4.2 Provider reachability baseline

Many ISP devices in bridge mode never answer on a management IP. To avoid misclassifying every outage as `PROVIDER_ROUTER_OR_WAN_LINK_DOWN` on such setups, the application shall maintain a provider reachability baseline:

```text
provider_baseline_reachable = TRUE if any provider IP has answered
at least once during OK-state samples within the last 24 hours
(persisted across restarts in the state, or rebuilt from recent logs)
```

If `provider_baseline_reachable` is FALSE, provider reachability carries no diagnostic information and rules 2 and 3 collapse into the generic `WAN_DOWN` state.

#### 4.4.3 Classification rules

```text
1. If Dream Router is unreachable:
   State = LOCAL_LAN_OR_DREAM_ROUTER_DOWN

2. If Dream Router is reachable, public internet is down, and
   provider_baseline_reachable is FALSE:
   State = WAN_DOWN

3. If Dream Router is reachable, provider router/modem is unreachable,
   and public internet is down:
   State = PROVIDER_ROUTER_OR_WAN_LINK_DOWN

4. If provider router/modem is reachable, but public internet is down:
   State = ISP_OR_COAX_UPSTREAM_DOWN

5. If public internet works, but all DNS lookups fail:
   State = DNS_FAILURE

6. If public internet works, but best public latency exceeds threshold:
   State = INTERNET_SLOW

7. If public internet works, provider_baseline_reachable is TRUE,
   but no provider IP answers:
   State = OK_PROVIDER_ROUTER_NOT_REACHABLE

8. If LAN, internet, and DNS work:
   State = OK
```

The latency compared against the slow threshold shall be the best (lowest) successful public ping latency in the sample, so a single congested path does not mark the whole connection as slow.

Default slow latency threshold:

```text
150 ms
```

#### 4.4.4 State debouncing

Raw per-sample classification shall be debounced before it becomes the reported state, so that one dropped packet does not generate state-change events:

```text
- A transition to a new state is confirmed only after
  state_confirm_samples consecutive samples classify into that state.
  Default: 2 consecutive samples.

- INTERNET_SLOW additionally requires slow_consecutive_samples
  consecutive samples over the latency threshold before it is entered.
  Default: 3 consecutive samples.

- Recovery back to OK is debounced with the same
  state_confirm_samples rule.

- COLLECTOR_ERROR is exempt from debouncing and is reported
  immediately, since it indicates the monitor itself is broken.
```

Both the raw per-sample classification and the debounced reported state shall be stored in the JSONL sample. Events and the dashboard state card shall use the debounced state.

---

### 4.5 Persistent Outage Events

The service shall track continuous failure duration.

Default persistent outage threshold:

```text
600 seconds
```

The service shall create event files for:

```text
- State change
- Persistent outage
- Recovery
```

Persistent outage events shall include:

```text
- Event timestamp
- State
- Severity
- Message
- Active since timestamp
- Duration
- Reboot candidate flag
```

The following states shall be marked as possible reboot candidates:

```text
PROVIDER_ROUTER_OR_WAN_LINK_DOWN
ISP_OR_COAX_UPSTREAM_DOWN
WAN_DOWN
```

The first version shall not perform reboot actions automatically.

---

## 5. Web Dashboard Requirements

The service shall provide a local web dashboard.

Default URL:

```text
http://<container-ip>:8080
```

The dashboard shall include:

```text
1. Current state card
2. State explanation message
3. Dream Router latency
4. Provider router/modem latency
5. Public internet latency
6. Estimated monitoring traffic and budget usage
7. Dream Router OK/FAIL
8. Provider router/modem OK/FAIL
9. Public ping OK/FAIL
10. DNS OK/FAIL
11. TCP OK/FAIL
12. Container hostname
13. Container load average
14. RAM usage
15. Disk usage
16. Recent telemetry samples table
17. Events table
18. Log files table
19. Configuration summary
```

The dashboard shall auto-refresh every:

```text
5 seconds
```

The dashboard shall expose these endpoints:

```text
GET /              Web dashboard
GET /api/status    JSON status snapshot
GET /healthz       Health check
GET /log?file=...  Download/view CSV or JSONL logs
```

The dashboard shall use no external CDN dependencies. It must work fully offline on the local network.

---

## 6. Configuration Page Requirements

The web dashboard shall include a dedicated **Configuration** page accessible from the main dashboard navigation.

Default URL:

```text
http://<container-ip>:8080/config
```

The configuration page shall allow the user to view and edit monitoring settings without manually editing the systemd service file.

---

### 6.1 Configuration File

The monitoring application shall store editable configuration in:

```text
/etc/internet-telemetry/config.json
```

The application shall load this configuration at startup.

If the file does not exist, the application shall create it with safe default values.

Example configuration:

```json
{
  "dream_ip": "192.168.1.1",
  "provider_ips": [
    "192.168.100.1",
    "192.168.0.1"
  ],
  "public_ping_targets": [
    "1.1.1.1",
    "8.8.8.8",
    "9.9.9.9"
  ],
  "dns_names": [
    "google.com",
    "cloudflare.com",
    "ui.com"
  ],
  "tcp_targets": [
    "1.1.1.1:443",
    "8.8.8.8:53",
    "google.com:443"
  ],
  "interval_sec": 10,
  "outage_after_sec": 600,
  "latency_warning_ms": 150,
  "state_confirm_samples": 2,
  "slow_consecutive_samples": 3,
  "monitoring_traffic_limit_percent": 3.0,
  "minimum_expected_downlink_mbps": 10,
  "minimum_expected_uplink_mbps": 2,
  "adaptive_backoff_enabled": true,
  "dashboard_bind": "0.0.0.0",
  "dashboard_port": 8080,
  "log_dir": "/var/log/internet-telemetry",
  "keep_samples": 360
}
```

---

### 6.2 Editable Settings

The configuration page shall allow editing of:

```text
- Dream Router IP
- Provider router/modem IP list
- Public ping target list
- DNS lookup name list
- TCP target list
- Sampling interval
- Persistent outage threshold
- Slow latency warning threshold
- State confirmation sample count (debounce)
- Slow-state consecutive sample count
- Monitoring traffic limit percentage
- Minimum expected downlink speed
- Minimum expected uplink speed
- Adaptive backoff enable/disable
- Dashboard bind address
- Dashboard port
- Log directory
- Number of recent samples kept in memory
```

Each list field shall support one item per line.

Example provider IP input:

```text
192.168.100.1
192.168.0.1
```

Example TCP target input:

```text
1.1.1.1:443
8.8.8.8:53
google.com:443
```

---

### 6.3 Configuration Validation

Before saving, the application shall validate:

```text
- IP address fields are valid IPv4 addresses, or valid hostnames where applicable
- TCP targets use host:port format
- TCP ports are in range 1..65535
- Sampling interval is greater than or equal to 5 seconds
- Outage threshold is greater than or equal to sampling interval
- Latency warning threshold is greater than 0 ms
- State confirmation sample count is between 1 and 10
- Slow-state consecutive sample count is between 1 and 30
- Monitoring traffic limit percentage is greater than 0 and less than or equal to 3
- Minimum expected downlink and uplink speeds are greater than 0
- Estimated monitoring traffic does not exceed the configured traffic budget
- Dashboard port is in range 1..65535
- Log directory is an absolute path
```

If validation fails, the page shall show a clear error and shall not save the invalid configuration.

---

### 6.4 Save and Apply Behavior

The configuration page shall provide these buttons:

```text
Save
Save and Restart Service
Reset to Defaults
Download Config
```

Button behavior:

```text
Save:
- Validate input
- Write /etc/internet-telemetry/config.json
- Show message that restart is required for some settings

Save and Restart Service:
- Validate input
- Write /etc/internet-telemetry/config.json
- Restart internet-telemetry-dashboard.service
- Return user to dashboard after restart

Reset to Defaults:
- Restore default configuration values in the form
- Require confirmation before writing to disk

Download Config:
- Download current config.json from browser
```

The service restart shall be handled safely. If the web request triggers restart, the page shall show a message:

```text
Configuration saved. Service is restarting. Refresh dashboard in a few seconds.
```

**Lock-out protection:** if `dashboard_bind` or `dashboard_port` was changed, the page shall show an explicit warning containing the new dashboard URL before the restart is triggered, for example:

```text
Warning: the dashboard address will change.
After restart, open: http://192.168.1.20:9090
```

The README shall document the recovery procedure for an unreachable dashboard after a bad bind/port change:

```bash
pct exec <CTID> -- nano /etc/internet-telemetry/config.json
pct exec <CTID> -- systemctl restart internet-telemetry-dashboard.service
```

---

### 6.5 API Endpoints

The web application shall expose configuration API endpoints:

```text
GET  /config
GET  /api/config
POST /api/config
POST /api/config/restart
POST /api/config/defaults
```

Endpoint behavior:

```text
GET /config:
- Render configuration web page

GET /api/config:
- Return current configuration as JSON

POST /api/config:
- Validate and save configuration
- Return validation result

POST /api/config/restart:
- Validate and save configuration
- Restart the service

POST /api/config/defaults:
- Return default configuration
- Shall not overwrite current config unless explicitly confirmed
```

---

### 6.6 Security Requirements

The configuration page shall be intended for local LAN use only.

First version requirements:

```text
- Do not expose dashboard to public internet
- Bind to LAN/container IP or 0.0.0.0 only inside trusted LAN
- Do not include cloud dependencies
- Do not store passwords
- Do not execute arbitrary shell commands from user input
- Only allow writing to /etc/internet-telemetry/config.json
- Validate the HTTP Host header against the configured dashboard
  address (and localhost); reject other hosts to block DNS rebinding
- Reject state-changing POST requests that carry a cross-site Origin
  header, and require the X-Requested-With header on all POST
  endpoints, so a malicious web page opened on the LAN cannot
  silently rewrite the configuration (CSRF protection)
- The /log endpoint shall accept only plain file basenames, resolve
  them strictly inside the log directory, and reject "..", path
  separators, absolute paths, and symlinks leaving the log directory
```

"Trusted LAN only" does not protect against CSRF or DNS rebinding, because the attack rides inside the user's own browser. The mitigations above are mandatory for the first release even without authentication.

Future optional enhancement:

```text
- Add basic username/password authentication
- Add HTTPS reverse proxy support
- Add allowed client IP list
```

---

### 6.7 Dashboard Navigation

The dashboard shall include top navigation links:

```text
Dashboard
Configuration
Logs
Events
```

The main dashboard shall show a small configuration summary:

```text
Dream Router: 192.168.1.1
Provider targets: 2
Public ping targets: 3
DNS targets: 3
TCP targets: 3
Sample interval: 10 s
Outage threshold: 600 s
Traffic budget: 3% of configured minimum link speed
Estimated telemetry traffic: <calculated> kbps
```

---

## 7. Logging Requirements

The service shall write logs to:

```text
/var/log/internet-telemetry
```

Required files:

```text
telemetry_YYYY-MM-DD.jsonl
summary_YYYY-MM-DD.csv
events/*.json
```

### 7.1 JSONL Telemetry

Each JSONL row shall contain the full raw sample.

### 7.2 CSV Summary

The CSV file shall include at minimum:

```text
timestamp_utc
state
severity
dream_ok
dream_latency_ms
provider_any_ok
provider_best_latency_ms
public_any_ok
public_best_latency_ms
dns_any_ok
tcp_any_ok
load_1min
mem_used_percent
disk_used_percent
message
```

### 7.3 Log Rotation

Install logrotate configuration:

```text
- Rotate daily
- Keep 30 days
- Compress old logs
- Do not fail if files are missing
```

---

## 8. systemd Service Requirements

The installer shall create this service inside the LXC:

```text
internet-telemetry-dashboard.service
```

The service shall:

```text
- Start after network-online.target
- Restart automatically on failure
- Restart with 5 second delay
- Start on container boot
```

Useful commands shall be documented:

```bash
systemctl status internet-telemetry-dashboard.service
systemctl restart internet-telemetry-dashboard.service
journalctl -u internet-telemetry-dashboard.service -f
```

From the Proxmox host:

```bash
pct exec <CTID> -- systemctl status internet-telemetry-dashboard.service
pct exec <CTID> -- journalctl -u internet-telemetry-dashboard.service -f
pct exec <CTID> -- tail -n 20 /var/log/internet-telemetry/summary_*.csv
```

---

## 9. Installer Script Requirements

The installer script shall be idempotent where reasonable, but it shall not overwrite an existing container with the same CTID.

If the CTID already exists, the script shall exit with a clear message:

```text
Container CTID already exists. Choose another CTID.
```

The script shall print a final summary:

```text
Container ID
Hostname
Container IP
Dashboard URL
Useful pct commands
Log directory
Service name
```

Example output:

```text
Dashboard available at:

    http://192.168.1.20:8080

Useful commands:

    pct enter 120
    pct exec 120 -- journalctl -u internet-telemetry-dashboard.service -f
    pct exec 120 -- ls -lah /var/log/internet-telemetry
    pct exec 120 -- tail -n 20 /var/log/internet-telemetry/summary_*.csv
```

---

## 10. Acceptance Criteria

The implementation is accepted when the following tests pass.

### Test 1 — LXC Creation

Run:

```bash
./create_internet_telemetry_dashboard_lxc.sh
```

Expected result:

```text
- Debian LXC is created
- Container starts successfully
- Container is reachable on configured IP
- Container starts automatically on Proxmox boot
```

---

### Test 2 — Service Running

Run:

```bash
pct exec 120 -- systemctl status internet-telemetry-dashboard.service
```

Expected result:

```text
Service is active/running
```

---

### Test 3 — Dashboard Reachable

Open:

```text
http://192.168.1.20:8080
```

Expected result:

```text
Dashboard loads without internet dependency
Current state is visible
Recent samples table updates automatically
```

---

### Test 4 — API Works

Run:

```bash
curl http://192.168.1.20:8080/api/status
```

Expected result:

```text
Valid JSON is returned
JSON contains latest state, samples, events, config, logs, and traffic budget status
```

---

### Test 5 — Logs Created

Run:

```bash
pct exec 120 -- ls -lah /var/log/internet-telemetry
```

Expected result:

```text
telemetry_YYYY-MM-DD.jsonl exists
summary_YYYY-MM-DD.csv exists
events/ directory exists
```

---

### Test 6 — Configuration Page Opens

Open:

```text
http://192.168.1.20:8080/config
```

Expected result:

```text
Configuration page opens
Current values are loaded from /etc/internet-telemetry/config.json
List fields are displayed one item per line
```

---

### Test 7 — Configuration Validation

Try to save invalid values:

```text
TCP target: 1.1.1.1:notaport
Interval: 1
Dashboard port: 99999
Log directory: relative/path
```

Expected result:

```text
Invalid values are rejected
Clear validation error is displayed
Config file is not overwritten
```

---

### Test 8 — Save and Restart Configuration

Edit a valid setting, then click:

```text
Save and Restart Service
```

Expected result:

```text
/etc/internet-telemetry/config.json is updated
internet-telemetry-dashboard.service restarts
Dashboard uses the new configuration after restart
```

---

### Test 9 — Monitoring Traffic Budget

Use a deliberately aggressive configuration, for example very short interval or too many targets.

Expected result:

```text
Configuration is rejected if estimated monitoring traffic exceeds 3% of configured minimum expected link speed
Dashboard shows estimated telemetry traffic and budget usage
During INTERNET_SLOW or outage states, the service does not increase probe traffic
No automatic speed test or bulk download is started
```

---

### Test 10 — Failure Classification

Disconnect or block one path at a time and verify classification. Practical methods: use a firewall rule on the Dream Router blocking traffic from the container's IP to the relevant targets, or temporary `iptables`/`nft` drop rules inside the container itself for a quick simulation.

```text
Block Dream Router access (drop traffic to 192.168.1.1 in the container):
Expected: LOCAL_LAN_OR_DREAM_ROUTER_DOWN

Block public internet but keep provider router reachable
(drop traffic to the public ping targets only):
Expected: ISP_OR_COAX_UPSTREAM_DOWN
(if the provider router never answers on this ISP setup: WAN_DOWN)

Break DNS only (set an unreachable DNS server or drop port 53):
Expected: DNS_FAILURE

Introduce high latency (e.g. tc netem delay on the container interface):
Expected: INTERNET_SLOW after slow_consecutive_samples samples
```

Each expected state shall appear only after the debounce condition is met, not on the first failing sample.

---

### Test 11 — Persistent Outage Event

Set outage threshold low for test:

```bash
OUTAGE_AFTER_SEC=30 ./create_internet_telemetry_dashboard_lxc.sh
```

Or edit configuration temporarily.

Expected result after continuous failure:

```text
persistent_outage event appears in dashboard
JSON event file appears in /var/log/internet-telemetry/events
```

---

### Test 12 — State Debouncing

Drop exactly one ping (for example, briefly block one public target for a single sample) while everything else stays up.

Expected result:

```text
Reported state remains OK
No state-change event is generated
The raw sample classification may differ, but the debounced state does not flap
```

---

### Test 13 — Endpoint Hardening

Run:

```bash
curl "http://192.168.1.20:8080/log?file=../../etc/passwd"
curl "http://192.168.1.20:8080/log?file=/etc/shadow"
curl -X POST http://192.168.1.20:8080/api/config -H "Origin: http://evil.example" -d '{}'
curl -X POST http://192.168.1.20:8080/api/config -d '{}'
curl -H "Host: attacker.example" http://192.168.1.20:8080/api/status
```

Expected result:

```text
Path traversal requests are rejected with an error status
Cross-origin POST is rejected
POST without X-Requested-With header is rejected
Request with unknown Host header is rejected
Legitimate dashboard requests continue to work
```

---

## 11. Non-Goals for First Version

The first implementation shall not include:

```text
- Automatic relay reboot
- Smart plug control
- Router login automation
- Telegram/email notifications
- Prometheus/Grafana integration
- Automatic speed tests or continuous bandwidth tests
- Authentication
- Public internet exposure of dashboard
```

These can be added later after telemetry proves the real failure mode.

---

## 12. Future Enhancements

Recommended next features:

```text
1. Optional smart plug / relay reboot action
2. Reboot cooldown and daily reboot limit
3. Manual reboot button with confirmation
4. Email/Telegram outage notifications
5. Export dashboard charts
6. Prometheus metrics endpoint
7. Grafana dashboard
8. DOCSIS modem signal scraping if provider router exposes signal page
9. UPS monitoring
10. Multi-WAN / LTE failover status tracking
11. Basic local authentication
12. HTTPS reverse proxy support
13. Optional manual speed test with strict rate limits and explicit user confirmation
```

---

## 13. Safety Requirement for Future Reboot Control

If automatic reboot is later implemented, it shall follow these rules:

```text
- Never reboot on LOCAL_LAN_OR_DREAM_ROUTER_DOWN
- Only reboot on persistent outage states
- Require at least two independent public targets to fail
- Require failure duration longer than configured threshold
- Enforce reboot cooldown
- Enforce daily reboot limit
- Log every reboot decision
- Provide manual disable flag
```

Recommended reboot candidate states:

```text
PROVIDER_ROUTER_OR_WAN_LINK_DOWN
ISP_OR_COAX_UPSTREAM_DOWN
WAN_DOWN
```

Do not switch mains voltage with unsafe relay hardware. Prefer certified smart plug, DC-side switching, or properly enclosed DIN-rail hardware.

---

## 14. Definition of Done

The task is complete when:

```text
- A single Proxmox installer script creates the monitoring LXC
- The telemetry dashboard service starts automatically
- The dashboard is reachable on the LAN
- The configuration page is reachable and functional
- Configuration is persisted in /etc/internet-telemetry/config.json
- Invalid configuration is rejected
- Monitoring traffic budget is enforced and visible in dashboard
- Save and Restart applies valid configuration
- JSONL and CSV logs are generated
- Outage/recovery events are generated
- State debouncing prevents single-packet-loss flapping
- Web endpoints reject CSRF, DNS rebinding, and log path traversal
- README explains installation, configuration, troubleshooting, and
  dashboard lock-out recovery via pct exec
- Acceptance tests pass
- No automatic reboot is performed in this version
```

---

## 15. Implementation Notes

### 15.1 Recommended file layout inside the LXC

```text
/opt/internet-telemetry/
    network_telemetry_dashboard.py

/etc/internet-telemetry/
    config.json

/etc/systemd/system/
    internet-telemetry-dashboard.service

/etc/logrotate.d/
    internet-telemetry

/var/log/internet-telemetry/
    telemetry_YYYY-MM-DD.jsonl
    summary_YYYY-MM-DD.csv
    events/
```

### 15.2 Recommended web implementation

Use only Python standard library for first version:

```text
http.server.ThreadingHTTPServer
BaseHTTPRequestHandler
json
csv
socket
subprocess
threading
pathlib
```

Do not require Flask, FastAPI, Node.js, external JavaScript frameworks, or CDN dependencies for first release.

### 15.3 Recommended configuration workflow

At startup:

```text
1. Load /etc/internet-telemetry/config.json
2. If missing, create default config
3. Validate loaded config, including monitoring traffic budget
4. If invalid, log error and fall back to defaults
5. Start telemetry collector
6. Start dashboard server
```

When saving config:

```text
1. Parse submitted form/API payload
2. Validate all fields, including estimated telemetry traffic against the 3% limit
3. Write temporary config file
4. Atomically replace config.json
5. Return success or validation error
```

For restart:

```text
1. Save valid config
2. Spawn delayed restart command
3. Return HTTP response before service stops
4. Restart systemd service after short delay
```

### 15.4 Suggested safe restart method

The web app should avoid blocking its own HTTP response during restart. Use a delayed restart command such as:

```bash
/bin/sh -c 'sleep 1; systemctl restart internet-telemetry-dashboard.service' &
```

Only this fixed command may be executed. Do not pass user input into shell commands.

---

## 16. Final Review Checklist

Before marking implementation complete, verify:

```text
[ ] Installer refuses to overwrite existing CTID
[ ] LXC starts after Proxmox reboot
[ ] Dashboard starts after LXC reboot
[ ] /api/status returns valid JSON
[ ] /config page loads
[ ] Config save works
[ ] Config restart works
[ ] Invalid config is rejected
[ ] Monitoring traffic estimate is visible in dashboard
[ ] Configurations exceeding 3% traffic budget are rejected
[ ] No speed test or bulk download runs automatically
[ ] JSONL logs contain full telemetry
[ ] CSV logs open cleanly in spreadsheet software
[ ] Event JSON files are generated
[ ] Dashboard requires no internet resources
[ ] No automatic reboot action exists in v1
[ ] Single dropped ping does not change reported state (debounce works)
[ ] WAN_DOWN is used when the provider router has no reachability baseline
[ ] Installer verifies ICMP ping works inside the unprivileged LXC
[ ] /log rejects path traversal and absolute paths
[ ] POST endpoints reject cross-site and header-less requests
[ ] Unknown Host header is rejected (DNS rebinding)
[ ] Changing bind/port shows the new dashboard URL before restart
[ ] README explains how to change IPs
[ ] README explains common failure states
[ ] README explains dashboard lock-out recovery
```
