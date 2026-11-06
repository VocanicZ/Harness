"""The transaction query language used by `tallybook query`, `tx list --query` and the API's `?q=`.

    query  := or
    or     := and ("or" and)*
    and    := not (["and"] not)*          adjacent terms are joined by an implicit "and"
    not    := "not" not | "(" or ")" | term

A query is evaluated posting by posting: a transaction matches when at least one of its postings makes the whole
expression true. Terms about the transaction itself (payee, narration, tag, date, flag, id, bare text) have the same
answer for every posting; terms about a posting (account, amount) look at the posting being tried.
"""
import operator
import re
from decimal import Decimal

from .dates import Period, parse_date
from .errors import ParseError, TallybookError


class QueryError(ParseError):
    """A query that cannot be parsed. `.position` is the 1-based character offset the message names."""

    def __init__(self, message, position):
        super().__init__("%s at position %d" % (message, position), position=position)
        self.position = position


COMPARISONS = {"<": operator.lt, "<=": operator.le, ">": operator.gt, ">=": operator.ge,
               "=": operator.eq, "!=": operator.ne}
_AMOUNT_LITERAL = re.compile(r"^([+-]?\d+(?:\.\d+)?)([A-Z]{3})?$")


def parse_amount_literal(text):
    """'-5', '10.00', '3.5USD' -> (Decimal, currency code or None); ValueError when it is none of those."""
    m = _AMOUNT_LITERAL.match(text)
    if not m:
        raise ValueError("not an amount: %r" % text)
    return Decimal(m.group(1)), m.group(2)


def amount_satisfies(money, op, number, currency):
    """Compare a Money, as a decimal number of major units, with a literal; a currency in the literal must match."""
    if money is None:
        return False
    if currency is not None and money.currency != currency:
        return False
    return COMPARISONS[op](Decimal(money.amount_str()), number)


_KEYS = ("account", "payee", "narration", "tag", "date", "flag", "id")
_KEY = re.compile(r"([A-Za-z]+):")
_CMP = re.compile(r"(amount|date)\s*(<=|>=|!=|<|>|=)\s*", re.IGNORECASE)
_SEGMENT = re.compile(r"^(?:\*\*|\*|[A-Za-z0-9_-]+)$")


class _Token:
    def __init__(self, kind, pos, node=None):
        self.kind, self.pos, self.node = kind, pos, node


def _read_word(text, i):
    j = i
    while j < len(text) and not text[j].isspace() and text[j] not in "()":
        j += 1
    return text[i:j], j


def _read_quoted(text, i):
    """text[i] is the opening quote. Returns (value, index after the closing quote)."""
    out, j = [], i + 1
    while j < len(text):
        ch = text[j]
        if ch == "\\" and j + 1 < len(text) and text[j + 1] in '"\\':
            out.append(text[j + 1])
            j += 2
        elif ch == '"':
            j += 1
            if j < len(text) and not text[j].isspace() and text[j] not in "()":
                raise QueryError("unexpected text after the closing quote", j + 1)
            return "".join(out), j
        else:
            out.append(ch)
            j += 1
    raise QueryError("unterminated quoted text", i + 1)


def _term(key, value, pos, chart):
    """Build the node of a `key:value` term. `pos` is the 1-based position of the term."""
    if key == "account":
        segments = value.split(":")
        if not all(_SEGMENT.match(s) for s in segments):
            raise QueryError("invalid account pattern %r" % value, pos)
        if chart is not None and not any(_match_segments(segments, a.path.split(":")) for a in chart.accounts()):
            raise QueryError("no account matches %r" % value, pos)
        return ("account", segments)
    if key in ("payee", "narration"):
        return (key, value.lower())
    if key == "tag":
        return ("tag", value.lower())
    if key == "date":
        try:
            return ("period", Period.parse(value))
        except TallybookError as e:
            raise QueryError("invalid date period %r (%s)" % (value, e.message), pos)
    if key == "flag":
        if value not in ("*", "!"):
            raise QueryError("flag must be * or !, not %r" % value, pos)
        return ("flag", value)
    if key == "id":
        if not value.isdigit() or not value.isascii():
            raise QueryError("id must be a whole number, not %r" % value, pos)
        return ("id", int(value))
    raise QueryError("unknown term %r" % (key + ":"), pos)


def _lex(text, chart):
    tokens, i, n = [], 0, len(text)
    while i < n:
        ch = text[i]
        if ch.isspace():
            i += 1
        elif ch == "(":
            tokens.append(_Token("lp", i + 1))
            i += 1
        elif ch == ")":
            tokens.append(_Token("rp", i + 1))
            i += 1
        elif ch == '"':
            value, end = _read_quoted(text, i)
            if not value:
                raise QueryError("empty text", i + 1)
            tokens.append(_Token("term", i + 1, ("text", value.lower())))
            i = end
        else:
            tokens.append(_lex_word(text, i, chart))
            i = tokens[-1].end
    return tokens


def _lex_word(text, i, chart):
    pos = i + 1
    m = _CMP.match(text, i)
    if m:
        key, op = m.group(1).lower(), m.group(2)
        value, end = _read_word(text, m.end())
        if not value:
            raise QueryError("missing value after %r" % (key + op), pos)
        if key == "amount":
            try:
                number, cur = parse_amount_literal(value)
            except ValueError:
                raise QueryError("invalid amount %r" % value, pos)
            node = ("amount", op, number, cur)
        else:
            try:
                node = ("datecmp", op, parse_date(value))
            except TallybookError as e:
                raise QueryError("invalid date %r (%s)" % (value, e.message), pos)
        tok = _Token("term", pos, node)
        tok.end = end
        return tok
    m = _KEY.match(text, i)
    if m:
        key = m.group(1).lower()
        if key not in _KEYS:
            raise QueryError("unknown term %r" % (m.group(1) + ":"), pos)
        j = m.end()
        if j < len(text) and text[j] == '"':
            value, end = _read_quoted(text, j)
        else:
            value, end = _read_word(text, j)
        if not value:
            raise QueryError("missing value after %r" % (key + ":"), pos)
        tok = _Token("term", pos, _term(key, value, pos, chart))
        tok.end = end
        return tok
    word, end = _read_word(text, i)
    low = word.lower()
    if low in ("and", "or", "not"):
        tok = _Token(low, pos)
    else:
        tok = _Token("term", pos, ("text", low))
    tok.end = end
    return tok


class _Parser:
    def __init__(self, tokens, end_pos):
        self.tokens, self.i, self.end_pos = tokens, 0, end_pos

    def peek(self):
        return self.tokens[self.i] if self.i < len(self.tokens) else None

    def parse(self):
        if not self.tokens:
            return ("true",)
        node = self.or_expr()
        tok = self.peek()
        if tok is not None:
            raise QueryError("unmatched ')'", tok.pos)
        return node

    def or_expr(self):
        parts = [self.and_expr()]
        while self.peek() is not None and self.peek().kind == "or":
            self.i += 1
            parts.append(self.and_expr())
        return parts[0] if len(parts) == 1 else ("or", parts)

    def and_expr(self):
        parts = [self.not_expr()]
        while True:
            tok = self.peek()
            if tok is None or tok.kind in ("or", "rp"):
                break
            if tok.kind == "and":
                self.i += 1
            parts.append(self.not_expr())
        return parts[0] if len(parts) == 1 else ("and", parts)

    def not_expr(self):
        tok = self.peek()
        if tok is None:
            raise QueryError("expected a term", self.end_pos)
        if tok.kind in ("and", "or", "rp"):
            raise QueryError("expected a term", tok.pos)
        self.i += 1
        if tok.kind == "not":
            return ("not", self.not_expr())
        if tok.kind == "lp":
            node = self.or_expr()
            close = self.peek()
            if close is None or close.kind != "rp":
                raise QueryError("missing ')' for the '('", tok.pos)
            self.i += 1
            return node
        return tok.node


def _match_segments(pattern, account):
    """Does the pattern match the account path or one of its ancestors-of-the-account prefixes?
    `*` is exactly one segment, `**` zero or more; whatever follows the matched prefix is a descendant."""
    if not pattern:
        return True
    head = pattern[0]
    if head == "**":
        return any(_match_segments(pattern[1:], account[k:]) for k in range(len(account) + 1))
    if not account:
        return False
    if head == "*" or head == account[0]:
        return _match_segments(pattern[1:], account[1:])
    return False


def _holds(node, tx, posting):
    kind = node[0]
    if kind == "true":
        return True
    if kind == "and":
        return all(_holds(n, tx, posting) for n in node[1])
    if kind == "or":
        return any(_holds(n, tx, posting) for n in node[1])
    if kind == "not":
        return not _holds(node[1], tx, posting)
    if kind == "text":
        return node[1] in tx.payee.lower() or node[1] in tx.narration.lower()
    if kind == "payee":
        return node[1] in tx.payee.lower()
    if kind == "narration":
        return node[1] in tx.narration.lower()
    if kind == "tag":
        return node[1] in tx.tags
    if kind == "period":
        return node[1].contains(tx.date)
    if kind == "datecmp":
        return COMPARISONS[node[1]](tx.date, node[2])
    if kind == "flag":
        return tx.flag == node[1]
    if kind == "id":
        return tx.id == node[1]
    if kind == "account":
        return _match_segments(node[1], posting.account.split(":"))
    if kind == "amount":
        return amount_satisfies(posting.amount, node[1], node[2], node[3])
    raise AssertionError(kind)


class Query:
    def __init__(self, text, node):
        self.text = text
        self._node = node

    def __repr__(self):
        return "Query(%r)" % self.text

    @property
    def is_empty(self):
        return self._node == ("true",)

    def matching_postings(self, tx):
        """The postings of `tx` that make the query true, in order."""
        return [p for p in tx.postings if _holds(self._node, tx, p)]

    def matches(self, tx):
        return self.is_empty or bool(self.matching_postings(tx))


def parse_query(text, chart=None):
    """Parse a query. With a `chart`, every `account:` pattern must match at least one account of it."""
    tokens = _lex(text, chart)
    return Query(text, _Parser(tokens, len(text) + 1).parse())


def select(transactions, query):
    """The transactions matching `query` (text or a Query), in the order given."""
    if not isinstance(query, Query):
        query = parse_query(query)
    return [tx for tx in transactions if query.matches(tx)]
