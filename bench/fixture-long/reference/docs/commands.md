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

## sort

`tabula sort FILE KEY...` sorts the rows by the first KEY, ties by the next. A KEY is a column with the modifiers `:num` and
`:desc`. Text compares by code point, the sort is stable, and a cell that is not a number under `:num` is a mistake.

## filter

`tabula filter FILE CONDITION...` keeps the rows where every `COLUMN OP VALUE` holds (`==`, `!=`, `>=`, `<=`, `>`, `<`, `~`).
Numbers compare as numbers when both sides are numbers, otherwise as text.

## group

`tabula group FILE BY AGGREGATE...` prints one row per value of BY with `count`, `sum:COL`, `min:COL`, `max:COL` or `mean:COL`.
The mean is rounded half up to two decimals.

## join

`tabula join LEFT RIGHT KEY [--kind inner|left]` joins two files on KEY. A right column whose name the left file has gets
`_right` added.

## pivot

`tabula pivot FILE ROW COLUMN VALUE` turns the values of COLUMN into columns and sums VALUE; a pair that never occurs is `0`.

## dedupe

`tabula dedupe FILE KEY... [--keep first|last]` drops rows whose KEY values repeat; the rest keep the order of the file.

## stats

`tabula stats FILE COLUMN...` prints `count`, `min`, `max`, `mean` and `median` of the numbers in each column; empty cells
are left out.

## select

`tabula select FILE ARG...` prints some of the columns: the ones named, in the order named, or, when every ARG starts with
`!`, every column except the ones named (without the `!`), in the order of the file. Mixing both kinds, or naming a column
twice, is a usage error. An ARG that starts with `!` is always a drop, so `!!x` drops a column named `!x`. A column the file
does not have is a mistake, and so is dropping every column (`t.csv: nothing left to print`).

## rename

`tabula rename FILE OLD=NEW...` renames columns and prints the whole table. Each argument is split at its first `=`; one
with no `=` or with nothing on a side of it is a usage error, and so is naming the same OLD twice. All renames apply at once
(`a=b b=a` swaps two columns). An OLD the file does not have is a mistake, and so is a result with a column name twice.

## rank

`tabula rank FILE KEY` prints the whole table in the order of the file with one more column, `rank`, at the end. KEY is read
as a KEY of `sort` is (`COLUMN` with `:num` and `:desc`). Rank 1 goes to the row that would come first in a `sort` by KEY;
rows that tie on KEY share the rank of the first of them and the next rank skips as many (1, 2, 2, 4). A file that already
has a column `rank` is a mistake.

## concat

`tabula concat FILE FILE...` prints the rows of the first file, then those of the second, and so on, with the columns of
the first file in its order. Every other file must have exactly the same set of column names, in any order; its cells go
to the column of the same name. A file that does not is a mistake that names it. At least two files are needed.

## melt

`tabula melt FILE ID COLUMN...` turns columns into rows. The result has the columns ID, `variable` and `value`: for each row
of the file, one row per COLUMN, in the order named, holding the column's name and its cell. A cell that is empty or only
whitespace gives no row. ID may not be one of the COLUMNs and a COLUMN may not be named twice (usage errors); an ID column
called `variable` or `value` is a mistake.

## window

`tabula window FILE COLUMN [--window N]` prints the whole table with one more column, `COLUMN_avg` (`qty_avg`): the mean of
the numbers in COLUMN over the row and the rows before it, at most N rows in all (`--window N` or `--window=N`, a whole
number of at least 1, 3 when not given; anything else is a usage error). Early rows look at the rows there are. Empty cells
are not counted, and a row whose window holds no number gets an empty cell. The mean is rounded half up to two decimals and
printed with two. A cell that is not a number is a mistake, and so is a file that already has the column `COLUMN_avg`.

## bucket

`tabula bucket FILE COLUMN WIDTH` prints the whole table with one more column, `bucket`: the largest multiple of WIDTH that
is not above the number in COLUMN (`-0.5` with width `1` is in bucket `-1`). WIDTH is a number above zero, anything else is a
usage error. The bucket is printed as a plain number with as many decimals as WIDTH was written with (width `0.50`: `1.25`
is in bucket `1.00`; width `5`: `3` is in bucket `0`, never `-0`). An empty cell gives an empty bucket; a cell that is not a
number is a mistake, and so is a file that already has a column `bucket`.
