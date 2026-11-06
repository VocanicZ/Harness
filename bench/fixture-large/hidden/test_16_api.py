"""Module 16: the HTTP API (`tallybook serve`). Black box over support.Server; the book is made with the library and
filled through the API itself."""
import atexit
import json
import os
import shutil
import signal
import tempfile
import threading
import unittest
import urllib.error
import urllib.request
from datetime import date
from unittest import mock

import support
from support import STANDARD_CHART, Server, lib, phase

MIB = 1024 * 1024


def make_book(path, chart=STANDARD_CHART):
    """A fresh, initialised book holding `chart` (the file is replaced; a running server opens it per request)."""
    if os.path.exists(path):
        os.remove(path)
    store = lib("storage").Store.open(path, create=True)
    try:
        for account in chart:
            store.add_account(account)
    finally:
        store.close()


def start_server(db, global_options=()):
    """`tallybook serve` on `db`; `global_options` (such as ["--today", "2024-06-30"]) go before the command."""
    if not global_options:
        return Server(db)
    base = support.cli_argv()
    with mock.patch.object(support, "cli_argv", lambda: base + list(global_options)):
        return Server(db)


def money(amount, currency="USD"):
    return {"amount": amount, "currency": currency}


def tx_body(day, payee, *postings, **extra):
    """A POST /transactions body; a posting is (account, "12.50 USD") or (account, None)."""
    body = {"date": day, "payee": payee, "postings": [{"account": a, "amount": m} for a, m in postings]}
    body.update(extra)
    return body


_SHARED = {}


def shared_server(options):
    """(book path, running server) for a set of global options. The tests run one by one, so a few servers live for
    the whole run (a server per test would cost a third of a second each); they are stopped when the run ends."""
    entry = _SHARED.get(options)
    if entry is None or entry[1].proc.poll() is not None:
        folder = tempfile.mkdtemp(prefix="tallybook-api-")
        db = os.path.join(folder, "book.db")
        make_book(db)
        entry = _SHARED[options] = (db, start_server(db, options), folder)
    return entry[0], entry[1]


@atexit.register
def _stop_servers():
    for db, srv, folder in _SHARED.values():
        srv.close()
        shutil.rmtree(folder, ignore_errors=True)


class ApiCase(unittest.TestCase):
    """A running server over a freshly made book (the standard chart, no transactions) for every test."""
    global_options = ()

    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="tallybook-api-test-")
        self.addCleanup(shutil.rmtree, self.tmp, ignore_errors=True)
        self.db, self.srv = shared_server(tuple(self.global_options))
        make_book(self.db)

    # ---- requests
    def get(self, path, **kw):
        return self.srv.call("GET", path, **kw)

    def post(self, path, body=None, **kw):
        return self.srv.call("POST", path, body, **kw)

    def put(self, path, body=None, **kw):
        return self.srv.call("PUT", path, body, **kw)

    def delete(self, path, **kw):
        return self.srv.call("DELETE", path, **kw)

    def raw(self, method, path, data=None, headers=None, base=None):
        """(status, headers, text) of any request, with the headers the Server helper does not return."""
        req = urllib.request.Request((base or self.srv.base) + path, data=data, method=method, headers=headers or {})
        try:
            with urllib.request.urlopen(req, timeout=30) as resp:
                return resp.status, resp.headers, resp.read().decode("utf-8")
        except urllib.error.HTTPError as err:
            return err.code, err.headers, err.read().decode("utf-8")

    # ---- expectations
    def ok(self, resp, status=200):
        self.assertEqual(resp[0], status, resp[1])
        return resp[1]

    def bad(self, resp, status=None):
        """An answer that refuses the request as wrong in either phase's error shape; returns the message."""
        got, body = resp
        self.assertIn(got, (400, 422) if status is None else (status,), body)
        self.assertIsInstance(body, dict)
        self.assertEqual(list(body), ["error"])
        err = body["error"]
        message = err if isinstance(err, str) else err["message"]
        self.assertTrue(message)
        return message

    # ---- fixtures
    def add_tx(self, day, payee, *postings, **extra):
        return self.ok(self.post("/transactions", tx_body(day, payee, *postings, **extra)), 201)

    def sample_book(self):
        """The sample book of the reports section, ids 1 to 8."""
        for day, payee, a, b in [
                ("2024-01-01", "Opening", ("Assets:Bank:Checking", "1000.00 USD"), ("Equity:Opening", "-1000.00 USD")),
                ("2024-03-01", "Acme", ("Assets:Bank:Checking", "2500.00 USD"), ("Income:Salary", "-2500.00 USD")),
                ("2024-03-02", "Market", ("Expenses:Food", "42.50 USD"), ("Assets:Bank:Checking", "-42.50 USD")),
                ("2024-03-05", "Landlord", ("Expenses:Rent", "900.00 USD"), ("Liabilities:Card", "-900.00 USD")),
                ("2024-03-10", "ATM", ("Assets:Cash", "100.00 USD"), ("Assets:Bank:Checking", "-100.00 USD")),
                ("2024-03-12", "Corner", ("Expenses:Food", "12.00 USD"), ("Assets:Cash", "-12.00 USD")),
                ("2024-04-02", "Card payoff", ("Liabilities:Card", "900.00 USD"), ("Assets:Bank:Checking", "-900.00 USD")),
                ("2024-04-03", "Market", ("Expenses:Food", "30.00 USD"), ("Assets:Bank:Checking", "-30.00 USD"))]:
            self.add_tx(day, payee, a, b)


# ---------------------------------------------------------------------------------------------------- the server

class M16Server(ApiCase):
    def test_health(self):
        self.assertEqual(self.get("/health"), (200, {"status": "ok", "version": "1.0.0", "schema_version": 4}))

    def test_json_answers_are_written_the_project_way(self):
        status, headers, text = self.raw("GET", "/health")
        self.assertEqual(status, 200)
        self.assertEqual(headers["Content-Type"], "application/json; charset=utf-8")
        self.assertEqual(int(headers["Content-Length"]), len(text.encode("utf-8")))
        self.assertEqual(text, json.dumps(json.loads(text), indent=2, sort_keys=True, ensure_ascii=False) + "\n")
        self.assertIn('\n  "schema_version": 4,\n', text)

    def test_non_ascii_text_is_not_escaped(self):
        self.add_tx("2024-03-01", "Café ☕", ("Expenses:Food", "4.50 USD"), ("Assets:Cash", None))
        status, headers, text = self.raw("GET", "/transactions/1")
        self.assertIn('"Café ☕"', text)
        self.assertEqual(json.loads(text)["payee"], "Café ☕")

    def test_unknown_paths_are_404(self):
        for path in ("/", "/nope", "/accounts/", "/transactions//1", "/Accounts", "/transactions/1/extra", "/reports",
                     "/reports/profit", "/budgets/status/1", "/health/", "/accounts/Assets:Cash/open", "/recurring/rent"):
            with self.subTest(path=path):
                self.assertEqual(self.get(path)[0], 404)
                self.assertEqual(self.post(path, {})[0], 404)

    def test_wrong_verbs_are_405_with_allow(self):
        for method, path, allow in [("DELETE", "/health", "GET"), ("PATCH", "/accounts", "GET, POST"),
                                    ("PUT", "/transactions", "GET, POST"), ("POST", "/transactions/1", "DELETE, GET"),
                                    ("PATCH", "/rates", "DELETE, GET, PUT"), ("POST", "/rules", "GET, PUT"),
                                    ("DELETE", "/budgets/status", "GET"), ("GET", "/recurring/materialize", "POST"),
                                    ("PUT", "/import", "POST"), ("POST", "/export", "GET"),
                                    ("DELETE", "/reports/register", "GET"), ("GET", "/accounts/Assets:Cash/close", "POST")]:
            with self.subTest(method=method, path=path):
                status, headers, text = self.raw(method, path, data=b"{}" if method in ("POST", "PUT", "PATCH") else None,
                                                headers={"Content-Type": "application/json"})
                self.assertEqual(status, 405)
                self.assertEqual(headers["Allow"], allow)
                self.assertIn("error", json.loads(text))

    def test_head_and_options_are_405(self):
        status, headers, text = self.raw("HEAD", "/health")
        self.assertEqual((status, headers["Allow"], text), (405, "GET", ""))
        status, headers, text = self.raw("OPTIONS", "/accounts")
        self.assertEqual((status, headers["Allow"]), (405, "GET, POST"))
        self.assertEqual(self.raw("HEAD", "/nowhere")[::2], (404, ""))

    def test_path_pieces_are_decoded_one_by_one(self):
        make_book(self.db, STANDARD_CHART + ["Assets:Bank:Savings"])
        for path in ("/accounts/Assets:Bank:Savings", "/accounts/Assets%3ABank%3ASavings", "/accounts/Assets%3aBank%3aSavings"):
            with self.subTest(path=path):
                self.assertEqual(self.ok(self.get(path))["path"], "Assets:Bank:Savings")
        self.assertEqual(self.get("/accounts/Assets%2FBank")[0], 404)       # %2F is not a path separator

    def test_query_strings_are_decoded(self):
        self.add_tx("2024-03-01", "Corner Shop", ("Expenses:Food", "1.00 USD"), ("Assets:Cash", None))
        self.add_tx("2024-03-02", "Market", ("Expenses:Food", "2.00 USD"), ("Assets:Cash", None))
        for q in ('payee:"Corner+Shop"', "payee%3A%22Corner%20Shop%22", "%22corner+shop%22"):
            with self.subTest(q=q):
                self.assertEqual([t["id"] for t in self.ok(self.get("/transactions?q=" + q))["items"]], [1])
        self.assertEqual(self.ok(self.get("/accounts?under=Assets%3ACash"))[0]["path"], "Assets:Cash")

    def test_repeated_parameter_last_wins_and_unknown_ones_are_ignored(self):
        for i in range(3):
            self.add_tx("2024-03-0%d" % (i + 1), "P%d" % i, ("Expenses:Food", "1.00 USD"), ("Assets:Cash", None))
        body = self.ok(self.get("/transactions?limit=1&limit=2&colour=red&offset=0"))
        self.assertEqual((body["limit"], len(body["items"])), (2, 2))
        self.assertEqual(self.ok(self.get("/transactions?q="))["total"], 3)     # an empty q is no filter

    def test_yes_no_parameters(self):
        self.ok(self.post("/accounts/Assets:Cash/close", {"on": "2024-02-01"}))
        for text, listed in [("true", 8), ("FALSE", 7), ("no", 7), ("0", 7), ("1", 8), ("Yes", 8)]:
            with self.subTest(include_closed=text):
                self.assertEqual(len(self.ok(self.get("/accounts?include_closed=" + text))), listed)
        self.bad(self.get("/accounts?include_closed=maybe"))

    def test_parallel_requests(self):
        results, lock = [], threading.Lock()

        def work(n):
            if n % 2:
                answer = self.srv.call("POST", "/transactions", tx_body("2024-03-01", "P%d" % n, ("Expenses:Food", "1.00 USD"),
                                                                    ("Assets:Cash", None)))
            else:
                answer = self.srv.call("GET", "/accounts")
            with lock:
                results.append(answer)

        threads = [threading.Thread(target=work, args=(n,)) for n in range(12)]
        for t in threads:
            t.start()
        for t in threads:
            t.join(60)
        self.assertEqual(len(results), 12)
        self.assertEqual(sorted(r[0] for r in results), [200] * 6 + [201] * 6)
        self.assertEqual(sorted(r[1]["id"] for r in results if r[0] == 201), [1, 2, 3, 4, 5, 6])
        self.assertEqual(self.ok(self.get("/transactions"))["total"], 6)

    def test_writes_are_committed_to_the_book_file(self):
        self.add_tx("2024-03-01", "Shop", ("Expenses:Food", "5.00 USD"), ("Assets:Cash", None))
        with lib("storage").Store.open(self.db) as store:
            self.assertEqual([t.payee for t in store.transactions()], ["Shop"])

    def test_stops_cleanly_on_sigterm_and_sigint(self):
        for sig in (signal.SIGTERM, signal.SIGINT):
            with self.subTest(signal=sig.name):
                srv = Server(self.db)
                try:
                    self.assertEqual(srv.get("/health")[0], 200)
                    srv.proc.send_signal(sig)
                    self.assertEqual(srv.proc.wait(20), 0)
                    out, err = srv.proc.stdout.read(), srv.proc.stderr.read()
                    self.assertEqual(out, "")           # the announce line was the only output
                    self.assertNotIn("Traceback", err)
                finally:
                    srv.close()

    def test_a_failing_request_prints_nothing(self):
        srv = Server(self.db)
        try:
            srv.get("/nope")
            srv.post("/transactions", raw=b"{broken")
            srv.post("/accounts", {"path": "nonsense"})
            srv.proc.terminate()
            self.assertEqual(srv.proc.wait(20), 0)
            self.assertEqual(srv.proc.stdout.read(), "")
            self.assertEqual(srv.proc.stderr.read(), "")
        finally:
            srv.close()


# ---------------------------------------------------------------------------------------------------- bodies

class M16Bodies(ApiCase):
    def test_content_type_parameters_and_case(self):
        for ctype in ("application/json", "application/json; charset=utf-8", "Application/JSON;charset=UTF-8"):
            with self.subTest(ctype=ctype):
                make_book(self.db)
                status, _, text = self.raw("POST", "/accounts", json.dumps({"path": "Assets:New"}).encode(),
                                           {"Content-Type": ctype})
                self.assertEqual(status, 201)

    def test_wrong_content_type_is_415(self):
        for ctype in ("text/plain", "application/xml", "application/x-www-form-urlencoded", ""):
            with self.subTest(ctype=ctype):
                status, _, text = self.raw("POST", "/accounts", b'{"path": "Assets:New"}', {"Content-Type": ctype} if ctype else {})
                self.assertEqual(status, 415)
                self.assertIn("error", json.loads(text))
        self.assertEqual(self.get("/accounts/Assets:New")[0], 404)

    def test_empty_body_needs_no_content_type(self):
        status, headers, text = self.raw("POST", "/recurring/materialize", data=b"")
        self.assertEqual((status, json.loads(text)), (200, {"added": []}))
        self.bad(self.post("/accounts", raw=b""))               # an empty object: `path` is missing

    def test_body_of_exactly_one_mib_is_fine_and_one_more_byte_is_413(self):
        body = b'{"rules": ""}'
        padded = body + b" " * (MIB - len(body))
        self.assertEqual(len(padded), MIB)
        self.assertEqual(self.put("/rules", raw=padded), (200, {"rules": ""}))
        status, body = self.put("/rules", raw=padded + b" ")
        self.assertEqual(status, 413)
        self.assertIn("error", body)
        self.assertEqual(self.get("/rules"), (200, {"rules": ""}))

    def test_a_large_refused_body_still_gets_its_answer(self):
        self.assertEqual(self.post("/transactions", raw=b"x" * (3 * MIB))[0], 413)
        self.assertEqual(self.post("/nope", raw=b"x" * (3 * MIB))[0], 404)
        self.assertEqual(self.get("/health")[0], 200)

    def test_unusable_bodies_are_refused(self):
        for raw in (b"{nope", b'{"path": ', b"\xff\xfe\x00", b"[1, 2]", b'"text"', b"3", b"'single'", b'{"path": "A"} x'):
            with self.subTest(raw=raw):
                self.bad(self.post("/accounts", raw=raw))
        self.assertEqual(len(self.ok(self.get("/accounts"))), 8)

    def test_unknown_missing_and_mistyped_fields(self):
        cases = [{"path": "Assets:New", "colour": "red"}, {"type": "asset"}, {"path": 5}, {"path": ["Assets:New"]},
                 {"path": "Assets:New", "note": 7}, {"path": "Assets:New", "currency": 3}, {"path": "Assets:New", "opened": 20240101},
                 {"path": None}]
        for body in cases:
            with self.subTest(body=body):
                self.bad(self.post("/accounts", body))
        self.assertEqual(len(self.ok(self.get("/accounts"))), 8)

    def test_null_means_not_given(self):
        body = {"path": "Assets:New", "type": None, "currency": None, "opened": None, "note": None}
        self.assertEqual(self.ok(self.post("/accounts", body), 201),
                         {"path": "Assets:New", "type": "asset", "currency": None, "opened": None, "closed": None, "note": ""})

    def test_body_of_get_and_delete_is_ignored(self):
        self.assertEqual(self.get("/health", raw=b"{broken")[0], 200)
        self.assertEqual(self.get("/health", raw=b"x" * 100, headers={"Content-Type": "text/plain"})[0], 200)


# ---------------------------------------------------------------------------------------------------- accounts

class M16Accounts(ApiCase):
    def test_list_is_sorted_by_path(self):
        accounts = self.ok(self.get("/accounts"))
        self.assertEqual([a["path"] for a in accounts], sorted(STANDARD_CHART))
        self.assertEqual(accounts[0], {"path": "Assets:Bank:Checking", "type": "asset", "currency": None, "opened": None,
                                       "closed": None, "note": ""})

    def test_create_with_all_fields(self):
        body = {"path": "Assets:Bank:Savings", "currency": "EUR", "opened": "2024-02-01", "note": "rainy day"}
        self.assertEqual(self.ok(self.post("/accounts", body), 201),
                         {"path": "Assets:Bank:Savings", "type": "asset", "currency": "EUR", "opened": "2024-02-01",
                          "closed": None, "note": "rainy day"})
        self.assertEqual(self.ok(self.get("/accounts/Assets:Bank:Savings"))["currency"], "EUR")
        self.assertEqual(self.ok(self.post("/accounts", {"path": "Income:Interest", "type": "income"}), 201)["type"], "income")

    def test_create_refusals(self):
        self.assertEqual(self.post("/accounts", {"path": "Assets:Cash"})[0], 409)
        for body in ({"path": "assets:lower"}, {"path": "Nothing:Here"}, {"path": "Assets:X", "type": "income"},
                     {"path": "Assets:X", "currency": "usd"}, {"path": "Assets:X", "currency": "ZZZ"},
                     {"path": "Assets:X", "opened": "2024-02-30"}, {"path": "Assets::X"}, {"path": ""}):
            with self.subTest(body=body):
                self.bad(self.post("/accounts", body))
        self.assertEqual(len(self.ok(self.get("/accounts"))), 8)

    def test_list_filters(self):
        self.ok(self.post("/accounts", {"path": "Assets:Bank:Savings", "currency": "EUR"}), 201)
        self.ok(self.post("/accounts/Assets:Cash/close", {"on": "2024-02-01"}))
        paths = lambda query: [a["path"] for a in self.ok(self.get("/accounts" + query))]
        self.assertEqual(paths("?type=liability"), ["Liabilities:Card"])
        self.assertEqual(paths("?type=expense"), ["Expenses:Food", "Expenses:Fun", "Expenses:Rent"])
        self.assertEqual(paths("?under=Assets:Bank"), ["Assets:Bank:Checking", "Assets:Bank:Savings"])
        self.assertEqual(paths("?under=Assets:Ban"), [])
        self.assertEqual(paths("?currency=EUR"), ["Assets:Bank:Savings"])
        self.assertNotIn("Assets:Cash", paths("?include_closed=false"))
        self.assertIn("Assets:Cash", paths(""))
        self.assertEqual(paths("?type=asset&under=Assets:Bank&include_closed=no"), ["Assets:Bank:Checking", "Assets:Bank:Savings"])
        self.bad(self.get("/accounts?type=cash"))

    def test_get_and_missing(self):
        self.assertEqual(self.ok(self.get("/accounts/Expenses:Food"))["type"], "expense")
        self.assertEqual(self.get("/accounts/Expenses:Nothing")[0], 404)
        self.assertEqual(self.get("/accounts/Assets")[0], 404)          # only a parent of longer paths

    def test_close(self):
        self.add_tx("2024-03-01", "Shop", ("Expenses:Food", "1.00 USD"), ("Assets:Cash", None))
        body = self.ok(self.post("/accounts/Assets:Cash/close", {"on": "2024-03-31"}))
        self.assertEqual((body["path"], body["closed"]), ("Assets:Cash", "2024-03-31"))
        self.assertEqual(self.ok(self.get("/accounts/Assets:Cash"))["closed"], "2024-03-31")
        self.add_tx("2024-03-31", "Last day", ("Expenses:Food", "1.00 USD"), ("Assets:Cash", None))
        self.bad(self.post("/transactions", tx_body("2024-04-01", "Late", ("Expenses:Food", "1.00 USD"), ("Assets:Cash", None))))

    def test_close_refusals(self):
        self.add_tx("2024-03-10", "Shop", ("Expenses:Food", "1.00 USD"), ("Assets:Cash", None))
        self.assertEqual(self.post("/accounts/Assets:Cash/close", {"on": "2024-03-01"})[0], 409)   # a posting is later
        self.assertEqual(self.post("/accounts/Assets:Nowhere/close", {"on": "2024-03-01"})[0], 404)
        self.bad(self.post("/accounts/Assets:Cash/close", {"on": "yesterday"}))
        self.bad(self.post("/accounts/Assets:Cash/close", {"when": "2024-03-01"}))
        self.assertIsNone(self.ok(self.get("/accounts/Assets:Cash"))["closed"])


class M16Today(ApiCase):
    """A server started with `--today 2024-06-30`."""
    global_options = ("--today", "2024-06-30")

    def test_close_without_a_day_closes_today(self):
        self.assertEqual(self.ok(self.post("/accounts/Assets:Cash/close"))["closed"], "2024-06-30")

    def test_materialize_stops_at_today(self):
        rent = {"name": "rent", "schedule": "monthly on 1", "start": "2024-01-01",
                "template": {"payee": "Flat", "postings": [{"account": "Expenses:Rent", "amount": "900.00 USD"},
                                                             {"account": "Assets:Cash", "amount": "-900.00 USD"}]}}
        self.ok(self.post("/recurring", rent), 201)
        added = self.ok(self.post("/recurring/materialize"))["added"]
        self.assertEqual([t["date"] for t in added], ["2024-%02d-01" % m for m in range(1, 7)])
        added = self.ok(self.post("/recurring/materialize", {"upto": "2030-01-01"}))["added"]      # still not past today
        self.assertEqual(added, [])
        self.assertEqual(self.ok(self.get("/transactions"))["total"], 6)

    def test_an_earlier_upto_wins_over_today(self):
        self.ok(self.post("/recurring", {"name": "daily", "schedule": "daily", "start": "2024-01-01", "count": 10,
                                         "template": {"payee": "x", "postings": [{"account": "Expenses:Food", "amount": "1.00 USD"},
                                                                                {"account": "Assets:Cash"}]}}), 201)
        added = self.ok(self.post("/recurring/materialize", {"upto": "2024-01-03"}))["added"]
        self.assertEqual([t["date"] for t in added], ["2024-01-01", "2024-01-02", "2024-01-03"])


# ---------------------------------------------------------------------------------------------------- transactions

class M16Transactions(ApiCase):
    def test_create_returns_the_stored_transaction(self):
        body = tx_body("2024-03-01", "Acme", ("Assets:Bank:Checking", "2500.00 USD"), ("Income:Salary", "-2500.00 USD"),
                       narration="March", flag="!", tags=["work", "income"])
        stored = self.ok(self.post("/transactions", body), 201)
        self.assertEqual(stored, {"id": 1, "date": "2024-03-01", "flag": "!", "payee": "Acme", "narration": "March",
                                  "tags": ["income", "work"],
                                  "postings": [{"account": "Assets:Bank:Checking", "amount": money("2500.00"), "note": ""},
                                               {"account": "Income:Salary", "amount": money("-2500.00"), "note": ""}]})
        self.assertEqual(self.get("/transactions/1"), (200, stored))

    def test_defaults_and_notes(self):
        stored = self.add_tx("2024-03-01", "Shop", ("Expenses:Food", "3.00 USD"), ("Assets:Cash", "-3.00 USD"))
        self.assertEqual((stored["flag"], stored["narration"], stored["tags"]), ("*", "", []))
        noted = self.ok(self.post("/transactions", {"date": "2024-03-02", "payee": "Shop", "tags": ["b", "a", "a"], "postings": [
            {"account": "Expenses:Food", "amount": "3.00 USD", "note": "bread"}, {"account": "Assets:Cash", "note": None}]}), 201)
        self.assertEqual(noted["tags"], ["a", "b"])
        self.assertEqual([p["note"] for p in noted["postings"]], ["bread", ""])
        self.assertEqual(noted["postings"][1]["amount"], money("-3.00"))
        self.assertEqual(noted["id"], 2)

    def test_amounts_in_both_forms_and_other_currencies(self):
        self.ok(self.post("/accounts", {"path": "Assets:Yen", "currency": "JPY"}), 201)
        body = {"date": "2024-03-01", "payee": "Trip", "postings": [
            {"account": "Assets:Yen", "amount": {"amount": "1500", "currency": "JPY"}},
            {"account": "Assets:Yen", "amount": "-1500 JPY"}]}
        stored = self.ok(self.post("/transactions", body), 201)
        self.assertEqual([p["amount"] for p in stored["postings"]], [money("1500", "JPY"), money("-1500", "JPY")])

    def test_amount_refusals(self):
        base = [{"account": "Expenses:Food", "amount": "3.00 USD"}, {"account": "Assets:Cash", "amount": None}]
        for amount in ("3.00", "3.001 USD", "3.00 usd", 3, 3.0, {"amount": "3.00"}, {"amount": 3, "currency": "USD"},
                       {"amount": "3.00", "currency": "USD", "extra": 1}, ["3.00 USD"]):
            with self.subTest(amount=amount):
                body = {"date": "2024-03-01", "payee": "Shop", "postings": [dict(base[0], amount=amount), base[1]]}
                self.bad(self.post("/transactions", body))
        self.assertEqual(self.ok(self.get("/transactions"))["total"], 0)

    def test_the_ledger_rules_apply_and_nothing_is_stored(self):
        cases = [tx_body("2024-03-01", "x", ("Expenses:Food", "3.00 USD"), ("Assets:Cash", "-2.00 USD")),     # unbalanced
                 tx_body("2024-03-01", "x", ("Expenses:Food", "3.00 USD")),                                    # one posting
                 tx_body("2024-03-01", "x", ("Expenses:Food", "3.00 USD"), ("Assets:Nowhere", "-3.00 USD")),   # unknown account
                 tx_body("2024-03-01", "x", ("Expenses:Food", None), ("Assets:Cash", None)),                  # two blanks
                 tx_body("2024-03-01", "x", ("Expenses:Food", "3.00 USD"), ("Assets:Cash", "-3.00 USD"), flag="?"),
                 tx_body("2024-03-01", "x", ("Expenses:Food", "3.00 USD"), ("Assets:Cash", "-3.00 USD"), tags=["a b"]),
                 tx_body("2024-03-01", "two\nlines", ("Expenses:Food", "3.00 USD"), ("Assets:Cash", "-3.00 USD")),
                 tx_body("2024-02-30", "x", ("Expenses:Food", "3.00 USD"), ("Assets:Cash", "-3.00 USD")),
                 tx_body("03/01/2024", "x", ("Expenses:Food", "3.00 USD"), ("Assets:Cash", "-3.00 USD"))]
        for body in cases:
            with self.subTest(body=body):
                self.bad(self.post("/transactions", body))
        self.assertEqual(self.ok(self.get("/transactions"))["total"], 0)

    def test_request_shape_refusals(self):
        ok_postings = [{"account": "Expenses:Food", "amount": "3.00 USD"}, {"account": "Assets:Cash"}]
        for body in ({"payee": "x", "postings": ok_postings}, {"date": "2024-03-01", "postings": ok_postings},
                     {"date": "2024-03-01", "payee": "x"}, {"date": "2024-03-01", "payee": 4, "postings": ok_postings},
                     {"date": 20240301, "payee": "x", "postings": ok_postings}, {"date": "2024-03-01", "payee": "x", "postings": "none"},
                     {"date": "2024-03-01", "payee": "x", "postings": [ok_postings[0], 5]},
                     {"date": "2024-03-01", "payee": "x", "postings": [{"amount": "1.00 USD"}, ok_postings[1]]},
                     {"date": "2024-03-01", "payee": "x", "postings": [dict(ok_postings[0], colour=1), ok_postings[1]]},
                     {"date": "2024-03-01", "payee": "x", "postings": ok_postings, "tags": "a"},
                     {"date": "2024-03-01", "payee": "x", "postings": ok_postings, "tags": [1]},
                     {"date": "2024-03-01", "payee": "x", "postings": ok_postings, "id": 9}):
            with self.subTest(body=body):
                self.bad(self.post("/transactions", body))

    def test_listing_envelope_and_order(self):
        self.add_tx("2024-03-05", "Third", ("Expenses:Food", "1.00 USD"), ("Assets:Cash", None))
        self.add_tx("2024-03-01", "First", ("Expenses:Food", "1.00 USD"), ("Assets:Cash", None))
        self.add_tx("2024-03-01", "Second", ("Expenses:Food", "1.00 USD"), ("Assets:Cash", None))
        body = self.ok(self.get("/transactions"))
        self.assertEqual(sorted(body), ["items", "limit", "offset", "total"])
        self.assertEqual([t["payee"] for t in body["items"]], ["First", "Second", "Third"])
        self.assertEqual((body["total"], body["limit"], body["offset"]), (3, None, 0))
        self.assertEqual(self.ok(self.get("/transactions"))["items"][0]["postings"][1]["amount"], money("-1.00"))

    def test_paging(self):
        for n in range(1, 6):
            self.add_tx("2024-03-%02d" % n, "P%d" % n, ("Expenses:Food", "1.00 USD"), ("Assets:Cash", None))
        for query, ids, limit, offset in [("?limit=2", [1, 2], 2, 0), ("?limit=2&offset=1", [2, 3], 2, 1),
                                          ("?offset=3", [4, 5], None, 3), ("?limit=10&offset=4", [5], 10, 4),
                                          ("?limit=0", [], 0, 0), ("?offset=99", [], None, 99), ("?limit=2&offset=04", [5], 2, 4)]:
            with self.subTest(query=query):
                body = self.ok(self.get("/transactions" + query))
                self.assertEqual(([t["id"] for t in body["items"]], body["total"], body["limit"], body["offset"]),
                                 (ids, 5, limit, offset))

    def test_query_filter_and_total(self):
        self.sample_book()
        body = self.ok(self.get("/transactions?q=account:Expenses:Food"))
        self.assertEqual([t["id"] for t in body["items"]], [3, 6, 8])
        self.assertEqual(body["total"], 3)
        body = self.ok(self.get("/transactions?q=account:Expenses:Food&limit=1&offset=1"))
        self.assertEqual(([t["id"] for t in body["items"]], body["total"]), ([6], 3))
        self.assertEqual(self.ok(self.get("/transactions?q=payee:market+date:2024-03"))["total"], 1)
        self.assertEqual(self.ok(self.get("/transactions?q=nothing-like-this"))["total"], 0)

    def test_listing_refusals(self):
        for query in ("?limit=-1", "?limit=abc", "?limit=2.5", "?limit=+3", "?limit=", "?offset=-1", "?offset=x",
                      "?limit=99999999999999999999", "?q=account:Nowhere", '?q=payee:"open'):
            with self.subTest(query=query):
                self.bad(self.get("/transactions" + query))

    def test_get_by_id(self):
        self.add_tx("2024-03-01", "Shop", ("Expenses:Food", "1.00 USD"), ("Assets:Cash", None))
        self.assertEqual(self.ok(self.get("/transactions/01"))["id"], 1)
        for ident in ("2", "abc", "-1", "+1", "1.0", "0x1", "1e0", "99999999999999999999999"):
            with self.subTest(ident=ident):
                self.assertEqual(self.get("/transactions/" + ident)[0], 404)

    def test_delete_returns_what_was_removed_and_ids_are_not_reused(self):
        first = self.add_tx("2024-03-01", "Shop", ("Expenses:Food", "1.00 USD"), ("Assets:Cash", None))
        self.assertEqual(self.delete("/transactions/1"), (200, first))
        self.assertEqual(self.get("/transactions/1")[0], 404)
        self.assertEqual(self.delete("/transactions/1")[0], 404)
        self.assertEqual(self.delete("/transactions/abc")[0], 404)
        self.assertEqual(self.add_tx("2024-03-01", "Again", ("Expenses:Food", "1.00 USD"), ("Assets:Cash", None))["id"], 2)
        self.assertEqual(self.ok(self.get("/transactions"))["total"], 1)


# ---------------------------------------------------------------------------------------------------- rates and budgets

class M16Rates(ApiCase):
    def test_put_list_replace_delete(self):
        self.assertEqual(self.ok(self.get("/rates")), [])
        rate = {"src": "USD", "dst": "EUR", "date": "2024-03-01", "rate": "0.9200"}
        self.assertEqual(self.put("/rates", rate), (200, rate))
        self.ok(self.put("/rates", {"src": "EUR", "dst": "USD", "date": "2024-02-01", "rate": "1.08"}))
        self.ok(self.put("/rates", dict(rate, date="2024-01-01", rate="0.91")))
        self.assertEqual([(r["src"], r["dst"], r["date"], r["rate"]) for r in self.ok(self.get("/rates"))],
                         [("EUR", "USD", "2024-02-01", "1.08"), ("USD", "EUR", "2024-01-01", "0.91"),
                          ("USD", "EUR", "2024-03-01", "0.9200")])
        self.ok(self.put("/rates", dict(rate, rate="0.93")))                       # same pair and day: replaced
        self.assertEqual(len(self.ok(self.get("/rates"))), 3)
        self.assertEqual(self.ok(self.get("/rates"))[2]["rate"], "0.93")
        self.assertEqual(self.delete("/rates?src=USD&dst=EUR&date=2024-03-01"), (200, dict(rate, rate="0.93")))
        self.assertEqual(len(self.ok(self.get("/rates"))), 2)

    def test_refusals(self):
        rate = {"src": "USD", "dst": "EUR", "date": "2024-03-01", "rate": "0.92"}
        for body in (dict(rate, rate=0.92), dict(rate, rate="0"), dict(rate, rate="-1"), dict(rate, rate="0.123456789"),
                     dict(rate, src="usd"), dict(rate, dst="XXX"), dict(rate, date="2024-3-1"), dict(rate, src=1),
                     {k: v for k, v in rate.items() if k != "rate"}, dict(rate, extra=1), {}):
            with self.subTest(body=body):
                self.bad(self.put("/rates", body))
        self.assertEqual(self.ok(self.get("/rates")), [])

    def test_delete_refusals(self):
        self.assertEqual(self.delete("/rates?src=USD&dst=EUR&date=2024-03-01")[0], 404)
        for query in ("", "?src=USD&dst=EUR", "?src=USD&dst=EUR&date=nope", "?dst=EUR&date=2024-03-01"):
            with self.subTest(query=query):
                self.bad(self.delete("/rates" + query))

    def test_a_rate_is_used_by_a_converted_report(self):
        self.sample_book()
        self.ok(self.put("/rates", {"src": "USD", "dst": "EUR", "date": "2024-03-01", "rate": "0.5"}))
        sheet = self.ok(self.get("/reports/balance-sheet?as_of=2024-03-31&convert_to=EUR"))
        self.assertEqual(sheet["currency"], "EUR")
        self.assertEqual(sheet["assets"]["total"], [money("1722.75", "EUR")])
        self.assertEqual(sheet["assets"]["accounts"][1],
                         {"account": "Assets:Cash", "balance": money("44.00", "EUR"), "original": money("88.00")})


class M16Budgets(ApiCase):
    BUDGET = {"pattern": "Expenses:Food", "period_kind": "month", "amount": money("400.00"), "start": "2024-01-01"}

    def test_create_list_delete(self):
        self.assertEqual(self.ok(self.get("/budgets")), [])
        self.assertEqual(self.ok(self.post("/budgets", self.BUDGET), 201), self.BUDGET)
        self.ok(self.post("/budgets", dict(self.BUDGET, period_kind="year", amount="3000.00 USD")), 201)
        self.ok(self.post("/budgets", dict(self.BUDGET, pattern="Expenses:*")), 201)
        listed = self.ok(self.get("/budgets"))
        self.assertEqual([(b["pattern"], b["period_kind"]) for b in listed],
                         [("Expenses:*", "month"), ("Expenses:Food", "month"), ("Expenses:Food", "year")])
        self.assertEqual(listed[2]["amount"], money("3000.00"))
        self.assertEqual(self.delete("/budgets?pattern=Expenses:Food&period_kind=month"), (200, self.BUDGET))
        self.assertEqual(len(self.ok(self.get("/budgets"))), 2)
        self.assertEqual(self.delete("/budgets?pattern=Expenses:Food&period_kind=month")[0], 404)
        self.assertEqual(self.delete("/budgets?pattern=Expenses%3A*&period_kind=month")[0], 200)

    def test_refusals(self):
        self.ok(self.post("/budgets", self.BUDGET), 201)
        self.assertEqual(self.post("/budgets", self.BUDGET)[0], 409)
        self.assertEqual(self.post("/budgets", dict(self.BUDGET, amount="500.00 USD"))[0], 409)
        for body in (dict(self.BUDGET, pattern="expenses"), dict(self.BUDGET, pattern="Expenses:Fo*"),
                     dict(self.BUDGET, pattern=""), dict(self.BUDGET, period_kind="week"),
                     dict(self.BUDGET, amount="0.00 USD"), dict(self.BUDGET, amount="-5.00 USD"), dict(self.BUDGET, amount=5),
                     dict(self.BUDGET, start="2024-1-1"), dict(self.BUDGET, pattern=7), dict(self.BUDGET, extra=1),
                     {k: v for k, v in self.BUDGET.items() if k != "start"}):
            with self.subTest(body=body):
                self.bad(self.post("/budgets", body))
        self.assertEqual(len(self.ok(self.get("/budgets"))), 1)
        for query in ("", "?pattern=Expenses:Food", "?period_kind=month"):
            with self.subTest(query=query):
                self.bad(self.delete("/budgets" + query))

    def test_status_over_the_sample_book(self):
        self.sample_book()
        self.ok(self.post("/budgets", self.BUDGET), 201)
        self.ok(self.post("/budgets", dict(self.BUDGET, pattern="Expenses", amount="800.00 USD")), 201)
        lines = self.ok(self.get("/budgets/status?period=2024-03"))
        self.assertEqual(len(lines), 2)
        self.assertEqual(lines[1], {
            "pattern": "Expenses:Food", "period_kind": "month", "budget": money("400.00"), "actual": money("54.50"),
            "remaining": money("345.50"), "percent": "13.6", "over": False,
            "accounts": [{"account": "Expenses:Food", "amount": money("54.50")}]})
        self.assertEqual((lines[0]["pattern"], lines[0]["actual"], lines[0]["over"]), ("Expenses", money("954.50"), True))
        self.assertEqual(self.ok(self.get("/budgets/status?period=2023-12")), [])
        april = self.ok(self.get("/budgets/status?period=2024-04"))
        self.assertEqual(april[1]["actual"], money("30.00"))

    def test_status_refusals(self):
        for query in ("", "?period=", "?period=March", "?period=2024-13", "?period=2024-03-31..2024-03-01"):
            with self.subTest(query=query):
                self.bad(self.get("/budgets/status" + query))

    @phase("pre")
    def test_percent_rounds_half_up_before_the_change(self):
        self.assertEqual(self._tiny_percent(), "0.3")

    @phase("post")
    def test_percent_rounds_half_even_after_the_change(self):
        self.assertEqual(self._tiny_percent(), "0.2")

    def _tiny_percent(self):
        """0.01 USD of a 4.00 USD allowance is exactly 0.25 percent."""
        self.ok(self.post("/budgets", {"pattern": "Expenses:Fun", "period_kind": "month", "amount": "4.00 USD",
                                       "start": "2024-01-01"}), 201)
        self.add_tx("2024-03-01", "Gum", ("Expenses:Fun", "0.01 USD"), ("Assets:Cash", None))
        return self.ok(self.get("/budgets/status?period=2024-03"))[0]["percent"]


# ---------------------------------------------------------------------------------------------------- recurring

class M16Recurring(ApiCase):
    RENT = {"name": "rent", "schedule": "monthly on 1", "start": "2024-01-01", "end": None, "count": None,
            "template": {"payee": "Flat", "narration": "", "flag": "*", "tags": ["home"], "postings": [
                {"account": "Expenses:Rent", "amount": money("900.00"), "note": ""},
                {"account": "Assets:Bank:Checking", "amount": money("-900.00"), "note": ""}]}}

    def test_create_list_delete(self):
        self.assertEqual(self.ok(self.get("/recurring")), [])
        self.assertEqual(self.ok(self.post("/recurring", self.RENT), 201), self.RENT)
        phone = {"name": "phone", "schedule": "Every 2  WEEKS from 2024-01-03", "start": "2024-02-01", "end": "2024-12-31",
                 "count": 20, "template": {"payee": "Telco", "postings": [{"account": "Expenses:Fun", "amount": "20.00 USD"},
                                                                         {"account": "Assets:Cash", "amount": None}]}}
        created = self.ok(self.post("/recurring", phone), 201)
        self.assertEqual((created["schedule"], created["end"], created["count"]), ("every 2 weeks from 2024-01-03", "2024-12-31", 20))
        self.assertEqual(created["template"], {"payee": "Telco", "narration": "", "flag": "*", "tags": [], "postings": [
            {"account": "Expenses:Fun", "amount": money("20.00"), "note": ""}, {"account": "Assets:Cash", "amount": None, "note": ""}]})
        self.assertEqual([r["name"] for r in self.ok(self.get("/recurring"))], ["phone", "rent"])
        self.assertEqual(self.delete("/recurring?name=rent"), (200, self.RENT))
        self.assertEqual([r["name"] for r in self.ok(self.get("/recurring"))], ["phone"])
        self.assertEqual(self.delete("/recurring?name=rent")[0], 404)
        self.bad(self.delete("/recurring"))

    def test_refusals(self):
        self.ok(self.post("/recurring", self.RENT), 201)
        self.assertEqual(self.post("/recurring", self.RENT)[0], 409)
        template = self.RENT["template"]
        for body in (dict(self.RENT, name="bad name"), dict(self.RENT, name="-x"), dict(self.RENT, schedule="monthly on 0"),
                     dict(self.RENT, schedule="sometimes"), dict(self.RENT, schedule=3), dict(self.RENT, start="soon"),
                     dict(self.RENT, name="b1", end="2023-12-31"), dict(self.RENT, name="b2", count=0),
                     dict(self.RENT, name="b3", count=True), dict(self.RENT, name="b4", count="3"),
                     dict(self.RENT, name="b5", template=None), dict(self.RENT, name="b6", template="rent"),
                     dict(self.RENT, name="b7", template={"postings": template["postings"]}),
                     dict(self.RENT, name="b8", template={"payee": "x"}),
                     dict(self.RENT, name="b9", template=dict(template, date="2024-01-01")),
                     dict(self.RENT, name="b10", colour=1)):
            with self.subTest(body=body):
                self.bad(self.post("/recurring", body))
        self.assertEqual(len(self.ok(self.get("/recurring"))), 1)

    def test_materialize_is_incremental(self):
        self.ok(self.post("/recurring", self.RENT), 201)
        first = self.ok(self.post("/recurring/materialize", {"upto": "2024-03-15"}))["added"]
        self.assertEqual([(t["id"], t["date"], t["tags"]) for t in first],
                         [(1, "2024-01-01", ["home", "recurring"]), (2, "2024-02-01", ["home", "recurring"]),
                          (3, "2024-03-01", ["home", "recurring"])])
        self.assertEqual(first[0]["postings"][0], {"account": "Expenses:Rent", "amount": money("900.00"), "note": ""})
        self.assertEqual(self.ok(self.post("/recurring/materialize", {"upto": "2024-03-15"})), {"added": []})
        more = self.ok(self.post("/recurring/materialize", {"upto": "2024-05-01"}))["added"]
        self.assertEqual([t["date"] for t in more], ["2024-04-01", "2024-05-01"])
        self.assertEqual(self.ok(self.get("/transactions"))["total"], 5)

    def test_materialize_count_and_end(self):
        self.ok(self.post("/recurring", dict(self.RENT, count=2)), 201)
        self.ok(self.post("/recurring", dict(self.RENT, name="insurance", schedule="monthly on 15", end="2024-02-20")), 201)
        added = self.ok(self.post("/recurring/materialize", {"upto": "2024-12-31"}))["added"]
        self.assertEqual([t["date"] for t in added], ["2024-01-01", "2024-01-15", "2024-02-01", "2024-02-15"])

    def test_materialize_failure_stores_nothing(self):
        self.ok(self.post("/recurring", self.RENT), 201)
        broken = dict(self.RENT, name="broken", start="2024-02-01",
                      template={"payee": "x", "postings": [{"account": "Expenses:Gone", "amount": "1.00 USD"},
                                                           {"account": "Assets:Cash"}]})
        self.ok(self.post("/recurring", broken), 201)
        self.bad(self.post("/recurring/materialize", {"upto": "2024-03-01"}))
        self.assertEqual(self.ok(self.get("/transactions"))["total"], 0)
        self.ok(self.delete("/recurring?name=broken"))
        self.assertEqual(len(self.ok(self.post("/recurring/materialize", {"upto": "2024-03-01"}))["added"]), 3)

    def test_materialize_refusals(self):
        for body in ({"upto": "2024-02-30"}, {"upto": 5}, {"until": "2024-03-01"}, [1]):
            with self.subTest(body=body):
                self.bad(self.post("/recurring/materialize", body))

    def test_removing_an_item_keeps_what_it_made(self):
        self.ok(self.post("/recurring", self.RENT), 201)
        self.ok(self.post("/recurring/materialize", {"upto": "2024-02-01"}))
        self.ok(self.delete("/recurring?name=rent"))
        self.assertEqual(self.ok(self.get("/transactions"))["total"], 2)


# ---------------------------------------------------------------------------------------------------- reports

BALANCE_SHEET_TEXT = """Balance sheet as of 2024-03-31

Account                     Balance
----------------------  -----------
Assets
  Assets:Bank:Checking  3357.50 USD
  Assets:Cash             88.00 USD
Total assets            3445.50 USD

Liabilities
  Liabilities:Card       900.00 USD
Total liabilities        900.00 USD

Equity
  Equity:Opening        1000.00 USD
  Retained earnings     1545.50 USD
Total equity            2545.50 USD
"""


class M16Reports(ApiCase):
    def setUp(self):
        super().setUp()
        self.sample_book()

    def test_trial_balance(self):
        report = self.ok(self.get("/reports/trial-balance?as_of=2024-03-31"))
        self.assertEqual((report["report"], report["as_of"]), ("trial_balance", "2024-03-31"))
        self.assertEqual([(a["account"], a["debit"], a["credit"]) for a in report["accounts"]][:3], [
            ("Assets:Bank:Checking", money("3357.50"), None), ("Assets:Cash", money("88.00"), None),
            ("Equity:Opening", None, money("1000.00"))])
        self.assertEqual(report["totals"], [{"currency": "USD", "debit": money("4400.00"), "credit": money("4400.00"),
                                             "balanced": True}])
        whole = self.ok(self.get("/reports/trial-balance"))
        self.assertIsNone(whole["as_of"])
        self.assertEqual(whole["totals"][0]["debit"], money("3500.00"))

    def test_trial_balance_of_an_empty_book(self):
        make_book(self.db)
        self.assertEqual(self.ok(self.get("/reports/trial-balance")),
                         {"report": "trial_balance", "as_of": None, "accounts": [], "totals": []})

    def test_balance_sheet(self):
        report = self.ok(self.get("/reports/balance-sheet?as_of=2024-03-31"))
        self.assertEqual(report["assets"]["total"], [money("3445.50")])
        self.assertEqual(report["liabilities"]["total"], [money("900.00")])
        self.assertEqual(report["equity"]["retained_earnings"], [money("1545.50")])
        self.assertEqual((report["equity"]["total"], report["balanced"], report["currency"]), ([money("2545.50")], True, None))

    def test_income_statement(self):
        report = self.ok(self.get("/reports/income-statement?period=2024-03"))
        self.assertEqual((report["start"], report["end"]), ("2024-03-01", "2024-03-31"))
        self.assertEqual([(a["account"], a["amount"], a["percent"]) for a in report["expenses"]["accounts"]],
                         [("Expenses:Food", money("54.50"), "5.7"), ("Expenses:Rent", money("900.00"), "94.3")])
        self.assertEqual(report["net"], [money("1545.50")])
        self.assertEqual(self.ok(self.get("/reports/income-statement?period=2024-03-01..2024-03-12"))["net"], [money("1545.50")])

    def test_cashflow(self):
        report = self.ok(self.get("/reports/cashflow?period=2024-03"))
        self.assertEqual((report["opening"], report["net"], report["closing"]), ([money("1000.00")], [money("2445.50")], [money("3445.50")]))
        self.assertEqual(report["inflows"], [{"account": "Income:Salary", "amount": money("2500.00")}])
        april = self.ok(self.get("/reports/cashflow?period=2024-04"))
        self.assertEqual([o["account"] for o in april["outflows"]], ["Expenses:Food", "Liabilities:Card"])

    def test_register(self):
        report = self.ok(self.get("/reports/register?account=Assets:Bank:Checking&period=2024-03"))
        self.assertEqual(report["opening"], [money("1000.00")])
        self.assertEqual([(r["id"], r["amount"]["amount"], r["balance"]["amount"]) for r in report["rows"]],
                         [(2, "2500.00", "3500.00"), (3, "-42.50", "3457.50"), (5, "-100.00", "3357.50")])
        self.assertEqual((report["closing"], report["rollup"]), ([money("3357.50")], False))
        whole = self.ok(self.get("/reports/register?account=Assets:Cash"))
        self.assertEqual((whole["start"], whole["end"], len(whole["rows"])), (None, None, 2))
        self.assertEqual(self.ok(self.get("/reports/register?account=Assets&rollup=true&period=2024-03"))["rollup"], True)
        self.assertEqual(len(self.ok(self.get("/reports/register?account=Assets"))["rows"]), 0)
        self.assertEqual(len(self.ok(self.get("/reports/register?account=Assets&rollup=yes"))["rows"]), 8)

    def test_text_format(self):
        status, headers, text = self.raw("GET", "/reports/balance-sheet?as_of=2024-03-31&format=text")
        self.assertEqual(status, 200)
        self.assertEqual(headers["Content-Type"], "text/plain; charset=utf-8")
        self.assertEqual(text, BALANCE_SHEET_TEXT)
        status, text = self.get("/reports/trial-balance?as_of=2024-03-31&format=text")
        self.assertTrue(text.startswith("Trial balance as of 2024-03-31\n\nAccount "))
        self.assertEqual(self.get("/reports/trial-balance?format=json")[0], 200)

    def test_conversion_needs_a_rate_and_a_date(self):
        for query in ("/reports/balance-sheet?as_of=2024-03-31&convert_to=EUR", "/reports/balance-sheet?convert_to=EUR",
                      "/reports/balance-sheet?as_of=2024-03-31&convert_to=XXX", "/reports/income-statement?period=2024-03&convert_to=EUR"):
            with self.subTest(query=query):
                self.bad(self.get(query))

    def test_refusals(self):
        for query in ("/reports/trial-balance?as_of=tomorrow", "/reports/trial-balance?as_of=", "/reports/trial-balance?format=pdf",
                      "/reports/balance-sheet?as_of=2024-02-30", "/reports/income-statement", "/reports/income-statement?period=Q1",
                      "/reports/cashflow", "/reports/cashflow?period=2024-03-02..2024-03-01", "/reports/register",
                      "/reports/register?account=Assets:Nowhere", "/reports/register?account=Assets:Cash&period=x",
                      "/reports/register?account=Assets:Cash&rollup=maybe"):
            with self.subTest(query=query):
                self.bad(self.get(query))


# ---------------------------------------------------------------------------------------------------- import, rules, export

PROFILE = """date_column = Date
payee_column = Payee
amount_column = Amount
currency = USD
account = Assets:Bank:Checking
default_account = Expenses:Fun
"""
STATEMENT = "Date,Payee,Amount\n2024-03-02,Cafe Nero,-4.50\n2024-03-03,Acme,2000.00\n"
CSV_HEADERS = {"Content-Type": "text/csv"}


class M16Import(ApiCase):
    def import_csv(self, query, text=STATEMENT, headers=CSV_HEADERS):
        return self.srv.call("POST", "/import" + query, raw=text.encode("utf-8"), headers=headers)

    def test_csv_body_with_profile_text(self):
        body = self.ok(self.import_csv("?profile=" + urllib.request.quote(PROFILE)))
        self.assertEqual(sorted(body), ["added", "duplicates"])
        self.assertEqual([(t["id"], t["date"], t["payee"]) for t in body["added"]], [(1, "2024-03-02", "Cafe Nero"), (2, "2024-03-03", "Acme")])
        self.assertEqual(body["added"][0]["postings"], [{"account": "Assets:Bank:Checking", "amount": money("-4.50"), "note": ""},
                                                        {"account": "Expenses:Fun", "amount": money("4.50"), "note": ""}])
        self.assertEqual(body["duplicates"], [])
        self.assertEqual(self.ok(self.get("/transactions"))["total"], 2)

    def test_stored_profile_and_text_plain(self):
        with lib("storage").Store.open(self.db) as store:
            store.set_profile("mybank", PROFILE)
        body = self.ok(self.import_csv("?profile=mybank", headers={"Content-Type": "text/plain; charset=utf-8"}))
        self.assertEqual(len(body["added"]), 2)

    def test_json_form(self):
        with lib("storage").Store.open(self.db) as store:
            store.set_profile("mybank", PROFILE)
        body = self.ok(self.post("/import", {"csv": STATEMENT, "profile": "mybank", "apply_rules": True}))
        self.assertEqual(len(body["added"]), 2)
        again = self.ok(self.post("/import", {"csv": STATEMENT, "profile": PROFILE, "apply_rules": None}))
        self.assertEqual((again["added"], len(again["duplicates"])), ([], 2))

    def test_importing_twice_reports_duplicates(self):
        query = "?profile=" + urllib.request.quote(PROFILE)
        self.ok(self.import_csv(query))
        again = self.ok(self.import_csv(query))
        self.assertEqual(again["added"], [])
        self.assertEqual([(t["id"], t["payee"]) for t in again["duplicates"]], [(None, "Cafe Nero"), (None, "Acme")])
        newer = self.ok(self.import_csv(query, STATEMENT + "2024-03-04,Bakery,-2.00\n"))
        self.assertEqual([t["payee"] for t in newer["added"]], ["Bakery"])
        self.assertEqual(self.ok(self.get("/transactions"))["total"], 3)

    def test_rules_are_applied_unless_switched_off(self):
        self.ok(self.put("/rules", {"rules": 'when payee ~ "nero" then account Expenses:Food tag coffee\n'}))
        profile = "?profile=" + urllib.request.quote(PROFILE)
        with_rules = self.ok(self.import_csv(profile))
        self.assertEqual((with_rules["added"][0]["postings"][1]["account"], with_rules["added"][0]["tags"]),
                         ("Expenses:Food", ["coffee"]))
        make_book(self.db)
        without = self.ok(self.import_csv(profile + "&apply_rules=false"))
        self.assertEqual((without["added"][0]["postings"][1]["account"], without["added"][0]["tags"]), ("Expenses:Fun", []))

    def test_bad_rows_import_nothing(self):
        text = STATEMENT + "not-a-date,Bad,1.00\n2024-03-05,Fine,-1.00\n2024-03-06,,-1.00\n"
        status, body = self.import_csv("?profile=" + urllib.request.quote(PROFILE), text)
        message = self.bad((status, body))
        self.assertTrue(message.startswith("import failed: row 4: "), message)
        self.assertIn("; row 6: ", message)
        self.assertEqual(self.ok(self.get("/transactions"))["total"], 0)

    def test_refusals(self):
        profile = "?profile=" + urllib.request.quote(PROFILE)
        self.assertEqual(self.import_csv("?profile=nosuchbank")[0], 404)
        self.bad(self.import_csv(""))                                             # no profile
        self.bad(self.import_csv("?profile=" + urllib.request.quote("nonsense = 1")))
        self.bad(self.import_csv(profile + "&apply_rules=maybe"))
        self.bad(self.import_csv(profile, "Wrong,Columns\n1,2\n"))                # the profile's columns are missing
        self.bad(self.import_csv(profile, ""))                                    # an empty file has no header
        self.bad(self.post("/import", {"csv": STATEMENT}))
        self.bad(self.post("/import", {"profile": PROFILE}))
        self.bad(self.post("/import", {"csv": 5, "profile": PROFILE}))
        self.bad(self.post("/import", {"csv": STATEMENT, "profile": PROFILE, "apply_rules": "yes"}))
        self.bad(self.post("/import", {"csv": STATEMENT, "profile": PROFILE, "extra": 1}))
        status, headers, text = self.raw("POST", "/import" + profile, STATEMENT.encode(), {"Content-Type": "application/xml"})
        self.assertEqual(status, 415)
        self.assertEqual(self.raw("POST", "/import" + profile, b"\xff\xfe", CSV_HEADERS)[0] in (400, 422), True)
        self.assertEqual(self.ok(self.get("/transactions"))["total"], 0)


class M16RulesAndExport(ApiCase):
    def test_rules_round_trip(self):
        self.assertEqual(self.get("/rules"), (200, {"rules": ""}))
        text = '# coffee\nwhen payee ~ "nero" then account Expenses:Food tag coffee\n\nwhen any then account Expenses:Fun\n'
        self.assertEqual(self.put("/rules", {"rules": text}), (200, {"rules": text}))
        self.assertEqual(self.get("/rules"), (200, {"rules": text}))
        self.assertEqual(self.put("/rules", {"rules": ""}), (200, {"rules": ""}))

    def test_bad_rules_change_nothing(self):
        text = "when any then account Expenses:Fun\n"
        self.ok(self.put("/rules", {"rules": text}))
        for body in ({"rules": "When any then flag *"}, {"rules": "when payee = nero then flag *"}, {"rules": 5}, {}, {"rules": text, "x": 1}):
            with self.subTest(body=body):
                self.bad(self.put("/rules", body))
        self.assertEqual(self.get("/rules"), (200, {"rules": text}))

    def test_export_json(self):
        self.assertEqual(self.get("/export"), (200, []))
        first = self.add_tx("2024-03-02", "B", ("Expenses:Food", "2.00 USD"), ("Assets:Cash", None))
        second = self.add_tx("2024-03-01", "A", ("Expenses:Food", "1.00 USD"), ("Assets:Cash", None), tags=["x"])
        self.assertEqual(self.get("/export?format=json"), (200, [second, first]))
        self.assertEqual(self.get("/export"), (200, [second, first]))

    def test_export_csv(self):
        self.add_tx("2024-03-01", "Café, Bäcker", ("Expenses:Food", "4.50 USD"), ("Assets:Cash", None), narration='say "hi"', tags=["b", "a"])
        status, headers, text = self.raw("GET", "/export?format=csv")
        self.assertEqual(status, 200)
        self.assertEqual(headers["Content-Type"], "text/csv; charset=utf-8")
        self.assertEqual(text, 'id,date,flag,payee,narration,tags,account,amount,currency,note\n'
                               '1,2024-03-01,*,"Café, Bäcker","say ""hi""",a;b,Expenses:Food,4.50,USD,\n'
                               '1,2024-03-01,*,"Café, Bäcker","say ""hi""",a;b,Assets:Cash,-4.50,USD,\n')

    def test_export_journal_is_the_whole_book(self):
        self.add_tx("2024-03-01", "Shop", ("Expenses:Food", "4.50 USD"), ("Assets:Cash", None))
        self.ok(self.put("/rates", {"src": "USD", "dst": "EUR", "date": "2024-03-01", "rate": "0.92"}))
        status, headers, text = self.raw("GET", "/export?format=journal")
        self.assertEqual((status, headers["Content-Type"]), (200, "text/plain; charset=utf-8"))
        journal = lib("journal").parse_journal(text)
        self.assertEqual(sorted(a.path for a in journal.accounts), sorted(STANDARD_CHART))
        self.assertEqual([(t.payee, t.postings[0].amount.minor) for t in journal.transactions], [("Shop", 450)])
        self.assertEqual(len(journal.rates), 1)
        self.assertEqual(text, lib("journal").format_journal(journal))

    def test_export_refusals(self):
        for query in ("?format=xml", "?format=", "?format=JSON"):
            with self.subTest(query=query):
                self.bad(self.get("/export" + query))


# ---------------------------------------------------------------------------------------------------- the error body

class ErrorShapes:
    """Every error answer, once for each generation of the API; subclasses say what the shape is."""

    def expect(self, resp, status, code):
        raise NotImplementedError

    def test_validation_error(self):
        self.expect(self.post("/accounts", {}), "bad", "validation")
        self.expect(self.post("/accounts", {"path": "Assets:X", "currency": "ZZZ"}), "bad", "validation")
        self.expect(self.get("/transactions?limit=-1"), "bad", "validation")

    def test_ledger_error(self):
        resp = self.post("/transactions", tx_body("2024-03-01", "x", ("Expenses:Food", "3.00 USD"), ("Assets:Cash", "-2.00 USD")))
        self.expect(resp, "bad", "validation")

    def test_parse_error(self):
        self.expect(self.post("/transactions", raw=b"{broken"), "bad", "parse")
        self.expect(self.post("/transactions", tx_body("2024-02-30", "x", ("Expenses:Food", "3.00 USD"), ("Assets:Cash", None))),
                    "bad", "parse")
        self.expect(self.get("/transactions?q=account:Nowhere"), "bad", "parse")
        self.expect(self.get("/reports/trial-balance?as_of=soon"), "bad", "parse")

    def test_not_found(self):
        self.expect(self.get("/transactions/99"), 404, "not_found")
        self.expect(self.get("/accounts/Assets:Nowhere"), 404, "not_found")
        self.expect(self.delete("/rates?src=USD&dst=EUR&date=2024-03-01"), 404, "not_found")

    def test_unknown_path(self):
        self.expect(self.get("/nowhere"), 404, "not_found")

    def test_conflict(self):
        self.expect(self.post("/accounts", {"path": "Assets:Cash"}), 409, "conflict")

    def test_wrong_verb(self):
        self.expect(self.delete("/accounts"), 405, None)

    def test_body_too_large(self):
        self.expect(self.post("/accounts", raw=b" " * (MIB + 1)), 413, None)

    def test_wrong_content_type(self):
        self.expect(self.post("/accounts", raw=b'{"path": "Assets:X"}', headers={"Content-Type": "text/plain"}), 415, None)

    def test_the_status_of_a_good_answer_is_untouched(self):
        self.assertEqual(self.post("/accounts", {"path": "Assets:X"})[0], 201)
        self.assertEqual(self.get("/accounts/Assets:X")[0], 200)


@phase("pre")
class M16ErrorsBeforeTheChange(ErrorShapes, ApiCase):
    def expect(self, resp, status, code):
        got, body = resp
        self.assertEqual(got, 400 if status == "bad" else status, body)
        self.assertEqual(list(body), ["error"])
        self.assertIsInstance(body["error"], str)
        self.assertTrue(body["error"])


@phase("post")
class M16ErrorsAfterTheChange(ErrorShapes, ApiCase):
    def expect(self, resp, status, code):
        got, body = resp
        self.assertEqual(got, 422 if status == "bad" else status, body)
        self.assertEqual(list(body), ["error"])
        self.assertEqual(sorted(body["error"]), ["code", "message"])
        self.assertTrue(body["error"]["message"])
        self.assertIsInstance(body["error"]["message"], str)
        if code is None:
            self.assertIsInstance(body["error"]["code"], str)
            self.assertTrue(body["error"]["code"])
        else:
            self.assertEqual(body["error"]["code"], code)


# ---------------------------------------------------------------------------------------------------- the lock (after the change)

@phase("pre")
class M16NoLockBeforeTheChange(ApiCase):
    def test_lock_is_an_unknown_path(self):
        for method in ("GET", "PUT", "DELETE", "POST"):
            with self.subTest(method=method):
                status, body = self.srv.call(method, "/lock", {"lock_date": "2024-03-31"} if method != "GET" else None)
                self.assertEqual(status, 404)
                self.assertEqual(list(body), ["error"])
                self.assertIsInstance(body["error"], str)


@phase("post")
class M16Lock(ApiCase):
    def lock(self, day):
        return self.ok(self.put("/lock", {"lock_date": day}))

    def test_no_lock_by_default(self):
        self.assertEqual(self.get("/lock"), (200, {"lock_date": None}))

    def test_set_get_and_clear(self):
        self.assertEqual(self.lock("2024-03-31"), {"lock_date": "2024-03-31"})
        self.assertEqual(self.get("/lock"), (200, {"lock_date": "2024-03-31"}))
        self.assertEqual(self.lock("2024-04-30"), {"lock_date": "2024-04-30"})
        self.assertEqual(self.lock(None), {"lock_date": None})
        self.assertEqual(self.get("/lock"), (200, {"lock_date": None}))

    def test_the_lock_is_kept_in_the_book(self):
        self.lock("2024-03-31")
        with lib("storage").Store.open(self.db) as store:
            self.assertEqual(store.lock_date(), date(2024, 3, 31))

    def test_refusals(self):
        for body in ({"lock_date": "2024-02-30"}, {"lock_date": "March"}, {"lock_date": 20240331}, {}, {"date": "2024-03-31"},
                     {"lock_date": "2024-03-31", "x": 1}):
            with self.subTest(body=body):
                status, answer = self.put("/lock", body)
                self.assertEqual(status, 422)
                self.assertEqual(answer["error"]["code"], "parse" if body == {"lock_date": "2024-02-30"} or body == {"lock_date": "March"} else "validation")
        self.assertEqual(self.get("/lock"), (200, {"lock_date": None}))
        self.assertEqual(self.post("/lock", {})[0], 405)
        self.assertEqual(self.delete("/lock")[0], 405)

    def test_adding_on_or_before_the_lock_is_refused(self):
        self.lock("2024-03-31")
        for day in ("2024-03-31", "2024-03-01", "2023-01-01"):
            with self.subTest(day=day):
                status, body = self.post("/transactions", tx_body(day, "x", ("Expenses:Food", "1.00 USD"), ("Assets:Cash", None)))
                self.assertEqual((status, body["error"]["code"]), (409, "locked"))
        self.assertEqual(self.ok(self.get("/transactions"))["total"], 0)
        self.assertEqual(self.add_tx("2024-04-01", "after", ("Expenses:Food", "1.00 USD"), ("Assets:Cash", None))["id"], 1)

    def test_deleting_inside_the_lock_is_refused(self):
        self.add_tx("2024-03-10", "old", ("Expenses:Food", "1.00 USD"), ("Assets:Cash", None))
        self.add_tx("2024-04-10", "new", ("Expenses:Food", "1.00 USD"), ("Assets:Cash", None))
        self.lock("2024-03-31")
        status, body = self.delete("/transactions/1")
        self.assertEqual((status, body["error"]["code"]), (409, "locked"))
        self.assertEqual(self.get("/transactions/1")[0], 200)
        self.assertEqual(self.delete("/transactions/2")[0], 200)
        self.lock(None)
        self.assertEqual(self.delete("/transactions/1")[0], 200)

    def test_import_inside_the_lock_adds_none_of_its_rows(self):
        self.lock("2024-03-02")
        status, body = self.srv.call("POST", "/import?profile=" + urllib.request.quote(PROFILE), raw=STATEMENT.encode(),
                                     headers=CSV_HEADERS)
        self.assertEqual((status, body["error"]["code"]), (409, "locked"))
        self.assertEqual(self.ok(self.get("/transactions"))["total"], 0)

    def test_materialize_inside_the_lock_adds_nothing(self):
        rent = {"name": "rent", "schedule": "monthly on 1", "start": "2024-01-01",
                "template": {"payee": "Flat", "postings": [{"account": "Expenses:Rent", "amount": "900.00 USD"},
                                                             {"account": "Assets:Cash"}]}}
        self.ok(self.post("/recurring", rent), 201)
        self.lock("2024-02-15")
        status, body = self.post("/recurring/materialize", {"upto": "2024-04-01"})
        self.assertEqual((status, body["error"]["code"]), (409, "locked"))
        self.assertEqual(self.ok(self.get("/transactions"))["total"], 0)
        self.lock(None)
        self.assertEqual(len(self.ok(self.post("/recurring/materialize", {"upto": "2024-04-01"}))["added"]), 4)


if __name__ == "__main__":
    unittest.main()
