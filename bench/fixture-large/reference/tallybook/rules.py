"""Categorisation rules: a small text format that decides the account, tags, narration, payee and flag of a
transaction from what the bank said about it.

    # one rule per line; the first rule that matches wins
    when payee ~ "coffee|cafe" and amount < 0 then account Expenses:Food tag coffee narration "Coffee break"
    when any then account Expenses:Misc
"""
import re
from dataclasses import dataclass, field, replace
from decimal import Decimal

from .dates import parse_date
from .errors import ParseError, TallybookError
from .query import COMPARISONS, amount_satisfies, parse_amount_literal


class RulesError(ParseError):
    """A rules file that cannot be parsed. `.line` is the 1-based line number the message names."""

    def __init__(self, message, line):
        super().__init__("line %d: %s" % (line, message), line=line)
        self.line = line


_TOKEN = re.compile(r'''\s*(?:(?P<str>"(?:[^"\\]|\\.)*")|(?P<op>!~|!=|<=|>=|~|=|<|>)'''
                    r'''|(?P<word>!(?![~=])|[^\s"~<>=!]+))''')
_PAIR = re.compile(r"\\(.)")
ACCOUNT_PATH = re.compile(r"^[A-Z][A-Za-z0-9_-]*(?::[A-Z][A-Za-z0-9_-]*)*$")
_TAG = re.compile(r"^[A-Za-z0-9_-]+$")

_TEXT_OPS = ("=", "!=", "~", "!~")
_ORDER_OPS = tuple(COMPARISONS)
_FIELD_OPS = {"payee": _TEXT_OPS, "narration": _TEXT_OPS, "amount": _ORDER_OPS, "date": _ORDER_OPS}


def _unquote(raw):
    """Inside the quotes only the pair \\" means something (a quote); every other backslash pair stays as written."""
    return _PAIR.sub(lambda m: '"' if m.group(1) == '"' else m.group(0), raw[1:-1])


def _tokenize(line, lineno):
    tokens, i = [], 0
    while True:
        if not line[i:].strip():
            return tokens
        m = _TOKEN.match(line, i)
        if m is None:
            raise RulesError("unterminated or unexpected text near %r" % line[i:].strip()[:20], lineno)
        kind = m.lastgroup
        tokens.append((kind, m.group(kind)))
        i = m.end()


@dataclass
class Condition:
    field: str
    op: str
    value: object                      # compiled regex, lower-cased text, Decimal or date
    currency: str = None

    def test(self, fields):
        if self.field in ("payee", "narration"):
            text = fields.get(self.field) or ""
            if self.op == "~":
                return self.value.search(text) is not None
            if self.op == "!~":
                return self.value.search(text) is None
            same = text.lower() == self.value
            return same if self.op == "=" else not same
        if self.field == "amount":
            return amount_satisfies(fields.get("amount"), self.op, self.value, self.currency)
        day = fields.get("date")
        return day is not None and COMPARISONS[self.op](day, self.value)


@dataclass
class Rule:
    line: int
    conditions: list = field(default_factory=list)
    actions: dict = field(default_factory=dict)

    def matches(self, fields):
        return all(c.test(fields) for c in self.conditions)


class _LineParser:
    def __init__(self, tokens, lineno):
        self.tokens, self.i, self.lineno = tokens, 0, lineno

    def fail(self, message):
        raise RulesError(message, self.lineno)

    def peek(self):
        return self.tokens[self.i] if self.i < len(self.tokens) else (None, None)

    def take(self, kind, what):
        got_kind, got = self.peek()
        if got_kind != kind:
            self.fail("expected %s" % what + (", found %r" % got if got is not None else " at the end of the line"))
        self.i += 1
        return got

    def parse(self):
        rule = Rule(self.lineno)
        word = self.take("word", "'when'")
        if word != "when":
            self.fail("a rule starts with 'when', not %r" % word)
        if self.peek() == ("word", "any"):
            self.i += 1
            self.take_then()
        else:
            while True:
                rule.conditions.append(self.condition())
                if self.take_then_or_and():
                    break
        while self.i < len(self.tokens):
            self.action(rule.actions)
        if not rule.actions:
            self.fail("a rule needs at least one action after 'then'")
        return rule

    def take_then(self):
        word = self.take("word", "'then'")
        if word != "then":
            self.fail("expected 'then', found %r" % word)

    def take_then_or_and(self):
        """True after 'then', False after 'and'."""
        word = self.take("word", "'and' or 'then'")
        if word not in ("and", "then"):
            self.fail("expected 'and' or 'then', found %r" % word)
        return word == "then"

    def condition(self):
        name = self.take("word", "a field name")
        if name not in _FIELD_OPS:
            self.fail("unknown field %r (use payee, narration, amount or date)" % name)
        op = self.take("op", "an operator")
        if op not in _FIELD_OPS[name]:
            self.fail("operator %s cannot be used with %s" % (op, name))
        if name in ("payee", "narration"):
            text = _unquote(self.take("str", "a quoted text"))
            if op in ("=", "!="):
                return Condition(name, op, text.lower())
            try:
                return Condition(name, op, re.compile(text, re.IGNORECASE))
            except re.error as e:
                self.fail("invalid regular expression %r: %s" % (text, e))
        value = self.take("word", "a value")
        if name == "amount":
            try:
                number, cur = parse_amount_literal(value)
            except ValueError:
                self.fail("invalid amount %r" % value)
            return Condition(name, op, number, cur)
        try:
            return Condition(name, op, parse_date(value))
        except TallybookError as e:
            self.fail("invalid date %r: %s" % (value, e.message))

    def action(self, actions):
        name = self.take("word", "an action")
        if name == "tag":
            tag = self.take("word", "a tag name")
            if not _TAG.match(tag):
                self.fail("invalid tag name %r" % tag)
            tags = actions.setdefault("tags", [])
            if tag.lower() not in tags:
                tags.append(tag.lower())
            return
        if name not in ("account", "narration", "payee", "flag"):
            self.fail("unknown action %r (use account, tag, narration, payee or flag)" % name)
        if name in actions:
            self.fail("%s is set twice" % name)
        if name == "account":
            value = self.take("word", "an account path")
            if not ACCOUNT_PATH.match(value):
                self.fail("invalid account path %r" % value)
        elif name == "flag":
            value = self.take("word", "* or !")
            if value not in ("*", "!"):
                self.fail("flag must be * or !, not %r" % value)
        else:
            value = _unquote(self.take("str", "a quoted text"))
            if name == "payee" and not value.strip():
                self.fail("payee must not be empty")
        actions[name] = value


class RuleSet:
    def __init__(self, rules=()):
        self.rules = list(rules)

    def __len__(self):
        return len(self.rules)

    def __iter__(self):
        return iter(self.rules)

    def match(self, fields):
        """The first rule whose conditions all hold for `fields`, or None."""
        for rule in self.rules:
            if rule.matches(fields):
                return rule
        return None

    def apply(self, fields):
        """The actions of the first matching rule as a new dict (only the keys the rule sets: account, tags (a list),
        narration, payee, flag), or None when no rule matches. `fields` has payee, narration, amount (Money), date."""
        rule = self.match(fields)
        if rule is None:
            return None
        return {k: (list(v) if isinstance(v, list) else v) for k, v in rule.actions.items()}

    def categorize(self, tx):
        """A copy of `tx` with the matching rule applied (`tx` itself when none matches). The rule sees the first
        posting's amount. `account` replaces the account of the second posting of a two-posting transaction."""
        fields = {"payee": tx.payee, "narration": tx.narration, "date": tx.date}
        if tx.postings:
            fields["amount"] = tx.postings[0].amount
        actions = self.apply(fields)
        if actions is None:
            return tx
        changes = {}
        for key in ("payee", "narration", "flag"):
            if key in actions:
                changes[key] = actions[key]
        if "tags" in actions:
            changes["tags"] = tuple(sorted(set(tx.tags) | set(actions["tags"])))
        if "account" in actions and len(tx.postings) == 2:
            changes["postings"] = [tx.postings[0], replace(tx.postings[1], account=actions["account"])]
        return replace(tx, **changes)


def parse_rules(text):
    rules = []
    if text.startswith("﻿"):
        text = text[1:]
    for lineno, raw in enumerate(text.split("\n"), 1):
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        rules.append(_LineParser(_tokenize(line, lineno), lineno).parse())
    return RuleSet(rules)
