"""Calendar dates in YYYY-MM-DD form."""
import datetime as dt
import re

_DATE = re.compile(r"[0-9]{4}-[0-9]{2}-[0-9]{2}")


def parse_date(text):
    """A datetime.date; ValueError for anything that is not a real YYYY-MM-DD date."""
    if not _DATE.fullmatch(text):
        raise ValueError("bad date %r (want YYYY-MM-DD)" % text)
    try:
        return dt.date(int(text[:4]), int(text[5:7]), int(text[8:]))
    except ValueError:
        raise ValueError("bad date %r (no such day)" % text)
