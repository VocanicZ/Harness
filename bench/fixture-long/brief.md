# Tabula: seven more commands

This repository already holds **tabula**, a small Python tool I use on CSV files (Python 3.9 or newer, standard
library only). Read the code first: `README.md`, `tabula/engine.py` and `tests/`. It has four commands today (`show`,
`head`, `cols`, `apply`), reads CSV files, and prints a table as text, CSV or JSON. I want seven more commands. They
all go into the same module, `tabula/engine.py`, the way the first four did: a `cmd_NAME(args, opts)` function that
returns a `Table`, one entry in `COMMANDS`. Keep what is there working: the four commands, their output, their exit
statuses, and `pip install .` giving the `tabula` command and `import tabula`. Each command also gets its own test file `tests/test_COMMAND.py`, a section in `docs/commands.md` (one section per
command, in the order of the sections below, written like the four that are there) and a line in the command list of `README.md`.

How a command behaves in general is already settled by the code and stays as it is: `--format text|csv|json` (text by
default) says how the result table is printed; a mistake in a file or in what I asked for prints
`tabula: <message>` on standard error and exits 1, with nothing on standard output; a command line that is not shaped
right (a missing argument, an unknown option, a condition with no operator) exits 2. A "row N" in a message counts the
data rows of the file from 1, the header not counted, in the order of the file (not the sorted order). Cell values are
text; a **number** is what `to_decimal` accepts (an optional sign, digits, an optional decimal point; no exponent, no
thousands marks). All arithmetic is exact (`Decimal`), never floating point. A column named in a request that the file
does not have is a mistake in the request (exit 1, the message names the column).

Two options are new and are read by one command each, but they are accepted on any command line, before or after the
command: `--kind inner|left` and `--keep first|last`, each as `--opt value` or `--opt=value`. Any other value is a
usage error (exit 2).

## sort

`tabula sort FILE KEY...` prints the rows sorted by the first KEY, ties by the second, and so on. A KEY is a column
name, optionally followed by the modifiers `:num` (compare as numbers, not as text) and `:desc` (largest first), in
either order (`price:num:desc`, `price:desc:num`). Text compares by code point (so `B` sorts before `a`). The sort is
stable: rows that tie on every key keep the order of the file, also with `:desc`. With `:num`, a cell that is not a
number is a mistake: `FILE: row N: column 'price': 'abc' is not a number`. A modifier given twice in one KEY is a usage
error. At least one KEY is needed.

## filter

`tabula filter FILE CONDITION...` prints the rows where every CONDITION holds, in the order of the file. A CONDITION
is one argument shaped `COLUMN OP VALUE` with no spaces added: `price>=10`, `city==Leeds`, `name~gnome`. The operators
are `==`, `!=`, `>=`, `<=`, `>`, `<` and `~` (the cell contains VALUE, ignoring upper and lower case). The operator is
the first one that appears in the argument (so a column name cannot contain one of them), and where two start at the
same place the longer one (`>=` and not `>`). For every operator but `~`, when both the cell and VALUE are numbers
they are compared as numbers (`10` is greater than `9`, `1.0` equals `1`); otherwise as text, by code point. An
argument with no operator, or nothing before the operator, is a usage error. At least one CONDITION is needed. A
table with no row left still prints its header.

## group

`tabula group FILE BY AGGREGATE...` prints one row per distinct value of column BY, in the order each value first
appears, with the columns BY and then one per AGGREGATE, named as written with `:` replaced by `_` (`sum_qty`). An
AGGREGATE is `count` (rows in the group) or `sum:COLUMN`, `min:COLUMN`, `max:COLUMN`, `mean:COLUMN` over the numbers of
that column. `sum`, `min` and `max` are printed as plain numbers (no `+` sign, no exponent; `10.50` stays `10.50`).
`mean` is the exact sum divided by the count, rounded half up to two decimals and always printed with two (`5.00`,
`2.25`). A cell that is not a number in a column being summed, compared or averaged is a mistake (the same
message as in `sort`). At least one AGGREGATE is needed; one that is not one of those, or the same one twice, is a
usage error.

## join

`tabula join LEFT RIGHT KEY` joins two files on the column KEY, which both must have. The result has the columns of
LEFT, then the columns of RIGHT except KEY. A RIGHT column whose name LEFT already has gets `_right` added to its name.
If that still leaves two columns of the same name the result cannot be printed: that is a mistake. Values match when
the text is exactly equal. With `--kind inner` (the default) the rows are, for each LEFT row in the order of LEFT, one
row per matching RIGHT row in the order of RIGHT; a LEFT row with no match is left out. With `--kind left` a LEFT row
with no match appears once, with empty text in the RIGHT columns. Exactly three arguments are needed.

## pivot

`tabula pivot FILE ROW COLUMN VALUE` turns the distinct values of column COLUMN into columns. The result has the column
ROW, then one column per distinct value of COLUMN in the order each first appears; one row per distinct value of ROW in
the order each first appears. A cell is the exact sum of the numbers in VALUE for the rows with that ROW and that
COLUMN value, printed as in `group`; a pair that never occurs is `0`. ROW and COLUMN must be different columns (usage
error otherwise). An empty value in COLUMN is a mistake (`FILE: row N: column 'C': empty value`), and so is a value of
COLUMN equal to the name of the ROW column, because the result would have a column name twice. A non-number in VALUE is
a mistake as in `sort`. Exactly four arguments are needed.

## dedupe

`tabula dedupe FILE KEY...` drops rows whose values in all the KEY columns equal those of another row (text equality).
With `--keep first` (the default) the first row of each such set stays; with `--keep last` the last one stays. The
rows that stay keep the relative order they have in the file. At least one KEY is needed.

## stats

`tabula stats FILE COLUMN...` prints one row per COLUMN, in the order asked, with the columns `column`, `count`, `min`,
`max`, `mean`, `median`. The statistics are over the cells of that column that are not empty (a cell of only
whitespace counts as empty); all of those must be numbers (mistake as in `sort` otherwise). `count` is how many there
are. `min` and `max` print as in `group`; `mean` and `median` are rounded half up to two decimals and always printed
with two (the median of an even count is the mean of the two middle numbers, taken exactly). With no numbers at all the
row is `COLUMN`, `0` and four empty cells. At least one COLUMN is needed.

## Order of work

File this as seven issues, one per command, so each can be built, tested and merged on its own. The seven commands do
not depend on each other, but they share the module, the option reading, the number helpers, `docs/commands.md` and the
README list, so expect to touch the same lines as the others. Finish the module's own conventions before adding to them:
do not add a second way to do something it already does.
