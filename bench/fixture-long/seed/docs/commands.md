# Commands

`tabula [--format text|csv|json] COMMAND ARGS...` reads CSV files (UTF-8, an optional byte order mark, LF or CRLF) and prints
a table. Every command returns a `Table`; `--format` says how it is printed (text by default). A mistake in a file or in a
request exits 1 with `tabula: <message>` on standard error; a command line that is not shaped right exits 2.

## show

`tabula show FILE` prints the whole table. Blank lines in the file are ignored. A row with more or fewer fields than the
header is a mistake that names the file and the line (`t.csv: line 3: expected 2 fields, found 1`).

## head

`tabula head FILE N` prints the header and the first N rows. N is a whole number (zero is fine); anything else is a usage
error.

## cols

`tabula cols FILE` prints one row per column with two columns, `position` (from 1) and `column`.

## apply

`tabula apply FILE COLUMN TRANSFORM...` runs each TRANSFORM, left to right, over every value of one column and prints the
whole table. A transform is `name` or `name:ARG`; the list is in `docs/transforms.md`. A value a transform cannot take is
a mistake that names the file and the row (`t.csv: row 2: 'abc' is not a number`). Rows count from 1, the header not
counted.
