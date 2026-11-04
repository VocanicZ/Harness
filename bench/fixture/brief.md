# Pennywise

I keep my household money in a plain text file and I'm tired of spreadsheets. I'd like a small
Python tool called **pennywise** that reads that file and tells me where the money went. It should
work two ways: as a library I can `import pennywise` from my own scripts, and as a `pennywise`
command I run in the terminal. Python 3.9 or newer, standard library only (no third-party
packages). Running `pip install .` in the project folder should give me both the importable
library and the `pennywise` command.

## The ledger file

One entry per line:

```
# household, March
2024-03-01 salary 2500.00 March pay
2024-03-02 groceries -42.50 weekly shop

2024-03-05 Rent -900
```

Each line has a date (`YYYY-MM-DD`), a category (one word), an amount, and an optional note. The
fields are separated by any amount of spaces or tabs. The note is the rest of the line exactly as I
wrote it (it can contain spaces), apart from trimming whitespace at both ends.

- A positive amount is money in, a negative one is money out. The sign is optional for money in, so
  `2500`, `+2500` and `2500.00` are all the same. Amounts have at most two decimal places: `12`,
  `12.5`, `-0.99` are fine; `12.505`, `1,000.00` and `abc` are not.
- Categories do not care about case: `Rent` and `rent` are the same category, and it is shown in
  lower case.
- Blank lines are ignored, and so are lines starting with `#`.
- Anything else is a mistake in my file, and the tool must tell me which line (counting from 1,
  blank and comment lines included). A date that does not exist, like `2024-02-30`, is a mistake
  too.

## Using it as a library

```python
import pennywise

entries = pennywise.parse(open("house.txt").read())
print(pennywise.balance(entries))
```

- `parse(text)` returns a list of entries, in the order they appear. Each entry has `.date` (a
  `datetime.date`), `.category` (a lower-case `str`), `.amount` (a `decimal.Decimal`) and `.note`
  (a `str`, empty when there is none).
- A bad line makes `parse` raise `pennywise.ParseError`. It is a `ValueError`, its `.line`
  attribute is the line number, and its message mentions `line N`.
- `balance(entries)` is the total of all amounts, a `Decimal` (zero for no entries).
- `by_category(entries)` is a `dict` of category to its total; `by_month(entries)` is the same
  keyed by month, like `"2024-03"`.
- `filter_entries(entries, category=None, since=None, until=None)` returns the matching entries in
  the order given. `category` is matched without regard to case; `since` and `until` are
  `datetime.date` values and both ends are included. Anything left as `None` is not filtered on.

## Using it from the terminal

```
$ pennywise balance house.txt
1457.50

$ pennywise summary house.txt
groceries  -42.50
rent  -900.00
salary  2500.00

$ pennywise list house.txt --category groceries
2024-03-02 groceries -42.50 weekly shop
```

- `pennywise balance FILE` prints the total with two decimals, on one line.
- `pennywise summary FILE [--by category|month]` prints one line per group, sorted by name: the
  name, some spaces, then the total with two decimals. The default is `--by category`.
- `pennywise list FILE [--category C] [--since DATE] [--until DATE]` prints the matching entries,
  oldest first (entries on the same day keep the order of the file), one per line as
  `DATE CATEGORY AMOUNT NOTE`. The amount always has two decimals, and the note (and the space
  before it) is left out when there is none.
- `pennywise add FILE DATE CATEGORY AMOUNT [NOTE]` adds an entry to the end of the file (creating
  the file if it does not exist) and prints the line it added, written the same way `list` writes
  it. I pass the note as a single quoted argument. An invalid entry is refused and the file is left
  exactly as it was.
- `pennywise export FILE [--format csv]` prints the entries, in the same order as `list`, as CSV
  with the header `date,category,amount,note`. CSV is the only format for now and the default.
- `balance`, `summary` and `list` take `--json` to print JSON instead. Amounts are strings with two
  decimals: `{"balance": "1457.50"}`, `{"groceries": "-42.50", "rent": "-900.00"}`, and for `list`
  an array of `{"date": "2024-03-02", "category": "groceries", "amount": "-42.50", "note":
  "weekly shop"}`.
- Wherever a command reads a file (not `add`), `-` means read the ledger from standard input.
- Exit status: `0` when it worked; `1` when the ledger (or the entry given to `add`) has a mistake,
  with a message on standard error that names the line and nothing on standard output; `2` when
  the file cannot be read or the command line is wrong (no command, an unknown command, a bad
  option value, a date I mistyped).
