#!/usr/bin/env python3
"""Alertmanager/Grafana webhook -> one consolidated GitHub alert issue per repo.

Every alert delivered to this bridge lands in a single fixed-title open issue
carrying ALERT_LABEL, with one `### <alertname>` section per alert. Each section
tracks the fingerprints of its firing instances (Alertmanager sends one
notification per alertname x namespace group), so a resolve from one group
never masks another group that is still firing. A section is resolved once its
last instance resolves, and the issue closes only when every section is
resolved. A firing with no open issue reopens the most
recently closed one if it closed within REOPEN_WINDOW_HOURS, so a flapping
alert never forks a second issue.

The body ends with Claws' occurrence block (`**First seen:**` / `**Last
seen:**` / `**Occurrences:**`), which Claws needs to suppress its
edit-triggered re-plan on every update.

Stdlib only; runs from a ConfigMap on a pinned public python image. A sibling
copy lives in St-John-Software/fleet-infra
apps/monitoring/grafana-github-alerts/ (fleet-infra#1554): keep behaviour in
sync. Everything repo-specific is an env var, so either copy can be promoted to
a shared image later without code changes. See docs/observability.md.
"""
import hashlib
import hmac
import http.server
import json
import os
import re
import sys
import threading
import traceback
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime, timedelta, timezone

GITHUB_API = "https://api.github.com"
# Explicit socket timeout: urlopen's default is None (block forever), and
# deliveries are serialised, so one stalled GitHub call would block every
# later delivery.
GITHUB_TIMEOUT = 30
MAX_BODY = 1 * 1024 * 1024
MAX_DESCRIPTION = 1000
# GitHub rejects issue bodies over 65,536 characters with a 422; stay well
# under it so a long-lived flapping issue never becomes unwritable.
MAX_ISSUE_BODY = 60000
SHORT_DESCRIPTION = 200
FOOTER_PREFIX = "*Automatically managed by alert-issue-bridge."
ZERO_TIME = "0001-01-01T00:00:00Z"

# Populated by configure(); defaults let tests import without secrets.
GITHUB_REPO = ""
GITHUB_TOKEN = ""
WEBHOOK_TOKEN = ""
ALERT_LABEL = "alert"
ISSUE_TITLE = "[Alert] Alerts firing"
REOPEN_WINDOW_HOURS = 24.0
INCLUDE_GENERATOR_URL = True
LINKS_MARKDOWN = ""
LISTEN_PORT = 8080


def log(level, msg, **fields):
    """One JSON object per line on stdout."""
    record = {
        "level": level,
        "time": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.%fZ"),
        "msg": msg,
        "service": "alert-issue-bridge",
        "component": fields.pop("component", "bridge"),
    }
    record.update(fields)
    print(json.dumps(record, default=str), flush=True)


def err_fields(exc):
    return {
        "err": {
            "type": type(exc).__name__,
            "message": str(exc),
            "stack": "".join(traceback.format_exception(exc)),
        }
    }


def env_bool(value, default):
    if value is None or value == "":
        return default
    return value.strip().lower() in ("1", "true", "yes", "on")


def configure(env):
    """Load configuration from an env mapping into module globals."""
    global GITHUB_REPO, GITHUB_TOKEN, WEBHOOK_TOKEN, ALERT_LABEL, ISSUE_TITLE
    global REOPEN_WINDOW_HOURS, INCLUDE_GENERATOR_URL, LINKS_MARKDOWN, LISTEN_PORT
    GITHUB_REPO = env.get("GITHUB_REPO", "")
    token_file = env.get("GITHUB_TOKEN_FILE", "")
    if token_file:
        with open(token_file, encoding="utf-8") as f:
            GITHUB_TOKEN = f.read().strip()
    else:
        GITHUB_TOKEN = env.get("GITHUB_TOKEN", "").strip()
    WEBHOOK_TOKEN = env.get("WEBHOOK_TOKEN", "").strip()
    ALERT_LABEL = env.get("ALERT_LABEL", "") or "alert"
    ISSUE_TITLE = env.get("ISSUE_TITLE", "") or "[Alert] Alerts firing"
    REOPEN_WINDOW_HOURS = float(env.get("REOPEN_WINDOW_HOURS", "") or 24)
    INCLUDE_GENERATOR_URL = env_bool(env.get("INCLUDE_GENERATOR_URL"), True)
    LINKS_MARKDOWN = env.get("LINKS_MARKDOWN", "")
    LISTEN_PORT = int(env.get("LISTEN_PORT", "") or 8080)


def github_api(method, path, body=None, expected_statuses=()):
    """GitHub API request. Returns parsed JSON, or None on any failure.

    An HTTP error whose status is in expected_statuses is logged at info
    rather than as a warning."""
    url = f"{GITHUB_API}{path}"
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(
        url,
        data=data,
        method=method,
        headers={
            "Authorization": f"Bearer {GITHUB_TOKEN}",
            "Accept": "application/vnd.github+json",
            "Content-Type": "application/json",
            "X-GitHub-Api-Version": "2022-11-28",
        },
    )
    try:
        with urllib.request.urlopen(req, timeout=GITHUB_TIMEOUT) as resp:
            raw = resp.read().decode()
            return json.loads(raw) if raw else {}
    except urllib.error.HTTPError as e:
        try:
            response = e.read().decode()[:2000]
        except Exception:
            response = ""
        if e.code in expected_statuses:
            log("info", "github api returned expected status", method=method,
                path=path, status=e.code)
        elif e.code == 422:
            # Validation failures (e.g. body too long) never fix themselves on
            # retry, so make them stand out from transient errors.
            log("error", "github api rejected request", method=method, path=path,
                status=e.code, response=response)
        else:
            log("warn", "github api error", method=method, path=path,
                status=e.code, response=response)
        return None
    except urllib.error.URLError as e:
        # HTTPError subclasses URLError, so this must come second.
        log("warn", "github api unreachable", method=method, path=path,
            reason=str(e.reason))
        return None
    except (OSError, json.JSONDecodeError) as e:
        log("warn", "github api request failed", method=method, path=path,
            **err_fields(e))
        return None


# ── Time helpers ──

def fmt_time(dt):
    return dt.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def parse_time(value):
    """Parse an RFC 3339 timestamp (any fractional precision). None if unparseable."""
    if not value or value == ZERO_TIME:
        return None
    m = re.match(r"^(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2})(\.\d+)?(Z|[+-]\d{2}:\d{2})$",
                 value.strip())
    if not m:
        return None
    tz = "+00:00" if m.group(3) == "Z" else m.group(3)
    try:
        dt = datetime.fromisoformat(m.group(1) + tz)
    except ValueError:
        return None
    if dt.year <= 1:
        return None
    return dt


def norm_time(value, fallback):
    dt = parse_time(value)
    return fmt_time(dt) if dt else fallback


# ── Payload grouping ──

def one_line(text):
    return " ".join(str(text).split())


def instance_key(alert):
    """Stable identity of one alert instance: Alertmanager's fingerprint, else a label-set hash."""
    fp = one_line(alert.get("fingerprint") or "")
    if fp and re.fullmatch(r"[0-9A-Za-z]+", fp):
        return fp
    labels = alert.get("labels") or {}
    canon = json.dumps(sorted((str(k), str(v)) for k, v in labels.items()))
    return hashlib.sha256(canon.encode()).hexdigest()[:16]


def group_alerts(alerts):
    """Group alert instances by alertname, preserving first-seen order."""
    groups = {}
    for alert in alerts:
        if not isinstance(alert, dict):
            continue
        labels = alert.get("labels") or {}
        name = one_line(labels.get("alertname") or "Unknown") or "Unknown"
        groups.setdefault(name, []).append(alert)
    result = {}
    for name, instances in groups.items():
        firing = [a for a in instances if a.get("status", "firing") == "firing"]
        rep = firing[0] if firing else instances[0]
        labels = rep.get("labels") or {}
        annotations = rep.get("annotations") or {}
        description = one_line(annotations.get("description") or "No description provided")
        if len(description) > MAX_DESCRIPTION:
            description = description[:MAX_DESCRIPTION - 1] + "…"
        firing_keys = {instance_key(a) for a in firing}
        result[name] = {
            "status": "firing" if firing else "resolved",
            "firing_keys": firing_keys,
            "resolved_keys": {instance_key(a) for a in instances
                              if a.get("status", "firing") != "firing"} - firing_keys,
            "severity": one_line(labels.get("severity") or "unknown") or "unknown",
            "starts_at": rep.get("startsAt") or "",
            "ends_at": rep.get("endsAt") or "",
            "summary": one_line(annotations.get("summary") or "No summary provided"),
            "description": description,
            "generator_url": one_line(rep.get("generatorURL") or ""),
            "dashboard": one_line(annotations.get("dashboard") or ""),
        }
    return result


# ── Body model ──
#
# state = {
#   "first_seen": str, "last_seen": str, "total": int,
#   "sections": {alertname: {severity, status, first, last, count, resolved,
#                            summary, description, source, dashboard, instances}},
# }
#
# `instances` is the set of firing instance keys (see instance_key), persisted
# as a hidden `<!-- firing-instances: ... -->` line in the section.

TABLE_ROWS = [
    ("Severity", "severity"),
    ("Status", "status"),
    ("First occurrence", "first"),
    ("Last occurrence", "last"),
    ("Occurrences", "count"),
    ("Resolved", "resolved"),
    ("Dashboard", "dashboard"),
    ("Source", "source"),
]
OPTIONAL_ROWS = {"dashboard", "source"}
ROW_RE = re.compile(r"^\| (" + "|".join(re.escape(k) for k, _ in TABLE_ROWS) + r") \| (.*) \|$")
INSTANCES_PREFIX = "<!-- firing-instances: "
INSTANCES_SUFFIX = " -->"


def new_state(now):
    return {"first_seen": now, "last_seen": now, "total": 0, "sections": {}}


def cell(value):
    return str(value).replace("|", "\\|")


def uncell(value):
    return value.replace("\\|", "|")


def all_resolved(state):
    return all(s["status"] == "resolved" for s in state["sections"].values())


def render_body(state):
    lines = [
        f"Alertmanager alerts for {GITHUB_REPO}. One section per alert; "
        "this issue closes when every section is resolved.",
        "",
    ]
    if LINKS_MARKDOWN:
        lines += [LINKS_MARKDOWN, ""]
    lines += ["## Currently firing", ""]
    firing = [(n, s) for n, s in state["sections"].items() if s["status"] == "firing"]
    if firing:
        lines += [f"- {n} ({s['severity']})" for n, s in firing]
    else:
        lines.append("- none")
    lines += ["", "## Alerts", ""]
    for name, s in state["sections"].items():
        lines += [f"### {name}", "", "| Field | Value |", "|---|---|"]
        for key, field in TABLE_ROWS:
            value = s[field]
            if field in OPTIONAL_ROWS and not value:
                continue
            lines.append(f"| {key} | {cell(value)} |")
        lines += [
            "",
            f"{INSTANCES_PREFIX}{','.join(sorted(s['instances']))}{INSTANCES_SUFFIX}",
            "",
            f"**Summary:** {s['summary']}",
            "",
            f"**Description:** {s['description']}",
            "",
        ]
    window = f"{REOPEN_WINDOW_HOURS:g}"
    lines += [
        f"{FOOTER_PREFIX} Closed when every alert above is resolved; "
        f"reopened if an alert re-fires within {window} hours.*",
        "",
        "---",
        f"**First seen:** {state['first_seen']}",
        f"**Last seen:** {state['last_seen']}",
        f"**Occurrences:** {state['total']}",
    ]
    return "\n".join(lines)


def resolved_order(item):
    name, s = item
    return parse_time(s["resolved"]) or datetime.min.replace(tzinfo=timezone.utc)


def render_bounded(state):
    """Render the body, pruning state until it fits MAX_ISSUE_BODY.

    Drops the oldest resolved sections first, then shortens descriptions.
    Firing sections are never dropped."""
    body = render_body(state)
    if len(body) <= MAX_ISSUE_BODY:
        return body
    resolved = sorted(((n, s) for n, s in state["sections"].items()
                       if s["status"] == "resolved"), key=resolved_order)
    dropped = []
    for name, _ in resolved:
        del state["sections"][name]
        dropped.append(name)
        body = render_body(state)
        if len(body) <= MAX_ISSUE_BODY:
            break
    shortened = False
    if len(body) > MAX_ISSUE_BODY:
        for s in state["sections"].values():
            if len(s["description"]) > SHORT_DESCRIPTION:
                s["description"] = s["description"][:SHORT_DESCRIPTION - 1] + "…"
                shortened = True
        body = render_body(state)
    log("warn" if len(body) <= MAX_ISSUE_BODY else "error",
        "issue body over size limit, pruned", dropped=dropped,
        shortened_descriptions=shortened, length=len(body))
    return body


def parse_tracking(body):
    """Read Claws' trailing occurrence block. Missing fields come back as None."""
    first = re.search(r"^\*\*First seen:\*\* (.+)$", body, re.M)
    last = re.search(r"^\*\*Last seen:\*\* (.+)$", body, re.M)
    total = re.search(r"^\*\*Occurrences:\*\* (\d+)\s*$", body, re.M)
    return (
        first.group(1).strip() if first else None,
        last.group(1).strip() if last else None,
        int(total.group(1)) if total else None,
    )


def parse_body(body):
    """Parse a rendered body back into state. None if it is not ours or was hand-edited."""
    if not body:
        return None
    lines = body.replace("\r\n", "\n").split("\n")
    try:
        start = lines.index("## Alerts")
    except ValueError:
        return None
    end = next((i for i in range(start + 1, len(lines))
                if lines[i].startswith(FOOTER_PREFIX)), None)
    if end is None:
        return None
    first_seen, last_seen, total = parse_tracking(body)
    if first_seen is None or last_seen is None or total is None:
        return None

    sections = {}
    current = None
    for line in lines[start + 1:end]:
        if line.startswith("### "):
            current = {"dashboard": "", "source": "", "instances": set()}
            sections[line[4:]] = current
            continue
        if current is None:
            if line.strip():
                return None
            continue
        m = ROW_RE.match(line)
        if m:
            field = dict(TABLE_ROWS)[m.group(1)]
            current[field] = uncell(m.group(2))
        elif line.startswith("**Summary:** "):
            current["summary"] = line[len("**Summary:** "):]
        elif line.startswith("**Description:** "):
            current["description"] = line[len("**Description:** "):]
        elif line.startswith(INSTANCES_PREFIX) and line.endswith(INSTANCES_SUFFIX):
            keys = line[len(INSTANCES_PREFIX):-len(INSTANCES_SUFFIX)]
            current["instances"] = {k for k in keys.split(",") if k}

    required = {f for _, f in TABLE_ROWS} | {"summary", "description"}
    for s in sections.values():
        if not required <= s.keys():
            return None
        if s["status"] not in ("firing", "resolved"):
            return None
        try:
            s["count"] = int(s["count"])
        except ValueError:
            return None
    return {"first_seen": first_seen, "last_seen": last_seen, "total": total,
            "sections": sections}


def state_from_issue(issue, now):
    """Parse an issue body, falling back to a fresh state that keeps the tracking block.

    Returns (state, rebuilt); rebuilt is True when the body did not parse."""
    body = issue.get("body") or ""
    state = parse_body(body)
    if state is not None:
        return state, False
    log("warn", "issue body unparseable, rebuilding sections from payload",
        issue=issue.get("number"))
    state = new_state(now)
    first_seen, last_seen, total = parse_tracking(body)
    if first_seen:
        state["first_seen"] = first_seen
    if last_seen:
        state["last_seen"] = last_seen
    if total is not None:
        state["total"] = total
    return state, True


def apply_payload(state, groups, now):
    """Fold one delivery's grouped alerts into state. Returns alertnames changed."""
    changed = []
    for name, g in groups.items():
        s = state["sections"].get(name)
        source = g["generator_url"] if INCLUDE_GENERATOR_URL else ""
        if g["status"] == "firing":
            if s is None:
                s = {"first": norm_time(g["starts_at"], now), "count": 0,
                     "instances": set()}
                state["sections"][name] = s
            if s.get("status") == "resolved":
                s["instances"] = set()
            s["instances"] = (s["instances"] - g["resolved_keys"]) | g["firing_keys"]
            s.update({
                "severity": g["severity"],
                "status": "firing",
                "last": now,
                "count": s["count"] + 1,
                "resolved": "-",
                "summary": g["summary"],
                "description": g["description"],
                "source": source,
                "dashboard": g["dashboard"],
            })
            state["total"] += 1
            state["last_seen"] = now
            changed.append(name)
        elif s is not None and s["status"] == "firing":
            remaining = s["instances"] - g["resolved_keys"]
            if remaining:
                # Another group of this alertname is still firing.
                if remaining != s["instances"]:
                    s["instances"] = remaining
                    changed.append(name)
                else:
                    log("info", "resolved instances not tracked in firing section, ignored",
                        alertname=name)
                continue
            s["instances"] = set()
            s["status"] = "resolved"
            s["resolved"] = norm_time(g["ends_at"], now)
            changed.append(name)
        else:
            log("info", "resolved alert has no firing section, ignored", alertname=name)
    return changed


# ── Issue lookup ──

def is_our_issue(item):
    return (
        isinstance(item, dict)
        and "pull_request" not in item
        and item.get("title") == ISSUE_TITLE
    )


def find_open_issue():
    """Returns (issue_or_None, ok)."""
    label = urllib.parse.quote(ALERT_LABEL, safe="")
    items = github_api(
        "GET", f"/repos/{GITHUB_REPO}/issues?state=open&labels={label}&per_page=100")
    if items is None:
        return None, False
    matches = sorted((i for i in items if is_our_issue(i)), key=lambda i: i["number"])
    if len(matches) > 1:
        log("warn", "multiple open alert issues, using lowest number",
            issues=[i["number"] for i in matches])
    return (matches[0] if matches else None), True


def find_reopen_candidate(now_dt):
    """Most recently closed alert issue if it closed within the window. Returns (issue_or_None, ok)."""
    label = urllib.parse.quote(ALERT_LABEL, safe="")
    items = github_api(
        "GET",
        f"/repos/{GITHUB_REPO}/issues?state=closed&labels={label}"
        "&sort=updated&direction=desc&per_page=30",
    )
    if items is None:
        return None, False
    best, best_closed = None, None
    for item in items:
        if not is_our_issue(item):
            continue
        closed = parse_time(item.get("closed_at") or "")
        if closed and (best_closed is None or closed > best_closed):
            best, best_closed = item, closed
    if best is None:
        return None, True
    if now_dt - best_closed > timedelta(hours=REOPEN_WINDOW_HOURS):
        return None, True
    return best, True


# ── Delivery handling ──

def handle_payload(alerts, now_dt=None):
    """Apply one webhook delivery. True on success; False means Alertmanager should retry."""
    now_dt = now_dt or datetime.now(timezone.utc)
    now = fmt_time(now_dt)
    groups = group_alerts(alerts)
    if not groups:
        return True

    issue, ok = find_open_issue()
    if not ok:
        return False
    if issue is not None:
        number = issue["number"]
        state, rebuilt = state_from_issue(issue, now)
        changed = apply_payload(state, groups, now)
        # A rebuilt body with nothing firing is closed rather than left open
        # forever with its hand-edited contents.
        closing = (bool(state["sections"]) or rebuilt) and all_resolved(state)
        if not changed and not closing and not rebuilt:
            return True
        patch = {"body": render_bounded(state)}
        if closing:
            patch["state"] = "closed"
        if github_api("PATCH", f"/repos/{GITHUB_REPO}/issues/{number}", patch) is None:
            return False
        log("info", "closed alert issue" if closing else "updated alert issue",
            issue=number, alertnames=changed)
        return True

    if not any(g["status"] == "firing" for g in groups.values()):
        log("info", "resolved alerts with no open issue, ignored", alertnames=list(groups))
        return True

    candidate, ok = find_reopen_candidate(now_dt)
    if not ok:
        return False
    if candidate is not None:
        number = candidate["number"]
        state, _ = state_from_issue(candidate, now)
        changed = apply_payload(state, groups, now)
        patch = {"state": "open", "body": render_bounded(state)}
        if github_api("PATCH", f"/repos/{GITHUB_REPO}/issues/{number}", patch) is None:
            return False
        log("info", "reopened alert issue", issue=number, alertnames=changed)
        return True

    state = new_state(now)
    changed = apply_payload(state, groups, now)
    result = github_api("POST", f"/repos/{GITHUB_REPO}/issues", {
        "title": ISSUE_TITLE,
        "body": render_bounded(state),
        "labels": [ALERT_LABEL],
    })
    if result is None:
        return False
    log("info", "created alert issue", issue=result.get("number"), alertnames=changed)
    return True


def ensure_label_exists():
    # 422 means the label already exists, the normal case after first start.
    result = github_api("POST", f"/repos/{GITHUB_REPO}/labels", {
        "name": ALERT_LABEL,
        "color": "d73a4a",
        "description": "Consolidated alert issue managed by alert-issue-bridge",
    }, expected_statuses=(422,))
    if result is not None:
        log("info", "created label", label=ALERT_LABEL)
    else:
        log("info", "label already exists or creation failed (non-fatal)", label=ALERT_LABEL)


# ── HTTP ──

WEBHOOK_PATHS = ("/webhook", "/v1/receiver")
# Deliveries read-modify-write one issue, so they must not interleave. Requests
# themselves are served on threads so /healthz never queues behind GitHub.
DELIVERY_LOCK = threading.Lock()


def is_authorized(headers):
    if not WEBHOOK_TOKEN:
        return True
    auth = headers.get("Authorization", "")
    if not auth.startswith("Bearer "):
        return False
    return hmac.compare_digest(auth[len("Bearer "):].encode(), WEBHOOK_TOKEN.encode())


class WebhookHandler(http.server.BaseHTTPRequestHandler):
    # Bound how long one slow client can hold its request thread.
    timeout = 30

    def reply(self, code, text):
        body = text.encode()
        self.send_response(code)
        self.send_header("Content-Type", "text/plain")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        # /healthz never calls GitHub: probe health must not depend on
        # api.github.com latency (#1314).
        if self.path == "/healthz":
            self.reply(200, "ok")
        else:
            self.reply(404, "not found")

    def do_POST(self):
        if self.path not in WEBHOOK_PATHS:
            self.reply(404, "not found")
            return
        if not is_authorized(self.headers):
            self.reply(401, "unauthorized")
            return
        try:
            length = int(self.headers.get("Content-Length", 0) or 0)
        except ValueError:
            length = 0
        if length > MAX_BODY:
            self.reply(413, "payload too large")
            return
        try:
            payload = json.loads(self.rfile.read(max(0, length)) or b"{}")
            alerts = payload.get("alerts") or []
            if not isinstance(alerts, list):
                raise ValueError("alerts is not a list")
        except (ValueError, AttributeError) as e:
            log("warn", "invalid webhook payload", **err_fields(e))
            self.reply(400, "invalid payload")
            return
        log("info", "webhook received", alert_count=len(alerts))
        try:
            with DELIVERY_LOCK:
                ok = handle_payload(alerts)
        except Exception as e:
            log("error", "webhook handling failed", **err_fields(e))
            self.reply(500, "error")
            return
        if ok:
            self.reply(200, "ok")
        else:
            self.reply(502, "github api failure")

    def log_message(self, format, *args):
        pass


def make_server(host, port):
    return http.server.ThreadingHTTPServer((host, port), WebhookHandler)


def main():
    configure(os.environ)
    if not GITHUB_REPO:
        log("error", "GITHUB_REPO is required")
        sys.exit(1)
    if not GITHUB_TOKEN:
        log("error", "no GitHub token configured; every GitHub call will fail")
    if not WEBHOOK_TOKEN:
        log("warn", "WEBHOOK_TOKEN unset; webhook accepts unauthenticated requests")
    ensure_label_exists()
    # Threaded so probes answer while a delivery waits on GitHub; deliveries
    # still serialise on DELIVERY_LOCK.
    server = make_server("0.0.0.0", LISTEN_PORT)
    log("info", "listening", port=LISTEN_PORT, repo=GITHUB_REPO, label=ALERT_LABEL)
    server.serve_forever()


if __name__ == "__main__":
    main()
