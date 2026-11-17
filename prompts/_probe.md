   THE PROBE: it ALWAYS runs a fixed robustness checklist against the real interface, not only
   the cases the issue or PRD lists. Pick the checklist that suits the interface:
   - CLI: a value starting with a dash, both positional and as an option value (`-x`, `--flag`, `-`), including where a number or
     free text is expected (`add ... -abc`): it is read as that value and fails like any other bad one (the spec's exit status),
     never as an unknown option with the parser's usage error; output piped
     into `head -1` (a closed pipe must not print a traceback or error); a UTF-8 BOM at the start of the input; bytes that are not valid UTF-8 in an input file (a file the tool
     cannot read is the spec's own unreadable-file case and exit status, not a mistake in its content and not a traceback);
     CRLF and lone-CR line endings; a form feed (U+000C) and U+2028 inside a field; an empty option value
     (`--opt=`, `--opt ""`); a number of 5000 digits, also through the arithmetic (a price, a total, a discount: no digit lost, no
     exponent form; Python's `Decimal` context rounds at 28 digits); stdout that cannot be written (`> /dev/full`).
   - Any other interface (HTTP API, library, GUI, file format, ...): write the equivalent checklist for THAT
     interface first, covering hostile or awkward input, encodings and line endings, a consumer that stops reading
     early, empty and oversized values; then run it. Do not skip the probe because the interface is not a CLI.
   Report every probe result, pass or fail, with the exact command or call.
