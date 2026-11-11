# Stockroom

I run a small online shop out of a spare room and I keep everything in plain text files: what I sell,
what came in and went out of the shelves, and what customers ordered. I'd like a Python tool called
**stockroom** that reads those files and answers three questions: what is on the shelves and what
needs buying, what an order costs, and what I can ship today. It should work two ways: as a library I
can `import stockroom` from my own scripts, and as a `stockroom` command in the terminal. Python 3.9 or
newer, standard library only (no third-party packages). Running `pip install .` in the project folder
should give me both the importable library and the `stockroom` command.

There are two halves to it: the **shelves** (the catalogue, the stock movements, what is low) and the
**orders** (prices, discounts, tax, shipping what is in stock, invoices, a report). The orders half
depends on the shelves, so build them in that order.

## The three files

They live in one folder (the command's current folder, or the one named by `--dir`). Text is UTF-8; a
byte order mark at the start of a file is ignored; a line ends at LF or at CRLF and nowhere else.
In every file, blank lines are ignored, and so are lines starting with `#` (after any leading
whitespace). Anything else that does not follow the rules below is a mistake in my file, and the tool
must tell me which file and which line (counting from 1, blank and comment lines included).

### `catalog.txt` — what I sell

One product per line, fields separated by `|`, whitespace around each field trimmed:

```
# SKU   | name            | price | reorder | tax
AB-100 | Garden gnome     | 12.50 | 5       | standard
cd-205 | Seed packet, mix | 1.99  | 40      | reduced
EF-310 | Gift voucher     | 25.00 | 0
```

- **SKU**: two to four letters, a dash, three digits (`AB-100`). Letters in any case are accepted; the
  SKU is always shown in upper case. Two lines with the same SKU are a mistake.
- **name**: not empty. It may contain anything except `|`.
- **price**: in pounds, at least `0.01`, at most two decimal places (`12`, `12.5`, `1.99` are fine;
  `12.505`, `1,000.00`, `-3` and `abc` are not).
- **reorder**: the stock level at or under which I need to buy more: a whole number, zero or more.
- **tax** (optional, `standard` when the field is left out, so a line has four or five fields): one of
  `standard` (20 %), `reduced` (5 %) or `zero` (0 %), in any case.

### `movements.txt` — what came in and went out

One movement per line: `DATE SKU QUANTITY [NOTE]`, separated by any amount of spaces or tabs. The note
is the rest of the line exactly as written, apart from trimming whitespace at both ends.

```
2024-03-01 AB-100 +20 first delivery
2024-03-04 ab-100 -3 order SO-1001
2024-03-05 CD-205 40
```

- **DATE** is `YYYY-MM-DD` and a date that exists (`2024-02-30` is a mistake).
- **SKU** must be in the catalogue (any case).
- **QUANTITY** is a whole number that is not zero, with an optional sign: positive means stock in,
  negative means stock out.
- The movements count in date order; movements on the same day keep the order of the file. The
  stock of a product may never be below zero at any point in that order. The line that takes it below
  zero is the mistake.

### `orders.txt` — what customers ordered

One order per line: `ORDER DATE CUSTOMER LINES`, separated by any amount of spaces or tabs:

```
SO-1001 2024-03-03 acme AB-100*12,CD-205*3
SO-1002 2024-03-09 Bea ab-100*2
```

- **ORDER** is `SO-` (any case) and one or more digits, shown in upper case; `SO-7` and `SO-007` are two
  different orders. It is unique: a second line with the same order number is a mistake.
- **DATE** as above. **CUSTOMER** is one word, shown as typed.
- **LINES** is one or more `SKU*QUANTITY` pairs separated by commas, no spaces. The SKU must be in the
  catalogue and appear once per order; the quantity is a whole number of one or more (no sign).

A missing `catalog.txt` is an error for every command. A missing `movements.txt` or `orders.txt` is
just empty. A command reads only the files it needs, and a mistake in a file it does not read is not its
business: the shelves commands (`stock`, `low`, `history`, `receive`, `ship`) read the catalogue and the
movements; `quote` reads the catalogue and the orders; `fulfil`, `invoice` and `report` read all three.

## Using it as a library

```python
import stockroom

catalog = stockroom.parse_catalog(open("catalog.txt").read())
moves = stockroom.parse_movements(open("movements.txt").read(), catalog)
print(stockroom.stock_levels(catalog, moves))
```

- `parse_catalog(text)` returns a `dict` of SKU to a product. A product has `.sku`, `.name`, `.price`
  (a `decimal.Decimal`), `.reorder` (an `int`) and `.tax` (`"standard"`, `"reduced"` or `"zero"`).
- `parse_movements(text, catalog)` returns a list of movements in the order they appear in the text,
  each with `.date` (a `datetime.date`), `.sku`, `.quantity` (an `int`) and `.note` (a `str`, empty when
  there is none).
- `parse_orders(text, catalog)` returns a list of orders in the order they appear, each with `.id`,
  `.date`, `.customer` and `.lines`: a list of `(sku, quantity)` pairs in the order written.
- A bad line makes any of these raise `stockroom.ParseError`. It is a `ValueError`, its `.line`
  attribute is the line number, and its message mentions `line N`.
- `stock_levels(catalog, movements)` is a `dict` of SKU to the quantity on the shelf, for every product
  in the catalogue (zero when it never moved).
- `price_order(order, catalog)` prices a whole order as described under *Prices* and returns a quote with
  `.lines` (each with `.sku`, `.quantity`, `.unit`, `.gross`, `.discount`, `.net`), `.subtotal`,
  `.order_discount`, `.tax` and `.total`, all `Decimal`s with two decimal places. A discount is zero or
  negative.

## Prices

All of this is exact to the penny and every rounding step rounds halves **up** (`0.005` becomes `0.01`).

1. A line's **gross** is its quantity times the unit price.
2. A line gets a **volume discount** of 5 % of its gross when the quantity is 10 or more, and 10 % when it
   is 50 or more (not both), rounded to the penny. The line's **net** is gross minus that.
3. The **subtotal** is the sum of the nets. When it is £500.00 or more the whole order gets an **order
   discount** of 3 % of the subtotal, rounded to the penny.
4. The order discount is shared out over the lines in proportion to their nets, to the penny: each line's
   share is rounded down, and the pennies left over go one each to the lines with the biggest part of a
   penny lost (the earlier line first on a tie). A line's **taxable amount** is its net less its share.
5. **Tax** is worked out per line on its taxable amount at its product's rate, rounded to the penny, and
   added up. Prices do not include tax.
6. The **total** is the subtotal, plus the order discount (a negative number), plus the tax.

## Using it from the terminal

Every command takes `--dir DIR` anywhere on the line (default: the current folder). Options are spelled out in full.

```
$ stockroom stock
AB-100 17 ok Garden gnome
CD-205 40 low Seed packet, mix
EF-310 0 out Gift voucher

$ stockroom quote SO-1001
SO-1001 2024-03-03 acme
AB-100 12 12.50 150.00 -7.50 142.50
CD-205 3 1.99 5.97 0.00 5.97
subtotal 148.47
order discount 0.00
tax 28.80
total 177.27
```

**The shelves**

- `stockroom stock [--json]` prints one line per product, by SKU: `SKU ONHAND STATUS NAME` separated by single
  spaces. The status is `out` when the stock is zero, `low` when it is above zero and at or under the product's
  reorder level, `ok` otherwise.
- `stockroom low [--json]` prints one line for each product that is `low` or `out`, by SKU:
  `SKU ONHAND REORDER BUY` where BUY is how many to buy to get back to twice the reorder level, and at least 1
  (`max(1, 2 × reorder − onhand)`).
- `stockroom history SKU [--json]` prints that product's movements, in the order they count, one per
  line as `DATE DELTA BALANCE NOTE`: the quantity with its sign (`+20`, `-3`), the stock after the
  movement, and the note (and its space) left out when there is none. A SKU that is not in the catalogue is
  refused.
- `stockroom receive DATE SKU QUANTITY [NOTE]` and `stockroom ship DATE SKU QUANTITY [NOTE]` add a stock-in or
  stock-out movement to the end of `movements.txt` (creating it if needed) and print the line they added,
  written the way `history` writes a movement without the balance: `DATE SKU ±QUANTITY NOTE`. The quantity is a
  whole number of one or more, no sign. I pass the note as a single quoted argument; a note may not contain a
  line break. A movement that would break a rule above (an unknown SKU, a quantity that is not a positive
  whole number, stock that would go below zero at any point in date order) is refused and the file is left
  exactly as it was. If the file does not end in a newline, one is added before the new line.

**The orders**

- `stockroom quote ORDER [--json]` prints the order priced as in the example: a header line
  `ORDER DATE CUSTOMER`, one line per order line `SKU QUANTITY UNIT GROSS DISCOUNT NET`, then
  `subtotal`, `order discount`, `tax` and `total` lines. Amounts have two decimals, discounts carry a minus
  sign (zero has none), values are separated by single spaces. An order that is not in `orders.txt` is
  refused.
- `stockroom fulfil ORDER DATE` ships what the shelves can cover. For each order line, what is still owed is its
  quantity less what earlier shipments of this order sent (the total of the negative quantities for that SKU in movements
  whose note is exactly `order SO-1001`, the order number in upper case; capped at the quantity ordered). It ships as many of those as the shelves allow on
  DATE: no more than the stock after all movements dated on or before DATE, and no more than the lowest stock at
  any later point (so that the shipment never makes a later movement take the stock below zero). It adds one
  movement `DATE SKU -N order SO-1001` per line with something to ship, at the end of the file. It prints one
  line per order line, `SKU shipped N backordered M` (M is what is still owed afterwards), then
  `status open`, `status partial` or `status complete`: `complete` when nothing is owed on any line, `open` when
  nothing has been shipped on any line yet, `partial` otherwise. DATE may not be before the order's date
  (refused).
- `stockroom invoice ORDER [--json]` is `quote` for what has actually shipped: the same rules and the same
  layout, with the quantities shipped so far (lines with nothing shipped are left out) and `invoice ` in front
  of the header line (`invoice SO-1001 2024-03-03 acme`). An order with nothing shipped is refused.
- `stockroom report [--format text|csv|json]` has one row per order, by order date and then by order
  number: `ORDER DATE CUSTOMER STATUS SHIPPED/ORDERED QUOTED INVOICED`: the status as above, the units shipped and
  ordered, the quote's total, and the invoice's total (`0.00` when nothing has shipped). `text` is the
  default and separates by single spaces. `csv` has the header
  `order,date,customer,status,ordered,shipped,quoted,invoiced`; `json` is an array of objects with those keys,
  the units as numbers and the amounts as strings with two decimals.
- With `--json`, `stock` prints an array of `{"sku", "name", "onhand", "status"}`, `low` an array of
  `{"sku", "onhand", "reorder", "buy"}`, `history` an array of `{"date", "delta", "balance", "note"}`, and
  `quote` / `invoice` an object with `order`, `date`, `customer`, `lines` (objects with `sku`, `quantity`,
  `unit`, `gross`, `discount`, `net`), `subtotal`, `order_discount`, `tax` and `total`. Amounts are strings
  with two decimals, counts are numbers, except a history `delta`, which is the signed string (`"+20"`, `"-3"`).
- `receive`, `ship` and `fulfil` take no options except `--dir`: every other argument is taken as typed, so a
  dash-led quantity is a bad quantity (refused) and a dash-led note is a note.
- The command line is checked first (exit `2` for anything wrong with it), then the files are read, then the
  request is carried out.
- Exit status: `0` when it worked; `1` when a data file has a mistake or what I asked for is refused (an unknown
  SKU or order, a movement that would break a rule, nothing shipped yet), with a message on standard error that
  names the file and the line where there is one, and nothing on standard output; `2` when a file cannot be read
  (a missing `catalog.txt`, a folder that does not exist, bytes that are not UTF-8) or the command line is wrong
  (no command, an unknown command, the wrong number of arguments, an unknown option, a bad option value, a date I
  mistyped).
- If whatever is reading the output goes away (`stockroom stock | head -1`) it just stops quietly, with status
  `0`.
