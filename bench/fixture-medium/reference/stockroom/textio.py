"""Reading and appending text files, and splitting text into numbered lines."""
import os
import re

from .errors import DataError


def decode(data):
    """Bytes to text: UTF-8, a byte order mark dropped. UnicodeDecodeError on anything else."""
    return data.decode("utf-8-sig")


def numbered(text):
    """[(line number, stripped line)] for the lines that carry data: blank lines and `#` comments are skipped but
    still counted. A line ends at LF or CRLF only; every other character stays inside its line."""
    out = []
    for number, raw in enumerate(text.split("\n"), 1):
        line = raw[:-1] if raw.endswith("\r") else raw
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        out.append((number, line))
    return out


def split_ws(line, parts):
    """Split on runs of spaces and tabs into at most `parts` pieces (the last keeps the rest of the line)."""
    return re.split(r"[ \t]+", line, maxsplit=parts - 1)


def read_file(path, required):
    """The text of `path`. A missing file is "" unless `required`. Raises DataError when it cannot be read."""
    try:
        with open(path, "rb") as fh:
            data = fh.read()
    except FileNotFoundError:
        if required:
            raise DataError("cannot read %s: no such file" % os.path.basename(path))
        return ""
    except OSError as exc:
        raise DataError("cannot read %s: %s" % (os.path.basename(path), exc.strerror or exc))
    try:
        return decode(data)
    except UnicodeDecodeError:
        raise DataError("cannot read %s: not valid UTF-8" % os.path.basename(path))


def append_line(path, line):
    """Add `line` and a newline to the end of the file, creating it; a missing final newline is supplied first."""
    try:
        existing = b""
        if os.path.exists(path):
            with open(path, "rb") as fh:
                existing = fh.read()
        with open(path, "ab") as fh:
            if existing and not existing.endswith(b"\n"):
                fh.write(b"\n")
            fh.write((line + "\n").encode("utf-8"))
    except OSError as exc:
        raise DataError("cannot write %s: %s" % (os.path.basename(path), exc.strerror or exc))
