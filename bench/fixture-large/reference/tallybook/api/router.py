"""Routing: which function answers which path and verb, what a request carries, and how any failure becomes the
error answer (the one place where the API of the first release and the changed one differ)."""
import json
from dataclasses import dataclass, field
from datetime import date
from urllib.parse import parse_qsl, unquote

from .. import _phase
from ..errors import ParseError, TallybookError, ValidationError
from ..storage import Store
from . import handlers as h

MAX_BODY = 1024 * 1024
JSON = "application/json"
CSV_TYPES = ("text/csv", "text/plain")

# the status a library error code answers with; parse and validation errors are 400, and 422 after the change
_STATUS = {"parse": 400, "validation": 400, "not_found": 404, "conflict": 409, "locked": 409}


class HttpError(TallybookError):
    """A failure of the HTTP exchange itself (no such path, wrong verb, body too big, wrong content type)."""

    def __init__(self, status, code, message, headers=None):
        super().__init__(message)
        self.status, self.code, self.headers = status, code, headers or {}


def error_response(exc):
    """(status, body, headers) answering the exception `exc`.

    The first release answers `{"error": "<message>"}` with 400 for what was wrong in the request (code parse or
    validation); after the change the body is `{"error": {"code": ..., "message": ...}}` and that status is 422.
    """
    headers = {}
    if isinstance(exc, HttpError):
        status, code, message, headers = exc.status, exc.code, exc.message, exc.headers
    elif isinstance(exc, TallybookError):
        code, message = exc.code, exc.message
        status = _STATUS.get(code, 400)
    elif isinstance(exc, UnicodeError):
        status, code, message = 400, "validation", "the text holds characters that cannot be stored"
    else:
        status, code, message = 500, "internal", "internal error"
    if _phase.PRE:
        return status, {"error": message}, headers
    if status == 400 and code in ("parse", "validation"):
        status = 422
    return status, {"error": {"code": code, "message": message}}, headers


@dataclass
class Request:
    method: str
    path: str
    segments: list
    params: dict
    body: bytes = b""
    content_type: str = ""
    today: date = None
    body_error: Exception = None
    args: dict = field(default_factory=dict)
    json: object = None

    @property
    def media_type(self):
        return (self.content_type or "").split(";")[0].strip().lower()

    def text(self):
        """The body as text."""
        try:
            return self.body.decode("utf-8")
        except UnicodeDecodeError:
            raise ParseError("the body is not valid UTF-8 text")


def split_target(target):
    """(path, segments, params): the path as sent, its segments percent-decoded one by one (None when it does not
    start with a slash), and the query parameters (the last of a repeated name wins)."""
    path, _, query = target.split("#", 1)[0].partition("?")
    segments = [unquote(part) for part in path[1:].split("/")] if path.startswith("/") else None
    return path, segments, dict(parse_qsl(query, keep_blank_values=True))


def load_json(body):
    try:
        return json.loads(body.decode("utf-8"))
    except UnicodeDecodeError:
        raise ParseError("the body is not valid UTF-8 text")
    except RecursionError:
        raise ParseError("the JSON body is nested too deeply")
    except ValueError as exc:
        raise ParseError("the body is not valid JSON: %s" % exc)


# (path pattern, {verb: (function, body types it takes or None)}); "{name}" captures one non-empty segment
def _routes():
    j = (JSON,)
    table = [
        (("health",), {"GET": (h.health, None)}),
        (("accounts",), {"GET": (h.list_accounts, None), "POST": (h.create_account, j)}),
        (("accounts", "{path}"), {"GET": (h.get_account, None)}),
        (("accounts", "{path}", "close"), {"POST": (h.close_account, j)}),
        (("transactions",), {"GET": (h.list_transactions, None), "POST": (h.create_transaction, j)}),
        (("transactions", "{id}"), {"GET": (h.get_transaction, None), "DELETE": (h.delete_transaction, None)}),
        (("rates",), {"GET": (h.list_rates, None), "PUT": (h.put_rate, j), "DELETE": (h.delete_rate, None)}),
        (("budgets",), {"GET": (h.list_budgets, None), "POST": (h.create_budget, j), "DELETE": (h.delete_budget, None)}),
        (("budgets", "status"), {"GET": (h.budget_status, None)}),
        (("recurring",), {"GET": (h.list_recurring, None), "POST": (h.create_recurring, j),
                          "DELETE": (h.delete_recurring, None)}),
        (("recurring", "materialize"), {"POST": (h.materialize, j)}),
        (("reports", "trial-balance"), {"GET": (h.report_trial_balance, None)}),
        (("reports", "balance-sheet"), {"GET": (h.report_balance_sheet, None)}),
        (("reports", "income-statement"), {"GET": (h.report_income_statement, None)}),
        (("reports", "cashflow"), {"GET": (h.report_cashflow, None)}),
        (("reports", "register"), {"GET": (h.report_register, None)}),
        (("import",), {"POST": (h.import_csv, (JSON,) + CSV_TYPES)}),
        (("rules",), {"GET": (h.get_rules, None), "PUT": (h.put_rules, j)}),
        (("export",), {"GET": (h.export, None)}),
    ]
    if not _phase.PRE:      # the period lock exists after the change only; before it /lock is an unknown path
        table.append((("lock",), {"GET": (h.get_lock, None), "PUT": (h.put_lock, j)}))
    return table


ROUTES = _routes()


def match(segments):
    """(verbs, captured arguments) of the route that fits the path, or (None, None)."""
    for pattern, verbs in ROUTES:
        if len(pattern) != len(segments):
            continue
        args = {}
        for want, got in zip(pattern, segments):
            if want.startswith("{"):
                if not got:
                    break
                args[want[1:-1]] = got
            elif want != got:
                break
        else:
            return verbs, args
    return None, None


def dispatch(req, db_path):
    """Answer a request with a handlers.Reply, or raise the error to be turned into an answer by error_response.
    The order of the checks is fixed: path, verb, body size, body type and syntax, then the book."""
    verbs, args = match(req.segments) if req.segments is not None else (None, None)
    if verbs is None:
        raise HttpError(404, "not_found", "no such path: %s" % req.path)
    if req.method not in verbs:
        allow = ", ".join(sorted(verbs))
        raise HttpError(405, "method_not_allowed", "%s is not allowed on %s, use %s" % (req.method, req.path, allow),
                        {"Allow": allow})
    if req.body_error is not None:
        raise req.body_error
    function, accepts = verbs[req.method]
    if accepts and req.body:
        if req.media_type not in accepts:
            raise HttpError(415, "unsupported_media_type", "send the body as %s" % " or ".join(accepts))
        if req.media_type == JSON:
            req.json = load_json(req.body)
    req.args = args
    store = Store.open(db_path)
    try:
        return function(req, store)
    finally:
        store.close()
