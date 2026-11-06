"""The error hierarchy: every failure a caller can cause is a TallybookError with a stable `code`."""


class TallybookError(Exception):
    code = "error"

    def __init__(self, message, **detail):
        super().__init__(message)
        self.message = str(message)
        self.detail = detail

    def __str__(self):
        return self.message


class ParseError(TallybookError):
    code = "parse"


class ValidationError(TallybookError):
    code = "validation"


class NotFoundError(TallybookError):
    code = "not_found"


class ConflictError(TallybookError):
    code = "conflict"


class LockedPeriodError(ConflictError):
    code = "locked"


ERRORS = {c.code: c for c in (TallybookError, ParseError, ValidationError, NotFoundError, ConflictError, LockedPeriodError)}
