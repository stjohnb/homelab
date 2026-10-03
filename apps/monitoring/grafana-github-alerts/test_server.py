"""Offline tests for server.py. Run: python3 -m unittest discover -s <this dir> -p 'test_*.py'."""
import http.client
import io
import json
import os
import re
import sys
import tempfile
import threading
import unittest
from contextlib import redirect_stdout
from datetime import datetime, timedelta, timezone
from urllib.parse import parse_qs, urlparse

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import server  # noqa: E402

REPO = "St-John-Software/production-infra"
TITLE = "[Alert] production-infra alerts firing"
NOW = datetime(2026, 9, 23, 12, 0, 0, tzinfo=timezone.utc)

BASE_ENV = {
    "GITHUB_REPO": REPO,
    "GITHUB_TOKEN": "test-token",
    "ALERT_LABEL": "alert",
    "ISSUE_TITLE": TITLE,
    "REOPEN_WINDOW_HOURS": "24",
    "INCLUDE_GENERATOR_URL": "true",
    "LINKS_MARKDOWN": "[📊 Grafana](https://grafana.bstjohn.net)",
}


def iso(dt):
    return dt.strftime("%Y-%m-%dT%H:%M:%SZ")


def alert(name, status="firing", severity="warning", summary=None, description=None,
          starts=NOW - timedelta(minutes=5), ends=None, namespace="plausible"):
    return {
        "status": status,
        "labels": {"alertname": name, "severity": severity, "namespace": namespace},
        "annotations": {
            "summary": summary or f"{name} summary",
            "description": description or f"{name} description",
        },
        "startsAt": starts.strftime("%Y-%m-%dT%H:%M:%S.123Z"),
        "endsAt": iso(ends) if ends else server.ZERO_TIME,
        "generatorURL": f"http://prometheus:9090/graph?{name}",
    }


class FakeGitHub:
    """In-memory stand-in for server.github_api."""

    def __init__(self):
        self.issues = []
        self.calls = []
        self.fail = set()  # methods that return None
        self.next_number = 100

    def add_issue(self, title=TITLE, state="open", labels=("alert",), body="",
                  closed_at=None, pull_request=False):
        issue = {
            "number": self.next_number,
            "title": title,
            "state": state,
            "labels": [{"name": n} for n in labels],
            "body": body,
            "closed_at": closed_at,
        }
        if pull_request:
            issue["pull_request"] = {}
        self.next_number += 1
        self.issues.append(issue)
        return issue

    def __call__(self, method, path, body=None, expected_statuses=()):
        self.calls.append((method, path, body))
        if method in self.fail:
            return None
        url = urlparse(path)
        if method == "GET" and url.path == f"/repos/{REPO}/issues":
            q = parse_qs(url.query)
            state = q["state"][0]
            label = q["labels"][0]
            return [dict(i) for i in self.issues
                    if i["state"] == state and label in [l["name"] for l in i["labels"]]]
        if method == "POST" and url.path == f"/repos/{REPO}/issues":
            issue = self.add_issue(title=body["title"], labels=body["labels"], body=body["body"])
            return dict(issue)
        m = re.match(rf"^/repos/{re.escape(REPO)}/issues/(\d+)$", url.path)
        if method == "PATCH" and m:
            issue = next(i for i in self.issues if i["number"] == int(m.group(1)))
            issue.update(body)
            if body.get("state") == "closed":
                issue["closed_at"] = iso(NOW)
            return dict(issue)
        if method == "POST" and url.path == f"/repos/{REPO}/labels":
            return {"name": body["name"]}
        raise AssertionError(f"unexpected call {method} {path}")

    def writes(self):
        return [c for c in self.calls if c[0] in ("POST", "PATCH")]


class BridgeTest(unittest.TestCase):
    def setUp(self):
        server.configure(dict(BASE_ENV))
        self.gh = FakeGitHub()
        self._orig = server.github_api
        server.github_api = self.gh
        self._out = io.StringIO()
        self._redirect = redirect_stdout(self._out)
        self._redirect.__enter__()

    def tearDown(self):
        self._redirect.__exit__(None, None, None)
        server.github_api = self._orig

    def deliver(self, alerts, now=NOW):
        return server.handle_payload(alerts, now)

    def only_issue(self):
        self.assertEqual(len(self.gh.issues), 1)
        return self.gh.issues[0]

    def section(self, issue, name):
        state = server.parse_body(issue["body"])
        self.assertIsNotNone(state, issue["body"])
        return state["sections"][name]

    # ── lifecycle ──

    def test_first_firing_creates_issue(self):
        self.assertTrue(self.deliver([alert("PlausibleOOM", severity="critical")]))
        issue = self.only_issue()
        self.assertEqual(issue["title"], TITLE)
        self.assertEqual([l["name"] for l in issue["labels"]], ["alert"])
        body = issue["body"]
        self.assertTrue(body.endswith(
            "\n\n---\n**First seen:** 2026-09-23T12:00:00Z\n"
            "**Last seen:** 2026-09-23T12:00:00Z\n**Occurrences:** 1"), body)
        self.assertEqual(body.count("**Occurrences:**"), 1)
        self.assertIn("### PlausibleOOM", body)
        self.assertIn("## Currently firing\n\n- PlausibleOOM (critical)", body)
        self.assertIn("[📊 Grafana](https://grafana.bstjohn.net)", body)
        s = self.section(issue, "PlausibleOOM")
        self.assertEqual(s["first"], "2026-09-23T11:55:00Z")
        self.assertEqual(s["count"], 1)
        self.assertEqual(s["resolved"], "-")
        self.assertEqual(s["source"], "http://prometheus:9090/graph?PlausibleOOM")

    def test_second_alertname_adds_section(self):
        self.deliver([alert("A")])
        self.deliver([alert("B")], NOW + timedelta(minutes=1))
        issue = self.only_issue()
        state = server.parse_body(issue["body"])
        self.assertEqual(list(state["sections"]), ["A", "B"])
        self.assertEqual(state["total"], 2)
        self.assertIn("- A (warning)\n- B (warning)", issue["body"])

    def test_repeat_firing_updates_section(self):
        self.deliver([alert("A")])
        later = NOW + timedelta(minutes=30)
        self.deliver([alert("A", summary="new summary")], later)
        issue = self.only_issue()
        s = self.section(issue, "A")
        self.assertEqual(s["count"], 2)
        self.assertEqual(s["last"], iso(later))
        self.assertEqual(s["first"], "2026-09-23T11:55:00Z")
        self.assertEqual(s["summary"], "new summary")
        self.assertTrue(issue["body"].endswith(
            f"**First seen:** {iso(NOW)}\n**Last seen:** {iso(later)}\n**Occurrences:** 2"))

    def test_partial_resolve_keeps_issue_open(self):
        self.deliver([alert("A"), alert("B")])
        ends = NOW + timedelta(minutes=10)
        self.assertTrue(self.deliver([alert("A", status="resolved", ends=ends)], ends))
        issue = self.only_issue()
        self.assertEqual(issue["state"], "open")
        a = self.section(issue, "A")
        self.assertEqual(a["status"], "resolved")
        self.assertEqual(a["resolved"], iso(ends))
        self.assertEqual(self.section(issue, "B")["status"], "firing")
        self.assertIn("## Currently firing\n\n- B (warning)\n", issue["body"])

    def test_all_resolved_closes_issue(self):
        self.deliver([alert("A"), alert("B")])
        self.deliver([alert("A", status="resolved", ends=NOW)])
        self.deliver([alert("B", status="resolved", ends=NOW)])
        issue = self.only_issue()
        self.assertEqual(issue["state"], "closed")
        self.assertEqual(self.gh.writes()[-1][2]["state"], "closed")
        self.assertIn("## Currently firing\n\n- none\n", issue["body"])

    def test_refire_within_window_reopens(self):
        self.deliver([alert("A")])
        self.deliver([alert("A", status="resolved", ends=NOW)])
        issue = self.only_issue()
        self.assertEqual(issue["state"], "closed")
        later = NOW + timedelta(hours=3)
        self.assertTrue(self.deliver([alert("A")], later))
        issue = self.only_issue()
        self.assertEqual(issue["state"], "open")
        self.assertEqual(self.gh.writes()[-1][2]["state"], "open")
        s = self.section(issue, "A")
        self.assertEqual(s["status"], "firing")
        self.assertEqual(s["count"], 2)
        self.assertTrue(issue["body"].endswith(
            f"**First seen:** {iso(NOW)}\n**Last seen:** {iso(later)}\n**Occurrences:** 2"))

    def test_refire_outside_window_creates_new_issue(self):
        self.gh.add_issue(state="closed", body="old",
                          closed_at=iso(NOW - timedelta(hours=25)))
        self.assertTrue(self.deliver([alert("A")]))
        self.assertEqual(len(self.gh.issues), 2)
        self.assertEqual(self.gh.issues[1]["state"], "open")
        self.assertEqual(self.gh.issues[0]["state"], "closed")
        self.assertEqual(self.gh.writes()[-1][0], "POST")

    def test_reopen_picks_most_recently_closed(self):
        old = self.gh.add_issue(state="closed", closed_at=iso(NOW - timedelta(hours=10)))
        recent = self.gh.add_issue(state="closed", closed_at=iso(NOW - timedelta(hours=1)))
        self.deliver([alert("A")])
        self.assertEqual(recent["state"], "open")
        self.assertEqual(old["state"], "closed")

    def test_other_titles_and_pull_requests_ignored(self):
        self.gh.add_issue(title="[Alert] something else")
        self.gh.add_issue(pull_request=True)
        self.gh.add_issue(title=TITLE, labels=("alert:boom:",))
        self.deliver([alert("A")])
        self.assertEqual(len(self.gh.issues), 4)
        self.assertEqual(self.gh.writes()[-1][0], "POST")

    def test_multiple_open_uses_lowest_number(self):
        self.deliver([alert("A")])
        self.gh.add_issue(body="dup")
        self.deliver([alert("B")])
        state = server.parse_body(self.gh.issues[0]["body"])
        self.assertEqual(list(state["sections"]), ["A", "B"])
        self.assertEqual(self.gh.issues[1]["body"], "dup")

    # ── edge cases ──

    def test_mixed_instances_yield_one_firing_section(self):
        self.deliver([
            alert("A", status="resolved", namespace="x", ends=NOW),
            alert("A", namespace="y"),
        ])
        state = server.parse_body(self.only_issue()["body"])
        self.assertEqual(list(state["sections"]), ["A"])
        self.assertEqual(state["sections"]["A"]["status"], "firing")
        self.assertEqual(state["total"], 1)

    def test_resolve_in_one_group_keeps_other_group_firing(self):
        # Alertmanager groups by [alertname, namespace]: separate deliveries.
        self.deliver([alert("A", namespace="x")])
        self.deliver([alert("A", namespace="y")])
        ends = NOW + timedelta(minutes=10)
        self.assertTrue(self.deliver([alert("A", status="resolved", namespace="x", ends=ends)],
                                     ends))
        issue = self.only_issue()
        self.assertEqual(issue["state"], "open")
        s = self.section(issue, "A")
        self.assertEqual(s["status"], "firing")
        self.assertEqual(len(s["instances"]), 1)
        self.assertIn("## Currently firing\n\n- A (warning)\n", issue["body"])
        self.deliver([alert("A", status="resolved", namespace="y", ends=ends)], ends)
        issue = self.only_issue()
        self.assertEqual(issue["state"], "closed")
        s = self.section(issue, "A")
        self.assertEqual(s["status"], "resolved")
        self.assertEqual(s["instances"], set())

    def test_fingerprint_used_as_instance_key(self):
        a = alert("A")
        a["fingerprint"] = "0123abcd"
        self.deliver([a])
        self.assertEqual(self.section(self.only_issue(), "A")["instances"], {"0123abcd"})
        r = alert("A", status="resolved", ends=NOW)
        r["fingerprint"] = "0123abcd"
        self.deliver([r])
        self.assertEqual(self.only_issue()["state"], "closed")

    def test_resolve_unknown_alertname_ignored(self):
        self.assertTrue(self.deliver([alert("A", status="resolved", ends=NOW)]))
        self.assertEqual(self.gh.issues, [])
        self.deliver([alert("B")])
        n = len(self.gh.writes())
        self.assertTrue(self.deliver([alert("A", status="resolved", ends=NOW)]))
        self.assertEqual(len(self.gh.writes()), n)
        self.assertEqual(self.only_issue()["state"], "open")

    def test_failed_create_returns_false(self):
        self.gh.fail.add("POST")
        self.assertFalse(self.deliver([alert("A")]))

    def test_failed_lookup_returns_false(self):
        self.gh.fail.add("GET")
        self.assertFalse(self.deliver([alert("A")]))

    def test_failed_update_returns_false(self):
        self.deliver([alert("A")])
        self.gh.fail.add("PATCH")
        self.assertFalse(self.deliver([alert("A")]))

    def test_unparseable_body_keeps_tracking_block(self):
        self.gh.add_issue(body="hand edited\n\n---\n**First seen:** 2026-09-01T00:00:00Z\n"
                               "**Last seen:** 2026-09-02T00:00:00Z\n**Occurrences:** 7")
        self.deliver([alert("A")])
        state = server.parse_body(self.only_issue()["body"])
        self.assertEqual(state["first_seen"], "2026-09-01T00:00:00Z")
        self.assertEqual(state["total"], 8)
        self.assertEqual(list(state["sections"]), ["A"])

    def test_unparseable_body_resolved_only_closes(self):
        self.gh.add_issue(body="hand edited\n\n---\n**First seen:** 2026-09-01T00:00:00Z\n"
                               "**Last seen:** 2026-09-02T00:00:00Z\n**Occurrences:** 7")
        self.assertTrue(self.deliver([alert("A", status="resolved", ends=NOW)]))
        issue = self.only_issue()
        self.assertEqual(issue["state"], "closed")
        state = server.parse_body(issue["body"])
        self.assertEqual(state["sections"], {})
        self.assertEqual(state["total"], 7)

    def test_body_bounded_by_pruning_oldest_resolved(self):
        long = "x" * server.MAX_DESCRIPTION
        for i in range(80):
            t = NOW + timedelta(minutes=i)
            self.deliver([alert(f"A{i:02d}", description=long)], t)
            self.deliver([alert(f"A{i:02d}", status="resolved", ends=t)], t)
            self.deliver([alert("Keep")], t)
        body = self.only_issue()["body"]
        self.assertLessEqual(len(body), server.MAX_ISSUE_BODY)
        state = server.parse_body(body)
        self.assertEqual(state["sections"]["Keep"]["status"], "firing")
        self.assertNotIn("A00", state["sections"])
        self.assertIn("A79", state["sections"])
        self.assertEqual(state["total"], 160)

    def test_body_bounded_by_shortening_firing_descriptions(self):
        long = "x" * server.MAX_DESCRIPTION
        self.deliver([alert(f"A{i:02d}", description=long) for i in range(80)])
        body = self.only_issue()["body"]
        self.assertLessEqual(len(body), server.MAX_ISSUE_BODY)
        state = server.parse_body(body)
        self.assertEqual(len(state["sections"]), 80)
        self.assertEqual(len(state["sections"]["A00"]["description"]),
                         server.SHORT_DESCRIPTION)

    def test_round_trip(self):
        state = {
            "first_seen": "2026-09-23T10:00:00Z",
            "last_seen": "2026-09-23T11:00:00Z",
            "total": 5,
            "sections": {
                "A": {"severity": "critical", "status": "firing",
                      "first": "2026-09-23T10:00:00Z", "last": "2026-09-23T11:00:00Z",
                      "count": 3, "resolved": "-", "summary": "s | with pipe",
                      "description": "d", "source": "http://x/?a|b",
                      "dashboard": "https://grafana.bstjohn.net/d/x",
                      "instances": {"abc123", "def456"}},
                "B": {"severity": "warning", "status": "resolved",
                      "first": "2026-09-23T10:30:00Z", "last": "2026-09-23T10:30:00Z",
                      "count": 2, "resolved": "2026-09-23T10:40:00Z", "summary": "s2",
                      "description": "d2", "source": "", "dashboard": "",
                      "instances": set()},
            },
        }
        self.assertEqual(server.parse_body(server.render_body(state)), state)

    def test_long_multiline_description_collapsed_and_truncated(self):
        self.deliver([alert("A", description="line1\nline2 " + "x" * 2000)])
        s = self.section(self.only_issue(), "A")
        self.assertTrue(s["description"].startswith("line1 line2 x"))
        self.assertEqual(len(s["description"]), server.MAX_DESCRIPTION)

    def test_source_row_omitted_without_generator_url(self):
        server.configure({**BASE_ENV, "INCLUDE_GENERATOR_URL": "false"})
        self.deliver([alert("A")])
        body = self.only_issue()["body"]
        self.assertNotIn("| Source |", body)
        self.assertNotIn("prometheus:9090", body)

    def test_dashboard_row_rendered(self):
        a = alert("A")
        a["annotations"]["dashboard"] = "https://grafana.bstjohn.net/d/plausible"
        self.deliver([a])
        self.assertIn("| Dashboard | https://grafana.bstjohn.net/d/plausible |",
                      self.only_issue()["body"])

    def test_token_file_stripped(self):
        with tempfile.NamedTemporaryFile("w", delete=False) as f:
            f.write("ghp_secret\n")
        try:
            server.configure({"GITHUB_REPO": REPO, "GITHUB_TOKEN_FILE": f.name})
            self.assertEqual(server.GITHUB_TOKEN, "ghp_secret")
        finally:
            os.unlink(f.name)

    def test_defaults(self):
        server.configure({"GITHUB_REPO": REPO})
        self.assertEqual(server.ALERT_LABEL, "alert")
        self.assertEqual(server.REOPEN_WINDOW_HOURS, 24)
        self.assertTrue(server.INCLUDE_GENERATOR_URL)
        self.assertEqual(server.WEBHOOK_TOKEN, "")


class HTTPTest(unittest.TestCase):
    def setUp(self):
        self.received = []
        self._orig = server.handle_payload
        server.handle_payload = lambda alerts: self.received.append(alerts) or True
        self._out = io.StringIO()
        self._redirect = redirect_stdout(self._out)
        self._redirect.__enter__()
        server.configure(dict(BASE_ENV))
        self.httpd = server.make_server("127.0.0.1", 0)
        self.thread = threading.Thread(target=self.httpd.serve_forever, daemon=True)
        self.thread.start()

    def tearDown(self):
        self.httpd.shutdown()
        self.httpd.server_close()
        self._redirect.__exit__(None, None, None)
        server.handle_payload = self._orig

    def request(self, method, path, body=None, headers=None):
        conn = http.client.HTTPConnection("127.0.0.1", self.httpd.server_address[1], timeout=5)
        data = json.dumps(body).encode() if body is not None else None
        conn.request(method, path, body=data, headers=headers or {})
        resp = conn.getresponse()
        resp.read()
        conn.close()
        return resp.status

    def test_healthz(self):
        self.assertEqual(self.request("GET", "/healthz"), 200)
        self.assertEqual(self.request("GET", "/"), 404)

    def test_both_post_paths_unauthenticated(self):
        payload = {"alerts": [alert("A")]}
        self.assertEqual(self.request("POST", "/v1/receiver", payload), 200)
        self.assertEqual(self.request("POST", "/webhook", payload), 200)
        self.assertEqual(self.request("POST", "/other", payload), 404)
        self.assertEqual(len(self.received), 2)

    def test_bearer_token_enforced_when_set(self):
        server.configure({**BASE_ENV, "WEBHOOK_TOKEN": "s3cret"})
        payload = {"alerts": [alert("A")]}
        self.assertEqual(self.request("POST", "/webhook", payload), 401)
        self.assertEqual(self.request("POST", "/webhook", payload,
                                      {"Authorization": "Bearer wrong"}), 401)
        self.assertEqual(self.request("POST", "/webhook", payload,
                                      {"Authorization": "Bearer s3cret"}), 200)
        self.assertEqual(len(self.received), 1)

    def test_github_failure_returns_502(self):
        server.handle_payload = lambda alerts: False
        self.assertEqual(self.request("POST", "/v1/receiver", {"alerts": [alert("A")]}), 502)

    def test_healthz_answers_while_delivery_blocked(self):
        started, release = threading.Event(), threading.Event()

        def slow(alerts):
            started.set()
            release.wait(10)
            return True

        server.handle_payload = slow
        codes = []
        t = threading.Thread(target=lambda: codes.append(
            self.request("POST", "/v1/receiver", {"alerts": [alert("A")]})))
        t.start()
        try:
            self.assertTrue(started.wait(5))
            self.assertEqual(self.request("GET", "/healthz"), 200)
        finally:
            release.set()
            t.join(5)
        self.assertEqual(codes, [200])

    def test_invalid_json_returns_400(self):
        conn = http.client.HTTPConnection("127.0.0.1", self.httpd.server_address[1], timeout=5)
        conn.request("POST", "/v1/receiver", body=b"not json")
        self.assertEqual(conn.getresponse().status, 400)
        conn.close()


if __name__ == "__main__":
    unittest.main()
