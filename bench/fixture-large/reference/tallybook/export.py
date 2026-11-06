"""Export: transactions as CSV or JSON, the fixed-width text table every text report is drawn with, and the
small conversions (money, transaction, JSON text) the other modules share."""
import json

from .dates import DateError, parse_date
from .errors import ValidationError
from .model import Posting, Transaction
from .money import Money, MoneyError

CSV_HEADER = ["id", "date", "flag", "payee", "narration", "tags", "account", "amount", "currency", "note"]
_WHITESPACE = {ord("\t"): " ", ord("\r"): " ", ord("\n"): " "}
_CSV_SPECIAL = (",", '"', "\r", "\n")


class ExportError(ValidationError):
    """A table or export request that cannot be honoured (ragged rows, a bad alignment spec)."""


# ---------------------------------------------------------------- shared conversions

def money_to_dict(money):
    """Money as the JSON object {"amount": "12.50", "currency": "USD"}; None stays None."""
    if money is None:
        return None
    return {"amount": money.amount_str(), "currency": money.currency}


def posting_to_dict(posting):
    return {"account": posting.account, "amount": money_to_dict(posting.amount), "note": posting.note}


def transaction_to_dict(tx):
    """The JSON shape of a transaction (tags sorted, postings in order)."""
    return {
        "id": tx.id,
        "date": tx.date.isoformat(),
        "flag": tx.flag,
        "payee": tx.payee,
        "narration": tx.narration,
        "tags": sorted(set(tx.tags)),
        "postings": [posting_to_dict(p) for p in tx.postings],
    }


def to_json(obj):
    """The project-wide JSON text: two-space indent, sorted keys, no ASCII escaping, one trailing newline."""
    return json.dumps(obj, indent=2, sort_keys=True, ensure_ascii=False) + "\n"


# ---------------------------------------------------------------- CSV and JSON

def _csv_field(value):
    text = "" if value is None else str(value)
    if any(ch in text for ch in _CSV_SPECIAL):
        return '"' + text.replace('"', '""') + '"'
    return text


def to_csv(headers, rows):
    """Records joined by "\\n", every record (the header included) ends with one. A field is quoted only when it
    holds a comma, a double quote, a CR or an LF; quotes inside are doubled. None is an empty field."""
    out = []
    for record in [headers] + [list(r) for r in rows]:
        out.append(",".join(_csv_field(v) for v in record) + "\n")
    return "".join(out)


def transactions_to_csv(txs):
    """One record per posting, transactions in the order given. A transaction without postings gives one
    record with the four posting columns empty. A posting without an amount leaves amount and currency empty."""
    rows = []
    for tx in txs:
        head = [
            "" if tx.id is None else str(tx.id),
            tx.date.isoformat(),
            tx.flag,
            tx.payee,
            tx.narration,
            ";".join(sorted(set(tx.tags))),
        ]
        if not tx.postings:
            rows.append(head + ["", "", "", ""])
        for p in tx.postings:
            amount = p.amount
            rows.append(head + [
                p.account,
                "" if amount is None else amount.amount_str(),
                "" if amount is None else amount.currency,
                p.note,
            ])
    return to_csv(CSV_HEADER, rows)


def transactions_to_json(txs):
    """A JSON array of transaction objects, in the order given ("[]" plus a newline for none)."""
    return to_json([transaction_to_dict(tx) for tx in txs])


# ---------------------------------------------------------------- fixed-width tables

def _cell(value):
    text = "" if value is None else str(value)
    return text.translate(_WHITESPACE)


def _alignments(align, count):
    if align is None:
        return ["l"] * count
    spec = list(align)
    if len(spec) != count or any(a not in ("l", "r") for a in spec):
        raise ExportError("align must give 'l' or 'r' for each of the %d columns" % count)
    return spec


def render_table(headers, rows, align=None):
    """Header line, a rule line, then the rows; columns are separated by two spaces and as wide as their widest
    cell (width is len()); `align` is None (all left) or a string/list of "l"/"r" per column. Lines carry no
    trailing spaces and the text ends with a newline. No headers: the empty string."""
    head = [_cell(h) for h in headers]
    count = len(head)
    if count == 0:
        return ""
    sides = _alignments(align, count)
    body = []
    for number, row in enumerate(rows, 1):
        cells = [_cell(c) for c in row]
        if len(cells) != count:
            raise ExportError("row %d has %d cells, expected %d" % (number, len(cells), count))
        body.append(cells)
    widths = [max([len(head[i])] + [len(r[i]) for r in body]) for i in range(count)]

    def line(cells):
        padded = [c.rjust(w) if s == "r" else c.ljust(w) for c, w, s in zip(cells, widths, sides)]
        return "  ".join(padded).rstrip() + "\n"

    rule = ["-" * w for w in widths]
    return line(head) + line(rule) + "".join(line(r) for r in body)


# ---------------------------------------------------------------- reading the JSON back

_TX_FIELDS = {"id", "date", "flag", "payee", "narration", "tags", "postings"}
_POSTING_FIELDS = {"account", "amount", "note"}


def _text_field(obj, key, where, default=None):
    if key not in obj:
        if default is None:
            raise ExportError("%s: missing '%s'" % (where, key))
        return default
    if not isinstance(obj[key], str):
        raise ExportError("%s: '%s' must be text" % (where, key))
    return obj[key]


def _money_field(value, where):
    if value is None:
        return None
    if not isinstance(value, dict) or set(value) != {"amount", "currency"} \
            or not all(isinstance(v, str) for v in value.values()):
        raise ExportError('%s: an amount is {"amount": "12.50", "currency": "USD"} or null' % where)
    try:
        return Money.of(value["amount"], value["currency"])
    except ValidationError as exc:
        raise ExportError("%s: %s" % (where, exc.message))


def _posting_from_dict(obj, where):
    if not isinstance(obj, dict):
        raise ExportError("%s: a posting is an object" % where)
    extra = sorted(set(obj) - _POSTING_FIELDS)
    if extra:
        raise ExportError("%s: unknown field '%s'" % (where, extra[0]))
    account = _text_field(obj, "account", where)
    note = _text_field(obj, "note", where, "")
    return Posting(account, _money_field(obj.get("amount"), where + " amount"), note)


def _transaction_from_dict(obj, where):
    if not isinstance(obj, dict):
        raise ExportError("%s: a transaction is an object" % where)
    extra = sorted(set(obj) - _TX_FIELDS)
    if extra:
        raise ExportError("%s: unknown field '%s'" % (where, extra[0]))
    tx_id = obj.get("id")
    if tx_id is not None and (isinstance(tx_id, bool) or not isinstance(tx_id, int) or tx_id < 1):
        raise ExportError("%s: 'id' must be a whole number of at least 1 or null" % where)
    try:
        day = parse_date(_text_field(obj, "date", where))
    except DateError as exc:
        raise ExportError("%s: %s" % (where, exc.message))
    flag = _text_field(obj, "flag", where, "*")
    if flag not in ("*", "!"):
        raise ExportError("%s: 'flag' must be * or !" % where)
    tags = obj.get("tags", [])
    if not isinstance(tags, list) or not all(isinstance(t, str) for t in tags):
        raise ExportError("%s: 'tags' must be a list of text" % where)
    postings = obj.get("postings")
    if not isinstance(postings, list):
        raise ExportError("%s: 'postings' must be a list" % where)
    return Transaction(
        date=day,
        payee=_text_field(obj, "payee", where),
        narration=_text_field(obj, "narration", where, ""),
        postings=[_posting_from_dict(p, "%s posting %d" % (where, n)) for n, p in enumerate(postings, 1)],
        tags=tuple(sorted(set(tags))),
        flag=flag,
        id=tx_id,
    )


def transactions_from_json(text):
    """The inverse of transactions_to_json: a list of Transactions. Optional fields: id (null), flag ("*"),
    narration (""), tags ([]), a posting's note ("") and amount (null). Anything else wrong, or not there, is an
    ExportError that says which transaction ("transaction 2") and which field."""
    try:
        data = json.loads(text)
    except (TypeError, ValueError) as exc:
        raise ExportError("not JSON: %s" % exc)
    if not isinstance(data, list):
        raise ExportError("expected a JSON array of transactions")
    return [_transaction_from_dict(obj, "transaction %d" % n) for n, obj in enumerate(data, 1)]
