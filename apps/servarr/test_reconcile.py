import json
import os
import sys
import tempfile
import time
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import reconcile  # noqa: E402


def json_copy(value):
    return json.loads(json.dumps(value))

BY_ID = ("Found matching series via grab history, but release was matched to "
         "series by ID. Automatic import is not possible.")


def record(did="abc", state="importBlocked", msgs=(BY_ID,), **extra):
    rec = {
        "downloadId": did,
        "title": "East.of.Eden.S01.1080p",
        "status": "completed",
        "trackedDownloadStatus": "warning",
        "trackedDownloadState": state,
        "statusMessages": [{"title": "x", "messages": list(msgs)}],
        "seriesId": 7,
    }
    rec.update(extra)
    return rec


def proposal(path="/downloads/e1.mkv", series_id=7, episodes=(101,), rejections=()):
    return {
        "path": path,
        "relativePath": os.path.basename(path),
        "folderName": "East.of.Eden.S01",
        "series": {"id": series_id} if series_id is not None else None,
        "episodes": [{"id": e} for e in episodes],
        "quality": {"quality": {"id": 3}},
        "languages": [{"id": 1}],
        "releaseGroup": "GRP",
        "releaseType": "seasonPack",
        "indexerFlags": 0,
        "downloadId": "abc",
        "rejections": list(rejections),
    }


class BlockedTests(unittest.TestCase):
    def test_import_blocked_and_pending(self):
        self.assertTrue(reconcile.is_blocked(record(state="importBlocked")))
        self.assertTrue(reconcile.is_blocked(record(state="importPending")))

    def test_completed_warning_is_blocked(self):
        self.assertTrue(reconcile.is_blocked(record(state="imported")))

    def test_downloading_is_not_blocked(self):
        rec = record(state="downloading", status="downloading",
                     trackedDownloadStatus="ok")
        self.assertFalse(reconcile.is_blocked(rec))

    def test_by_id_only(self):
        self.assertTrue(reconcile.is_by_id_only(record()))
        movie = record(msgs=("release was matched to movie by ID.",))
        self.assertTrue(reconcile.is_by_id_only(movie))

    def test_mixed_or_other_reason_is_not_by_id(self):
        self.assertFalse(reconcile.is_by_id_only(record(msgs=(BY_ID, "Not an upgrade"))))
        self.assertFalse(reconcile.is_by_id_only(record(msgs=("Unknown Series",))))
        self.assertFalse(reconcile.is_by_id_only(record(msgs=())))

    def test_merge_groups_season_pack_records(self):
        items = reconcile.merge_queue_records([
            record(episodeId=1), record(episodeId=2, msgs=("Not an upgrade",)),
            record(did="other", state="downloading", status="downloading",
                   trackedDownloadStatus="ok"),
        ])
        self.assertEqual(list(items), ["abc"])
        self.assertFalse(reconcile.is_by_id_only(items["abc"]))


class ImportPlanTests(unittest.TestCase):
    def test_accepts_unambiguous_sonarr(self):
        files, reason = reconcile.import_plan(
            record(), [proposal(), proposal("/downloads/e2.mkv", episodes=(102,))],
            "sonarr")
        self.assertEqual(reason, "unambiguous")
        self.assertEqual([f["episodeIds"] for f in files], [[101], [102]])
        self.assertEqual(files[0]["seriesId"], 7)
        self.assertEqual(files[0]["downloadId"], "abc")
        self.assertNotIn("movieId", files[0])

    def test_accepts_unambiguous_radarr(self):
        prop = proposal(series_id=None, episodes=())
        prop["movie"] = {"id": 9}
        files, _ = reconcile.import_plan({"movieId": 9, "downloadId": "abc"},
                                         [prop], "radarr")
        self.assertEqual(files[0]["movieId"], 9)
        self.assertNotIn("episodeIds", files[0])

    def test_rejects_rejection(self):
        files, reason = reconcile.import_plan(
            record(), [proposal(rejections=[{"reason": "Sample", "type": "permanent"}])],
            "sonarr")
        self.assertIsNone(files)
        self.assertIn("Sample", reason)

    def test_rejects_series_mismatch(self):
        files, _ = reconcile.import_plan(record(), [proposal(series_id=8)], "sonarr")
        self.assertIsNone(files)

    def test_rejects_missing_series(self):
        files, _ = reconcile.import_plan(record(), [proposal(series_id=None)], "sonarr")
        self.assertIsNone(files)

    def test_rejects_unknown_series_queue_item(self):
        files, _ = reconcile.import_plan(record(seriesId=None), [proposal()], "sonarr")
        self.assertIsNone(files)

    def test_rejects_two_episodes(self):
        files, _ = reconcile.import_plan(record(), [proposal(episodes=(1, 2))], "sonarr")
        self.assertIsNone(files)

    def test_rejects_two_files_one_episode(self):
        files, _ = reconcile.import_plan(
            record(), [proposal(), proposal("/downloads/dup.mkv")], "sonarr")
        self.assertIsNone(files)

    def test_rejects_empty_list(self):
        files, reason = reconcile.import_plan(record(), [], "sonarr")
        self.assertIsNone(files)
        self.assertEqual(reason, "empty proposal")


class RequestTests(unittest.TestCase):
    def series(self):
        return {"seasons": [
            {"seasonNumber": 0, "statistics": {"episodeFileCount": 0,
                                               "previousAiring": "2020-01-01T00:00:00Z"}},
            {"seasonNumber": 1, "statistics": {"episodeFileCount": 0,
                                               "previousAiring": "2020-01-01T00:00:00Z"}},
            {"seasonNumber": 2, "statistics": {"episodeFileCount": 4,
                                               "previousAiring": "2021-01-01T00:00:00Z"}},
            {"seasonNumber": 3, "statistics": {"episodeFileCount": 0}},
        ]}

    def test_missing_requested_seasons(self):
        aired = {0: 1, 1: 1, 2: 1}
        self.assertEqual(
            reconcile.missing_requested_seasons(self.series(), [1, 2, 3, 9], aired), [1])
        # Without an air check every requested season with no files counts.
        self.assertEqual(
            reconcile.missing_requested_seasons(self.series(), [1, 2, 3, 9]), [1, 3])

    def test_unrequested_season_is_ignored(self):
        self.assertEqual(reconcile.missing_requested_seasons(
            self.series(), [2], {2: 1}), [])

    def test_season_first_aired_ignores_monitoring_and_future(self):
        now = reconcile.parse_time("2026-01-01T00:00:00Z")
        episodes = [
            {"seasonNumber": 1, "monitored": False, "airDateUtc": "2020-02-01T00:00:00Z"},
            {"seasonNumber": 1, "monitored": False, "airDateUtc": "2020-01-01T00:00:00Z"},
            {"seasonNumber": 2, "monitored": True, "airDateUtc": "2027-01-01T00:00:00Z"},
            {"seasonNumber": 3, "monitored": True},
        ]
        self.assertEqual(reconcile.season_first_aired(episodes, now),
                         {1: reconcile.parse_time("2020-01-01T00:00:00Z")})

    def test_classify_search(self):
        self.assertEqual(reconcile.classify_search(
            [{"rejected": True}, {"rejected": False}]), "searching")
        self.assertEqual(reconcile.classify_search(
            [{"rejected": True}]), "no_acceptable_release")
        self.assertEqual(reconcile.classify_search([]), "no_acceptable_release")

    def test_top_rejections(self):
        results = [
            {"rejections": ["Quality not wanted", "Too small"]},
            {"rejections": ["Quality not wanted"]},
            {"rejections": ["Unknown"]},
            {"rejections": ["Too small", "Quality not wanted", "Other"]},
        ]
        self.assertEqual(reconcile.top_rejections(results),
                         "Quality not wanted; Too small; Unknown")
        self.assertEqual(reconcile.top_rejections([]), "no results from indexers")
        self.assertLessEqual(len(reconcile.top_rejections(
            [{"rejections": ["x" * 500]}])), 200)

    def test_merge_requests(self):
        reqs = [
            {"type": "tv", "media": {"tvdbId": 1}, "seasons": [{"seasonNumber": 1}]},
            {"type": "tv", "media": {"tvdbId": 1}, "seasons": [{"seasonNumber": 2}]},
            {"type": "tv", "is4k": True, "media": {"tvdbId": 2},
             "seasons": [{"seasonNumber": 1}]},
            {"type": "tv", "media": {"tvdbId": 1}, "createdAt": "1970-01-01T00:02:00Z",
             "seasons": [{"seasonNumber": 2}, {"seasonNumber": 3}]},
            {"type": "tv", "media": {"tvdbId": 1}, "createdAt": "1970-01-01T00:01:00Z",
             "seasons": [{"seasonNumber": 3}]},
            {"type": "movie", "media": {"tmdbId": 5}, "createdAt": "1970-01-01T00:01:00Z"},
        ]
        # Earliest request per season; an unknown createdAt is 0.
        self.assertEqual(reconcile.merge_requests(reqs, "tv"), {1: {1: 0, 2: 0, 3: 60}})
        self.assertEqual(reconcile.merge_requests(reqs, "movie"), {5: 60})

    def test_parse_time(self):
        self.assertEqual(reconcile.parse_time("1970-01-01T00:01:00Z"), 60)
        self.assertEqual(reconcile.parse_time("1970-01-01T00:01:00.1234567Z"), 60.123456)
        self.assertEqual(reconcile.parse_time("1970-01-01T01:01:00+01:00"), 60)
        self.assertIsNone(reconcile.parse_time("garbage"))

    def test_next_season_rotates(self):
        self.assertEqual(reconcile.next_season([1, 2, 3], None), 1)
        self.assertEqual(reconcile.next_season([1, 2, 3], 1), 2)
        self.assertEqual(reconcile.next_season([1, 2, 3], 3), 1)
        self.assertEqual(reconcile.next_season([None], None), None)

    def test_display_title(self):
        self.assertEqual(reconcile.display_title({"title": "Slow Horses", "year": 2022}),
                         "Slow Horses (2022)")
        self.assertEqual(reconcile.display_title({"title": "East of Eden (2026)",
                                                  "year": 2026}),
                         "East of Eden (2026)")

    def test_escape_label(self):
        self.assertEqual(reconcile.escape_label('a"b\\c\nd'), 'a\\"b\\\\c\\nd')


class FakeReconciler(reconcile.Reconciler):
    """Answers *arr and request-app calls from a dict; records every call."""

    def __init__(self, env, routes):
        self.routes = routes
        self.calls = []
        super().__init__(env)

    def http(self, method, url, headers, body=None, timeout=30):
        self.calls.append((method, url, body))
        for prefix, value in sorted(self.routes.items(), key=lambda kv: -len(kv[0])):
            if url.split("?")[0].endswith(prefix):
                return value(method, url, body) if callable(value) else value
        return None

    def writes(self):
        return [c for c in self.calls if c[0] != "GET"]


class RuntimeTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.env = {
            "APP": "sonarr", "API_PORT": "8989", "APIKEY": "k",
            "ROOT_FOLDER": "/tv", "CATEGORY_FIELD": "tvCategory",
            "CATEGORY_VALUE": "tv-sonarr",
            "REQUEST_APPS": "seerr=http://seerr:5055",
            "SEERR_API_KEY": "s",
            "STATE_FILE": os.path.join(self.tmp.name, "state.json"),
        }
        self.healthy = {
            "/system/status": {},
            "/rootfolder": [{"path": "/tv"}],
            "/downloadclient": [{"implementation": "Transmission"}],
            "/downloadclient/1": {"implementation": "Transmission",
                                  "removeCompletedDownloads": True,
                                  "removeFailedDownloads": True},
            "/queue": {"records": []},
            "/api/v1/request": {"results": [], "pageInfo": {"page": 1, "pages": 1}},
            "/series": [],
        }

    def tearDown(self):
        self.tmp.cleanup()

    def test_steady_state_makes_no_writes(self):
        r = FakeReconciler(self.env, self.healthy)
        r.run_once()
        self.assertEqual(r.writes(), [])
        self.assertFalse(os.path.exists(self.env["STATE_FILE"]))

    def test_by_id_item_is_imported_once_per_hour(self):
        routes = dict(self.healthy)
        routes["/queue"] = {"records": [record()]}
        routes["/manualimport"] = [proposal()]
        routes["/command"] = {"id": 1}
        r = FakeReconciler(self.env, routes)
        r.run_once()
        posts = [c for c in r.writes() if c[1].endswith("/command")]
        self.assertEqual(len(posts), 1)
        self.assertEqual(posts[0][2]["name"], "ManualImport")
        self.assertEqual(posts[0][2]["importMode"], "auto")
        self.assertEqual(r.metrics["auto_import"]["imported"], 1)
        r.run_once()
        self.assertEqual(len([c for c in r.writes() if c[1].endswith("/command")]), 1)
        # The cap survives a pod restart via the state file.
        r2 = FakeReconciler(self.env, routes)
        r2.run_once()
        self.assertEqual(r2.writes(), [])

    def test_other_reason_only_alerts(self):
        routes = dict(self.healthy)
        routes["/queue"] = {"records": [record(msgs=("Unknown Series",))]}
        r = FakeReconciler(self.env, routes)
        r.run_once()
        self.assertEqual(r.writes(), [])
        text = r.render_metrics()
        self.assertIn('reason="Unknown Series"', text)
        self.assertIn("servarr_queue_import_blocked_seconds{", text)

    def stalled_routes(self, monitored=False):
        old = "2026-06-29T10:00:00Z"
        # Real Sonarr computes previousAiring from monitored episodes only, so
        # an unmonitored season has none; airing comes from /episode instead.
        series = {
            "id": 3, "title": "Slow Horses", "year": 2022, "tvdbId": 100,
            "monitored": True, "added": old,
            "seasons": [
                {"seasonNumber": n, "monitored": monitored,
                 "statistics": {"episodeFileCount": 0,
                                "previousAiring": ("2022-04-01T00:00:00Z"
                                                   if monitored else None)}}
                for n in (1, 2, 3)
            ],
        }
        routes = dict(self.healthy)
        routes["/api/v1/request"] = {
            "results": [{"type": "tv", "media": {"tvdbId": 100},
                         "seasons": [{"seasonNumber": 1}, {"seasonNumber": 2}]}],
            "pageInfo": {"page": 1, "pages": 1}}
        routes["/series"] = [series]
        routes["/episode"] = [
            {"seasonNumber": n, "monitored": monitored,
             "airDateUtc": "2022-04-01T00:00:00Z"} for n in (1, 2, 3)]
        routes["/history/series"] = []
        routes["/series/3"] = series
        routes["/release"] = [{"rejected": False}]
        routes["/command"] = {"id": 2}
        return routes

    def test_unmonitored_request_is_remonitored_and_searched_daily(self):
        r = FakeReconciler(self.env, self.stalled_routes())
        r.run_once()
        puts = [c for c in r.writes() if c[0] == "PUT"]
        self.assertEqual(len(puts), 1)
        monitored = {s["seasonNumber"]: s["monitored"] for s in puts[0][2]["seasons"]}
        self.assertEqual(monitored, {1: True, 2: True, 3: False})
        commands = [c[2] for c in r.writes() if c[1].endswith("/command")]
        self.assertEqual(commands, [{"name": "SeasonSearch", "seriesId": 3,
                                     "seasonNumber": 1}])
        self.assertIn('reason="unmonitored"', r.render_metrics())
        # Next loop (and after a restart): no second search within a day.
        r2 = FakeReconciler(self.env, self.stalled_routes(monitored=True))
        r2.run_once()
        self.assertEqual(r2.writes(), [])
        self.assertFalse(any("/release" in c[1] for c in r2.calls))
        self.assertIn('reason="searching"', r2.render_metrics())

    def test_no_acceptable_release_alerts_without_writes(self):
        routes = self.stalled_routes(monitored=True)
        routes["/release"] = [{"rejected": True, "rejections": ["Quality not wanted"]}]
        r = FakeReconciler(self.env, routes)
        r.run_once()
        self.assertEqual(r.writes(), [])
        text = r.render_metrics()
        self.assertIn('reason="no_acceptable_release"', text)
        self.assertIn('rejections="Quality not wanted"', text)
        self.assertIn('title="Slow Horses (2022)"', text)

    def test_search_failure(self):
        routes = self.stalled_routes(monitored=True)

        def boom(method, url, body):
            raise OSError("timed out")
        routes["/release"] = boom
        r = FakeReconciler(self.env, routes)
        r.run_once()
        self.assertIn('reason="search_failed"', r.render_metrics())

    def test_grace_period_and_grab_suppress(self):
        routes = self.stalled_routes()
        recent = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
        routes["/series"][0]["added"] = recent
        r = FakeReconciler(self.env, routes)
        r.run_once()
        self.assertEqual(r.writes(), [])
        routes = self.stalled_routes()
        routes["/history/series"] = [{"date": "2026-06-29T11:00:00Z"}]
        r = FakeReconciler(self.env, routes)
        r.run_once()
        self.assertEqual(r.writes(), [])
        self.assertNotIn("servarr_request_stalled{", r.render_metrics())

    def test_unrequested_series_is_ignored(self):
        routes = self.stalled_routes()
        routes["/api/v1/request"] = {"results": [], "pageInfo": {"page": 1, "pages": 1}}
        r = FakeReconciler(self.env, routes)
        r.run_once()
        self.assertEqual(r.writes(), [])

    def test_unreachable_request_app_skips(self):
        routes = self.stalled_routes()

        def boom(method, url, body):
            raise OSError("refused")
        routes["/api/v1/request"] = boom
        r = FakeReconciler(self.env, routes)
        r.run_once()
        self.assertEqual(r.writes(), [])

    def test_new_request_on_old_series_waits(self):
        routes = self.stalled_routes()
        now = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
        routes["/api/v1/request"]["results"][0]["createdAt"] = now
        r = FakeReconciler(self.env, routes)
        r.run_once()
        self.assertEqual(r.writes(), [])
        self.assertNotIn("servarr_request_stalled{", r.render_metrics())

    def test_season_that_just_started_airing_waits(self):
        routes = self.stalled_routes()
        now = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
        for ep in routes["/episode"]:
            ep["airDateUtc"] = now
        r = FakeReconciler(self.env, routes)
        r.run_once()
        self.assertEqual(r.writes(), [])

    def test_partial_request_view_keeps_search_cap(self):
        env = dict(self.env, OVERSEERR_API_KEY="o", REQUEST_APPS=(
            "seerr=http://seerr:5055,overseerr=http://overseerr:5055"))
        routes = self.stalled_routes(monitored=True)
        request = routes["/api/v1/request"]
        empty = {"results": [], "pageInfo": {"page": 1, "pages": 1}}
        down = {"overseerr": False}

        def requests(method, url, body):
            if not url.startswith("http://overseerr"):
                return empty
            if down["overseerr"]:
                raise OSError("restarting")
            return request
        routes["/api/v1/request"] = requests
        r = FakeReconciler(env, routes)
        r.run_once()
        self.assertEqual(len([c for c in r.calls if "/release" in c[1]]), 1)
        down["overseerr"] = True
        r.run_once()
        self.assertIn('reason="searching"', r.render_metrics())
        down["overseerr"] = False
        r.run_once()
        self.assertEqual(len([c for c in r.calls if "/release" in c[1]]), 1)

    def two_sources(self, routes, overseerr):
        """Seerr serves the routes' requests; Overseerr calls overseerr()."""
        env = dict(self.env, OVERSEERR_API_KEY="o", REQUEST_APPS=(
            "seerr=http://seerr:5055,overseerr=http://overseerr:5055"))
        request = routes["/api/v1/request"]

        def requests(method, url, body):
            if url.startswith("http://overseerr"):
                return overseerr()
            return request
        routes["/api/v1/request"] = requests
        return env

    def test_failing_source_does_not_hide_healthy_source_alerts(self):
        routes = self.stalled_routes(monitored=True)
        routes["/release"] = [{"rejected": True, "rejections": ["Quality not wanted"]}]

        def down():
            raise OSError("401 Unauthorized")
        env = self.two_sources(routes, down)
        # A fresh pod (NAS wake) with Overseerr failing on every loop.
        r = FakeReconciler(env, routes)
        r.run_once()
        r.run_once()
        text = r.render_metrics()
        self.assertIn('reason="no_acceptable_release"', text)
        self.assertIn('servarr_request_source_up{app="sonarr",source="overseerr"} 0', text)
        self.assertIn('servarr_request_source_up{app="sonarr",source="seerr"} 1', text)

    def test_carried_entry_resolves_when_healthy_source_sees_it_fulfilled(self):
        routes = self.stalled_routes(monitored=True)
        up = {"overseerr": True}
        empty = {"results": [], "pageInfo": {"page": 1, "pages": 1}}

        def overseerr():
            if not up["overseerr"]:
                raise OSError("restarting")
            return empty
        env = self.two_sources(routes, overseerr)
        r = FakeReconciler(env, routes)
        r.run_once()
        self.assertIn('reason="searching"', r.render_metrics())
        up["overseerr"] = False
        routes["/history/series"] = [{"date": time.strftime(
            "%Y-%m-%dT%H:%M:%SZ", time.gmtime())}]
        r.run_once()
        self.assertNotIn("servarr_request_stalled{", r.render_metrics())

    def test_failed_lookup_keeps_only_that_item_and_expires(self):
        routes = self.stalled_routes(monitored=True)
        routes["/release"] = [{"rejected": True, "rejections": ["Quality not wanted"]}]
        other = json_copy(routes["/series"][0])
        other.update(id=4, title="Bad Sisters", year=2022, tvdbId=200)
        routes["/series"].append(other)
        routes["/api/v1/request"]["results"].append(
            {"type": "tv", "media": {"tvdbId": 200}, "seasons": [{"seasonNumber": 1}]})
        r = FakeReconciler(self.env, routes)
        # Two loops: one release search per loop.
        r.run_once()
        r.run_once()
        text = r.render_metrics()
        self.assertIn('title="Slow Horses (2022)"', text)
        self.assertIn('title="Bad Sisters (2022)"', text)
        # Bad Sisters' lookup now fails every loop; Slow Horses is fulfilled.
        episodes = routes["/episode"]

        def episode(method, url, body):
            if "seriesId=4" in url:
                raise OSError("500 Internal Server Error")
            return episodes
        routes["/episode"] = episode
        routes["/history/series"] = [{"date": time.strftime(
            "%Y-%m-%dT%H:%M:%SZ", time.gmtime())}]
        r.run_once()
        text = r.render_metrics()
        self.assertNotIn('title="Slow Horses (2022)"', text)
        self.assertIn('title="Bad Sisters (2022)"', text)
        # A carried entry lives at most a day past its last evaluation.
        for e in r.metrics["stalled"]:
            e["seen"] -= reconcile.SEARCH_INTERVAL_SECONDS
        r.run_once()
        self.assertNotIn("servarr_request_stalled{", r.render_metrics())

    def test_manualimport_failure_still_exports_blocked(self):
        routes = dict(self.healthy)
        routes["/queue"] = {"records": [
            record(), record(did="other", msgs=("Unknown Series",))]}

        def boom(method, url, body):
            raise OSError("500 Internal Server Error")
        routes["/manualimport"] = boom
        r = FakeReconciler(self.env, routes)
        r.run_once()
        text = r.render_metrics()
        self.assertIn('download_id="abc"', text)
        self.assertIn('download_id="other"', text)
        self.assertEqual(r.metrics["auto_import"]["failed"], 1)
        # The failed lookup counts as this hour's attempt.
        r.calls = []
        r.run_once()
        self.assertFalse(any("/manualimport" in c[1] for c in r.calls))

    def test_queue_is_paginated(self):
        routes = dict(self.healthy)

        def queue(method, url, body):
            did = "p2" if "page=2&" in url else "p1"
            return {"totalRecords": 2,
                    "records": [record(did=did, msgs=("Unknown Series",))]}
        routes["/queue"] = queue
        r = FakeReconciler(self.env, routes)
        r.run_once()
        text = r.render_metrics()
        self.assertIn('download_id="p1"', text)
        self.assertIn('download_id="p2"', text)


class JellyfinTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.env = {
            "APP": "sonarr", "API_PORT": "8989", "APIKEY": "k",
            "ROOT_FOLDER": "/tv", "JELLYFIN_LIBRARY_PATH": "/media/TV",
            "JELLYFIN_API_KEY": "jf",
            "STATE_FILE": os.path.join(self.tmp.name, "state.json"),
        }

    def tearDown(self):
        self.tmp.cleanup()

    def existing(self, **overrides):
        body = reconcile.jellyfin_body("sonarr", "/tv", "/media/TV", "********")
        body.update(id=4, **overrides)
        return body

    def test_missing_key_skips_without_calls(self):
        env = dict(self.env, JELLYFIN_API_KEY="")
        r = FakeReconciler(env, {})
        r.reconcile_jellyfin()
        r.reconcile_jellyfin()
        self.assertEqual(r.calls, [])

    def test_adds_connection_when_absent(self):
        r = FakeReconciler(self.env, {"/notification": []})
        r.reconcile_jellyfin()
        self.assertEqual(len(r.writes()), 1)
        method, url, body = r.writes()[0]
        self.assertEqual(method, "POST")
        self.assertNotIn("forceSave", url)
        fields = {f["name"]: f["value"] for f in body["fields"]}
        self.assertEqual(fields["apiKey"], "jf")
        self.assertEqual(fields["mapFrom"], "/tv")
        self.assertEqual(fields["mapTo"], "/media/TV")
        self.assertTrue(body["onImportComplete"])
        self.assertFalse(body["onGrab"])

    def test_reasserts_once_then_only_on_drift(self):
        current = self.existing()
        r = FakeReconciler(self.env, {"/notification": lambda *a: [current]})
        r.reconcile_jellyfin()
        self.assertEqual([c[1].split("/api/v3")[1] for c in r.writes()],
                         ["/notification/4?forceSave=true"])
        self.assertEqual(r.writes()[0][2]["id"], 4)
        r.reconcile_jellyfin()
        self.assertEqual(len(r.writes()), 1)
        current["onRename"] = False
        r.reconcile_jellyfin()
        self.assertEqual(len(r.writes()), 2)

    def test_drift_ignores_masked_key(self):
        desired = reconcile.jellyfin_body("radarr", "/movies", "/media/Movies", "jf")
        current = reconcile.jellyfin_body("radarr", "/movies", "/media/Movies",
                                          "********")
        self.assertIsNone(reconcile.jellyfin_drift(current, desired, "radarr"))
        current["fields"][-1]["value"] = "/media/TV"
        self.assertEqual(reconcile.jellyfin_drift(current, desired, "radarr"),
                         "mapTo")


if __name__ == "__main__":
    unittest.main()
