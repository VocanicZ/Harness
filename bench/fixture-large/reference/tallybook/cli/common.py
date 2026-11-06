"""What the command families share: the run context, reading input, and the small formats several of them print."""
import re
import sys
from datetime import date

from ..dates import Period, parse_date
from ..errors import NotFoundError, TallybookError
from ..export import money_to_dict, render_table, to_json, transaction_to_dict
from ..model import Posting, Transaction
from ..money import Money
from ..storage import Store

DEFAULT_DB = "tallybook.db"


class CliError(TallybookError):
    """A failure the command line itself detects (an unreadable file, a malformed option value). Exit status 1."""


class Context:
    """Per-run state: which book, what 'today' is, and the stores to close at the end."""

    def __init__(self, db_path, today_text=None):
        self.db_path = db_path
        self.today_text = today_text
        self._stores = []

    def today(self):
        if self.today_text is not None:
            return parse_date(self.today_text)
        return date.today()

    def store(self):
        """The existing book. A missing file is reported with the hint to run `tallybook init`."""
        try:
            store = Store.open(self.db_path)
        except NotFoundError as exc:
            if str(exc).startswith("no such database"):
                raise NotFoundError("%s (run `tallybook init`)" % exc)
            raise
        self._stores.append(store)
        return store

    def close(self):
        for store in self._stores:
            store.close()
        self._stores = []


class Output:
    """What a command returns: the text for stdout and an exit status (non-zero only for `db check`)."""

    def __init__(self, text="", status=0):
        self.text = text
        self.status = status


# ---------------------------------------------------------------- reading input

def read_text(path, what="file"):
    """The UTF-8 text of a file, or of standard input for '-'. A byte-order mark is left for the library to ignore."""
    try:
        if path == "-":
            data = sys.stdin.buffer.read()
        else:
            with open(path, "rb") as fh:
                data = fh.read()
    except OSError as exc:
        raise CliError("cannot read %s %s: %s" % (what, path, exc.strerror or exc))
    try:
        return data.decode("utf-8")
    except UnicodeDecodeError:
        raise CliError("%s is not UTF-8 text" % ("standard input" if path == "-" else path))


def label(path):
    return "standard input" if path == "-" else path


def whole_number(text, what, minimum=0):
    """A decimal whole number of at most 18 digits; anything else is a CliError."""
    if not re.fullmatch(r"-?[0-9]{1,18}", text) or int(text) < minimum:
        raise CliError("invalid %s '%s': expected a whole number of at least %d" % (what, text, minimum))
    return int(text)


def optional_number(text, what, minimum=0):
    return None if text is None else whole_number(text, what, minimum)


def month_of(day):
    """The calendar month holding `day` as a Period."""
    return Period.parse("%04d-%02d" % (day.year, day.month))


def optional_date(text, default=None):
    return default if text is None else parse_date(text)


# ---------------------------------------------------------------- transactions typed on the command line

def parse_posting(text):
    """'ACCOUNT', 'ACCOUNT AMOUNT CURRENCY', either followed by '; note' -> Posting."""
    body, semicolon, note = text.partition(";")
    words = body.split()
    note = note.strip() if semicolon else ""
    if len(words) == 1:
        return Posting(words[0], None, note)
    if len(words) == 3:
        return Posting(words[0], Money.of(words[1], words[2]), note)
    raise CliError("invalid posting '%s': expected ACCOUNT or ACCOUNT AMOUNT CURRENCY (then an optional ; note)"
                   % text)


def build_transaction(day, payee, narration, flag, tags, postings):
    return Transaction(date=day, payee=payee, narration=narration or "", flag=flag or "*",
                       tags=tuple(tags), postings=[parse_posting(p) for p in postings])


# ---------------------------------------------------------------- shared formats

def table(headers, rows, align=None):
    return render_table(headers, rows, align)


def json_text(value):
    return to_json(value)


def tx_listing(txs, as_json=False):
    """Transactions as a table (or the JSON array): Id Date Flag Payee Narration Tags."""
    if as_json:
        return to_json([transaction_to_dict(tx) for tx in txs])
    if not txs:
        return ""
    rows = [[tx.id, tx.date.isoformat(), tx.flag, tx.payee, tx.narration, " ".join("#" + t for t in sorted(set(tx.tags)))]
            for tx in txs]
    return render_table(["Id", "Date", "Flag", "Payee", "Narration", "Tags"], rows, "rlllll")


def account_to_dict(account):
    return {
        "path": account.path,
        "type": account.type,
        "currency": account.currency,
        "opened": account.opened.isoformat() if account.opened else None,
        "closed": account.closed.isoformat() if account.closed else None,
        "note": account.note,
    }


def money_list(values):
    return [money_to_dict(m) for m in values]


def with_newline(text):
    """Stored text printed as it is, but ending in exactly the newline a text output needs (nothing for nothing)."""
    if text == "" or text.endswith("\n"):
        return text
    return text + "\n"


def counts_text(journal):
    return "%d accounts, %d rates, %d transactions" % (len(journal.accounts), len(journal.rates),
                                                       len(journal.transactions))
