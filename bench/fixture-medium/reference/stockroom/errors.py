"""Errors. ParseError is a ValueError that knows its file and line; Refused is a request the tool will not carry out."""


class ParseError(ValueError):
    """A mistake in one of the data files. `.line` is the 1-based line number, `.file` the file's name (or None)."""

    def __init__(self, message, line=None, file=None):
        self.line = line
        self.file = file
        self.reason = message
        where = ""
        if file:
            where = "%s " % file
        if line is not None:
            where += "line %d: " % line
        elif where:
            where += ": "
        super().__init__(where + message)

    def in_file(self, file):
        """The same mistake, labelled with the file it was found in."""
        return ParseError(self.reason, self.line, file)


class Refused(ValueError):
    """The request is understood but cannot be carried out (an unknown SKU or order, a movement that breaks a rule)."""


class UsageError(Exception):
    """The command line is wrong (exit status 2)."""


class DataError(Exception):
    """A file cannot be read (exit status 2)."""
