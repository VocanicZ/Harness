"""The two kinds of failure a command can end in."""


class TabulaError(Exception):
    """A mistake in a file or in what was asked for; the command line ends with exit status 1."""


class UsageError(Exception):
    """A command line that is not shaped right; the command line ends with exit status 2."""
