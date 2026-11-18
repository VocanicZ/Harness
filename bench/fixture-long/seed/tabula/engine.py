"""tabula.engine -- the table model, the transforms, the output formats and the command line.

This is the one module every command lives in. A command is a function `cmd_NAME(args, opts)` that gets the
positional arguments (a list of strings) and the options (a dict) and returns a Table, which `main` then prints in the
format asked for (`--format text|csv|json`, text by default). A mistake in a file or in a request raises TabulaError
(exit status 1); a command line that is not shaped right raises UsageError (exit status 2).
"""
import csv
import io
import json
import re
import sys
import unicodedata
from decimal import Decimal, InvalidOperation, ROUND_HALF_UP, ROUND_FLOOR, ROUND_CEILING, ROUND_DOWN, getcontext

from .errors import TabulaError, UsageError

PROG = "tabula"
FORMATS = ("text", "csv", "json")
getcontext().prec = 60

NUMBER = re.compile(r"[+-]?(?:\d+(?:\.\d*)?|\.\d+)")


# --- numbers -------------------------------------------------------------------------------------------------

def to_decimal(text):
    """The Decimal a cell holds, or None when it is not a plain decimal number (no exponent, no thousands marks)."""
    text = text.strip()
    if not NUMBER.fullmatch(text):
        return None
    try:
        return Decimal(text)
    except InvalidOperation:
        return None


def fmt_decimal(number):
    """A Decimal as plain text: no exponent, no negative zero."""
    text = format(number, "f")
    if text.startswith("-") and not text.strip("-0."):
        text = text[1:]
    return text


def _need_number(value):
    number = to_decimal(value)
    if number is None:
        raise TabulaError("%r is not a number" % value)
    return number


def _need_count(arg, name):
    if arg is None or not arg.isdigit():
        raise TabulaError("%s needs a whole number argument, got %r" % (name, arg))
    return int(arg)


def _need_decimal_arg(arg, name):
    number = None if arg is None else to_decimal(arg)
    if number is None:
        raise TabulaError("%s needs a number argument, got %r" % (name, arg))
    return number


def _no_arg(name, arg):
    if arg is not None:
        raise TabulaError("%s takes no argument, got %r" % (name, arg))


def _need_text(arg, name):
    if arg is None:
        raise TabulaError("%s needs an argument" % name)
    return arg


# --- the table -----------------------------------------------------------------------------------------------

class Table:
    """Column names and rows of strings. `source` names where it came from, for messages."""

    def __init__(self, columns, rows, source="<table>"):
        self.columns = list(columns)
        self.rows = [list(r) for r in rows]
        self.source = source

    def __len__(self):
        return len(self.rows)

    def index(self, name):
        """Position of a column; TabulaError when there is none."""
        try:
            return self.columns.index(name)
        except ValueError:
            raise TabulaError("%s: no column %r (columns: %s)" % (self.source, name, ", ".join(self.columns)))

    def column(self, name):
        at = self.index(name)
        return [row[at] for row in self.rows]

    def dicts(self):
        return [dict(zip(self.columns, row)) for row in self.rows]

    def with_rows(self, rows, columns=None):
        return Table(self.columns if columns is None else columns, rows, self.source)


def parse_text(text, source):
    """CSV text into a Table. Blank lines are ignored; every row must have as many fields as the header."""
    if text.startswith("﻿"):
        text = text[1:]
    reader = csv.reader(io.StringIO(text, newline=""))
    columns, rows = None, []
    try:
        for fields in reader:
            if not fields:
                continue
            if columns is None:
                for name in fields:
                    if not name.strip():
                        raise TabulaError("%s: line %d: empty column name" % (source, reader.line_num))
                if len(set(fields)) != len(fields):
                    raise TabulaError("%s: line %d: duplicate column name" % (source, reader.line_num))
                columns = fields
                continue
            if len(fields) != len(columns):
                raise TabulaError("%s: line %d: expected %d fields, found %d"
                                  % (source, reader.line_num, len(columns), len(fields)))
            rows.append(fields)
    except csv.Error as exc:
        raise TabulaError("%s: line %d: %s" % (source, reader.line_num, exc))
    if columns is None:
        raise TabulaError("%s: no header line" % source)
    return Table(columns, rows, source)


def load(path):
    """Read a CSV file (UTF-8, optional byte order mark, LF or CRLF) into a Table."""
    try:
        with open(path, "rb") as fh:
            raw = fh.read()
    except OSError as exc:
        raise TabulaError("%s: cannot read: %s" % (path, exc.strerror or exc))
    try:
        text = raw.decode("utf-8")
    except UnicodeDecodeError:
        raise TabulaError("%s: not valid UTF-8" % path)
    return parse_text(text, path)


# --- output --------------------------------------------------------------------------------------------------

def render_text(table):
    cells = [table.columns] + table.rows
    widths = [max(len(row[i]) for row in cells) for i in range(len(table.columns))]
    lines = ["  ".join(cell.ljust(width) for cell, width in zip(row, widths)).rstrip() for row in cells]
    return "\n".join(lines) + "\n"


def render_csv(table):
    out = io.StringIO()
    writer = csv.writer(out, lineterminator="\n")
    writer.writerow(table.columns)
    writer.writerows(table.rows)
    return out.getvalue()


def render_json(table):
    return json.dumps(table.dicts(), ensure_ascii=False) + "\n"


RENDERERS = {"text": render_text, "csv": render_csv, "json": render_json}


def render(table, fmt="text"):
    return RENDERERS[fmt](table)


# --- transforms: one small function each, `name` or `name:ARG` in `apply` ----------------------------------------


def t_upper(value, arg=None):
    """The value in upper case.

    Example: upper applied to '  Héllo, World 42 "x" ' gives '  HÉLLO, WORLD 42 "X" '.
    An argument that is missing or of the wrong kind is a TabulaError, not a guess.
    """
    _no_arg("upper", arg)
    return value.upper()


def t_lower(value, arg=None):
    """The value in lower case.

    Example: lower applied to '  Héllo, World 42 "x" ' gives '  héllo, world 42 "x" '.
    An argument that is missing or of the wrong kind is a TabulaError, not a guess.
    """
    _no_arg("lower", arg)
    return value.lower()


def t_title(value, arg=None):
    """Each word capitalised.

    Example: title applied to '  Héllo, World 42 "x" ' gives '  Héllo, World 42 "X" '.
    An argument that is missing or of the wrong kind is a TabulaError, not a guess.
    """
    _no_arg("title", arg)
    return value.title()


def t_capitalize(value, arg=None):
    """The first letter upper, the rest lower.

    Example: capitalize applied to '  Héllo, World 42 "x" ' gives '  héllo, world 42 "x" '.
    An argument that is missing or of the wrong kind is a TabulaError, not a guess.
    """
    _no_arg("capitalize", arg)
    return value.capitalize()


def t_swapcase(value, arg=None):
    """Upper and lower case swapped.

    Example: swapcase applied to '  Héllo, World 42 "x" ' gives '  hÉLLO, wORLD 42 "X" '.
    An argument that is missing or of the wrong kind is a TabulaError, not a guess.
    """
    _no_arg("swapcase", arg)
    return value.swapcase()


def t_strip(value, arg=None):
    """Without leading and trailing whitespace.

    Example: strip applied to '  Héllo, World 42 "x" ' gives 'Héllo, World 42 "x"'.
    An argument that is missing or of the wrong kind is a TabulaError, not a guess.
    """
    _no_arg("strip", arg)
    return value.strip()


def t_lstrip(value, arg=None):
    """Without leading whitespace.

    Example: lstrip applied to '  Héllo, World 42 "x" ' gives 'Héllo, World 42 "x" '.
    An argument that is missing or of the wrong kind is a TabulaError, not a guess.
    """
    _no_arg("lstrip", arg)
    return value.lstrip()


def t_rstrip(value, arg=None):
    """Without trailing whitespace.

    Example: rstrip applied to '  Héllo, World 42 "x" ' gives '  Héllo, World 42 "x"'.
    An argument that is missing or of the wrong kind is a TabulaError, not a guess.
    """
    _no_arg("rstrip", arg)
    return value.rstrip()


def t_reverse(value, arg=None):
    """The characters in reverse order.

    Example: reverse applied to '  Héllo, World 42 "x" ' gives ' "x" 24 dlroW ,olléH  '.
    An argument that is missing or of the wrong kind is a TabulaError, not a guess.
    """
    _no_arg("reverse", arg)
    return value[::-1]


def t_squeeze(value, arg=None):
    """Runs of whitespace collapsed to one space.

    Example: squeeze applied to '  Héllo, World 42 "x" ' gives 'Héllo, World 42 "x"'.
    An argument that is missing or of the wrong kind is a TabulaError, not a guess.
    """
    _no_arg("squeeze", arg)
    return ' '.join(value.split())


def t_nospace(value, arg=None):
    """All whitespace removed.

    Example: nospace applied to '  Héllo, World 42 "x" ' gives 'Héllo,World42"x"'.
    An argument that is missing or of the wrong kind is a TabulaError, not a guess.
    """
    _no_arg("nospace", arg)
    return ''.join(value.split())


def t_digits(value, arg=None):
    """Only the digits.

    Example: digits applied to '  Héllo, World 42 "x" ' gives '42'.
    An argument that is missing or of the wrong kind is a TabulaError, not a guess.
    """
    _no_arg("digits", arg)
    return ''.join(c for c in value if c.isdigit())


def t_letters(value, arg=None):
    """Only the letters.

    Example: letters applied to '  Héllo, World 42 "x" ' gives 'HélloWorldx'.
    An argument that is missing or of the wrong kind is a TabulaError, not a guess.
    """
    _no_arg("letters", arg)
    return ''.join(c for c in value if c.isalpha())


def t_alnum(value, arg=None):
    """Only letters and digits.

    Example: alnum applied to '  Héllo, World 42 "x" ' gives 'HélloWorld42x'.
    An argument that is missing or of the wrong kind is a TabulaError, not a guess.
    """
    _no_arg("alnum", arg)
    return ''.join(c for c in value if c.isalnum())


def t_punct_free(value, arg=None):
    """Punctuation removed.

    Example: punct_free applied to '  Héllo, World 42 "x" ' gives '  Héllo World 42 x '.
    An argument that is missing or of the wrong kind is a TabulaError, not a guess.
    """
    _no_arg("punct_free", arg)
    return re.sub(r'[^\w\s]', '', value)


def t_slug(value, arg=None):
    """Lower case words joined by dashes.

    Example: slug applied to '  Héllo, World 42 "x" ' gives 'h-llo-world-42-x'.
    An argument that is missing or of the wrong kind is a TabulaError, not a guess.
    """
    _no_arg("slug", arg)
    return re.sub(r'[^a-z0-9]+', '-', value.lower()).strip('-')


def t_snake(value, arg=None):
    """Lower case words joined by underscores.

    Example: snake applied to '  Héllo, World 42 "x" ' gives 'h_llo_world_42_x'.
    An argument that is missing or of the wrong kind is a TabulaError, not a guess.
    """
    _no_arg("snake", arg)
    return re.sub(r'[^a-z0-9]+', '_', value.lower()).strip('_')


def t_kebab(value, arg=None):
    """Lower case words joined by dashes (same as slug).

    Example: kebab applied to '  Héllo, World 42 "x" ' gives 'h-llo-world-42-x'.
    An argument that is missing or of the wrong kind is a TabulaError, not a guess.
    """
    _no_arg("kebab", arg)
    return re.sub(r'[^a-z0-9]+', '-', value.lower()).strip('-')


def t_camel(value, arg=None):
    """Words run together, each capitalised.

    Example: camel applied to '  Héllo, World 42 "x" ' gives 'HLloWorld42X'.
    An argument that is missing or of the wrong kind is a TabulaError, not a guess.
    """
    _no_arg("camel", arg)
    return ''.join(w.capitalize() for w in re.split(r'[^A-Za-z0-9]+', value) if w)


def t_initials(value, arg=None):
    """The first letter of each word, upper case.

    Example: initials applied to '  Héllo, World 42 "x" ' gives 'HW4"'.
    An argument that is missing or of the wrong kind is a TabulaError, not a guess.
    """
    _no_arg("initials", arg)
    return ''.join(w[0].upper() for w in value.split())


def t_first_word(value, arg=None):
    """The first word.

    Example: first_word applied to '  Héllo, World 42 "x" ' gives 'Héllo,'.
    An argument that is missing or of the wrong kind is a TabulaError, not a guess.
    """
    _no_arg("first_word", arg)
    return (value.split() or [''])[0]


def t_last_word(value, arg=None):
    """The last word.

    Example: last_word applied to '  Héllo, World 42 "x" ' gives '"x"'.
    An argument that is missing or of the wrong kind is a TabulaError, not a guess.
    """
    _no_arg("last_word", arg)
    return (value.split() or [''])[-1]


def t_length(value, arg=None):
    """The number of characters.

    Example: length applied to '  Héllo, World 42 "x" ' gives '22'.
    An argument that is missing or of the wrong kind is a TabulaError, not a guess.
    """
    _no_arg("length", arg)
    return str(len(value))


def t_words(value, arg=None):
    """The number of words.

    Example: words applied to '  Héllo, World 42 "x" ' gives '4'.
    An argument that is missing or of the wrong kind is a TabulaError, not a guess.
    """
    _no_arg("words", arg)
    return str(len(value.split()))


def t_vowels(value, arg=None):
    """The number of vowels.

    Example: vowels applied to '  Héllo, World 42 "x" ' gives '2'.
    An argument that is missing or of the wrong kind is a TabulaError, not a guess.
    """
    _no_arg("vowels", arg)
    return str(sum(c in 'aeiouAEIOU' for c in value))


def t_ascii_fold(value, arg=None):
    """Accents dropped, other non-ASCII removed.

    Example: ascii_fold applied to '  Héllo, World 42 "x" ' gives '  Hello, World 42 "x" '.
    An argument that is missing or of the wrong kind is a TabulaError, not a guess.
    """
    _no_arg("ascii_fold", arg)
    return unicodedata.normalize('NFKD', value).encode('ascii', 'ignore').decode('ascii')


def t_nfc(value, arg=None):
    """Composed Unicode form.

    Example: nfc applied to '  Héllo, World 42 "x" ' gives '  Héllo, World 42 "x" '.
    An argument that is missing or of the wrong kind is a TabulaError, not a guess.
    """
    _no_arg("nfc", arg)
    return unicodedata.normalize('NFC', value)


def t_nfd(value, arg=None):
    """Decomposed Unicode form.

    Example: nfd applied to '  Héllo, World 42 "x" ' gives '  Héllo, World 42 "x" '.
    An argument that is missing or of the wrong kind is a TabulaError, not a guess.
    """
    _no_arg("nfd", arg)
    return unicodedata.normalize('NFD', value)


def t_quote(value, arg=None):
    """Wrapped in double quotes, inner quotes doubled.

    Example: quote applied to '  Héllo, World 42 "x" ' gives '"  Héllo, World 42 ""x"" "'.
    An argument that is missing or of the wrong kind is a TabulaError, not a guess.
    """
    _no_arg("quote", arg)
    return '"' + value.replace('"', '""') + '"'


def t_unquote(value, arg=None):
    """The quotes of a quoted value removed.

    Example: unquote applied to '  Héllo, World 42 "x" ' gives '  Héllo, World 42 "x" '.
    An argument that is missing or of the wrong kind is a TabulaError, not a guess.
    """
    _no_arg("unquote", arg)
    return value[1:-1].replace('""', '"') if len(value) >= 2 and value[0] == value[-1] == '"' else value


def t_blank_to_dash(value, arg=None):
    """An empty value shown as a dash.

    Example: blank_to_dash applied to '  Héllo, World 42 "x" ' gives '  Héllo, World 42 "x" '.
    An argument that is missing or of the wrong kind is a TabulaError, not a guess.
    """
    _no_arg("blank_to_dash", arg)
    return value if value.strip() else '-'


def t_dash_to_blank(value, arg=None):
    """A lone dash shown as empty.

    Example: dash_to_blank applied to '  Héllo, World 42 "x" ' gives '  Héllo, World 42 "x" '.
    An argument that is missing or of the wrong kind is a TabulaError, not a guess.
    """
    _no_arg("dash_to_blank", arg)
    return '' if value.strip() == '-' else value


def t_is_empty(value, arg=None):
    """Yes when the value is empty or blank.

    Example: is_empty applied to '  Héllo, World 42 "x" ' gives 'no'.
    An argument that is missing or of the wrong kind is a TabulaError, not a guess.
    """
    _no_arg("is_empty", arg)
    return 'yes' if not value.strip() else 'no'


def t_is_number(value, arg=None):
    """Yes when the value is a plain number.

    Example: is_number applied to '  Héllo, World 42 "x" ' gives 'no'.
    An argument that is missing or of the wrong kind is a TabulaError, not a guess.
    """
    _no_arg("is_number", arg)
    return 'yes' if to_decimal(value) is not None else 'no'


def t_is_upper(value, arg=None):
    """Yes when every letter is upper case.

    Example: is_upper applied to '  Héllo, World 42 "x" ' gives 'no'.
    An argument that is missing or of the wrong kind is a TabulaError, not a guess.
    """
    _no_arg("is_upper", arg)
    return 'yes' if value.isupper() else 'no'


def t_hash_len(value, arg=None):
    """The number of UTF-8 bytes.

    Example: hash_len applied to '  Héllo, World 42 "x" ' gives '23'.
    An argument that is missing or of the wrong kind is a TabulaError, not a guess.
    """
    _no_arg("hash_len", arg)
    return str(len(value.encode('utf-8')))


def t_prefix(value, arg=None):
    """The argument put before the value.

    Example: prefix:- applied to 'alpha-beta-gamma' gives '-alpha-beta-gamma'.
    An argument that is missing or of the wrong kind is a TabulaError, not a guess.
    """
    arg = _need_text(arg, "prefix")
    return arg + value


def t_suffix(value, arg=None):
    """The argument put after the value.

    Example: suffix:- applied to 'alpha-beta-gamma' gives 'alpha-beta-gamma-'.
    An argument that is missing or of the wrong kind is a TabulaError, not a guess.
    """
    arg = _need_text(arg, "suffix")
    return value + arg


def t_wrap(value, arg=None):
    """The argument put on both sides.

    Example: wrap:- applied to 'alpha-beta-gamma' gives '-alpha-beta-gamma-'.
    An argument that is missing or of the wrong kind is a TabulaError, not a guess.
    """
    arg = _need_text(arg, "wrap")
    return arg + value + arg


def t_remove(value, arg=None):
    """Every occurrence of the argument removed.

    Example: remove:- applied to 'alpha-beta-gamma' gives 'alphabetagamma'.
    An argument that is missing or of the wrong kind is a TabulaError, not a guess.
    """
    arg = _need_text(arg, "remove")
    return value.replace(arg, '')


def t_remove_chars(value, arg=None):
    """Every character that is in the argument removed.

    Example: remove_chars:- applied to 'alpha-beta-gamma' gives 'alphabetagamma'.
    An argument that is missing or of the wrong kind is a TabulaError, not a guess.
    """
    arg = _need_text(arg, "remove_chars")
    return ''.join(c for c in value if c not in arg)


def t_keep_chars(value, arg=None):
    """Only the characters that are in the argument.

    Example: keep_chars:- applied to 'alpha-beta-gamma' gives '--'.
    An argument that is missing or of the wrong kind is a TabulaError, not a guess.
    """
    arg = _need_text(arg, "keep_chars")
    return ''.join(c for c in value if c in arg)


def t_default(value, arg=None):
    """The argument when the value is empty.

    Example: default:- applied to 'alpha-beta-gamma' gives 'alpha-beta-gamma'.
    An argument that is missing or of the wrong kind is a TabulaError, not a guess.
    """
    arg = _need_text(arg, "default")
    return value if value.strip() else arg


def t_strip_prefix(value, arg=None):
    """The argument removed from the start when present.

    Example: strip_prefix:- applied to 'alpha-beta-gamma' gives 'alpha-beta-gamma'.
    An argument that is missing or of the wrong kind is a TabulaError, not a guess.
    """
    arg = _need_text(arg, "strip_prefix")
    return value[len(arg):] if arg and value.startswith(arg) else value


def t_strip_suffix(value, arg=None):
    """The argument removed from the end when present.

    Example: strip_suffix:- applied to 'alpha-beta-gamma' gives 'alpha-beta-gamma'.
    An argument that is missing or of the wrong kind is a TabulaError, not a guess.
    """
    arg = _need_text(arg, "strip_suffix")
    return value[:-len(arg)] if arg and value.endswith(arg) else value


def t_before(value, arg=None):
    """The text before the first argument.

    Example: before:- applied to 'alpha-beta-gamma' gives 'alpha'.
    An argument that is missing or of the wrong kind is a TabulaError, not a guess.
    """
    arg = _need_text(arg, "before")
    return value.split(arg, 1)[0] if arg and arg in value else value


def t_after(value, arg=None):
    """The text after the first argument.

    Example: after:- applied to 'alpha-beta-gamma' gives 'beta-gamma'.
    An argument that is missing or of the wrong kind is a TabulaError, not a guess.
    """
    arg = _need_text(arg, "after")
    return value.split(arg, 1)[1] if arg and arg in value else ''


def t_starts_with(value, arg=None):
    """Yes when the value starts with the argument.

    Example: starts_with:- applied to 'alpha-beta-gamma' gives 'no'.
    An argument that is missing or of the wrong kind is a TabulaError, not a guess.
    """
    arg = _need_text(arg, "starts_with")
    return 'yes' if value.startswith(arg) else 'no'


def t_ends_with(value, arg=None):
    """Yes when the value ends with the argument.

    Example: ends_with:- applied to 'alpha-beta-gamma' gives 'no'.
    An argument that is missing or of the wrong kind is a TabulaError, not a guess.
    """
    arg = _need_text(arg, "ends_with")
    return 'yes' if value.endswith(arg) else 'no'


def t_contains(value, arg=None):
    """Yes when the value contains the argument.

    Example: contains:- applied to 'alpha-beta-gamma' gives 'yes'.
    An argument that is missing or of the wrong kind is a TabulaError, not a guess.
    """
    arg = _need_text(arg, "contains")
    return 'yes' if arg in value else 'no'


def t_icontains(value, arg=None):
    """Yes when it contains the argument, case aside.

    Example: icontains:- applied to 'alpha-beta-gamma' gives 'yes'.
    An argument that is missing or of the wrong kind is a TabulaError, not a guess.
    """
    arg = _need_text(arg, "icontains")
    return 'yes' if arg.lower() in value.lower() else 'no'


def t_count_of(value, arg=None):
    """How many times the argument occurs.

    Example: count_of:- applied to 'alpha-beta-gamma' gives '2'.
    An argument that is missing or of the wrong kind is a TabulaError, not a guess.
    """
    arg = _need_text(arg, "count_of")
    return str(value.count(arg)) if arg else '0'


def t_join_chars(value, arg=None):
    """The argument put between the characters.

    Example: join_chars:- applied to 'alpha-beta-gamma' gives 'a-l-p-h-a---b-e-t-a---g-a-m-m-a'.
    An argument that is missing or of the wrong kind is a TabulaError, not a guess.
    """
    arg = _need_text(arg, "join_chars")
    return arg.join(value)


def t_split_first(value, arg=None):
    """The first piece when split on the argument.

    Example: split_first:- applied to 'alpha-beta-gamma' gives 'alpha'.
    An argument that is missing or of the wrong kind is a TabulaError, not a guess.
    """
    arg = _need_text(arg, "split_first")
    return (value.split(arg) or [''])[0] if arg else value


def t_split_last(value, arg=None):
    """The last piece when split on the argument.

    Example: split_last:- applied to 'alpha-beta-gamma' gives 'gamma'.
    An argument that is missing or of the wrong kind is a TabulaError, not a guess.
    """
    arg = _need_text(arg, "split_last")
    return (value.split(arg) or [''])[-1] if arg else value


def t_equals(value, arg=None):
    """Yes when the value is the argument.

    Example: equals:- applied to 'alpha-beta-gamma' gives 'no'.
    An argument that is missing or of the wrong kind is a TabulaError, not a guess.
    """
    arg = _need_text(arg, "equals")
    return 'yes' if value == arg else 'no'


def t_pad_left(value, arg=None):
    """Padded with spaces on the left to N characters.

    Example: pad_left:4 applied to 'alpha beta' gives 'alpha beta'.
    An argument that is missing or of the wrong kind is a TabulaError, not a guess.
    """
    count = _need_count(arg, "pad_left")
    return value.rjust(count)


def t_pad_right(value, arg=None):
    """Padded with spaces on the right to N characters.

    Example: pad_right:4 applied to 'alpha beta' gives 'alpha beta'.
    An argument that is missing or of the wrong kind is a TabulaError, not a guess.
    """
    count = _need_count(arg, "pad_right")
    return value.ljust(count)


def t_center(value, arg=None):
    """Centred in N characters.

    Example: center:4 applied to 'alpha beta' gives 'alpha beta'.
    An argument that is missing or of the wrong kind is a TabulaError, not a guess.
    """
    count = _need_count(arg, "center")
    return value.center(count)


def t_zero_fill(value, arg=None):
    """Zero-filled on the left to N characters.

    Example: zero_fill:4 applied to '42' gives '0042'.
    An argument that is missing or of the wrong kind is a TabulaError, not a guess.
    """
    count = _need_count(arg, "zero_fill")
    return value.zfill(count)


def t_truncate(value, arg=None):
    """Cut to at most N characters.

    Example: truncate:4 applied to 'alpha beta' gives 'alph'.
    An argument that is missing or of the wrong kind is a TabulaError, not a guess.
    """
    count = _need_count(arg, "truncate")
    return value[:count]


def t_take_right(value, arg=None):
    """The last N characters.

    Example: take_right:4 applied to 'alpha beta' gives 'beta'.
    An argument that is missing or of the wrong kind is a TabulaError, not a guess.
    """
    count = _need_count(arg, "take_right")
    return value[len(value) - count:] if count else ''


def t_drop_left(value, arg=None):
    """Without the first N characters.

    Example: drop_left:4 applied to 'alpha beta' gives 'a beta'.
    An argument that is missing or of the wrong kind is a TabulaError, not a guess.
    """
    count = _need_count(arg, "drop_left")
    return value[count:]


def t_drop_right(value, arg=None):
    """Without the last N characters.

    Example: drop_right:4 applied to 'alpha beta' gives 'alpha '.
    An argument that is missing or of the wrong kind is a TabulaError, not a guess.
    """
    count = _need_count(arg, "drop_right")
    return value[:len(value) - count] if count else value


def t_repeat(value, arg=None):
    """Repeated N times.

    Example: repeat:4 applied to 'alpha beta' gives 'alpha betaalpha betaalpha betaalpha beta'.
    An argument that is missing or of the wrong kind is a TabulaError, not a guess.
    """
    count = _need_count(arg, "repeat")
    return value * count


def t_word(value, arg=None):
    """The Nth word, counting from 1.

    Example: word:4 applied to 'alpha beta' gives ''.
    An argument that is missing or of the wrong kind is a TabulaError, not a guess.
    """
    count = _need_count(arg, "word")
    return (value.split() + [''] * count)[count - 1] if count else ''


def t_abs(value, arg=None):
    """The absolute value.

    Example: abs applied to '-12.345' gives '12.345'.
    An argument that is missing or of the wrong kind is a TabulaError, not a guess.
    """
    _no_arg("abs", arg)
    number = _need_number(value)
    return fmt_decimal(abs(number))


def t_neg(value, arg=None):
    """The sign flipped.

    Example: neg applied to '-12.345' gives '12.345'.
    An argument that is missing or of the wrong kind is a TabulaError, not a guess.
    """
    _no_arg("neg", arg)
    number = _need_number(value)
    return fmt_decimal(-number)


def t_floor(value, arg=None):
    """Rounded down to a whole number.

    Example: floor applied to '-12.345' gives '-13'.
    An argument that is missing or of the wrong kind is a TabulaError, not a guess.
    """
    _no_arg("floor", arg)
    number = _need_number(value)
    return fmt_decimal(number.to_integral_value(rounding=ROUND_FLOOR))


def t_ceil(value, arg=None):
    """Rounded up to a whole number.

    Example: ceil applied to '-12.345' gives '-12'.
    An argument that is missing or of the wrong kind is a TabulaError, not a guess.
    """
    _no_arg("ceil", arg)
    number = _need_number(value)
    return fmt_decimal(number.to_integral_value(rounding=ROUND_CEILING))


def t_trunc(value, arg=None):
    """The whole part.

    Example: trunc applied to '-12.345' gives '-12'.
    An argument that is missing or of the wrong kind is a TabulaError, not a guess.
    """
    _no_arg("trunc", arg)
    number = _need_number(value)
    return fmt_decimal(number.to_integral_value(rounding=ROUND_DOWN))


def t_round0(value, arg=None):
    """Rounded half up to a whole number.

    Example: round0 applied to '-12.345' gives '-12'.
    An argument that is missing or of the wrong kind is a TabulaError, not a guess.
    """
    _no_arg("round0", arg)
    number = _need_number(value)
    return fmt_decimal(number.quantize(Decimal(1), rounding=ROUND_HALF_UP))


def t_sign(value, arg=None):
    """1, 0 or -1.

    Example: sign applied to '-12.345' gives '-1'.
    An argument that is missing or of the wrong kind is a TabulaError, not a guess.
    """
    _no_arg("sign", arg)
    number = _need_number(value)
    return fmt_decimal(Decimal((number > 0) - (number < 0)))


def t_square(value, arg=None):
    """The number times itself.

    Example: square applied to '-12.345' gives '152.399025'.
    An argument that is missing or of the wrong kind is a TabulaError, not a guess.
    """
    _no_arg("square", arg)
    number = _need_number(value)
    return fmt_decimal(number * number)


def t_cube(value, arg=None):
    """The number cubed.

    Example: cube applied to '-12.345' gives '-1881.365963625'.
    An argument that is missing or of the wrong kind is a TabulaError, not a guess.
    """
    _no_arg("cube", arg)
    number = _need_number(value)
    return fmt_decimal(number * number * number)


def t_half(value, arg=None):
    """The number divided by two.

    Example: half applied to '-12.345' gives '-6.1725'.
    An argument that is missing or of the wrong kind is a TabulaError, not a guess.
    """
    _no_arg("half", arg)
    number = _need_number(value)
    return fmt_decimal(number / 2)


def t_double(value, arg=None):
    """The number times two.

    Example: double applied to '-12.345' gives '-24.690'.
    An argument that is missing or of the wrong kind is a TabulaError, not a guess.
    """
    _no_arg("double", arg)
    number = _need_number(value)
    return fmt_decimal(number * 2)


def t_inc(value, arg=None):
    """One more.

    Example: inc applied to '-12.345' gives '-11.345'.
    An argument that is missing or of the wrong kind is a TabulaError, not a guess.
    """
    _no_arg("inc", arg)
    number = _need_number(value)
    return fmt_decimal(number + 1)


def t_dec(value, arg=None):
    """One less.

    Example: dec applied to '-12.345' gives '-13.345'.
    An argument that is missing or of the wrong kind is a TabulaError, not a guess.
    """
    _no_arg("dec", arg)
    number = _need_number(value)
    return fmt_decimal(number - 1)


def t_frac(value, arg=None):
    """The fractional part, unsigned.

    Example: frac applied to '-12.345' gives '0.345'.
    An argument that is missing or of the wrong kind is a TabulaError, not a guess.
    """
    _no_arg("frac", arg)
    number = _need_number(value)
    return fmt_decimal(abs(number) - abs(number).to_integral_value(rounding=ROUND_DOWN))


def t_percent(value, arg=None):
    """The number times one hundred.

    Example: percent applied to '-12.345' gives '-1234.500'.
    An argument that is missing or of the wrong kind is a TabulaError, not a guess.
    """
    _no_arg("percent", arg)
    number = _need_number(value)
    return fmt_decimal(number * 100)


def t_permille(value, arg=None):
    """The number times one thousand.

    Example: permille applied to '-12.345' gives '-12345.000'.
    An argument that is missing or of the wrong kind is a TabulaError, not a guess.
    """
    _no_arg("permille", arg)
    number = _need_number(value)
    return fmt_decimal(number * 1000)


def t_cents(value, arg=None):
    """Pounds as pence, rounded half up.

    Example: cents applied to '-12.345' gives '-1235'.
    An argument that is missing or of the wrong kind is a TabulaError, not a guess.
    """
    _no_arg("cents", arg)
    number = _need_number(value)
    return fmt_decimal((number * 100).to_integral_value(rounding=ROUND_HALF_UP))


def t_is_even(value, arg=None):
    """Yes when a whole number is even.

    Example: is_even applied to '42' gives 'yes'.
    An argument that is missing or of the wrong kind is a TabulaError, not a guess.
    """
    _no_arg("is_even", arg)
    number = _need_number(value)
    return 'yes' if number % 2 == 0 else 'no'


def t_is_positive(value, arg=None):
    """Yes when the number is above zero.

    Example: is_positive applied to '-12.345' gives 'no'.
    An argument that is missing or of the wrong kind is a TabulaError, not a guess.
    """
    _no_arg("is_positive", arg)
    number = _need_number(value)
    return 'yes' if number > 0 else 'no'


def t_is_zero(value, arg=None):
    """Yes when the number is zero.

    Example: is_zero applied to '-12.345' gives 'no'.
    An argument that is missing or of the wrong kind is a TabulaError, not a guess.
    """
    _no_arg("is_zero", arg)
    number = _need_number(value)
    return 'yes' if number == 0 else 'no'


def t_add(value, arg=None):
    """The argument added.

    Example: add:4 applied to '-12.345' gives '-8.345'.
    An argument that is missing or of the wrong kind is a TabulaError, not a guess.
    """
    number = _need_number(value)
    amount = _need_decimal_arg(arg, "add")
    return fmt_decimal(number + amount)


def t_sub(value, arg=None):
    """The argument taken away.

    Example: sub:4 applied to '-12.345' gives '-16.345'.
    An argument that is missing or of the wrong kind is a TabulaError, not a guess.
    """
    number = _need_number(value)
    amount = _need_decimal_arg(arg, "sub")
    return fmt_decimal(number - amount)


def t_mul(value, arg=None):
    """Times the argument.

    Example: mul:4 applied to '-12.345' gives '-49.380'.
    An argument that is missing or of the wrong kind is a TabulaError, not a guess.
    """
    number = _need_number(value)
    amount = _need_decimal_arg(arg, "mul")
    return fmt_decimal(number * amount)


def t_div(value, arg=None):
    """Divided by the argument (an error when it is zero).

    Example: div:7 applied to '-12.345' gives '-1.76357142857142857142857142857142857142857142857142857142857'.
    An argument that is missing or of the wrong kind is a TabulaError, not a guess.
    """
    number = _need_number(value)
    amount = _need_decimal_arg(arg, "div")
    if amount == 0:
        raise TabulaError("div: the argument must not be zero")
    return fmt_decimal(number / amount)


def t_mod(value, arg=None):
    """The remainder after dividing by the argument.

    Example: mod:7 applied to '-12.345' gives '-5.345'.
    An argument that is missing or of the wrong kind is a TabulaError, not a guess.
    """
    number = _need_number(value)
    amount = _need_decimal_arg(arg, "mod")
    if amount == 0:
        raise TabulaError("mod: the argument must not be zero")
    return fmt_decimal(number % amount)


def t_min_of(value, arg=None):
    """The lower of the number and the argument.

    Example: min_of:4 applied to '-12.345' gives '-12.345'.
    An argument that is missing or of the wrong kind is a TabulaError, not a guess.
    """
    number = _need_number(value)
    amount = _need_decimal_arg(arg, "min_of")
    return fmt_decimal(min(number, amount))


def t_max_of(value, arg=None):
    """The higher of the number and the argument.

    Example: max_of:4 applied to '-12.345' gives '4'.
    An argument that is missing or of the wrong kind is a TabulaError, not a guess.
    """
    number = _need_number(value)
    amount = _need_decimal_arg(arg, "max_of")
    return fmt_decimal(max(number, amount))


def t_diff(value, arg=None):
    """The distance from the argument.

    Example: diff:4 applied to '-12.345' gives '16.345'.
    An argument that is missing or of the wrong kind is a TabulaError, not a guess.
    """
    number = _need_number(value)
    amount = _need_decimal_arg(arg, "diff")
    return fmt_decimal(abs(number - amount))


def t_scale(value, arg=None):
    """The argument percent of the number.

    Example: scale:4 applied to '-12.345' gives '-0.4938'.
    An argument that is missing or of the wrong kind is a TabulaError, not a guess.
    """
    number = _need_number(value)
    amount = _need_decimal_arg(arg, "scale")
    return fmt_decimal(number * amount / 100)


def t_round_to(value, arg=None):
    """Rounded half up to N decimals.

    Example: round_to:2 applied to '-12.345' gives '-12.35'.
    An argument that is missing or of the wrong kind is a TabulaError, not a guess.
    """
    number = _need_number(value)
    amount = _need_decimal_arg(arg, "round_to")
    return fmt_decimal(number.quantize(Decimal(1).scaleb(-int(amount)), rounding=ROUND_HALF_UP))


def t_floor_to(value, arg=None):
    """Rounded down to a multiple of the argument.

    Example: floor_to:7 applied to '-12.345' gives '-14'.
    An argument that is missing or of the wrong kind is a TabulaError, not a guess.
    """
    number = _need_number(value)
    amount = _need_decimal_arg(arg, "floor_to")
    if amount == 0:
        raise TabulaError("floor_to: the argument must not be zero")
    return fmt_decimal((number / amount).to_integral_value(rounding=ROUND_FLOOR) * amount)


def t_ceil_to(value, arg=None):
    """Rounded up to a multiple of the argument.

    Example: ceil_to:7 applied to '-12.345' gives '-7'.
    An argument that is missing or of the wrong kind is a TabulaError, not a guess.
    """
    number = _need_number(value)
    amount = _need_decimal_arg(arg, "ceil_to")
    if amount == 0:
        raise TabulaError("ceil_to: the argument must not be zero")
    return fmt_decimal((number / amount).to_integral_value(rounding=ROUND_CEILING) * amount)


def t_gt(value, arg=None):
    """Yes when the number is above the argument.

    Example: gt:4 applied to '-12.345' gives 'no'.
    An argument that is missing or of the wrong kind is a TabulaError, not a guess.
    """
    number = _need_number(value)
    amount = _need_decimal_arg(arg, "gt")
    return 'yes' if number > amount else 'no'


def t_lt(value, arg=None):
    """Yes when the number is below the argument.

    Example: lt:4 applied to '-12.345' gives 'yes'.
    An argument that is missing or of the wrong kind is a TabulaError, not a guess.
    """
    number = _need_number(value)
    amount = _need_decimal_arg(arg, "lt")
    return 'yes' if number < amount else 'no'


def t_ge(value, arg=None):
    """Yes when the number is at least the argument.

    Example: ge:4 applied to '-12.345' gives 'no'.
    An argument that is missing or of the wrong kind is a TabulaError, not a guess.
    """
    number = _need_number(value)
    amount = _need_decimal_arg(arg, "ge")
    return 'yes' if number >= amount else 'no'

TRANSFORMS = {
    "upper": t_upper,
    "lower": t_lower,
    "title": t_title,
    "capitalize": t_capitalize,
    "swapcase": t_swapcase,
    "strip": t_strip,
    "lstrip": t_lstrip,
    "rstrip": t_rstrip,
    "reverse": t_reverse,
    "squeeze": t_squeeze,
    "nospace": t_nospace,
    "digits": t_digits,
    "letters": t_letters,
    "alnum": t_alnum,
    "punct_free": t_punct_free,
    "slug": t_slug,
    "snake": t_snake,
    "kebab": t_kebab,
    "camel": t_camel,
    "initials": t_initials,
    "first_word": t_first_word,
    "last_word": t_last_word,
    "length": t_length,
    "words": t_words,
    "vowels": t_vowels,
    "ascii_fold": t_ascii_fold,
    "nfc": t_nfc,
    "nfd": t_nfd,
    "quote": t_quote,
    "unquote": t_unquote,
    "blank_to_dash": t_blank_to_dash,
    "dash_to_blank": t_dash_to_blank,
    "is_empty": t_is_empty,
    "is_number": t_is_number,
    "is_upper": t_is_upper,
    "hash_len": t_hash_len,
    "prefix": t_prefix,
    "suffix": t_suffix,
    "wrap": t_wrap,
    "remove": t_remove,
    "remove_chars": t_remove_chars,
    "keep_chars": t_keep_chars,
    "default": t_default,
    "strip_prefix": t_strip_prefix,
    "strip_suffix": t_strip_suffix,
    "before": t_before,
    "after": t_after,
    "starts_with": t_starts_with,
    "ends_with": t_ends_with,
    "contains": t_contains,
    "icontains": t_icontains,
    "count_of": t_count_of,
    "join_chars": t_join_chars,
    "split_first": t_split_first,
    "split_last": t_split_last,
    "equals": t_equals,
    "pad_left": t_pad_left,
    "pad_right": t_pad_right,
    "center": t_center,
    "zero_fill": t_zero_fill,
    "truncate": t_truncate,
    "take_right": t_take_right,
    "drop_left": t_drop_left,
    "drop_right": t_drop_right,
    "repeat": t_repeat,
    "word": t_word,
    "abs": t_abs,
    "neg": t_neg,
    "floor": t_floor,
    "ceil": t_ceil,
    "trunc": t_trunc,
    "round0": t_round0,
    "sign": t_sign,
    "square": t_square,
    "cube": t_cube,
    "half": t_half,
    "double": t_double,
    "inc": t_inc,
    "dec": t_dec,
    "frac": t_frac,
    "percent": t_percent,
    "permille": t_permille,
    "cents": t_cents,
    "is_even": t_is_even,
    "is_positive": t_is_positive,
    "is_zero": t_is_zero,
    "add": t_add,
    "sub": t_sub,
    "mul": t_mul,
    "div": t_div,
    "mod": t_mod,
    "min_of": t_min_of,
    "max_of": t_max_of,
    "diff": t_diff,
    "scale": t_scale,
    "round_to": t_round_to,
    "floor_to": t_floor_to,
    "ceil_to": t_ceil_to,
    "gt": t_gt,
    "lt": t_lt,
    "ge": t_ge,
}


def parse_spec(spec):
    """`name` or `name:arg` into (function, arg); the argument is everything after the first colon."""
    name, _, arg = spec.partition(":")
    if name not in TRANSFORMS:
        raise TabulaError("unknown transform %r" % name)
    return TRANSFORMS[name], (arg if ":" in spec else None)


def apply_transforms(value, specs):
    for fn, arg in specs:
        value = fn(value, arg)
    return value


# --- commands ------------------------------------------------------------------------------------------------

def _need_args(args, count, usage):
    if len(args) != count:
        raise UsageError("usage: %s %s" % (PROG, usage))


def cmd_show(args, opts):
    _need_args(args, 1, "show FILE")
    return load(args[0])


def cmd_head(args, opts):
    _need_args(args, 2, "head FILE N")
    if not args[1].isdigit():
        raise UsageError("head: N must be a whole number, got %r" % args[1])
    table = load(args[0])
    return table.with_rows(table.rows[:int(args[1])])


def cmd_cols(args, opts):
    _need_args(args, 1, "cols FILE")
    table = load(args[0])
    return Table(["position", "column"], [[str(i + 1), name] for i, name in enumerate(table.columns)], table.source)


def cmd_apply(args, opts):
    if len(args) < 3:
        raise UsageError("usage: %s apply FILE COLUMN TRANSFORM..." % PROG)
    table = load(args[0])
    at = table.index(args[1])
    specs = [parse_spec(s) for s in args[2:]]
    rows = []
    for number, row in enumerate(table.rows, 1):
        row = list(row)
        try:
            row[at] = apply_transforms(row[at], specs)
        except TabulaError as exc:
            raise TabulaError("%s: row %d: %s" % (table.source, number, exc))
        rows.append(row)
    return table.with_rows(rows)


COMMANDS = {
    "show": (cmd_show, "show FILE", "print a table"),
    "head": (cmd_head, "head FILE N", "the first N rows"),
    "cols": (cmd_cols, "cols FILE", "the column names, numbered"),
    "apply": (cmd_apply, "apply FILE COLUMN TRANSFORM...", "run transforms over one column"),
}


# --- the command line ----------------------------------------------------------------------------------------

def usage_text():
    lines = ["usage: %s [--format text|csv|json] COMMAND ARGS..." % PROG, "", "commands:"]
    width = max(len(u) for _, u, _ in COMMANDS.values())
    for _, use, what in COMMANDS.values():
        lines.append("  %s  %s" % (use.ljust(width), what))
    return "\n".join(lines) + "\n"


def parse_args(argv):
    """(command, positional arguments, options) from the command line."""
    opts, rest, i = {"format": "text"}, [], 0
    while i < len(argv):
        arg = argv[i]
        if arg in ("-h", "--help"):
            opts["help"] = True
        elif arg == "--format" or arg.startswith("--format="):
            if arg == "--format":
                i += 1
                if i >= len(argv):
                    raise UsageError("--format needs a value")
                value = argv[i]
            else:
                value = arg.split("=", 1)[1]
            if value not in FORMATS:
                raise UsageError("--format must be one of %s, got %r" % (", ".join(FORMATS), value))
            opts["format"] = value
        elif arg.startswith("-") and len(arg) > 1:
            raise UsageError("unknown option %s" % arg)
        else:
            rest.append(arg)
        i += 1
    if opts.get("help"):
        return None, rest, opts
    if not rest:
        raise UsageError("no command given")
    if rest[0] not in COMMANDS:
        raise UsageError("unknown command %r" % rest[0])
    return rest[0], rest[1:], opts


def main(argv=None):
    argv = sys.argv[1:] if argv is None else list(argv)
    try:
        name, args, opts = parse_args(argv)
        if name is None:
            sys.stdout.write(usage_text())
            return 0
        table = COMMANDS[name][0](args, opts)
        sys.stdout.write(render(table, opts["format"]))
        sys.stdout.flush()
        return 0
    except UsageError as exc:
        print("%s: %s" % (PROG, exc), file=sys.stderr)
        return 2
    except TabulaError as exc:
        print("%s: %s" % (PROG, exc), file=sys.stderr)
        return 1
    except BrokenPipeError:
        return 0
