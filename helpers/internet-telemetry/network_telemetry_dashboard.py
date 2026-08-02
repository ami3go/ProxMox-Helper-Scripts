#!/usr/bin/env python3
"""
Internet telemetry collector + web dashboard.

Runs inside a Debian LXC on Proxmox. Monitors LAN router, provider
router/modem, public internet, DNS and TCP reachability, classifies
failures with quorum + debounce rules, logs JSONL/CSV, emits events,
and serves a local dashboard with a configuration page.

Python standard library only. See task spec (revision 2).
"""

import csv
import ipaddress
import json
import os
import re
import shutil
import socket
import statistics
import subprocess
import sys
import threading
import time
import urllib.parse
from datetime import datetime, timezone, timedelta
from http.server import ThreadingHTTPServer, BaseHTTPRequestHandler
from pathlib import Path

APP_VERSION = "1.0.0"
SERVICE_NAME = "internet-telemetry-dashboard.service"
CONFIG_PATH = Path(os.environ.get("IT_CONFIG", "/etc/internet-telemetry/config.json"))

# ---------------------------------------------------------------------------
# Defaults and constants
# ---------------------------------------------------------------------------

DEFAULT_CONFIG = {
    "dream_ip": "192.168.1.1",
    "provider_ips": ["192.168.100.1", "192.168.0.1"],
    "public_ping_targets": ["1.1.1.1", "8.8.8.8", "9.9.9.9"],
    "dns_names": ["google.com", "cloudflare.com", "ui.com"],
    "tcp_targets": ["1.1.1.1:443", "8.8.8.8:53", "google.com:443"],
    "interval_sec": 10,
    "outage_after_sec": 600,
    "latency_warning_ms": 150,
    "state_confirm_samples": 2,
    "slow_consecutive_samples": 3,
    "monitoring_traffic_limit_percent": 3.0,
    "minimum_expected_downlink_mbps": 10,
    "minimum_expected_uplink_mbps": 2,
    "adaptive_backoff_enabled": True,
    "dashboard_bind": "0.0.0.0",
    "dashboard_port": 8080,
    "log_dir": "/var/log/internet-telemetry",
    "keep_samples": 720,
}

# Conservative per-probe traffic estimates (bytes on the wire, both
# directions, including headers, rounded up).
BYTES_PER_PING = 2 * 120       # 1 ICMP echo request + reply
BYTES_PER_DNS = 450            # query + response (UDP, generous)
BYTES_PER_TCP = 600            # SYN/SYN-ACK/ACK + FIN teardown (generous)

STATE_OK = "OK"
STATE_OK_PROVIDER_NR = "OK_PROVIDER_ROUTER_NOT_REACHABLE"
STATE_LAN_DOWN = "LOCAL_LAN_OR_DREAM_ROUTER_DOWN"
STATE_PROVIDER_DOWN = "PROVIDER_ROUTER_OR_WAN_LINK_DOWN"
STATE_ISP_DOWN = "ISP_OR_COAX_UPSTREAM_DOWN"
STATE_WAN_DOWN = "WAN_DOWN"
STATE_DNS_FAIL = "DNS_FAILURE"
STATE_SLOW = "INTERNET_SLOW"
STATE_UNKNOWN = "UNKNOWN_FAILURE"
STATE_COLLECTOR_ERROR = "COLLECTOR_ERROR"

FAILURE_STATES = {
    STATE_LAN_DOWN, STATE_PROVIDER_DOWN, STATE_ISP_DOWN, STATE_WAN_DOWN,
    STATE_DNS_FAIL, STATE_SLOW, STATE_UNKNOWN,
}
REBOOT_CANDIDATE_STATES = {STATE_PROVIDER_DOWN, STATE_ISP_DOWN, STATE_WAN_DOWN}

SEVERITY = {
    STATE_OK: "ok",
    STATE_OK_PROVIDER_NR: "info",
    STATE_SLOW: "warning",
    STATE_DNS_FAIL: "warning",
    STATE_LAN_DOWN: "critical",
    STATE_PROVIDER_DOWN: "critical",
    STATE_ISP_DOWN: "critical",
    STATE_WAN_DOWN: "critical",
    STATE_UNKNOWN: "critical",
    STATE_COLLECTOR_ERROR: "error",
}

STATE_MESSAGES = {
    STATE_OK: "All monitored paths are healthy.",
    STATE_OK_PROVIDER_NR: "Internet is up. Provider router management IP is not answering (often normal in bridge mode).",
    STATE_LAN_DOWN: "The Dream Router / local LAN is unreachable from the monitoring container.",
    STATE_PROVIDER_DOWN: "LAN is up but the provider router/modem and the internet are unreachable. Provider device or WAN link problem.",
    STATE_ISP_DOWN: "Provider router answers but the internet is unreachable. Likely coax / ISP upstream outage.",
    STATE_WAN_DOWN: "LAN is up, internet is down. Provider router has no reachability baseline, so provider vs upstream cannot be distinguished.",
    STATE_DNS_FAIL: "Internet is reachable by IP but all DNS lookups fail.",
    STATE_SLOW: "Internet is reachable but latency exceeds the configured threshold.",
    STATE_UNKNOWN: "Unclassified failure pattern.",
    STATE_COLLECTOR_ERROR: "The telemetry collector itself hit an error. Check journalctl.",
}

CSV_FIELDS = [
    "timestamp_utc", "state", "severity",
    "dream_ok", "dream_latency_ms",
    "provider_any_ok", "provider_best_latency_ms",
    "public_any_ok", "public_best_latency_ms",
    "dns_any_ok", "tcp_any_ok",
    "load_1min", "mem_used_percent", "disk_used_percent",
    "message",
]

HOSTNAME_RE = re.compile(r"^(?=.{1,253}$)[a-zA-Z0-9]([a-zA-Z0-9-]{0,62})(\.[a-zA-Z0-9]([a-zA-Z0-9-]{0,62}))*$")
LOG_BASENAME_RE = re.compile(r"^[A-Za-z0-9._-]+$")


def utcnow():
    return datetime.now(timezone.utc)


def iso(dt):
    return dt.strftime("%Y-%m-%dT%H:%M:%SZ")


def log(msg):
    print(f"[{iso(utcnow())}] {msg}", flush=True)


# ---------------------------------------------------------------------------
# Traffic budget estimation
# ---------------------------------------------------------------------------

def estimate_sample_bytes(cfg):
    n_ping = 1 + len(cfg["provider_ips"]) + len(cfg["public_ping_targets"])
    return (n_ping * BYTES_PER_PING
            + len(cfg["dns_names"]) * BYTES_PER_DNS
            + len(cfg["tcp_targets"]) * BYTES_PER_TCP)


def traffic_estimate(cfg):
    per_sample = estimate_sample_bytes(cfg)
    interval = max(1, int(cfg["interval_sec"]))
    kbps = per_sample * 8 / interval / 1000.0
    per_minute_kb = per_sample * (60.0 / interval) / 1000.0
    min_mbps = min(float(cfg["minimum_expected_downlink_mbps"]),
                   float(cfg["minimum_expected_uplink_mbps"]))
    budget_kbps = min_mbps * 1000.0 * float(cfg["monitoring_traffic_limit_percent"]) / 100.0
    usage_pct = (kbps / budget_kbps * 100.0) if budget_kbps > 0 else 100.0
    if usage_pct > 100.0:
        status = "EXCEEDED"
    elif usage_pct > 50.0:
        status = "WARNING"
    else:
        status = "OK"
    return {
        "bytes_per_sample": per_sample,
        "kb_per_minute": round(per_minute_kb, 2),
        "estimated_kbps": round(kbps, 3),
        "budget_kbps": round(budget_kbps, 3),
        "budget_usage_percent": round(usage_pct, 1),
        "budget_status": status,
    }


# ---------------------------------------------------------------------------
# Configuration: load / validate / save
# ---------------------------------------------------------------------------

def _is_ipv4(s):
    try:
        ipaddress.IPv4Address(s)
        return True
    except ValueError:
        return False


def _is_host(s):
    return _is_ipv4(s) or bool(HOSTNAME_RE.match(s))


def _as_str_list(v):
    if isinstance(v, list):
        return [str(x).strip() for x in v if str(x).strip()]
    if isinstance(v, str):
        return [line.strip() for line in v.splitlines() if line.strip()]
    return None


def validate_config(raw):
    """Return (config, errors). config is normalized; errors is a list of strings."""
    errors = []
    cfg = dict(DEFAULT_CONFIG)
    if not isinstance(raw, dict):
        return cfg, ["Configuration must be a JSON object."]

    unknown = set(raw) - set(DEFAULT_CONFIG)
    for k in unknown:
        errors.append(f"Unknown setting: {k}")

    merged = dict(DEFAULT_CONFIG)
    merged.update({k: v for k, v in raw.items() if k in DEFAULT_CONFIG})

    # --- scalar host fields
    dream = str(merged["dream_ip"]).strip()
    if not _is_ipv4(dream):
        errors.append("dream_ip must be a valid IPv4 address.")
    cfg["dream_ip"] = dream

    # --- list fields
    for key, ip_only in (("provider_ips", True), ("public_ping_targets", False), ("dns_names", False)):
        vals = _as_str_list(merged[key])
        if vals is None or not vals:
            errors.append(f"{key} must contain at least one entry.")
            vals = DEFAULT_CONFIG[key]
        for v in vals:
            if ip_only and not _is_ipv4(v):
                errors.append(f"{key}: '{v}' is not a valid IPv4 address.")
            elif not ip_only and not _is_host(v):
                errors.append(f"{key}: '{v}' is not a valid IPv4 address or hostname.")
        cfg[key] = vals

    tcp = _as_str_list(merged["tcp_targets"])
    if tcp is None or not tcp:
        errors.append("tcp_targets must contain at least one entry.")
        tcp = DEFAULT_CONFIG["tcp_targets"]
    for t in tcp:
        if ":" not in t:
            errors.append(f"tcp_targets: '{t}' must use host:port format.")
            continue
        host, _, port = t.rpartition(":")
        if not _is_host(host):
            errors.append(f"tcp_targets: '{t}' has an invalid host.")
        if not port.isdigit() or not (1 <= int(port) <= 65535):
            errors.append(f"tcp_targets: '{t}' port must be in range 1..65535.")
    cfg["tcp_targets"] = tcp

    # --- numeric fields
    def num(key, lo, hi, kind=float, msg=None):
        try:
            v = kind(merged[key])
        except (TypeError, ValueError):
            errors.append(msg or f"{key} must be a number.")
            return DEFAULT_CONFIG[key]
        if not (lo <= v <= hi):
            errors.append(msg or f"{key} must be between {lo} and {hi}.")
        return v

    cfg["interval_sec"] = num("interval_sec", 5, 3600, int,
                              "interval_sec must be an integer between 5 and 3600 seconds.")
    cfg["outage_after_sec"] = num("outage_after_sec", 5, 86400, int,
                                  "outage_after_sec must be an integer between 5 and 86400 seconds.")
    if cfg["outage_after_sec"] < cfg["interval_sec"]:
        errors.append("outage_after_sec must be greater than or equal to interval_sec.")
    cfg["latency_warning_ms"] = num("latency_warning_ms", 1, 100000, float,
                                    "latency_warning_ms must be greater than 0.")
    cfg["state_confirm_samples"] = num("state_confirm_samples", 1, 10, int,
                                       "state_confirm_samples must be between 1 and 10.")
    cfg["slow_consecutive_samples"] = num("slow_consecutive_samples", 1, 30, int,
                                          "slow_consecutive_samples must be between 1 and 30.")
    cfg["monitoring_traffic_limit_percent"] = num(
        "monitoring_traffic_limit_percent", 0.001, 3.0, float,
        "monitoring_traffic_limit_percent must be greater than 0 and at most 3.")
    cfg["minimum_expected_downlink_mbps"] = num(
        "minimum_expected_downlink_mbps", 0.001, 100000, float,
        "minimum_expected_downlink_mbps must be greater than 0.")
    cfg["minimum_expected_uplink_mbps"] = num(
        "minimum_expected_uplink_mbps", 0.001, 100000, float,
        "minimum_expected_uplink_mbps must be greater than 0.")
    cfg["dashboard_port"] = num("dashboard_port", 1, 65535, int,
                                "dashboard_port must be in range 1..65535.")
    cfg["keep_samples"] = num("keep_samples", 10, 100000, int,
                              "keep_samples must be between 10 and 100000.")

    cfg["adaptive_backoff_enabled"] = bool(merged["adaptive_backoff_enabled"])

    bind = str(merged["dashboard_bind"]).strip()
    if bind != "0.0.0.0" and not _is_ipv4(bind):
        errors.append("dashboard_bind must be 0.0.0.0 or a valid IPv4 address.")
    cfg["dashboard_bind"] = bind

    log_dir = str(merged["log_dir"]).strip()
    if not log_dir.startswith("/"):
        errors.append("log_dir must be an absolute path.")
    cfg["log_dir"] = log_dir

    # --- traffic budget (only meaningful if the rest parsed)
    if not errors:
        est = traffic_estimate(cfg)
        if est["budget_status"] == "EXCEEDED":
            errors.append(
                f"Estimated monitoring traffic {est['estimated_kbps']} kbps exceeds the "
                f"budget of {est['budget_kbps']} kbps "
                f"({cfg['monitoring_traffic_limit_percent']}% of the minimum expected link speed). "
                "Increase interval_sec, remove targets, or raise the minimum link speeds.")
    return cfg, errors


def load_config():
    if CONFIG_PATH.exists():
        try:
            raw = json.loads(CONFIG_PATH.read_text())
        except (OSError, json.JSONDecodeError) as e:
            log(f"CONFIG ERROR: cannot read {CONFIG_PATH}: {e}. Falling back to defaults.")
            return dict(DEFAULT_CONFIG)
        cfg, errors = validate_config(raw)
        if errors:
            log(f"CONFIG ERROR: {CONFIG_PATH} is invalid, falling back to defaults:")
            for e in errors:
                log(f"  - {e}")
            return dict(DEFAULT_CONFIG)
        return cfg
    log(f"No config at {CONFIG_PATH}; creating defaults.")
    save_config(dict(DEFAULT_CONFIG))
    return dict(DEFAULT_CONFIG)


def save_config(cfg):
    CONFIG_PATH.parent.mkdir(parents=True, exist_ok=True)
    tmp = CONFIG_PATH.with_suffix(".json.tmp")
    tmp.write_text(json.dumps(cfg, indent=2) + "\n")
    os.replace(tmp, CONFIG_PATH)


# ---------------------------------------------------------------------------
# Probes
# ---------------------------------------------------------------------------

PING_TIMEOUT = 2
DNS_TIMEOUT = 3
TCP_TIMEOUT = 3


def ping_once(host):
    """Return (ok, latency_ms)."""
    try:
        r = subprocess.run(
            ["ping", "-n", "-c", "1", "-W", str(PING_TIMEOUT), host],
            capture_output=True, text=True, timeout=PING_TIMEOUT + 3)
    except (subprocess.TimeoutExpired, OSError):
        return False, None
    if r.returncode != 0:
        return False, None
    m = re.search(r"time[=<]([\d.]+)", r.stdout)
    return True, (float(m.group(1)) if m else None)


def dns_lookup(name):
    """Return (ok, latency_ms). Runs getaddrinfo in a helper thread with a timeout."""
    result = {}

    def work():
        try:
            socket.getaddrinfo(name, None, family=socket.AF_INET)
            result["ok"] = True
        except OSError:
            result["ok"] = False

    t0 = time.monotonic()
    t = threading.Thread(target=work, daemon=True)
    t.start()
    t.join(DNS_TIMEOUT)
    elapsed = (time.monotonic() - t0) * 1000.0
    if t.is_alive() or not result.get("ok"):
        return False, None
    return True, round(elapsed, 1)


def tcp_check(target):
    """Return (ok, latency_ms)."""
    host, _, port = target.rpartition(":")
    t0 = time.monotonic()
    try:
        with socket.create_connection((host, int(port)), timeout=TCP_TIMEOUT):
            pass
        return True, round((time.monotonic() - t0) * 1000.0, 1)
    except OSError:
        return False, None


def system_metrics():
    m = {"load_1min": None, "mem_used_percent": None, "disk_used_percent": None,
         "hostname": socket.gethostname(), "default_route": None}
    try:
        m["load_1min"] = round(os.getloadavg()[0], 2)
    except OSError:
        pass
    try:
        info = {}
        with open("/proc/meminfo") as f:
            for line in f:
                k, _, v = line.partition(":")
                info[k] = int(v.strip().split()[0])
        total = info.get("MemTotal", 0)
        avail = info.get("MemAvailable", 0)
        if total:
            m["mem_used_percent"] = round((total - avail) / total * 100.0, 1)
    except (OSError, ValueError):
        pass
    try:
        du = shutil.disk_usage("/")
        m["disk_used_percent"] = round(du.used / du.total * 100.0, 1)
    except OSError:
        pass
    try:
        r = subprocess.run(["ip", "route", "show", "default"],
                           capture_output=True, text=True, timeout=3)
        m["default_route"] = r.stdout.strip().splitlines()[0] if r.stdout.strip() else None
    except (OSError, subprocess.TimeoutExpired, IndexError):
        pass
    return m


# ---------------------------------------------------------------------------
# Collector
# ---------------------------------------------------------------------------

class Collector:
    def __init__(self, cfg):
        self.cfg = cfg
        self.lock = threading.Lock()
        self.samples = []            # newest last, bounded by keep_samples
        self.events = []             # newest last, bounded to 300 in memory
        self.reported_state = None
        self.state_since = utcnow()
        self.pending_state = None
        self.pending_count = 0
        self.failure_since = None
        self.persistent_emitted = False
        self.last_provider_ok = None  # datetime of last provider reply during OK-ish state
        self.stop = threading.Event()

        self.log_dir = Path(cfg["log_dir"])
        self.events_dir = self.log_dir / "events"
        self.log_dir.mkdir(parents=True, exist_ok=True)
        self.events_dir.mkdir(parents=True, exist_ok=True)
        self._load_runtime_state()

    # -- runtime state (provider baseline persistence) ----------------------

    def _runtime_path(self):
        return self.log_dir / "runtime_state.json"

    def _load_runtime_state(self):
        try:
            data = json.loads(self._runtime_path().read_text())
            ts = data.get("last_provider_ok_utc")
            if ts:
                self.last_provider_ok = datetime.strptime(
                    ts, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc)
        except (OSError, ValueError, json.JSONDecodeError):
            pass

    def _save_runtime_state(self):
        try:
            tmp = self._runtime_path().with_suffix(".tmp")
            tmp.write_text(json.dumps({
                "last_provider_ok_utc": iso(self.last_provider_ok) if self.last_provider_ok else None,
            }))
            os.replace(tmp, self._runtime_path())
        except OSError as e:
            log(f"runtime state write failed: {e}")

    def provider_baseline_reachable(self):
        if self.last_provider_ok is None:
            return False
        return utcnow() - self.last_provider_ok <= timedelta(hours=24)

    # -- adaptive backoff ---------------------------------------------------

    def _active_targets(self):
        cfg = self.cfg
        degraded = (self.reported_state in FAILURE_STATES
                    and self.failure_since is not None
                    and (utcnow() - self.failure_since).total_seconds() >= cfg["outage_after_sec"])
        if cfg["adaptive_backoff_enabled"] and degraded:
            return {
                "provider": cfg["provider_ips"][:1],
                "public": cfg["public_ping_targets"][:2],
                "dns": cfg["dns_names"][:1],
                "tcp": cfg["tcp_targets"][:1],
                "backoff": True,
            }
        return {
            "provider": cfg["provider_ips"],
            "public": cfg["public_ping_targets"],
            "dns": cfg["dns_names"],
            "tcp": cfg["tcp_targets"],
            "backoff": False,
        }

    # -- classification -----------------------------------------------------

    def classify(self, dream_ok, provider_any_ok, public_down, public_ok,
                 dns_any_ok, best_public_latency):
        cfg = self.cfg
        if not dream_ok:
            return STATE_LAN_DOWN
        if public_down:
            if not self.provider_baseline_reachable():
                return STATE_WAN_DOWN
            if not provider_any_ok:
                return STATE_PROVIDER_DOWN
            return STATE_ISP_DOWN
        if public_ok and not dns_any_ok:
            return STATE_DNS_FAIL
        if public_ok and best_public_latency is not None \
                and best_public_latency > cfg["latency_warning_ms"]:
            return STATE_SLOW
        if public_ok and self.provider_baseline_reachable() and not provider_any_ok:
            return STATE_OK_PROVIDER_NR
        if public_ok:
            return STATE_OK
        return STATE_UNKNOWN

    # -- debounce -----------------------------------------------------------

    def debounce(self, raw_state):
        cfg = self.cfg
        if raw_state == STATE_COLLECTOR_ERROR:
            self.pending_state, self.pending_count = raw_state, 0
            return self._transition_if_needed(raw_state)
        if raw_state == self.reported_state:
            self.pending_state, self.pending_count = None, 0
            return self.reported_state
        if raw_state == self.pending_state:
            self.pending_count += 1
        else:
            self.pending_state, self.pending_count = raw_state, 1
        needed = cfg["state_confirm_samples"]
        if raw_state == STATE_SLOW:
            needed = max(needed, cfg["slow_consecutive_samples"])
        if self.reported_state is None:
            needed = 1  # first-ever sample sets the state immediately
        if self.pending_count >= needed:
            return self._transition_if_needed(raw_state)
        return self.reported_state

    def _transition_if_needed(self, new_state):
        old = self.reported_state
        if new_state == old:
            return old
        now = utcnow()
        was_failure = old in FAILURE_STATES
        is_failure = new_state in FAILURE_STATES
        self.reported_state = new_state
        self.state_since = now
        self.pending_state, self.pending_count = None, 0

        if is_failure and not was_failure:
            self.failure_since = now
            self.persistent_emitted = False
        if not is_failure:
            if was_failure:
                dur = (now - self.failure_since).total_seconds() if self.failure_since else 0
                self.emit_event("recovery", new_state,
                                f"Recovered to {new_state} after {int(dur)} s of {old}.",
                                active_since=self.failure_since, duration_sec=int(dur))
            self.failure_since = None
            self.persistent_emitted = False
        if old is not None:
            self.emit_event("state_change", new_state,
                            f"State changed: {old} -> {new_state}.")
        return new_state

    # -- events -------------------------------------------------------------

    def emit_event(self, etype, state, message, active_since=None, duration_sec=None):
        now = utcnow()
        ev = {
            "timestamp_utc": iso(now),
            "type": etype,
            "state": state,
            "severity": SEVERITY.get(state, "info"),
            "message": message,
            "active_since_utc": iso(active_since) if active_since else None,
            "duration_sec": duration_sec,
            "reboot_candidate": bool(etype == "persistent_outage"
                                     and state in REBOOT_CANDIDATE_STATES),
        }
        with self.lock:
            self.events.append(ev)
            del self.events[:-300]
        fname = now.strftime("%Y%m%dT%H%M%SZ") + f"_{etype}.json"
        try:
            (self.events_dir / fname).write_text(json.dumps(ev, indent=2) + "\n")
        except OSError as e:
            log(f"event write failed: {e}")
        log(f"EVENT {etype}: {message}")

    def check_persistent_outage(self):
        if (self.reported_state in FAILURE_STATES and self.failure_since
                and not self.persistent_emitted):
            dur = (utcnow() - self.failure_since).total_seconds()
            if dur >= self.cfg["outage_after_sec"]:
                self.persistent_emitted = True
                self.emit_event(
                    "persistent_outage", self.reported_state,
                    f"Persistent outage: {self.reported_state} for {int(dur)} s "
                    f"(threshold {self.cfg['outage_after_sec']} s).",
                    active_since=self.failure_since, duration_sec=int(dur))

    # -- logging ------------------------------------------------------------

    def write_logs(self, sample):
        day = utcnow().strftime("%Y-%m-%d")
        try:
            with open(self.log_dir / f"telemetry_{day}.jsonl", "a") as f:
                f.write(json.dumps(sample) + "\n")
        except OSError as e:
            log(f"jsonl write failed: {e}")
        csv_path = self.log_dir / f"summary_{day}.csv"
        try:
            new = not csv_path.exists() or csv_path.stat().st_size == 0
            with open(csv_path, "a", newline="") as f:
                w = csv.DictWriter(f, fieldnames=CSV_FIELDS, extrasaction="ignore")
                if new:
                    w.writeheader()
                w.writerow({k: sample.get(k) for k in CSV_FIELDS})
        except OSError as e:
            log(f"csv write failed: {e}")

    # -- main sample --------------------------------------------------------

    def collect_sample(self):
        cfg = self.cfg
        now = utcnow()
        try:
            targets = self._active_targets()

            dream_ok, dream_lat = ping_once(cfg["dream_ip"])

            provider_results = {ip: ping_once(ip) for ip in targets["provider"]}
            provider_any_ok = any(ok for ok, _ in provider_results.values())
            provider_lats = [lat for ok, lat in provider_results.values() if ok and lat is not None]

            public_results = {ip: ping_once(ip) for ip in targets["public"]}
            public_any_ok = any(ok for ok, _ in public_results.values())
            public_down = all(not ok for ok, _ in public_results.values())
            public_lats = [lat for ok, lat in public_results.values() if ok and lat is not None]
            best_public = min(public_lats) if public_lats else None

            dns_results = {n: dns_lookup(n) for n in targets["dns"]}
            dns_any_ok = any(ok for ok, _ in dns_results.values())

            tcp_results = {t: tcp_check(t) for t in targets["tcp"]}
            tcp_any_ok = any(ok for ok, _ in tcp_results.values())

            sysm = system_metrics()

            raw_state = self.classify(dream_ok, provider_any_ok, public_down,
                                      public_any_ok, dns_any_ok, best_public)

            # provider baseline: only count replies seen while the connection is healthy
            if provider_any_ok and raw_state in (STATE_OK, STATE_SLOW, STATE_DNS_FAIL):
                self.last_provider_ok = now
                self._save_runtime_state()

        except Exception as e:  # collector must never die silently
            log(f"COLLECTOR ERROR: {e!r}")
            raw_state = STATE_COLLECTOR_ERROR
            dream_ok = provider_any_ok = public_any_ok = dns_any_ok = tcp_any_ok = False
            public_down = True
            dream_lat = best_public = None
            provider_lats = []
            provider_results = public_results = dns_results = tcp_results = {}
            targets = {"backoff": False}
            sysm = system_metrics()

        reported = self.debounce(raw_state)
        self.check_persistent_outage()

        est = traffic_estimate(cfg)
        sample = {
            "timestamp_utc": iso(now),
            "state": reported,
            "raw_state": raw_state,
            "severity": SEVERITY.get(reported, "info"),
            "message": STATE_MESSAGES.get(reported, ""),
            "state_since_utc": iso(self.state_since),
            "dream_ok": dream_ok,
            "dream_latency_ms": dream_lat,
            "provider_any_ok": provider_any_ok,
            "provider_best_latency_ms": min(provider_lats) if provider_lats else None,
            "provider_results": {k: {"ok": ok, "latency_ms": lat}
                                 for k, (ok, lat) in provider_results.items()},
            "provider_baseline_reachable": self.provider_baseline_reachable(),
            "public_any_ok": public_any_ok,
            "public_down": public_down,
            "public_best_latency_ms": best_public,
            "public_results": {k: {"ok": ok, "latency_ms": lat}
                               for k, (ok, lat) in public_results.items()},
            "dns_any_ok": dns_any_ok,
            "dns_results": {k: {"ok": ok, "latency_ms": lat}
                            for k, (ok, lat) in dns_results.items()},
            "tcp_any_ok": tcp_any_ok,
            "tcp_results": {k: {"ok": ok, "latency_ms": lat}
                            for k, (ok, lat) in tcp_results.items()},
            "adaptive_backoff_active": targets.get("backoff", False),
            "hostname": sysm["hostname"],
            "load_1min": sysm["load_1min"],
            "mem_used_percent": sysm["mem_used_percent"],
            "disk_used_percent": sysm["disk_used_percent"],
            "default_route": sysm["default_route"],
            "traffic_bytes_per_sample": est["bytes_per_sample"],
            "traffic_kb_per_minute": est["kb_per_minute"],
            "traffic_estimated_kbps": est["estimated_kbps"],
            "traffic_budget_kbps": est["budget_kbps"],
            "traffic_budget_usage_percent": est["budget_usage_percent"],
            "traffic_budget_status": est["budget_status"],
        }
        with self.lock:
            self.samples.append(sample)
            del self.samples[:-int(cfg["keep_samples"])]
        self.write_logs(sample)
        return sample

    def run(self):
        log(f"Collector started: interval={self.cfg['interval_sec']}s, "
            f"traffic estimate={traffic_estimate(self.cfg)['estimated_kbps']} kbps")
        last_prune = 0.0
        while not self.stop.is_set():
            t0 = time.monotonic()
            self.collect_sample()
            if time.monotonic() - last_prune > 86400 or last_prune == 0.0:
                self._prune_old_events()
                last_prune = time.monotonic()
            elapsed = time.monotonic() - t0
            self.stop.wait(max(0.5, self.cfg["interval_sec"] - elapsed))

    def _prune_old_events(self, max_age_days=30):
        cutoff = time.time() - max_age_days * 86400
        try:
            for p in self.events_dir.glob("*.json"):
                if p.stat().st_mtime < cutoff:
                    p.unlink(missing_ok=True)
        except OSError as e:
            log(f"event prune failed: {e}")

    # -- API snapshot --------------------------------------------------------

    @staticmethod
    def _compact_series(samples):
        """Small per-sample rows for client-side charts (keeps payload light)."""
        out = []
        for s in samples:
            out.append({
                "t": s["timestamp_utc"],
                "sev": s.get("severity", "info"),
                "st": s.get("state", ""),
                "pub": s.get("public_best_latency_ms"),
                "dr": s.get("dream_latency_ms"),
                "pr": s.get("provider_best_latency_ms"),
                "d": 1 if s.get("dream_ok") else 0,
                "p": 1 if s.get("provider_any_ok") else 0,
                "u": 1 if s.get("public_any_ok") else 0,
                "n": 1 if s.get("dns_any_ok") else 0,
                "c": 1 if s.get("tcp_any_ok") else 0,
            })
        return out

    def _window_summary(self, samples):
        """Availability stats over the in-memory ring."""
        if not samples:
            return {"samples": 0}
        n = len(samples)
        ok = sum(1 for s in samples if s["state"] == STATE_OK)
        failures = sum(1 for s in samples if s["state"] in FAILURE_STATES)
        # count down episodes + current streak length (consecutive same reported state)
        episodes, prev_fail = 0, False
        for s in samples:
            f = s["state"] in FAILURE_STATES
            if f and not prev_fail:
                episodes += 1
            prev_fail = f
        streak = 1
        for i in range(len(samples) - 2, -1, -1):
            if samples[i]["state"] == samples[-1]["state"]:
                streak += 1
            else:
                break
        try:
            t0 = datetime.strptime(samples[0]["timestamp_utc"], "%Y-%m-%dT%H:%M:%SZ")
            t1 = datetime.strptime(samples[-1]["timestamp_utc"], "%Y-%m-%dT%H:%M:%SZ")
            span_min = round((t1 - t0).total_seconds() / 60.0, 1)
        except (ValueError, KeyError):
            span_min = None
        pubs = [s["public_best_latency_ms"] for s in samples
                if s.get("public_best_latency_ms") is not None]
        pubs_sorted = sorted(pubs)
        p95 = pubs_sorted[min(len(pubs_sorted) - 1, int(0.95 * len(pubs_sorted)))] if pubs else None
        return {
            "samples": n,
            "window_minutes": span_min,
            "uptime_percent": round(ok / n * 100.0, 1),
            "failure_samples": failures,
            "down_episodes": episodes,
            "current_state": samples[-1]["state"],
            "current_streak_samples": streak,
            "public_latency_median_ms": round(statistics.median(pubs), 1) if pubs else None,
            "public_latency_p95_ms": round(p95, 1) if p95 is not None else None,
        }

    def status_snapshot(self):
        with self.lock:
            samples = list(self.samples)
            events = list(self.events)
        latest = samples[-1] if samples else None
        logs = []
        try:
            for p in sorted(self.log_dir.iterdir()):
                if p.is_file() and (p.suffix in (".jsonl", ".csv", ".gz")
                                    or ".jsonl" in p.name or ".csv" in p.name):
                    logs.append({"name": p.name, "size_bytes": p.stat().st_size})
        except OSError:
            pass
        cfg = self.cfg
        return {
            "app_version": APP_VERSION,
            "generated_utc": iso(utcnow()),
            "state": latest["state"] if latest else "STARTING",
            "message": latest["message"] if latest else "Collecting first sample...",
            "latest": latest,
            "samples": samples[-60:],
            "series": self._compact_series(samples),
            "window_summary": self._window_summary(samples),
            "events": events[-100:],
            "logs": logs,
            "traffic": traffic_estimate(cfg),
            "config_summary": {
                "dream_ip": cfg["dream_ip"],
                "provider_targets": len(cfg["provider_ips"]),
                "public_ping_targets": len(cfg["public_ping_targets"]),
                "dns_targets": len(cfg["dns_names"]),
                "tcp_targets": len(cfg["tcp_targets"]),
                "interval_sec": cfg["interval_sec"],
                "outage_after_sec": cfg["outage_after_sec"],
                "latency_warning_ms": cfg["latency_warning_ms"],
                "traffic_limit_percent": cfg["monitoring_traffic_limit_percent"],
                "adaptive_backoff_enabled": cfg["adaptive_backoff_enabled"],
            },
        }


# ---------------------------------------------------------------------------
# HTTP server
# ---------------------------------------------------------------------------

def local_ipv4_addresses():
    addrs = {"127.0.0.1", "localhost"}
    try:
        r = subprocess.run(["ip", "-o", "-4", "addr", "show"],
                           capture_output=True, text=True, timeout=3)
        for line in r.stdout.splitlines():
            m = re.search(r"inet (\d+\.\d+\.\d+\.\d+)/", line)
            if m:
                addrs.add(m.group(1))
    except (OSError, subprocess.TimeoutExpired):
        pass
    try:
        addrs.add(socket.gethostname())
        addrs.add(socket.gethostname() + ".local")
    except OSError:
        pass
    return {a.lower() for a in addrs}


class Handler(BaseHTTPRequestHandler):
    server_version = "internet-telemetry/" + APP_VERSION
    collector = None          # set at startup
    allowed_hosts = set()     # set at startup

    # ---- helpers ----------------------------------------------------------

    def log_message(self, fmt, *args):  # keep journal quiet; errors still surface
        pass

    def _send(self, code, body, ctype="text/html; charset=utf-8", extra=None):
        data = body.encode() if isinstance(body, str) else body
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("Referrer-Policy", "no-referrer")
        for k, v in (extra or {}).items():
            self.send_header(k, v)
        self.end_headers()
        self.wfile.write(data)

    def _json(self, obj, code=200):
        self._send(code, json.dumps(obj, indent=2), "application/json")

    def _host_allowed(self):
        host = (self.headers.get("Host") or "").split(":")[0].strip().lower()
        if not host:
            return False
        if host in self.allowed_hosts:
            return True
        if host == self.collector.cfg.get("dashboard_bind", "").lower():
            return True
        return False

    def _csrf_ok(self):
        origin = self.headers.get("Origin")
        if origin:
            try:
                ohost = urllib.parse.urlsplit(origin).hostname or ""
            except ValueError:
                return False
            if ohost.lower() not in self.allowed_hosts \
                    and ohost.lower() != self.collector.cfg.get("dashboard_bind", "").lower():
                return False
        if self.headers.get("X-Requested-With") is None:
            return False
        return True

    # ---- GET --------------------------------------------------------------

    def do_GET(self):
        if not self._host_allowed():
            self._json({"error": "Host header not allowed (DNS rebinding protection)."}, 421)
            return
        path, _, query = self.path.partition("?")
        params = urllib.parse.parse_qs(query)
        if path == "/":
            self._send(200, DASHBOARD_HTML)
        elif path == "/config":
            self._send(200, CONFIG_HTML)
        elif path == "/healthz":
            self._json({"status": "ok", "state": self.collector.reported_state or "STARTING"})
        elif path == "/api/status":
            self._json(self.collector.status_snapshot())
        elif path == "/api/config":
            self._json({"config": self.collector.cfg,
                        "traffic": traffic_estimate(self.collector.cfg)})
        elif path == "/log":
            self._serve_log(params)
        else:
            self._json({"error": "not found"}, 404)

    def _serve_log(self, params):
        name = (params.get("file") or [""])[0]
        if not LOG_BASENAME_RE.match(name) or ".." in name:
            self._json({"error": "invalid file name"}, 400)
            return
        log_dir = Path(self.collector.cfg["log_dir"]).resolve()
        target = (log_dir / name).resolve()
        if target.parent != log_dir or not target.is_file():
            self._json({"error": "file not found"}, 404)
            return
        ctype = "text/csv" if target.suffix == ".csv" else \
                "application/gzip" if target.suffix == ".gz" else "text/plain"
        try:
            self._send(200, target.read_bytes(), ctype + ("; charset=utf-8" if "text" in ctype else ""),
                       {"Content-Disposition": f'attachment; filename="{name}"'})
        except OSError:
            self._json({"error": "read failed"}, 500)

    # ---- POST -------------------------------------------------------------

    def do_POST(self):
        if not self._host_allowed():
            self._json({"error": "Host header not allowed (DNS rebinding protection)."}, 421)
            return
        if not self._csrf_ok():
            self._json({"error": "Cross-site request rejected. "
                                 "X-Requested-With header is required and Origin must match."}, 403)
            return
        path = self.path.partition("?")[0]
        if path == "/api/config/defaults":
            self._json({"config": dict(DEFAULT_CONFIG)})
            return
        if path not in ("/api/config", "/api/config/restart"):
            self._json({"error": "not found"}, 404)
            return
        try:
            length = int(self.headers.get("Content-Length") or 0)
            if length > 256 * 1024:
                self._json({"error": "payload too large"}, 413)
                return
            raw = json.loads(self.rfile.read(length) or b"{}")
        except (ValueError, OSError):
            self._json({"error": "invalid JSON body"}, 400)
            return
        cfg, errors = validate_config(raw)
        if errors:
            self._json({"saved": False, "errors": errors}, 400)
            return
        old_cfg = dict(self.collector.cfg)
        save_config(cfg)
        self.collector.cfg = cfg
        address_changed = (cfg["dashboard_bind"] != old_cfg["dashboard_bind"]
                           or cfg["dashboard_port"] != old_cfg["dashboard_port"])
        resp = {
            "saved": True,
            "errors": [],
            "restart_required": True,
            "address_changed": address_changed,
            "new_dashboard_url": f"http://<container-ip>:{cfg['dashboard_port']}"
                                 if address_changed else None,
            "traffic": traffic_estimate(cfg),
        }
        if path == "/api/config/restart":
            resp["restarting"] = True
            self._json(resp)
            # Fixed command only; user input is never passed to the shell.
            subprocess.Popen(
                ["/bin/sh", "-c",
                 f"sleep 1; systemctl restart {SERVICE_NAME}"],
                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            return
        self._json(resp)


# ---------------------------------------------------------------------------
# Dashboard HTML (no external dependencies; works fully offline)
# ---------------------------------------------------------------------------

BASE_CSS = """
:root{
  --bg:#10151c; --panel:#171e28; --panel2:#1d2634; --line:#2a3648;
  --text:#d7e0ec; --dim:#8496ad; --mono:'DejaVu Sans Mono',ui-monospace,Menlo,Consolas,monospace;
  --ok:#3fb96b; --info:#4d9fd6; --warn:#d6a53f; --crit:#d65454; --err:#b06ad6;
}
*{box-sizing:border-box} body{margin:0;background:var(--bg);color:var(--text);
  font:14px/1.5 system-ui,-apple-system,'Segoe UI',sans-serif}
a{color:var(--info);text-decoration:none} a:hover{text-decoration:underline}
header{display:flex;align-items:baseline;gap:1.2rem;padding:.9rem 1.4rem;
  border-bottom:1px solid var(--line);background:var(--panel)}
header h1{font-size:1rem;margin:0;letter-spacing:.06em;text-transform:uppercase;color:var(--dim)}
header h1 b{color:var(--text)} nav{margin-left:auto;display:flex;gap:1rem}
main{padding:1.2rem 1.4rem;max-width:1200px;margin:0 auto}
.grid{display:grid;gap:.8rem;grid-template-columns:repeat(auto-fit,minmax(230px,1fr))}
.card{background:var(--panel);border:1px solid var(--line);border-radius:8px;padding:.8rem 1rem}
.card h2{margin:0 0 .4rem;font-size:.72rem;letter-spacing:.08em;text-transform:uppercase;color:var(--dim)}
.big{font-family:var(--mono);font-size:1.5rem}
.pill{display:inline-block;padding:.35rem .9rem;border-radius:999px;font-family:var(--mono);
  font-weight:bold;letter-spacing:.03em}
.s-ok{background:rgba(63,185,107,.15);color:var(--ok);border:1px solid var(--ok)}
.s-info{background:rgba(77,159,214,.15);color:var(--info);border:1px solid var(--info)}
.s-warning{background:rgba(214,165,63,.15);color:var(--warn);border:1px solid var(--warn)}
.s-critical{background:rgba(214,84,84,.15);color:var(--crit);border:1px solid var(--crit)}
.s-error{background:rgba(176,106,214,.15);color:var(--err);border:1px solid var(--err)}
table{width:100%;border-collapse:collapse;font-family:var(--mono);font-size:.78rem}
th,td{padding:.3rem .5rem;border-bottom:1px solid var(--line);text-align:left;white-space:nowrap}
th{color:var(--dim);font-weight:normal;text-transform:uppercase;font-size:.68rem;letter-spacing:.06em}
.okv{color:var(--ok)} .failv{color:var(--crit)} .dimv{color:var(--dim)}
section{margin-top:1.4rem} section>h2{font-size:.8rem;letter-spacing:.08em;
  text-transform:uppercase;color:var(--dim);border-bottom:1px solid var(--line);padding-bottom:.3rem}
.scroll{overflow-x:auto}
button{background:var(--panel2);color:var(--text);border:1px solid var(--line);
  border-radius:6px;padding:.5rem 1rem;cursor:pointer;font:inherit}
button:hover{border-color:var(--info)} button.primary{border-color:var(--ok);color:var(--ok)}
button.danger{border-color:var(--crit);color:var(--crit)}
input,textarea{width:100%;background:var(--bg);color:var(--text);border:1px solid var(--line);
  border-radius:6px;padding:.45rem .6rem;font-family:var(--mono);font-size:.85rem}
label{display:block;margin:.7rem 0 .2rem;color:var(--dim);font-size:.78rem;
  text-transform:uppercase;letter-spacing:.05em}
.msg{margin:.8rem 0;padding:.6rem .9rem;border-radius:6px;display:none;white-space:pre-wrap}
.msg.err{display:block;background:rgba(214,84,84,.12);border:1px solid var(--crit)}
.msg.ok{display:block;background:rgba(63,185,107,.12);border:1px solid var(--ok)}
.msg.warn{display:block;background:rgba(214,165,63,.12);border:1px solid var(--warn)}
footer{color:var(--dim);font-size:.72rem;padding:1rem 1.4rem;text-align:center}
.chart{width:100%;display:block;background:var(--panel);border:1px solid var(--line);border-radius:8px}
.chartwrap{margin:.6rem 0}
.chartwrap .cap{color:var(--dim);font-size:.72rem;letter-spacing:.05em;text-transform:uppercase;margin:.2rem 0 .3rem}
.legend{display:flex;gap:1rem;flex-wrap:wrap;font-size:.72rem;color:var(--dim);margin:.2rem 0 .6rem}
.legend span{display:inline-flex;align-items:center;gap:.35rem}
.legend i{width:.7rem;height:.7rem;border-radius:2px;display:inline-block}
.stat{font-family:var(--mono)} .stat b{font-size:1.3rem;color:var(--text)}
.svgtip{fill:var(--text);font:10px var(--mono)} .svggrid{stroke:var(--line);stroke-width:1}
.svgaxis{fill:var(--dim);font:9px var(--mono)}
"""

NAV = """<header><h1><b>internet</b>-telemetry</h1>
<nav><a href="/">Dashboard</a><a href="/config">Configuration</a>
<a href="/#logs">Logs</a><a href="/#events">Events</a></nav></header>"""

DASHBOARD_HTML = f"""<!DOCTYPE html><html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>Internet telemetry</title><style>{BASE_CSS}</style></head><body>
{NAV}
<main>
<div class="grid">
  <div class="card" style="grid-column:1/-1;display:flex;gap:1.2rem;align-items:center;flex-wrap:wrap">
    <span id="state" class="pill s-info">STARTING</span>
    <span id="stateMsg" class="dimv">Collecting first sample…</span>
    <span id="stateSince" class="dimv" style="margin-left:auto"></span>
  </div>
  <div class="card"><h2>Dream Router</h2><div class="big" id="dream">–</div></div>
  <div class="card"><h2>Provider router</h2><div class="big" id="provider">–</div></div>
  <div class="card"><h2>Public internet</h2><div class="big" id="public">–</div></div>
  <div class="card"><h2>DNS</h2><div class="big" id="dns">–</div></div>
  <div class="card"><h2>TCP</h2><div class="big" id="tcp">–</div></div>
  <div class="card"><h2>Telemetry traffic</h2><div class="big" id="traffic">–</div>
    <div class="dimv" id="trafficDetail"></div></div>
  <div class="card"><h2>Container</h2><div id="sys" class="dimv" style="font-family:var(--mono)"></div></div>
  <div class="card"><h2>Configuration summary</h2><div id="cfgsum" class="dimv"
    style="font-family:var(--mono);font-size:.78rem"></div></div>
</div>

<section><h2>Recent samples</h2><div class="scroll"><table id="samples">
<thead><tr><th>time (utc)</th><th>state</th><th>dream</th><th>provider</th>
<th>public</th><th>dns</th><th>tcp</th><th>best pub ms</th></tr></thead>
<tbody></tbody></table></div></section>

<section id="events"><h2>Events &amp; live charts</h2>

<div class="grid" style="margin-bottom:.4rem">
  <div class="card"><h2>Window</h2><div class="stat"><b id="wsWindow">–</b> <span class="dimv">min</span></div></div>
  <div class="card"><h2>Uptime (window)</h2><div class="stat"><b id="wsUptime">–</b><span class="dimv">%</span></div></div>
  <div class="card"><h2>Down episodes</h2><div class="stat"><b id="wsEpisodes">–</b></div></div>
  <div class="card"><h2>Current streak</h2><div class="stat"><b id="wsStreak">–</b> <span class="dimv" id="wsStreakState"></span></div></div>
  <div class="card"><h2>Public latency</h2><div class="stat" style="font-size:.95rem">
    med <b id="wsMed">–</b> · p95 <b id="wsP95">–</b> <span class="dimv">ms</span></div></div>
</div>

<div class="chartwrap">
  <div class="cap">Availability timeline (each bar = one sample, left = oldest)</div>
  <div class="legend">
    <span><i style="background:#3fb96b"></i>OK</span>
    <span><i style="background:#4d9fd6"></i>info</span>
    <span><i style="background:#d6a53f"></i>slow / DNS</span>
    <span><i style="background:#d65454"></i>outage</span>
    <span><i style="background:#b06ad6"></i>collector error</span>
  </div>
  <svg id="cTimeline" class="chart" viewBox="0 0 1000 60" preserveAspectRatio="none" height="60"></svg>
</div>

<div class="chartwrap">
  <div class="cap">Best public latency over time (dashed line = slow threshold)</div>
  <svg id="cLatency" class="chart" viewBox="0 0 1000 200" preserveAspectRatio="none" height="200"></svg>
</div>

<div class="chartwrap">
  <div class="cap">Layer reachability (green = reachable, red = failed)</div>
  <svg id="cLayers" class="chart" viewBox="0 0 1000 150" preserveAspectRatio="none" height="150"></svg>
</div>

<div class="scroll"><table id="eventsTable">
<thead><tr><th>time (utc)</th><th>type</th><th>state</th><th>severity</th>
<th>duration</th><th>reboot cand.</th><th>message</th></tr></thead>
<tbody></tbody></table></div></section>

<section id="logs"><h2>Log files</h2><div class="scroll"><table id="logsTable">
<thead><tr><th>file</th><th>size</th></tr></thead><tbody></tbody></table></div></section>
</main>
<footer>Local monitoring only — no external resources, no automatic reboot in v1.
Auto-refresh every 5 s.</footer>
<script>
function esc(s){{return String(s??'').replace(/[&<>"]/g,c=>({{'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;'}}[c]))}}
function okf(v){{return v===true?'<span class="okv">OK</span>':v===false?'<span class="failv">FAIL</span>':'<span class="dimv">–</span>'}}
function latf(ok,lat){{return ok?(lat!=null?lat.toFixed(1)+' ms':'OK'):'FAIL'}}
async function refresh(){{
 try{{
  const r=await fetch('/api/status');const d=await r.json();
  const st=document.getElementById('state');
  st.textContent=d.state;st.className='pill s-'+((d.latest&&d.latest.severity)||'info');
  document.getElementById('stateMsg').textContent=d.message||'';
  const L=d.latest;
  if(L){{
   document.getElementById('stateSince').textContent='since '+L.state_since_utc+
     (L.adaptive_backoff_active?'  ·  adaptive backoff active':'');
   document.getElementById('dream').innerHTML=L.dream_ok?
     '<span class="okv">'+esc(latf(true,L.dream_latency_ms))+'</span>':'<span class="failv">FAIL</span>';
   document.getElementById('provider').innerHTML=L.provider_any_ok?
     '<span class="okv">'+esc(latf(true,L.provider_best_latency_ms))+'</span>':
     '<span class="'+(L.provider_baseline_reachable?'failv':'dimv')+'">'+
     (L.provider_baseline_reachable?'FAIL':'no answer')+'</span>';
   document.getElementById('public').innerHTML=L.public_any_ok?
     '<span class="okv">'+esc(latf(true,L.public_best_latency_ms))+'</span>':'<span class="failv">FAIL</span>';
   document.getElementById('dns').innerHTML=okf(L.dns_any_ok);
   document.getElementById('tcp').innerHTML=okf(L.tcp_any_ok);
   document.getElementById('sys').innerHTML=
     esc(L.hostname)+'<br>load '+esc(L.load_1min)+' · ram '+esc(L.mem_used_percent)+
     '% · disk '+esc(L.disk_used_percent)+'%<br><span style="font-size:.7rem">'+
     esc(L.default_route||'no default route')+'</span>';
  }}
  const t=d.traffic;
  document.getElementById('traffic').innerHTML=
    '<span class="'+(t.budget_status==='OK'?'okv':t.budget_status==='WARNING'?'':'failv')+'">'+
    t.estimated_kbps+' kbps</span>';
  document.getElementById('trafficDetail').textContent=
    'budget '+t.budget_kbps+' kbps · usage '+t.budget_usage_percent+'% · '+t.budget_status;
  const c=d.config_summary;
  document.getElementById('cfgsum').innerHTML=
    'Dream Router: '+esc(c.dream_ip)+'<br>Provider targets: '+c.provider_targets+
    ' · Public: '+c.public_ping_targets+' · DNS: '+c.dns_targets+' · TCP: '+c.tcp_targets+
    '<br>Interval: '+c.interval_sec+' s · Outage threshold: '+c.outage_after_sec+' s'+
    '<br>Slow threshold: '+c.latency_warning_ms+' ms · Budget: '+c.traffic_limit_percent+'% of min link';
  document.querySelector('#samples tbody').innerHTML=(d.samples||[]).slice().reverse().map(s=>
    '<tr><td>'+esc(s.timestamp_utc)+'</td><td class="'+
    (s.severity==='ok'?'okv':s.severity==='critical'||s.severity==='error'?'failv':'')+'">'+
    esc(s.state)+'</td><td>'+okf(s.dream_ok)+'</td><td>'+okf(s.provider_any_ok)+
    '</td><td>'+okf(s.public_any_ok)+'</td><td>'+okf(s.dns_any_ok)+'</td><td>'+okf(s.tcp_any_ok)+
    '</td><td>'+esc(s.public_best_latency_ms!=null?s.public_best_latency_ms.toFixed(1):'–')+'</td></tr>').join('');
  document.querySelector('#eventsTable tbody').innerHTML=(d.events||[]).slice().reverse().map(e=>
    '<tr><td>'+esc(e.timestamp_utc)+'</td><td>'+esc(e.type)+'</td><td>'+esc(e.state)+
    '</td><td class="'+(e.severity==='critical'?'failv':e.severity==='ok'?'okv':'')+'">'+esc(e.severity)+
    '</td><td>'+esc(e.duration_sec!=null?e.duration_sec+' s':'–')+'</td><td>'+
    (e.reboot_candidate?'<span class="failv">yes</span>':'no')+'</td><td>'+esc(e.message)+'</td></tr>').join('');
  document.querySelector('#logsTable tbody').innerHTML=(d.logs||[]).map(l=>
    '<tr><td><a href="/log?file='+encodeURIComponent(l.name)+'">'+esc(l.name)+'</a></td><td>'+
    (l.size_bytes/1024).toFixed(1)+' KB</td></tr>').join('');
  renderSummary(d.window_summary||{{}});
  renderCharts(d.series||[], (c&&c.latency_warning_ms)||150);
 }}catch(e){{document.getElementById('stateMsg').textContent='Dashboard cannot reach the API: '+e}}
}}

const SEVCOLOR={{ok:'#3fb96b',info:'#4d9fd6',warning:'#d6a53f',critical:'#d65454',error:'#b06ad6'}};
function renderSummary(w){{
  const set=(id,v)=>{{const el=document.getElementById(id);if(el)el.textContent=(v==null?'–':v);}};
  set('wsWindow',w.window_minutes);set('wsUptime',w.uptime_percent);
  set('wsEpisodes',w.down_episodes);set('wsStreak',w.current_streak_samples);
  set('wsStreakState',w.current_state?('× '+w.current_state):'');
  set('wsMed',w.public_latency_median_ms);set('wsP95',w.public_latency_p95_ms);
  const up=document.getElementById('wsUptime');
  if(up)up.style.color=w.uptime_percent>=99?'var(--ok)':w.uptime_percent>=90?'var(--warn)':'var(--crit)';
}}
const SVGNS='http://www.w3.org/2000/svg';
function el(tag,attrs){{const e=document.createElementNS(SVGNS,tag);
  for(const k in attrs)e.setAttribute(k,attrs[k]);return e;}}
function clear(svg){{while(svg.firstChild)svg.removeChild(svg.firstChild);}}

function renderCharts(series,threshold){{
  drawTimeline(document.getElementById('cTimeline'),series);
  drawLatency(document.getElementById('cLatency'),series,threshold);
  drawLayers(document.getElementById('cLayers'),series);
}}

function drawTimeline(svg,series){{
  if(!svg)return;clear(svg);
  const W=1000,H=60,n=series.length;if(!n){{return;}}
  const bw=W/n;
  for(let i=0;i<n;i++){{
    const rect=el('rect',{{x:(i*bw).toFixed(2),y:0,width:Math.ceil(bw)+0.5,height:H,
      fill:SEVCOLOR[series[i].sev]||'#4d9fd6'}});
    const tt=el('title',{{}});tt.textContent=series[i].t+'  '+series[i].st+
      (series[i].pub!=null?'  ('+series[i].pub+' ms)':'');
    rect.appendChild(tt);svg.appendChild(rect);
  }}
}}

function niceMax(v){{if(v<=0)return 10;const p=Math.pow(10,Math.floor(Math.log10(v)));
  const n=v/p;return (n<=1?1:n<=2?2:n<=5?5:10)*p;}}
function drawLatency(svg,series,threshold){{
  if(!svg)return;clear(svg);
  const W=1000,H=200,padL=44,padB=18,padT=10,n=series.length;
  const vals=series.map(s=>s.pub).filter(v=>v!=null);
  const dataMax=vals.length?Math.max(...vals):50;
  const ymax=niceMax(Math.max(dataMax,threshold*1.2));
  const x=i=>padL+(W-padL-4)*(n<=1?0:i/(n-1));
  const y=v=>padT+(H-padT-padB)*(1-v/ymax);
  // gridlines + y labels
  for(let g=0;g<=4;g++){{const val=ymax*g/4;const yy=y(val);
    svg.appendChild(el('line',{{x1:padL,y1:yy,x2:W-2,y2:yy,class:'svggrid'}}));
    const tx=el('text',{{x:2,y:yy+3,class:'svgaxis'}});tx.textContent=Math.round(val);svg.appendChild(tx);}}
  // threshold line
  const ty=y(threshold);
  svg.appendChild(el('line',{{x1:padL,y1:ty,x2:W-2,y2:ty,stroke:'#d6a53f','stroke-width':1.5,'stroke-dasharray':'5 4'}}));
  const tl=el('text',{{x:W-4,y:ty-3,class:'svgaxis','text-anchor':'end',fill:'#d6a53f'}});
  tl.textContent=threshold+' ms';svg.appendChild(tl);
  // outage shading (where public not reachable)
  for(let i=0;i<n;i++){{if(series[i].u===0){{
    svg.appendChild(el('rect',{{x:x(i)-((W-padL)/n/2),y:padT,width:Math.max(1,(W-padL)/n),
      height:H-padT-padB,fill:'#d65454',opacity:0.10}}));}}}}
  // path over reachable points (break on gaps)
  let dd='',pen=false;
  for(let i=0;i<n;i++){{const v=series[i].pub;
    if(v==null){{pen=false;continue;}}
    dd+=(pen?'L':'M')+x(i).toFixed(1)+' '+y(v).toFixed(1)+' ';pen=true;}}
  if(dd)svg.appendChild(el('path',{{d:dd,fill:'none',stroke:'#4d9fd6','stroke-width':1.5}}));
}}

function drawLayers(svg,series){{
  if(!svg)return;clear(svg);
  const W=1000,H=150,n=series.length;if(!n)return;
  const rows=[['dream','d'],['provider','p'],['public','u'],['dns','n'],['tcp','c']];
  const rh=H/rows.length,labelW=72,plotW=W-labelW,cw=plotW/n;
  rows.forEach((row,ri)=>{{
    const yTop=ri*rh, barY=yTop+4, barH=rh-8;
    const lbl=el('text',{{x:6,y:yTop+rh/2+3,class:'svgaxis'}});lbl.textContent=row[0];svg.appendChild(lbl);
    for(let i=0;i<n;i++){{
      const rect=el('rect',{{x:(labelW+i*cw).toFixed(2),y:barY,
        width:Math.ceil(cw)+0.5,height:barH,
        fill:series[i][row[1]]===1?'#3fb96b':'#d65454',
        opacity:series[i][row[1]]===1?0.8:0.92}});
      const tt=el('title',{{}});tt.textContent=row[0]+' '+(series[i][row[1]]===1?'up':'DOWN')+
        ' @ '+series[i].t;rect.appendChild(tt);svg.appendChild(rect);
    }}
  }});
}}

refresh();setInterval(refresh,5000);
</script></body></html>"""

CONFIG_HTML = f"""<!DOCTYPE html><html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>Configuration — internet telemetry</title><style>{BASE_CSS}
.cols{{display:grid;gap:0 2rem;grid-template-columns:repeat(auto-fit,minmax(300px,1fr))}}
</style></head><body>
{NAV}
<main>
<h2 style="margin-top:0">Configuration</h2>
<p class="dimv">Stored in <code>/etc/internet-telemetry/config.json</code>.
List fields take one item per line. Most changes need a service restart to apply.</p>
<div id="msg" class="msg"></div>
<div class="cols">
 <div>
  <label>Dream Router IP</label><input id="dream_ip">
  <label>Provider router/modem IPs</label><textarea id="provider_ips" rows="3"></textarea>
  <label>Public ping targets</label><textarea id="public_ping_targets" rows="4"></textarea>
  <label>DNS lookup names</label><textarea id="dns_names" rows="4"></textarea>
  <label>TCP targets (host:port)</label><textarea id="tcp_targets" rows="4"></textarea>
 </div>
 <div>
  <label>Sampling interval (s, ≥5)</label><input id="interval_sec" type="number" min="5">
  <label>Persistent outage threshold (s)</label><input id="outage_after_sec" type="number">
  <label>Slow latency threshold (ms)</label><input id="latency_warning_ms" type="number">
  <label>State confirm samples (debounce)</label><input id="state_confirm_samples" type="number" min="1" max="10">
  <label>Slow-state consecutive samples</label><input id="slow_consecutive_samples" type="number" min="1" max="30">
  <label>Traffic limit (% of min link, ≤3)</label><input id="monitoring_traffic_limit_percent" type="number" step="0.1" max="3">
  <label>Minimum expected downlink (Mbps)</label><input id="minimum_expected_downlink_mbps" type="number" step="0.1">
  <label>Minimum expected uplink (Mbps)</label><input id="minimum_expected_uplink_mbps" type="number" step="0.1">
  <label>Adaptive backoff</label>
  <select id="adaptive_backoff_enabled" style="width:100%;background:var(--bg);color:var(--text);
    border:1px solid var(--line);border-radius:6px;padding:.45rem .6rem">
    <option value="true">enabled</option><option value="false">disabled</option></select>
  <label>Dashboard bind address</label><input id="dashboard_bind">
  <label>Dashboard port</label><input id="dashboard_port" type="number" min="1" max="65535">
  <label>Log directory (absolute path)</label><input id="log_dir">
  <label>Samples kept in memory</label><input id="keep_samples" type="number">
 </div>
</div>
<div class="card" style="margin-top:1rem"><h2>Estimated telemetry traffic for these settings</h2>
<div id="est" class="dimv" style="font-family:var(--mono)">–</div></div>
<div style="display:flex;gap:.7rem;margin-top:1rem;flex-wrap:wrap">
 <button class="primary" onclick="save(false)">Save</button>
 <button class="primary" onclick="save(true)">Save and Restart Service</button>
 <button onclick="resetDefaults()">Reset to Defaults</button>
 <button onclick="downloadCfg()">Download Config</button>
</div>
</main>
<footer>Local LAN use only. Changing bind/port shows the new URL before restarting.</footer>
<script>
const LISTS=['provider_ips','public_ping_targets','dns_names','tcp_targets'];
const FIELDS=['dream_ip',...LISTS,'interval_sec','outage_after_sec','latency_warning_ms',
 'state_confirm_samples','slow_consecutive_samples','monitoring_traffic_limit_percent',
 'minimum_expected_downlink_mbps','minimum_expected_uplink_mbps','adaptive_backoff_enabled',
 'dashboard_bind','dashboard_port','log_dir','keep_samples'];
function fill(c){{for(const f of FIELDS){{const el=document.getElementById(f);
 if(LISTS.includes(f))el.value=(c[f]||[]).join('\\n');
 else el.value=String(c[f]);}}}}
function collect(){{const c={{}};for(const f of FIELDS){{const el=document.getElementById(f);
 if(LISTS.includes(f))c[f]=el.value.split('\\n').map(s=>s.trim()).filter(Boolean);
 else if(f==='adaptive_backoff_enabled')c[f]=el.value==='true';
 else if(el.type==='number')c[f]=Number(el.value);
 else c[f]=el.value.trim();}}return c;}}
function show(cls,text){{const m=document.getElementById('msg');m.className='msg '+cls;m.textContent=text;
 window.scrollTo({{top:0,behavior:'smooth'}});}}
function renderEst(t){{document.getElementById('est').textContent=
 t.estimated_kbps+' kbps of '+t.budget_kbps+' kbps budget ('+t.budget_usage_percent+'%) — '+t.budget_status;}}
async function load(){{const r=await fetch('/api/config');const d=await r.json();
 fill(d.config);renderEst(d.traffic);}}
async function save(restart){{
 const body=JSON.stringify(collect());
 const cur=collect();
 const addrChanged=confirmAddr(cur);
 if(restart&&addrChanged===null)return;
 const r=await fetch(restart?'/api/config/restart':'/api/config',{{method:'POST',
  headers:{{'Content-Type':'application/json','X-Requested-With':'internet-telemetry'}},body}});
 const d=await r.json();
 if(!d.saved){{show('err','Configuration not saved:\\n• '+(d.errors||['unknown error']).join('\\n• '));return}}
 renderEst(d.traffic);
 if(restart){{
  let m='Configuration saved. Service is restarting. Refresh dashboard in a few seconds.';
  if(d.address_changed)m+='\\nWarning: the dashboard address changed. After restart, open: '+
    'http://<container-ip>:'+cur.dashboard_port;
  show('warn',m);
  if(!d.address_changed)setTimeout(()=>location.href='/',6000);
 }}else{{
  show('ok','Configuration saved. Restart the service to apply changed settings.'+
   (d.address_changed?'\\nWarning: bind/port changed — after restart open http://<container-ip>:'+cur.dashboard_port:''));
 }}}}
function confirmAddr(cur){{
 // returns null if the user cancels an address-changing restart
 if(!window.__orig)return false;
 const changed=cur.dashboard_bind!==window.__orig.dashboard_bind||
   Number(cur.dashboard_port)!==Number(window.__orig.dashboard_port);
 if(changed&&!confirm('Warning: the dashboard address will change.\\nAfter restart, open: '+
   'http://<container-ip>:'+cur.dashboard_port+'\\n\\nContinue?'))return null;
 return changed;}}
async function resetDefaults(){{
 const r=await fetch('/api/config/defaults',{{method:'POST',
  headers:{{'X-Requested-With':'internet-telemetry'}}}});
 const d=await r.json();fill(d.config);
 show('warn','Defaults loaded into the form. Nothing is written until you press Save.');}}
function downloadCfg(){{
 const blob=new Blob([JSON.stringify(collect(),null,2)],{{type:'application/json'}});
 const a=document.createElement('a');a.href=URL.createObjectURL(blob);
 a.download='config.json';a.click();URL.revokeObjectURL(a.href);}}
load().then(async()=>{{const r=await fetch('/api/config');const d=await r.json();
 window.__orig={{dashboard_bind:d.config.dashboard_bind,dashboard_port:d.config.dashboard_port}};}});
</script></body></html>"""


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main():
    cfg = load_config()
    est = traffic_estimate(cfg)
    log(f"internet-telemetry v{APP_VERSION} starting")
    log(f"traffic estimate: {est['estimated_kbps']} kbps of {est['budget_kbps']} kbps "
        f"budget ({est['budget_status']})")
    if est["budget_status"] == "EXCEEDED":
        log("CONFIG ERROR: monitoring traffic budget exceeded; falling back to defaults.")
        cfg = dict(DEFAULT_CONFIG)

    collector = Collector(cfg)
    Handler.collector = collector
    Handler.allowed_hosts = local_ipv4_addresses()
    log(f"allowed Host headers: {sorted(Handler.allowed_hosts)}")

    t = threading.Thread(target=collector.run, daemon=True)
    t.start()

    addr = (cfg["dashboard_bind"], int(cfg["dashboard_port"]))
    httpd = ThreadingHTTPServer(addr, Handler)
    httpd.daemon_threads = True
    log(f"dashboard listening on http://{addr[0]}:{addr[1]}")
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        collector.stop.set()


if __name__ == "__main__":
    main()
