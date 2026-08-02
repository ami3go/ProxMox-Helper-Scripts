#!/usr/bin/env python3
"""Logic tests: classification quorum, debounce, WAN_DOWN fallback,
persistent outage + recovery events, traffic budget validation."""
import json, os, sys, tempfile, time
from datetime import timedelta

os.environ["IT_CONFIG"] = tempfile.mktemp(suffix=".json")
import network_telemetry_dashboard as app

FAILED = []

def check(name, cond):
    print(("PASS  " if cond else "FAIL  ") + name)
    if not cond:
        FAILED.append(name)

# --- scenario-driven fake probes -------------------------------------------
SCEN = {"dream": True, "provider": False, "public": True, "dns": True,
        "tcp": True, "latency": 20.0}

def fake_ping(host):
    cfg = C.cfg
    if host == cfg["dream_ip"]:
        return (True, 1.0) if SCEN["dream"] else (False, None)
    if host in cfg["provider_ips"]:
        return (True, 2.0) if SCEN["provider"] else (False, None)
    return (SCEN["public"], SCEN["latency"] if SCEN["public"] else None)

app.ping_once = fake_ping
app.dns_lookup = lambda n: (SCEN["dns"], 10.0 if SCEN["dns"] else None)
app.tcp_check = lambda t: (SCEN["tcp"], 5.0 if SCEN["tcp"] else None)

tmpdir = tempfile.mkdtemp()
cfg = dict(app.DEFAULT_CONFIG)
cfg.update({"log_dir": tmpdir, "interval_sec": 5, "outage_after_sec": 15,
            "state_confirm_samples": 2, "slow_consecutive_samples": 3})
C = app.Collector(cfg)

def step(n=1):
    s = None
    for _ in range(n):
        s = C.collect_sample()
    return s

# --- 1. startup: first sample sets state immediately, no provider baseline ---
s = step()
check("first sample -> OK (no OK_PROVIDER_NR without baseline)", s["state"] == "OK")
check("no baseline yet", s["provider_baseline_reachable"] is False)

# --- 2. debounce: single-sample public blip does not change reported state ---
SCEN["public"] = False
s = step()
check("blip raw state is WAN_DOWN (no baseline)", s["raw_state"] == "WAN_DOWN")
check("blip does NOT change reported state", s["state"] == "OK")
check("no event on single blip", len(C.events) == 0)
SCEN["public"] = True
s = step()
check("recovered raw==reported OK, still no event", s["state"] == "OK" and len(C.events) == 0)

# --- 3. sustained outage without baseline -> WAN_DOWN after 2 samples --------
SCEN["public"] = False
step()
s = step()
check("2 consecutive down samples -> WAN_DOWN", s["state"] == "WAN_DOWN")
check("state_change event emitted", any(e["type"] == "state_change" for e in C.events))

# --- 4. persistent outage event + reboot candidate ---------------------------
C.failure_since = app.utcnow() - timedelta(seconds=999)  # simulate elapsed time
s = step()
pe = [e for e in C.events if e["type"] == "persistent_outage"]
check("persistent_outage emitted after threshold", len(pe) == 1)
check("WAN_DOWN is reboot candidate", pe and pe[0]["reboot_candidate"] is True)
check("only one persistent event per outage", len([e for e in C.events if e["type"]=="persistent_outage"]) == 1)
step()  # extra failing sample should not duplicate
check("no duplicate persistent event", len([e for e in C.events if e["type"]=="persistent_outage"]) == 1)

# --- 5. recovery -------------------------------------------------------------
SCEN["public"] = True
step()   # 1st OK sample: pending
s = step()  # 2nd: confirmed
check("recovery debounced then applied", s["state"] == "OK")
check("recovery event emitted", any(e["type"] == "recovery" for e in C.events))

# --- 6. provider baseline -> ISP vs PROVIDER distinction ---------------------
SCEN["provider"] = True
s = step()
check("provider reply during OK sets baseline", s["provider_baseline_reachable"] is True)
SCEN["public"] = False           # provider still up, public down
s = step(2)
check("baseline + provider up + public down -> ISP_OR_COAX_UPSTREAM_DOWN",
      s["state"] == "ISP_OR_COAX_UPSTREAM_DOWN")
SCEN["provider"] = False         # now provider also down
s = step(2)
check("baseline + provider down + public down -> PROVIDER_ROUTER_OR_WAN_LINK_DOWN",
      s["state"] == "PROVIDER_ROUTER_OR_WAN_LINK_DOWN")

# --- 7. OK_PROVIDER_ROUTER_NOT_REACHABLE only with baseline ------------------
SCEN["public"] = True
s = step(2)
check("public up, provider silent, baseline -> OK_PROVIDER_ROUTER_NOT_REACHABLE",
      s["state"] == "OK_PROVIDER_ROUTER_NOT_REACHABLE")

# --- 8. INTERNET_SLOW needs slow_consecutive_samples (3) ---------------------
SCEN["provider"] = True
step(2)  # back to OK
SCEN["latency"] = 500.0
s1 = step(); s2 = step()
check("slow x2 not yet reported", s2["state"] != "INTERNET_SLOW")
s3 = step()
check("slow x3 -> INTERNET_SLOW", s3["state"] == "INTERNET_SLOW")
check("slow raw state correct", s3["raw_state"] == "INTERNET_SLOW")
SCEN["latency"] = 20.0
step(2)

# --- 9. LAN down beats everything --------------------------------------------
SCEN["dream"] = False
s = step(2)
check("dream unreachable -> LOCAL_LAN_OR_DREAM_ROUTER_DOWN", s["state"] == "LOCAL_LAN_OR_DREAM_ROUTER_DOWN")
SCEN["dream"] = True

# --- 10. DNS failure quorum: all fail -> DNS_FAILURE -------------------------
s = step(2)  # settle to OK
SCEN["dns"] = False
s = step(2)
check("all DNS fail with internet up -> DNS_FAILURE", s["state"] == "DNS_FAILURE")
SCEN["dns"] = True

# --- 11. traffic budget validation -------------------------------------------
bad = dict(app.DEFAULT_CONFIG)
bad.update({"interval_sec": 5, "public_ping_targets": ["1.1.1.1"] * 100,
            "minimum_expected_downlink_mbps": 0.1, "minimum_expected_uplink_mbps": 0.1})
_, errors = app.validate_config(bad)
check("aggressive config rejected by traffic budget", any("budget" in e for e in errors))
good, errors2 = app.validate_config(dict(app.DEFAULT_CONFIG))
check("default config passes validation", errors2 == [])
est = app.traffic_estimate(good)
check("default estimate well under budget (<0.5% of link)",
      est["estimated_kbps"] < min(good["minimum_expected_downlink_mbps"],
                                  good["minimum_expected_uplink_mbps"]) * 1000 * 0.005)

# --- 12. adaptive backoff reduces probes -------------------------------------
SCEN["public"] = False
step(2)                                   # enter WAN-down-ish state
C.failure_since = app.utcnow() - timedelta(seconds=999)
s = step()
check("adaptive backoff active during persistent outage", s["adaptive_backoff_active"] is True)
check("backoff keeps >=2 public targets", len(s["public_results"]) == 2)
check("backoff keeps 1 provider target", len(s["provider_results"]) == 1)

# --- 13. event files on disk -------------------------------------------------
import pathlib
evfiles = list(pathlib.Path(tmpdir, "events").glob("*.json"))
check("event JSON files written to disk", len(evfiles) >= 3)
ev = json.loads(evfiles[0].read_text())
check("event file has required fields",
      all(k in ev for k in ("timestamp_utc","type","state","severity","message",
                            "active_since_utc","duration_sec","reboot_candidate")))

print()
if FAILED:
    print(f"{len(FAILED)} FAILED: {FAILED}")
    sys.exit(1)
print("ALL LOGIC TESTS PASSED")
