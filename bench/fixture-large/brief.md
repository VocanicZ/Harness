# Tallybook

I keep the books for my household and a small side business, and I have outgrown spreadsheets. I want a proper
double-entry bookkeeping tool that I can script, run from the terminal and put behind a small web service for the
family. I'm calling it **tallybook**. Build it carefully rather than quickly; the pieces depend on each other, so read
the whole document first.

It comes in three layers that share one engine:

- a **library**, `import tallybook`, which does all the real work: money, currencies, dates, accounts, a ledger, a
  text journal, queries, rules, CSV import, budgets, recurring entries, reports and export;
- a **database** (SQLite, standard library) with numbered schema versions and migrations, so a book I start today
  still opens after I update the tool;
- a **command line**, `tallybook`, and a small **HTTP API**, `tallybook serve`, both thin layers on the library.

Python 3.9 or newer, standard library only (no third-party packages, no network at build or run time). Running
`pip install .` in the project folder must give me both the importable `tallybook` package and the `tallybook`
command (`python -m tallybook` should do the same thing). How you lay out the files is up to you, but the module,
class and function names I give below are what my own scripts import, so use exactly those. Everything is
deterministic: nothing reads the clock except where I say "today", and wherever "today" matters I can pass the date in.

## How to read this document

A name in `monospace` is the exact name. A format (a journal line, a table, a JSON object) is exact. Where I say a
thing is an error, I name the exception class or exit status I expect. Anything I do not say is up to you; my scripts
only rely on what is written here.

### Conventions that hold everywhere

- **Dates** are written `YYYY-MM-DD`, always four-digit years, nothing else is accepted.
- **Money** is never a float. An amount is a whole number of the currency's smallest unit (cents for dollars, yen for
  yen) together with a three-letter currency code.
- **Errors.** Everything that goes wrong because of what I asked for is an exception deriving from
  `tallybook.errors.TallybookError`, with a `.message` (human text) and a `.code` (a short stable word). The codes are
  `parse` (`ParseError`), `validation` (`ValidationError`), `not_found` (`NotFoundError`) and `conflict`
  (`ConflictError`); every module's own error class below derives from one of those. `str(error)` is the message.
  Wherever I say a message "contains" some text, that text appears in it exactly as given.
- **Integers.** `True` and `False` are never accepted where an integer is required.
- **Text output** is UTF-8 with `\n` line endings, no trailing spaces on any line, ending with one newline; no output at
  all is the empty string.
- **JSON output** (the `--json` flag of the command line, the HTTP API) is
  `json.dumps(value, indent=2, sort_keys=True, ensure_ascii=False)` followed by one newline. An amount of money in JSON
  is an object `{"amount": "12.50", "currency": "USD"}`, a date is a `"YYYY-MM-DD"` string.
- **Rounding.** When something has to be rounded to a currency's smallest unit, `tallybook.money.round_div(n, d)` does
  it: the quotient of two integers, `d > 0`, rounded half away from zero. Every place that rounds uses it.
- **Account names** look like `Assets:Bank:Checking`: segments joined by colons, each segment starting with a capital
  letter. The first segment decides the kind of account (see Accounts).
- **Account patterns** ("all my food accounts") appear in the chart, in queries and in budgets. Each of those sections
  has its own pattern rules and they are *not* the same; use the rules of the section you are in.

## Money

Everything is built on this, so I describe it carefully. Tools that keep money as floating point end up a cent out
after a long year, so here money is always a whole number of **minor units** (cents, pence, yen, fils) with a currency
code, and no floating point anywhere near an amount. I want to write

```python
from tallybook.money import Money, MoneyError, parse_amount, format_minor, round_div
```

and get the names below. (Currencies are in the next section; USD has 2 decimals, JPY 0, KWD 3, so `Money(1250, "USD")`
is 12.50 dollars, `Money(1250, "JPY")` 1,250 yen and `Money(1250, "KWD")` 1.250 dinars.)

### The Money value

`Money(minor, currency)` takes an `int` number of minor units and a currency code such as `"USD"`. It is immutable
(assigning to `.minor` fails) and hashable, so amounts work as dictionary keys and in sets. The attributes are
`.minor` and `.currency`. Two amounts are equal when both parts are equal; comparing a `Money` with anything that is
not a `Money` is `False`, never an error.

- `minor` must be a real integer. A float (`12.5`), a string, `None` or a `bool` raises `MoneyError`. Any size of
  integer is fine: tallybook must not overflow or lose digits however enormous the amount (`Money(10**30, "USD")`
  works and behaves exactly).
- `currency` must be a code from the currency table, upper case. Anything else, including `"usd"`, raises
  `CurrencyError` (in `tallybook.currency`, whose message contains the code). `MoneyError` and `CurrencyError` are both
  kinds of `ValidationError`. Every unknown-currency refusal in this section is that `CurrencyError`.
- `Money.zero("USD")` is the zero amount of a currency; `m.exponent` is the number of decimals of its currency.

`repr(m)` is `Money(1250, 'USD')` (currency in single quotes, exactly like that). `str(m)` is the amount, one space
and the code: `12.50 USD`, `-0.05 USD`, `1250 JPY`, `1.250 KWD`. `m.amount_str()` is the amount part, `12.50`.

### Writing amounts

Amounts are written with exactly as many decimals as the currency has, with a `.` and no thousands separator:

| minor units | currency | `amount_str()` |
|---|---|---|
| 1250 | USD | `12.50` |
| -5 | USD | `-0.05` |
| 0 | USD | `0.00` |
| 1250 | JPY | `1250` |
| -7 | KWD | `-0.007` |
| 123456789012345678901234567890 | USD | `1234567890123456789012345678.90` |

A minus sign is written for any amount below zero and for nothing else: zero is `0.00`, never `-0.00`. A positive
amount never gets a `+`. A JPY amount has no decimal point.

`format_minor(minor, currency)` does the same for a bare integer, so `format_minor(-5, "USD")` is `"-0.05"`. It raises
`CurrencyError` for an unknown currency and `MoneyError` when `minor` is not an integer.

### Reading amounts

I type amounts by hand, so reading is strict and predictable. `parse_amount(text, currency)` returns the number of
minor units as an `int`; `Money.of(text, currency)` returns a `Money`; `Money.parse("12.50 USD")` reads an amount and
its currency together.

- Digits `0-9` only, optionally preceded by one `+` or `-`, optionally followed by a `.` and more digits. So `12`,
  `12.5`, `12.50`, `+12.50`, `-12.50`, `007.50` and `0` are fine.
- At most as many decimals as the currency has. For USD, `12.505` is refused and `12.500` is refused too (three
  decimals is three decimals, even if the last is a zero). For JPY there must be no decimal point at all: `5` is
  fine, `5.0` is refused. For KWD, up to three decimals.
- `-0`, `-0.00` and `+0.00` are just zero.
- Refused: the empty string; a lone sign; `1.` and `.5` (a decimal point needs digits on both sides); separators
  (`1,000.00`, `1 000`, `1_000`); `--5`; `1e3`; `NaN`; `inf`; letters or symbols (`$5`); whitespace anywhere, leading and
  trailing included; digits that are not plain `0-9` (Arabic-Indic, full-width).
- Anything that is not text (a number, `None`, a `bool`) is refused too.

Every refusal raises `MoneyError` whose message contains the offending text as given (for `"12.505"` it contains
`12.505`); an unknown currency raises `CurrencyError`.

For `Money.parse(text)` the text is the amount, **exactly one space**, and the currency code: `12.50 USD`, `-3 JPY`,
`0.007 KWD`. No space, two spaces, a leading or trailing space, a tab instead of the space, or a third word raises
`MoneyError` (message contains the text). A bad amount raises `MoneyError` as above (message contains the amount),
an unknown or lower-case code raises `CurrencyError`, and text that is not a string raises `MoneyError`.
`Money.parse(str(m)) == m` for every amount.

### Arithmetic

| expression | result |
|---|---|
| `a + b`, `a - b` | `Money` in the same currency |
| `-a`, `abs(a)` | `Money` |
| `a * 3`, `3 * a` | `Money`, the minor units multiplied by the integer (negative and zero are fine) |
| `a.scale(num, den=1)` | `Money` multiplied by the ratio `num/den`, rounded to a whole minor unit |
| `a < b`, `a <= b`, `a > b`, `a >= b` | `bool`, same currency only |
| `a.is_zero()` | `True` when the amount is zero |
| `a.sign()` | `-1`, `0` or `1` |

Adding, subtracting or ordering amounts in **different currencies** raises `MoneyError` whose message names both
currency codes (`cannot add USD and EUR: different currencies`). `==` between different currencies is `False`, not an
error. Multiplying by anything that is not an integer (a float, a `Money`) is a `TypeError`, and so is adding a bare
number to a `Money` or ordering a `Money` against one (`Money(1, "USD") < 5`): money and plain numbers must never mix
silently.

`scale` is how I take a percentage or fraction of an amount: `Money(1000, "USD").scale(15, 100)` is fifteen percent of
ten dollars, 1.50 USD. Both arguments must be integers (otherwise `MoneyError`); `den` may not be zero (`MoneyError`);
a negative `den` just flips the sign. The exact product is divided by `den` and rounded as below.

### Rounding

Whenever tallybook rounds a result to a whole minor unit it uses `round_div(n, d)`, which returns the integer nearest
to the exact quotient `n / d`, for any integer `n` and integer `d > 0` (`d <= 0` or a non-integer argument raises
`MoneyError`). A quotient exactly halfway between two integers rounds **away from zero**: a half goes up in size,
whichever the sign.

| `n / d` | result |
|---|---|
| 0.5 | 1 |
| 1.5 | 2 |
| 2.5 | 3 |
| -0.5 | -1 |
| -2.5 | -3 |
| 2.4999 | 2 |
| exact (6/3) | 2 |

So `Money(5, "USD").scale(1, 2)` (2.5 cents) is 3 cents and `Money(-5, "USD").scale(1, 2)` is -3 cents. Currency
conversion and every percentage in the program use this function, so they all agree about halves.

### Splitting an amount fairly

When I split a bill the parts must add up to the total to the last cent, and nobody is cheated by more than one minor
unit. `m.allocate(weights)` takes a list of non-negative integer weights and returns a list of `Money`, one
per weight in the same order, in the same currency, always summing exactly to `m`.

The method is **largest remainder**: each part first gets its whole share (`amount * weight // total_weight`); the
minor units left over are then handed out one each to the parts whose exact share had the biggest fractional
remainder. Equal remainders: the earlier part in the list gets the extra unit first.

- `Money(100, "USD").allocate([1, 1, 1])` is `[34, 33, 33]` cents; `Money(1, "USD").allocate([1, 1])` is `[1, 0]`.
- `Money(10, "USD").allocate([3, 1])` is `[8, 2]` (exact shares 7.5 and 2.5 tie on remainder; the earlier wins).
- `Money(7, "USD").allocate([5, 3, 1])` is `[4, 2, 1]`.
- A weight of `0` always gets exactly zero: `Money(5, "USD").allocate([0, 1, 1])` is `[0, 3, 2]`, and `[1, 0, 0]` gives the
  whole amount to the first part.
- A negative amount is split as if positive and then negated: `Money(-100, "USD").allocate([1, 1, 1])` is
  `[-34, -33, -33]`.
- Zero splits into all zeros. A single weight returns the whole amount. Weights are scale-free: `[1, 1]` and
  `[50, 50]` give the same answer.

The weights must be a list of integers, each zero or more, with a sum above zero. An empty list, all zeros, a negative
weight or a non-integer weight (`1.5`) raises `MoneyError`. Allocation does no `round_div` rounding at all.

## Currencies and exchange rates

One of us is paid in euros and we travel, so the books must hold several currencies, never mix them by accident, and
convert when I ask. The code goes in `tallybook.currency`:

```python
from tallybook.currency import Currency, CURRENCIES, currency, RateTable, CurrencyError
```

### The currency table

`CURRENCIES` is a `dict` from the three-letter upper-case code to a `Currency`. A `Currency` is a frozen record
(immutable, hashable, equal when all fields are equal), built as `Currency(code, exponent, name, symbol)`, all
readable as attributes; `exponent` is how many decimals the minor unit has. I want these currencies with exactly these
numbers and spellings (the table may hold more, but nothing else is guaranteed):

| code | exponent | name | symbol |
|---|---|---|---|
| USD | 2 | US Dollar | `$` |
| EUR | 2 | Euro | `€` |
| GBP | 2 | British Pound | `£` |
| JPY | 0 | Japanese Yen | `¥` |
| CHF | 2 | Swiss Franc | `CHF` |
| CAD | 2 | Canadian Dollar | `CA$` |
| AUD | 2 | Australian Dollar | `A$` |
| KWD | 3 | Kuwaiti Dinar | `KD` |
| SEK | 2 | Swedish Krona | `kr` |
| INR | 2 | Indian Rupee | `₹` |
| NZD | 2 | New Zealand Dollar | `NZ$` |
| NOK | 2 | Norwegian Krone | `kr` |
| KRW | 0 | South Korean Won | `₩` |
| BHD | 3 | Bahraini Dinar | `BD` |
| CNY | 2 | Chinese Yuan | `CN¥` |
| MXN | 2 | Mexican Peso | `MX$` |

`currency(code)` returns the `Currency` for a code, so `currency("KWD").exponent` is `3`. A code not in the table
raises `CurrencyError` whose message contains the code exactly as given (`unknown currency 'usd'`). Codes are case
sensitive: `"usd"`, `"Usd"`, `" USD"` and `"USDX"` are all unknown, and so is anything that is not a string (`None`,
`840`). `CurrencyError` is a kind of `ValidationError` (`.code` is `"validation"`, `.message` is the text).

### Exchange rates

A `RateTable` remembers what one currency was worth in another on particular days. A new table is empty.

```python
rates = RateTable()
rates.set("USD", "EUR", "0.9215", date(2024, 3, 1))
rates.rate("USD", "EUR", date(2024, 3, 15))   # Fraction(1843, 2000)
```

**`set(src, dst, rate_text, on)`** records that **one unit of `src` buys `rate_text` units of `dst`** from day `on` (a
`datetime.date`) onward. It returns nothing.

- `src` and `dst` must be currencies in the table and must differ; otherwise `CurrencyError`.
- `rate_text` must be **text** holding a positive decimal: digits, optionally a `.` followed by 1 to 8 digits. So
  `"150.5"`, `"0.9215"`, `"1"`, `"007.5"` and `"0.00000001"` are fine. Refused with `CurrencyError` (message containing
  the text): `"0"`, `"0.0"`, `"-1.5"`, `"+1.5"`, `".5"`, `"1."`, `"1,5"`, `"1e-3"`, `"1/2"`, `""`, `"abc"`, text with
  spaces or other kinds of digit characters, and anything with more than 8 decimals (`"1.123456789"`, even if the
  extra digits are zeros). Anything that is not text (a float, an int, a `Fraction`,
  `None`) is refused too: `0.9` and `2` are errors.
- `on` must be a `datetime.date`; a string like `"2024-03-01"`, `None` or a number is a `CurrencyError`, and so it is
  for `rate`, `convert` and `remove`. Every function here refuses an unknown or non-string currency code with
  `CurrencyError`.
- The rate is kept **exactly**, as a `fractions.Fraction`, never a float.
- Setting a rate for the same `(src, dst, on)` again **replaces** the earlier one.
- A rate is stored for one direction only; the opposite direction is worked out when asked.

A refused `set` changes nothing.

**`rate(src, dst, on)`** returns the rate in force on day `on` as a `Fraction`:

1. If `src == dst` it is `Fraction(1)` (both codes still have to be known currencies).
2. Otherwise, the rate set for `src -> dst` with the **latest date on or before `on`**. A rate dated the same day
   counts; a later one does not.
3. If no `src -> dst` rate is dated on or before `on`, the **inverse** of the rate set for `dst -> src` with the latest
   date on or before `on`, i.e. `1 / that_rate`, exactly.
4. Otherwise `CurrencyError` with the message `no rate USD -> EUR on 2024-03-01` (the codes and date asked for).

Two points I care about. A **direct rate always beats an inverse one**: as soon as any direct `src -> dst` rate is
dated on or before the day, it is used, even if an opposite-direction rate is more recent. And tallybook **never goes
through a third currency**: with `USD -> EUR` and `EUR -> GBP` set, `USD -> GBP` is an error. I would rather be told
than get a made-up rate.

After `set("USD", "EUR", "0.5", 2024-03-01)` and `set("USD", "EUR", "0.75", 2024-03-10)`:

| asked | answer |
|---|---|
| `rate("USD","EUR", 2024-02-29)` | error: no rate USD -> EUR on 2024-02-29 |
| `rate("USD","EUR", 2024-03-01)` | `Fraction(1, 2)` |
| `rate("USD","EUR", 2024-03-10)` | `Fraction(3, 4)` |
| `rate("EUR","USD", 2024-03-10)` | `Fraction(4, 3)` (the inverse of 3/4) |
| `rate("GBP","GBP", anything)` | `Fraction(1)` |

If `EUR -> USD` is also set to `"1.5"` on 2024-03-02, then `rate("EUR","USD", 2024-03-10)` is `3/2` (the direct rate
beats the inverse of `USD -> EUR`), while `rate("USD","EUR", ...)` still reads the `USD -> EUR` entries.

**`convert(money, dst, on)`** returns a `Money` in currency `dst`: the amount converted at `rate(money.currency, dst,
on)`. It converts the **value**, allowing for the different numbers of decimals, and rounds to a whole minor unit of
`dst` with `round_div` (see Money). With `e_src` and `e_dst` the two exponents, the new minor units are the old
minor units times the rate times `10 ** (e_dst - e_src)`, rounded.

- Converting to the same currency returns the same amount (no rate needed; `dst` must still be a known currency).
- `100.00 USD` to JPY at `150.5` is `15050 JPY` (10000 minor units × 150.5 ÷ 100). `1.00 USD` at `150.5` is `150.5`
  yen, exactly halfway, so it rounds away from zero to `151 JPY`; at `151.5` it is `152 JPY`.
- `1.234 KWD` to USD at `3.25` is 4.0105 dollars, `4.01 USD`. `1 JPY` to USD at `0.0067` is 0.67 cents, `0.01 USD`.
- Negative amounts round symmetrically: `-1.00 USD` at `150.5` is `-151 JPY`.
- `1.00 USD` to EUR at `0.125` is 12.5 cents, which rounds to `0.13 EUR`.
- No rate: `CurrencyError` as for `rate`. An amount that is not a `Money`, or an unknown `dst`: `CurrencyError`.
- Converting back and forth is **not** exact and I do not expect it to be.

**`entries()`** returns every stored rate (not the inverses) as a list of `(src, dst, on, rate)` tuples, `rate` a
`Fraction`, sorted by `src`, then `dst`, then date. An empty table gives `[]`.

**`remove(src, dst, on)`** deletes the rate stored for exactly that source, destination and day and returns nothing.
It does not look at inverses: removing `EUR -> USD` when only `USD -> EUR` was set is an error. With no such entry,
`CurrencyError` with exactly the message `no rate USD -> EUR set on 2024-03-01` (the codes and day of the request).
Other dates are untouched: after removing the later of two USD -> EUR rates, lookups fall back to the earlier one.


## Dates and periods

My old spreadsheets lied most about month ends, leap years and "which quarter is this". tallybook reads and writes
dates one way only, `YYYY-MM-DD`, and never looks at the clock: when something depends on "today" I pass it in. The
code goes in `tallybook.dates`:

```python
from tallybook.dates import parse_date, format_date, add_months, last_day, Period, periods, DateError
```

All dates are `datetime.date` objects. `DateError` is the error for everything in this section, and it is a kind of
`ParseError` (`code` is `"parse"`).

### Reading and writing a date

`parse_date(text)` returns a `datetime.date` and is **strict**: exactly four digits, a `-`, two digits, a `-`, two
digits, nothing else, and the day must exist on the calendar.

| text | result |
|---|---|
| `2024-03-01`, `2024-02-29`, `2000-02-29`, `9999-12-31` | fine |
| `2023-02-29`, `1900-02-29`, `2100-02-29` | refused: not a leap year (a century year is one only when divisible by 400) |
| `2024-02-30`, `2024-04-31` | refused: no such day |
| `2024-13-01`, `2024-03-00`, `2024-03-32` | refused |
| `2024-3-1`, `2024-03-1` | refused (digits must be zero padded) |
| `24-03-01`, `20240301`, `2024/03/01`, `01-03-2024` | refused |
| ` 2024-03-01`, `2024-03-01 `, `2024-03-01\n` | refused: no spaces, tabs or newlines around it |
| `2024-03-01T10:00`, `2024-03-01 10:00` | refused: only a date |
| `0000-01-01` | refused (the calendar starts at year 1) |
| `٢٠٢٤-٠٣-٠١` (non-ASCII digits) | refused: ASCII digits only |
| `""` | refused |
| `None`, a number, a `date` object | refused: the input must be text |

A refusal raises `DateError` whose message contains the offending text as given.

`format_date(d)` returns the `YYYY-MM-DD` text of a date, zero padded: `format_date(date(2024, 3, 5))` is `"2024-03-05"`
and `format_date(date(999, 1, 2))` is `"0999-01-02"`. Anything that is not a date raises `DateError`.
`parse_date(format_date(d)) == d` for every date.

### Month ends and leap years

`last_day(year, month)` returns the number of the last day of that month as an `int`: `last_day(2024, 2)` is `29`,
`last_day(2023, 2)` is `28`, `last_day(1900, 2)` is `28`, `last_day(2000, 2)` is `29`, `last_day(2024, 4)` is `30`,
`last_day(2024, 12)` is `31`. A month outside 1 to 12, a year outside 1 to 9999, or a value that is not an integer (a
float, a string, `None`, a `bool`) raises `DateError`.

`add_months(d, n)` moves a date by a whole number of months, forwards or backwards (`n` can be negative or zero). The
day of the month is kept when the target month has it, otherwise it is **clamped to the last day of the target month**:

| call | result |
|---|---|
| `add_months(2024-01-31, 1)` | `2024-02-29` |
| `add_months(2023-01-31, 1)` | `2023-02-28` |
| `add_months(2024-03-31, -1)` | `2024-02-29` |
| `add_months(2024-02-29, 12)` | `2025-02-28` |
| `add_months(2024-11-30, 3)` | `2025-02-28` |
| `add_months(2024-01-15, -1)` | `2023-12-15` |
| `add_months(2024-01-31, 25)` | `2026-02-28` |

The result is always computed from the date you gave, never from a previous result: `add_months(add_months(2024-01-31,
1), 1)` is `2024-03-29` but `add_months(2024-01-31, 2)` is `2024-03-31`. Going before year 1 or after year 9999
raises `DateError`; so does a non-integer `n` (`1.5`, `True`) or a first argument that is not a date.

### Periods

A **period** is a run of whole days, both ends included. `Period(start, end)` takes two dates (`.start`, `.end`). It
is immutable and hashable, and two periods with the same start and end are equal. An **empty** period is not allowed:
if `end` is before `start` the constructor raises `DateError` (its message names both dates). A one-day period
(`start == end`) is fine. A `start` or `end` that is not a `date` (a string, `None`) raises `DateError` too.

| member | meaning |
|---|---|
| `p.contains(d)` | `True` when `start <= d <= end` (both ends are inside); a non-date raises `DateError` |
| `p.days` | how many days it holds, both ends counted, as an `int`: January 2024 has `31` |
| `p.label` | the short name, below |
| `str(p)` | the same as the label |
| `p.next()` | the period that follows, below |

**Reading a period.** `Period.parse(text)` accepts exactly four shapes:

| text | period |
|---|---|
| `2024` | the whole year, 2024-01-01 to 2024-12-31 |
| `2024-03` | the month, 2024-03-01 to 2024-03-31 |
| `2024-Q1` | the quarter: Q1 is Jan-Mar, Q2 Apr-Jun, Q3 Jul-Sep, Q4 Oct-Dec |
| `2024-03-01..2024-03-31` | an explicit range of two full dates joined by two dots |

Everything else is a `DateError` whose message contains the whole text: `2024-3`, `2024-13`, `2024-Q0`, `2024-Q5`,
`2024-q1` (the Q is upper case), `2024Q1`, `24`, `12345`, `0000`, a lone date `2024-03-01` (write
`2024-03-01..2024-03-01`), `2024-03-01..`, `..2024-03-31`, `2024-03-01...2024-03-31`, `2024-03-01 .. 2024-03-31`,
`2024-03..2024-04`, `2024-02-30..2024-03-31`, an empty string, text with whitespace around it, and anything that is
not a string. A range ending before it starts (`2024-03-31..2024-03-01`) is an empty period, refused the same way;
`2024-03-05..2024-03-05` is fine.

**The label** names a period as briefly as possible, looking only at its dates, not at how it was written. Exactly one
whole calendar year is `2024`; a whole calendar month is `2024-03`; a whole calendar quarter is `2024-Q1`; anything
else is the range `2024-03-05..2024-03-20` (a single day is `2024-03-05..2024-03-05`). Years are four digits, so year
999 is `0999`. So `Period.parse("2024-01-01..2024-03-31").label` is `2024-Q1`, `Period.parse("2024-03-01..2024-03-31").label`
is `2024-03`, and `Period.parse("2024-04-01..2024-04-29").label` stays a range because April has 30 days.
`Period.parse(p.label) == p` for every period `p`.

**`p.next()`** is the following period of the same kind, the kind being decided by the dates alone, like the label:

- after a whole month, the next whole month (`2024-02` → `2024-03`, `2024-12` → `2025-01`; `2024-01` → `2024-02`, which
  has 29 days);
- after a whole quarter, the next quarter (`2024-Q4` → `2025-Q1`);
- after a whole year, the next year;
- after any other range, the range that starts the day after it ends and holds the same number of days:
  `2024-03-05..2024-03-14` → `2024-03-15..2024-03-24`, and a one-day period is followed by the next day.

A `next()` that would pass 9999-12-31 raises `DateError`.

### Lists of periods

`periods(start, end, step)` takes two dates and a step: `"week"`, `"month"`, `"quarter"` or `"year"`. It returns a list
of `Period`, in order and with no gaps, that **covers** `start` to `end`: the first period contains `start` and the last
contains `end`. They are whole calendar periods and are not trimmed to the dates you gave:

- `"month"`: `periods(2024-01-15, 2024-03-02, "month")` is January, February and March 2024 (labels `2024-01` to `2024-03`).
- `"quarter"`: `2023-11-15` to `2024-02-03` gives `2023-Q4`, `2024-Q1`. `"year"`: calendar years.
- `"week"`: weeks that run **Monday to Sunday**. `periods(2024-03-06, 2024-03-18, "week")` (a Wednesday to a Monday)
  is `2024-03-04..2024-03-10`, `2024-03-11..2024-03-17`, `2024-03-18..2024-03-24`.

If `start` and `end` are the same date, or fall in the same period, there is exactly one period. If `end` is before
`start`, or the step is unknown (`"day"`, `"fortnight"`, `"Month"`, `None`; the message contains the step), or an
argument that should be a date is not one, it raises `DateError`.


## Accounts

tallybook keeps a **chart of accounts**: the places money can sit or come from or go to, as a tree like my paper
folders: `Assets:Bank:Checking` is the checking account, inside the `Bank` group, inside `Assets`. I want this in
`tallybook.accounts`:

```python
from tallybook.accounts import Chart, ChartError, valid_path, parent_path, account_type, path_matches
```

The account record is `tallybook.model.Account`, a plain dataclass with the attributes `path`, `type`, `currency` (a
currency code, or `None` when the account takes any currency), `opened` (a `datetime.date` or `None`), `closed` (a date
or `None`) and `note` (text, empty by default). Its constructor is `Account(path, type, currency=None, opened=None,
closed=None, note="")`, in that order. `ChartError` is a `ValidationError` (code `validation`); asking for an account
that is not there is a `NotFoundError`.

### Account paths

An account path is segments joined by `:`. Every segment starts with an **upper-case ASCII letter** and goes on with
ASCII letters, digits, `_` or `-`. The first segment (the root) must be one of exactly five words, and it decides the
kind of account:

| root | type |
|---|---|
| `Assets` | `asset` |
| `Liabilities` | `liability` |
| `Equity` | `equity` |
| `Income` | `income` |
| `Expenses` | `expense` |

So `Assets`, `Expenses:Food-and_Drink` and `Assets:Bank2:Checking` are fine; `assets:Bank`, `Assets:bank`,
`Assets::Bank`, `Assets:`, `:Assets`, `Assets:Bank Account`, `Assets:Café`, `Savings:Bank` (not a root), the empty
string and anything that is not text are not.

- `valid_path(text)` says `True` or `False` and never raises, whatever you give it.
- `parent_path(path)` cuts off the last segment: `parent_path("Assets:Bank:Checking")` is `"Assets:Bank"`; a root such as
  `"Assets"` has no parent (`None`). A path that is not valid is a `ChartError`.
- `account_type(path)` is the type from the table: `account_type("Expenses:Food")` is `"expense"`. Invalid path:
  `ChartError`.

### The chart

`Chart()` starts empty. Its methods:

- `add(path, type=None, currency=None, opened=None, note="")` adds an account and returns its `Account`. The type comes
  from the root; if I pass a `type` it must be one of the five type words *and* agree with the root
  (`add("Assets:Cash", type="expense")` is a `ChartError`). `currency` must be a known code (`"usd"` or `"ZZZ"` is a
  `ChartError`); `opened` must be a `datetime.date` (not a `datetime`) or `None`; `note` must be text. An invalid path
  (including one that is not text) is a `ChartError`. A refused `add` changes nothing, not even the parents below.
- Adding a path that is already in the chart is also a `ChartError`, with `.code == "conflict"` and a message
  containing `already exists`, so a caller can tell "duplicate" from "malformed".
- Adding an account also **creates its missing parents**, as plain accounts with no currency, dates or note. After
  `add("Assets:Bank:Checking")` the chart has three accounts: `Assets`, `Assets:Bank` and `Assets:Bank:Checking`. Such a
  parent is not "taken": I can still `add("Assets:Bank", currency="USD", note="my bank")` later and it becomes a normal
  account with those settings, no duplicate error. Only a second `add` of an account I added myself is a duplicate.
- `get(path)` returns the `Account`; a path that is not in the chart (not valid, not text, or valid but unknown) is a
  `NotFoundError` whose message contains `no such account`. `exists(path)` is `True`/`False` and never raises, and
  `path in chart` means the same.
- `accounts()` returns every account (parents included) as a list of `Account`, sorted by path **segment by segment**,
  not character by character: `Assets:Bank` comes before `Assets:Bank:Checking`, which comes before `Assets:Bank2`.
- `children(path)` are the accounts exactly one segment below `path`, `descendants(path)` everything below it at any
  depth (not the account itself); both are sorted like `accounts()` and are `[]` for a leaf. `is_leaf(path)` is `True`
  when there are no children. An unknown path is a `NotFoundError` in all three.

The chart does not know about transactions: closing an account does not look at what was already posted to it.
`add`, `get`, `accounts()` and friends hand out the chart's own `Account` records, so a record I fetched earlier shows
a later `close`.

### Opening and closing

An account **can be used on a day** when `opened` is empty or on/before that day, and `closed` is empty or on/after
that day: the closing day itself is the last usable day. `chart.is_open(path, on)` answers exactly that with
`True`/`False` (unknown path: `NotFoundError`).

`close(path, on)` sets the closing date and returns the `Account`. It is a `NotFoundError` for an unknown path and a
`ChartError` if `on` is not a date (a `datetime` is not), if the account is already closed (message contains
`already closed`), or if `on` is before its `opened` date; a refused close changes nothing. Closing a parent does **not**
close what is below it. There is no re-opening.

### Patterns

Elsewhere I want to say "all my food accounts" in one short expression, so a chart answers account **patterns**. A
pattern looks like a path, but a segment may also be `*` or `**`:

| pattern | matches |
|---|---|
| `Expenses` (no wildcard) | the account `Expenses` **and everything below it** |
| `Expenses:Food` (no wildcard) | `Expenses:Food` and `Expenses:Food:Groceries`, not `Expenses:Foods` |
| `Expenses:*` | accounts exactly one level below `Expenses` (`Expenses:Food`, not `Expenses:Food:Groceries`) |
| `Expenses:**` | everything **below** `Expenses` at any depth (one or more segments), not `Expenses` itself |
| `Assets:*:Checking` | `Assets:Bank:Checking`, not `Assets:Checking` and not `Assets:Bank:Old:Checking` |
| `Assets:**:Checking` | `Checking` under any one-or-more segments below `Assets` |
| `*` | the root accounts only (`Assets`, `Income`, ...) |
| `**` | every account |

A pattern with at least one wildcard segment is matched segment by segment, exactly, with no implicit "and below"; a
pattern with none matches the account and its descendants. Matching is case sensitive. The first segment of a pattern
need not be one of the five roots (`Savings` just matches nothing). A pattern that is not text, is empty, has an empty
segment (`Expenses::Food`, `Expenses:`), a lower-case segment, or a segment like `F*`, `***` or `Café` is a
`ChartError`. These rules belong to `Chart.matches` and `path_matches` only: the query language and budgets define
their own, different pattern rules in their own sections (for instance `Expenses:**` here excludes `Expenses` itself).

- `chart.matches(pattern)` returns the matching accounts as a list of `Account`, sorted like `accounts()`.
- `path_matches(pattern, path)` asks the same of one path, without a chart: `True`/`False`. It raises `ChartError` for a
  bad pattern; the path is just text and need not exist.

## The ledger

The ledger is the heart of it: the transactions, and the balances worked out from them. I want it in `tallybook.ledger`:

```python
from tallybook.ledger import Ledger, LedgerError
from tallybook.model import Posting, Transaction
```

### Transactions and postings

These two plain-data records are in `tallybook.model`; the ledger gives them meaning.

- `Posting(account, amount, note="")` is one line of a transaction: an account path (text), an amount (a `Money`) and a
  free-text note. A posting is immutable. **One posting per transaction may have `amount=None`**; only `Ledger.add`
  accepts that, and it works the amount out (see below).
- `Transaction(date, payee, narration="", postings=[], tags=(), flag="*", id=None)` is a dated event: a
  `datetime.date`, who it was with (`payee`), what it was for (`narration`), a list of postings, a tuple of tags, a
  flag (`"*"` cleared or `"!"` pending) and an `id` that is `None` until the ledger gives it one.

A transaction is double-entry in one object: money leaves one account and arrives in another, so its amounts add up
to nothing. Lunch is `Expenses:Food 12.50 USD` and `Assets:Cash -12.50 USD`.

### Making a ledger

`Ledger(chart=None, rates=None)` takes the `Chart` (see Accounts) and the `RateTable` (see Currency) it should use,
and makes empty ones when I give none. They are `ledger.chart` and `ledger.rates`. `len(ledger)` is the number of
transactions. I call `ledger.chart.add(...)` to create accounts before posting to them.

### Adding a transaction

`ledger.add(tx)` checks the transaction, stores it and **returns the stored transaction**: a new object (with its id,
tags cleaned and any amount worked out); the one I passed in is never modified. If anything is wrong a `LedgerError`
(a `ValidationError`, code `validation`) is raised and **nothing at all is stored or changed**, not even the next id.
The rules:

1. **Basics.** `date` must be a `datetime.date` (not a `datetime`), `flag` must be `"*"` or `"!"`, payee and narration
   must be text without a line break (empty is fine), every tag must look like `salary`, `trip-2024` or `a_b` (ASCII
   letters and digits to start, then letters, digits, `_` and `-`). A posting's note must be text without a line break,
   and an amount must be a `Money` or `None`. The stored tags are sorted and without repeats, as a tuple.
2. **At least two postings**, and the one without an amount counts. Fewer is an error (message contains
   `at least two postings`), whatever they say.
3. **Accounts.** Every posting's account must exist in the chart (message contains `unknown account` and the path;
   an invalid path is just unknown) and be usable on the transaction's date (see Accounts), otherwise the message
   contains the path and `is not open on` and the date. Posting to a parent account such as `Assets:Bank` is allowed. If
   the account was added with a currency, every amount posted to it must be in that currency, else the message contains
   `only holds` (for example `account Assets:Bank only holds USD, not EUR`).
4. **Balance.** Group the amounts by currency: **every currency has to add up to zero on its own.** There is no
   automatic conversion; `100.00 USD` out and `92.00 EUR` in does not balance (two currencies, each off), while 100 USD
   and 92 EUR in two separate balanced pairs is fine. A transaction that does not balance is a `LedgerError` whose
   message contains `does not balance` and names every currency that is off with the sum of that currency's postings
   (for example `USD 5.00` or `JPY -300`), currencies in alphabetical order, separated by `, `.
5. **One amount may be left out.** If exactly one posting has `amount=None`, it gets whatever balances the transaction:
   the negative of the sum of the others. If the others are off in several currencies, that posting is replaced, in its
   place, by **one posting per currency that is off**, in alphabetical order of currency code, each with the same account
   and note. If the other postings already balance there is nothing to infer: `LedgerError`, message contains
   `nothing to infer`. Two or more postings without an amount: `LedgerError`, message contains
   `more than one posting without an amount`. The account-currency rule above applies to worked-out amounts too.
6. **Ids.** If `tx.id` is `None` the ledger assigns the next one: ids count 1, 2, 3, and **an id is never handed out
   again** in the same ledger, even after the transaction is removed (the next id is always one more than the highest id
   ever stored). I may give an id myself (my storage code does when it reloads a book): it must be an int of at least 1
   (not a `bool`) and not in use (message contains `already exists`), and later automatic ids continue after the highest.
7. Zero amounts are fine (`0.00 USD` postings are allowed).

### Adding several at once, and changing one

- `ledger.add_many(transactions)` adds an iterable of transactions in order, exactly as if I called `add` for each, and
  returns the list of stored transactions (`[]` for an empty batch). It is **all or nothing**: if any one is refused,
  that error is raised and the ledger is exactly as it was before the call, ids included (a later automatic id starts
  again where it would have). Each is judged against the ledger-so-far (a duplicate explicit id within the batch is refused).
- `ledger.replace(id, tx)` swaps the stored transaction `id` for a new version `tx` and returns the stored new one. It
  keeps the id (`tx.id` must be `None` or equal to `id`, else `LedgerError`). The new version goes through every rule of
  `add`, again all or nothing: if it is refused, the old transaction stays as it was. An unknown id is a `NotFoundError`.

### Looking things up

- `ledger.get(id)` returns the stored transaction; an unknown id is a `NotFoundError` (message contains
  `no transaction`).
- `ledger.remove(id)` deletes a transaction and returns it; an unknown id is a `NotFoundError` with the same message.
- `ledger.transactions()` returns all transactions as a list sorted by `(date, id)`: oldest first, and on the same day in
  id order.
- `ledger.postings()` yields `(transaction, posting)` pairs for every posting of every transaction, in `transactions()`
  order and then posting order. Worked-out amounts are there as ordinary postings.

### Balances

All of these count a transaction when its date is on or before `as_of` (a date, **inclusive**); `as_of=None` counts
everything. They are exact integers in minor units, per currency; currencies are never added together.

- `ledger.balances(as_of=None)` returns `{account: {currency: minor}}`: for each account the sum of what was posted
  **to that very account** (no roll-up of parents). A zero total is left out, and so is an account with nothing left.
  Plain `dict`s, for example `{"Assets:Cash": {"EUR": 500, "USD": 2000}}`.
- `ledger.rollup_balances(as_of=None)` is the same shape, but every account also counts everything posted anywhere below
  it, so parents show up too: with `Assets:Bank:Checking` holding 2000 USD, `Assets:Bank` and `Assets` have 2000 USD as
  well. Zero entries are left out the same way.
- `ledger.balance(account, as_of=None, currency=None, rollup=True)` is one account's balance. The account must be in
  the chart (a parent made by `add` counts), otherwise `NotFoundError`. With `rollup=True` it includes everything below
  the account, with `rollup=False` only postings to that account itself. With a `currency` it returns a `Money` (zero if
  nothing was posted); without one, a `dict` of currency code to `Money`, zero currencies left out (`{}` when empty).

Balances do not depend on the order transactions were added in.

## The journal file

I want to keep a whole book as one readable text file, edit it in any editor, put it in git, and load it back, in the
spirit of ledger-cli but simpler. The module is `tallybook.journal`:

```python
from tallybook.journal import Journal, JournalError, parse_journal, format_journal, format_transaction
```

Here is a small journal, which is also exactly the *canonical* form tallybook writes:

```
account Assets:Bank:Checking USD open 2023-01-01 "main account"
account Income:Salary

rate 2024-03-01 USD EUR 0.92

2024-03-01 * "Employer" "March pay" #salary
  Income:Salary         -2500.00 USD
  Assets:Bank:Checking   2500.00 USD  ; net of tax

2024-03-02 ! "Corner shop"
  Expenses:Food  12.50 USD
  Assets:Cash
```

### What the module offers

- `Journal(accounts=[], rates=[], transactions=[])` is a dataclass (two journals with the same content are `==`; each
  journal has its own lists). `accounts` is a list of `tallybook.model.Account`, `rates` a list of tuples
  `(src, dst, date, rate_text)` with a `datetime.date` and the rate as the text that was written (`"0.92"`),
  `transactions` a list of `Transaction` (with `id=None`; a posting written without an amount has `amount=None`; tags a
  sorted tuple). All three keep file order.
- `parse_journal(text) -> Journal`, `format_journal(journal) -> str` and `format_transaction(tx) -> str`.
- `journal.to_ledger()` makes a new `Ledger` holding the journal's content: each account added to its chart (with its
  type, currency, opening date and note, and closed if it has a closing date), each rate set in its rate table, then each
  transaction added with `Ledger.add` in list order. Errors from those calls (an unbalanced transaction, an unknown
  account, a duplicate account in a hand-built journal...) come out unchanged: *reading* a file only checks the writing,
  not the book-keeping.
- `JournalError` is a `ParseError` (code `parse`). It has `.line`, the 1-based number of the line with the first
  mistake, and its message starts with `line N: ` (that same number) followed by a short description. The description is
  up to you; the line number is not.

### Reading the file

The text may start with a byte-order mark (`﻿`, ignored) and its lines may end in `\n` or `\r\n`. Line numbers count
every line, blank and comment lines included, from 1 (the mark is not a line, and `\r\n` is one line break). A last line
without a line break is fine. An empty text, or one with only comments and blank lines, is an empty `Journal`.

- Parts of a line are separated by any amount of spaces and tabs.
- A **blank line** (nothing, or only spaces and tabs) separates things. A **comment line** is one whose first non-blank
  character is `;` or `#`, indented or not; it is ignored wherever it is (inside a transaction too, where it does *not*
  end the transaction). A trailing `; text` on an `account`, `rate` or transaction line is ignored too. On a posting
  line it is the posting's **note**: `Assets:Cash  -5.00 USD  ; coffee` gives the note `coffee` (trimmed; `;` alone
  gives an empty note). A `;` starts the comment even with no space before it (`-5.00 USD;coffee`), except inside a
  quoted string, where it is just a character.
- **Quoted strings** (payee, narration, account note): `\"` is a quote and `\\` a backslash; any other backslash, or a
  missing closing quote, is a mistake.
- **Account lines.** `account PATH [CUR] [open DATE] [close DATE] ["note"]`. The path must be a valid account path (see
  Accounts), `CUR` a known currency code, the dates real `YYYY-MM-DD` dates; the order is fixed and everything after
  the path is optional. The type comes from the root. An account declared twice is a mistake (reported on the second
  line), and so is `close` before `open`.
- **Rate lines.** `rate DATE FROM TO RATE`, e.g. `rate 2024-03-01 USD EUR 0.92`: two different, known currency codes and a
  positive number written with digits, optionally followed by `.` and one to eight decimal digits (`0.92`, `150`,
  `1.00000001`; not `.5`, `1.`, `0`, `0.000`, `-1`, `1e3`, nine decimals). The text is kept as written.
- **Transactions.** A transaction line starts in column 0 with the date, then an optional flag `*` or `!` (`*` when
  omitted), then one or two quoted strings (payee, then narration; the narration is empty when there is only one; the
  payee is required, `""` is a legal empty payee), then any number of tags written `#name` (letters and digits to start,
  then letters, digits, `_` and `-`; repeating one is harmless; they end up sorted).
- **Postings** follow the transaction line, **indented** (at least one space or tab): `ACCOUNT  AMOUNT CUR`, or just
  `ACCOUNT` for the posting whose amount is to be worked out. An amount is written like everywhere else (`-2500.00 USD`,
  `+5 JPY`; at most the decimals the currency has; see Money) and is *not* optional once there is one: `Assets:Cash 5.00`
  is a mistake, as is a third item. A transaction's postings end at the first blank line or the first line that is not
  indented (comment lines do not end it). A transaction with no postings at all is readable (the ledger refuses it
  later). An indented line that does not belong to a transaction (after a blank line, after an `account` line, at the
  very top) is a mistake.
- Anything else in column 0 (a word that is not `account` or `rate`, a date-less line) is a mistake. So is any
  malformed date (`2024-02-30`, `2024-3-1`), an unknown currency, a bad amount, or an invalid account path, reported on
  the line where it stands. Only the first mistake is reported.

### Writing it

`format_journal(journal)` writes the text above. The layout is fixed, so the same journal always gives the same text and
**`format_journal(parse_journal(text)) == text` for every text that is already canonical** (and
`parse_journal(format_journal(j)) == j` for journals made of valid parts).

- Order: all `account` lines (list order), a blank line, all `rate` lines (list order), a blank line, then the
  transactions (list order) each separated from the next by one blank line. A group with nothing in it, and its blank
  line, is left out. The text ends with exactly one `\n`; an empty journal is `""`. Lines use `\n` and have no trailing
  spaces.
- Account line: `account PATH`, then ` CUR` if there is a currency, ` open DATE` if opened, ` close DATE` if closed,
  ` "note"` if the note is not empty, each separated by one space.
- Rate line: `rate DATE FROM TO RATE`, single spaces, the rate text as stored.
- Transaction: `DATE FLAG "PAYEE"` always with the flag, then ` "NARRATION"` only if the narration is not empty, then
  ` #tag` for each distinct tag in sorted order. In quoted strings (account notes too) `\` is written `\\` and `"` is
  written `\"`.
- Postings: two spaces, then the account. For a posting **with** an amount the account is padded with spaces to the
  length of the longest account name *among this transaction's postings that have an amount*, followed by two spaces,
  then the amount text right-aligned (padded on the left with spaces) to the longest amount text of the transaction,
  then one space and the currency code. A posting without an amount is the two spaces and the account (no padding). A
  non-empty note goes at the end of the line as two spaces, `; `, and the note. The amount text is the usual one (`-0.05`,
  `1250` for JPY). In the example above `Income:Salary` is padded to the length of `Assets:Bank:Checking`, and
  `-2500.00` and ` 2500.00` have the same width.
- `format_transaction(tx)` is one transaction written that way (its line and its postings, ending in `\n`, no blank line
  after it).

Comments and blank-line habits of a hand-written file are not kept: reading then writing normalises it.

## Finding transactions: the query language

Once the book has a few thousand transactions I need a way to ask for "everything I paid to the bakery last
quarter" without writing Python. I want one small query language, used the same way everywhere: by
`tallybook query "..."`, by `tx list --query "..."`, and by the API's `?q=` parameter. This section is the
language and its library; the commands and endpoints that carry it come later.

### The library

```python
from tallybook.query import parse_query, select, Query, QueryError

q = parse_query('payee:bakery date:2024-Q1 amount>5')
q.matches(tx)             # True or False for one Transaction
q.matching_postings(tx)   # the postings of tx that make the query true, in order (a list, maybe empty)
select(transactions, q)   # the matching transactions, in the order given (a list); q may also be query text
```

- `parse_query(text, chart=None)` returns a `Query`. `q.text` is the text it was made from, `q.is_empty` is true for
  an empty query, and `repr(q)` is `Query('payee:bakery')`.
- `QueryError` is a `ParseError`; `parse_query` raises it for any text it cannot understand.
- A query is parsed once and can be used on many plain `Transaction` objects of the data model.
- An empty query (nothing, or only spaces) matches every transaction, and `matching_postings` then returns all of its
  postings. A transaction with no postings at all matches only an empty query.

### Terms

A query is made of terms: `name:value`, a comparison, or plain text. Names are not case sensitive (`PAYEE:` works).

| Term | Matches a transaction when |
|---|---|
| `payee:text` | the payee contains `text`, ignoring upper/lower case |
| `narration:text` | the narration contains `text`, ignoring case |
| `tag:name` | the transaction has exactly the tag `name` (whole tag, never a part of one) |
| `date:PERIOD` | its date lies in the period: `2024`, `2024-03`, `2024-Q1` or `2024-03-01..2024-03-31` |
| `date>=2024-03-01` | its date compares so with a full date; the operators are `<` `<=` `>` `>=` `=` `!=` |
| `flag:*` or `flag:!` | its flag is that one (`*` cleared, `!` pending) |
| `id:3` | its id is 3; the value is digits only, and a transaction without an id never matches |
| `account:PATTERN` | the posting being looked at is in an account the pattern names (see below) |
| `amount>10.00` | the posting being looked at has an amount that compares so; operators as for dates |
| a bare word, or `"some words"` | the payee or the narration contains it, ignoring case |

Details I care about:

- The `tag:` value is lower-cased first, so `tag:Coffee` finds the tag `coffee` (tags are kept in lower case).
- An unquoted value runs up to the next space or parenthesis (`payee:Blue-Bottle`). For text with spaces, quote
  it: `payee:"Blue Bottle"`, `"blue bottle"`. Inside quotes `\"` is a quote and `\\` is a backslash; every other
  character, including other backslashes, is itself. After the closing quote there must be a space, a
  parenthesis or the end of the query.
- Spaces are allowed around a comparison operator: `amount > 10` means `amount>10`.
- A bare word `and`, `or` or `not` (in any case) is the keyword; quote it (`"and"`) to search for that text. Only a
  bare word can be a keyword: `payee:and` looks for "and" in the payee.

### Accounts

`account:Expenses:Food` is a path pattern, split at `:`. Each part must match the account's parts from the start,
and the account may go on below that: `Expenses:Food` matches `Expenses:Food` and `Expenses:Food:Coffee`, but not
`Expenses:Foodie` and not `Expenses` itself. A part can be `*`, exactly one part of the path, or `**`, any number
of parts, even none: `Expenses:*` matches `Expenses:Food:Coffee` but not `Expenses`; `Assets:**` matches `Assets`
too; `**:Coffee` matches `Expenses:Coffee` and `Expenses:Food:Coffee`. Matching is case sensitive. A part may
contain only letters, digits, `_` and `-` (or be exactly `*` or `**`); `Fo*` and an empty part (`Expenses::Food`)
are errors.

If `parse_query` is given a `chart` (a `Chart` from the accounts module), then every `account:` pattern must
match at least one account of that chart; otherwise it is a `QueryError` ("no account matches ...") naming the
term. Without a chart nothing is checked.

### Amounts

`amount` compares the signed amount of one posting, as a number of whole units of its currency (`12.50 USD` is
`12.5`, `1500 JPY` is `1500`); money leaving an asset account is negative, as in the book. The number after the
operator is an optional sign, digits, and optionally a dot and digits (`-5`, `+5`, `10.00`, `3.5`). Comparison is
numeric and exact, so `amount=3.5` matches a posting of `3.50`. If the number is directly followed by an
upper-case three-letter currency code (`amount>10USD`; `10usd` is an error) only postings in that currency can
match; without a code the currency is ignored.

### Combining terms

- `and`, `or`, `not` and parentheses work as usual. `not` binds tighter than `and`, and `and` tighter than `or`:
  `a or not b and c` is `a or ((not b) and c)`.
- Two terms next to each other are joined by an implicit `and`: `payee:bakery amount>5` is
  `payee:bakery and amount>5`. `not a b` is `(not a) and b`.

A query is judged one posting at a time: a transaction matches when at least one of its postings makes the whole
expression true. The terms about the transaction (payee, narration, tag, date, flag, id and plain text) are the same
for each posting; `account` and `amount` look at the posting under test. So:

- `account:Expenses:Food amount>10` needs one posting that is both in Food and above 10, and `account:Assets and
  amount<0` finds money going out of an asset account.
- `account:Assets:Bank and account:Expenses` can never match, because no posting is in two accounts at once;
  with `or` it finds the transactions touching either.
- `not account:Expenses` matches a transaction with at least one posting outside Expenses (nearly every ordinary
  purchase). It does not mean "has no Expenses posting".
- `payee:bakery or amount>100` matches if the payee fits, or if some posting is above 100.

`q.matching_postings(tx)` returns exactly the postings for which the expression is true: for `account:Assets and
amount<0` the outgoing asset postings, for `payee:bakery` all postings of the transaction.

### Mistakes in a query

`QueryError` has a `.position` attribute: the 1-based position (the first character is 1) in the query text of
the place that is wrong, and its message always ends with `at position N` for the same N. The positions:

| Problem | Position |
|---|---|
| an unknown name before a colon (`colour:red`, or `amount:5`: amounts take an operator), a missing value (`payee:`, `amount>`), an invalid value (`id:abc`, `flag:x`, a bad period or date, a bad amount, an invalid account pattern, empty quotes) | the first character of that term |
| an unterminated quote | the opening quote |
| text right after a closing quote (`"abc"def`) | the first character after the quote |
| a term was expected but there is `and`, `or`, `)` or nothing (`a and`, `or a`, `()`, `not`) | that `and`/`or`/`)`, or one past the end of the text |
| a `)` with no matching `(` | that `)` |
| a `(` that is never closed | that `(` (the last one opened, if several) |

So `parse_query('payee:x and ')` fails with position 13 (the text has 12 characters), and
`parse_query('(payee:x')` with position 1. The rest of the message wording is up to you.

## Rules: sorting transactions into accounts for me

My bank sends "CAFE NERO 0412 LONDON" and I want that to land in `Expenses:Food` with the tag `coffee`, every
time, without touching it. I want a small hand-written rules file for that, read by a function, and used both by
the CSV import (described next) and on transactions already in the book.

### The file

One rule per line. Blank lines are ignored, and so are lines whose first non-space character is `#`. (A `#` later
in a line is just a character, there are no trailing comments.) Either line ending works and a leading
byte-order mark is ignored.

```
# coffee and lunch
when payee ~ "nero|starbucks|coffee" and amount < 0 then account Expenses:Food tag coffee narration "Coffee break"
when payee = "ACME PAYROLL" then account Income:Salary tag salary flag *
when narration ~ "^rent\b" and amount <= -500.00USD then account Expenses:Rent
when date >= 2024-01-01 and date < 2024-02-01 and amount > 1000 then flag !
when any then account Expenses:Misc
```

A rule is `when` conditions `then` actions. The words `when`, `then`, `and`, `any`, the field names and the action
names are lower case exactly; `When` is a mistake. Words are separated by spaces; spaces around an operator are
optional (`amount<0`).

**Conditions**, joined by `and` (there is no `or`: write two rules):

| Field | Operators | Value |
|---|---|---|
| `payee`, `narration` | `=` `!=` | a quoted text; the whole value equals it, ignoring case |
| `payee`, `narration` | `~` `!~` | a quoted regular expression; `~` holds when it is found anywhere in the value, `!~` when it is not |
| `amount` | `<` `<=` `>` `>=` `=` `!=` | a number such as `-5`, `10.00`, `+3.5`, optionally directly followed by an upper-case three-letter currency code (`500USD`; `500usd` is a mistake) |
| `date` | `<` `<=` `>` `>=` `=` `!=` | a full date `YYYY-MM-DD` |

- `when any then ...` is the rule that matches everything. `any` cannot be combined with other conditions.
- Regular expressions are Python's `re`, compiled with `re.IGNORECASE` and searched with `re.search`: `"nero"`
  matches "CAFE NERO 0412" and `"^rent"` is anchored at the start. `(?-i:...)` switches case sensitivity back on.
- Text in quotes: write `\"` for a quote. Any other backslash and the character after it are kept exactly as
  written, both of them, so `"\d+"` is the regular expression `\d+` and `"a\\b"` is the four characters `a\\b`
  (as a regular expression, one backslash). A backslash always pairs with the character after it, reading left to
  right. A string cannot span lines.
- The amount is in whole units of its currency (`12.50 USD` is `12.5`), signed (money going out of the bank is
  negative). With a currency code in the rule, only amounts in that currency can satisfy it; without one the
  currency is ignored. An amount that is not there never satisfies an amount condition, not even `!=`; the same
  goes for a missing date.

**Actions**, any order, at least one:

| Action | Effect |
|---|---|
| `account Expenses:Food` | the account for the other side of the transaction; a valid account path (it need not exist, and its first part may be any capitalised name) |
| `tag coffee` | adds a tag; may be repeated. Letters, digits, `_` and `-`; stored in lower case; the same tag twice counts once |
| `narration "text"` | sets the narration (the text may be empty) |
| `payee "text"` | sets the payee (not empty or only spaces) |
| `flag *` or `flag !` | sets the flag |

`account`, `narration`, `payee` and `flag` can each appear only once in one rule.

### The library

```python
from tallybook.rules import parse_rules, RuleSet, Rule, RulesError

rules = parse_rules(open("rules.txt").read())
rules.apply({"payee": "CAFE NERO", "narration": "", "amount": Money.parse("-3.40 GBP"), "date": date(2024, 3, 2)})
# -> {"account": "Expenses:Food", "tags": ["coffee"], "narration": "Coffee break"}
```

- `parse_rules(text)` returns a `RuleSet`; an empty text gives an empty set. `len(rules)` is the number of rules,
  and iterating gives the `Rule` objects in file order; each has `.line`, the 1-based line it was written on.
- Rules are tried in file order and **the first rule whose conditions all hold wins**; the others are not looked
  at, even if they are more specific. `rules.match(fields)` returns that `Rule` or `None`.
- `rules.apply(fields)` takes a dict with `payee` (text), `narration` (text), `amount` (a `Money`) and `date` (a
  `datetime.date`). A missing `payee` or `narration` counts as an empty text; a missing `amount` or `date` fails
  every condition on it. It returns `None` when no rule matches, else a **new** dict (changing it never changes the
  rules) holding only the keys the winning rule sets: `account`, `tags` (a list of lower-case names, in the order
  written, each once), `narration`, `payee`, `flag`.
- `rules.categorize(tx)` takes a `Transaction` and returns it with the winning rule applied (the same transaction
  if no rule matches). The rule sees `tx.payee`, `tx.narration`, `tx.date` and the amount of the **first posting**
  (no postings: no amount). Then `payee`, `narration` and `flag` are replaced by the rule's; `tags` becomes the
  sorted union (a tuple) of the tags it had and the rule's; `account` replaces the account of the **second**
  posting, but only when the transaction has exactly two postings. Amounts, the date and the id never change, and
  the original object is not modified.

### Mistakes in a rules file

`RulesError` is a `ParseError`. Its `.line` is the 1-based line number of the first bad rule (counting blank and
comment lines) and its message starts with `line N: `. A bad file raises; no partial rule set is returned. These
are mistakes:

- a line that does not start with `when`, or lacks `then`, or has nothing after `then`, or has a condition or an
  action with a part missing (`when then ...`, `amount <`, `then tag`, `then account`), or has words left over;
- an unknown field or action name, an operator that does not belong to the field (`payee < "x"`, `amount ~ "1"`),
  a text that is not in quotes (`payee ~ coffee`), a string that is never closed;
- a regular expression that `re` rejects;
- an amount that is not a number such as the above, a date that is not a real `YYYY-MM-DD` date (`2024-02-30`);
- an invalid account path (`:`-separated parts, each an upper-case letter followed by letters, digits, `_`, `-`),
  a flag other than `*` or `!`, an invalid tag name;
- `account`, `narration`, `payee` or `flag` given twice, an empty `payee`.

## Importing my bank's CSV files

Every month I download a statement from the bank as a CSV file, and every bank lays its columns out differently.
I want to describe a bank once, in a small **profile** file, and then feed it statements. A bad row must never
cost me a good one, and importing the same statement twice must not double anything.

### The profile

A profile is plain text, one `setting = value` per line. Blank lines and lines starting with `#` are ignored (a
`#` anywhere else is just a character: `date_column = #1`). Spaces around the name and the value are dropped; a
value wrapped in double quotes loses the quotes and keeps its spaces inside (`date_column = "Booking date"`; no
escapes). A leading byte-order mark is ignored.

```
# My bank, statements from the web site
date_column = Booking date
date_format = %d.%m.%Y
payee_column = Description
narration_column = Reference
amount_column = Amount
currency = EUR
account = Assets:Bank:Checking
default_account = Expenses:Uncategorized
delimiter = ;
skip_rows = 2
decimal_separator = ,
thousands_separator = .
tags = imported
```

| Setting | Meaning | Default |
|---|---|---|
| `date_column`, `payee_column` | required; the column holding the date and the payee | |
| `narration_column` | optional column for the narration | none |
| `amount_column` | one signed amount column; **or** | |
| `debit_column` and `credit_column` | two columns, both required together; not allowed with `amount_column` | |
| `currency` | required; a known currency code, all rows are in it | |
| `account` | required; the bank's own account path | |
| `default_account` | the other account when no rule picks one | none |
| `date_format` | how dates are written (below) | `%Y-%m-%d` |
| `delimiter` | one character (not `"` or a line break), or the word `comma`, `tab`, `semicolon`, `pipe`, `space` | `,` |
| `skip_rows` | whole number of lines at the top of the file to ignore | `0` |
| `has_header` | `yes`/`no` or `true`/`false`, any case (nothing else) | `yes` |
| `negate` | same values: flip the sign of every amount (card statements show spending as positive) | `no` |
| `decimal_separator` | `.` or `,` | `.` |
| `thousands_separator` | `none`, `comma`, `dot`, `space`, `apostrophe` (or the character itself: `,` `.` `'` or `" "`) | none |
| `flag` | `*` or `!`, the flag of imported transactions | `*` |
| `tags` | comma separated tag names (letters, digits, `_`, `-`) added to every imported transaction (stored lower case, sorted, once each); not empty | none |

A **column** is written as the header's name (compared ignoring case and surrounding spaces; the first such
column if a name repeats) or as `#3`, the third column, counting from 1. With `has_header = no` (wherever it
stands in the file) only `#N` is allowed. `date_format` uses `%Y` (4 digits), `%y` (2 digits, meaning 2000 to
2099), `%m` and `%d` (one or two digits), `%b` (three-letter English month abbreviation such as `Mar`), `%B` (full
English month name), both in any case, and `%%`; every other character stands for itself. It must contain a year,
a month and a day, each once, and no other `%` directive.

`parse_profile(text)` returns an `ImportProfile` whose attributes are named exactly like the settings:
`date_column`, `date_format`, `payee_column`, `narration_column`, `amount_column`, `debit_column`,
`credit_column`, `currency`, `account`, `default_account`, `delimiter` (the real character), `skip_rows` (int),
`has_header` and `negate` (bool), `decimal_separator`, `thousands_separator` (`""` for none, else the character),
`flag`, `tags` (a sorted tuple). Column attributes keep what was written (`"Booking date"`, `"#3"`).

A bad profile raises `CsvImportError` (a `ParseError`). For a problem on one line the error's `.line` is that
line number (counting blank and comment lines) and the message starts `line N: `: a line without `=`, an unknown
setting, a setting given twice, a column written as `#0` or as an empty or `#`-led non-number, a column name with
`has_header = no`, an account that is not a valid path (as in the rules file), an unknown currency, a bad
`date_format`, a bad value for any other setting. For a problem with the whole profile `.line` is `None`: a missing
required setting, `amount_column` together with debit/credit, only one of `debit_column`/`credit_column` (or none
of the three kinds), equal decimal and thousands separators.

### Importing

```python
from tallybook.csvimport import parse_profile, import_csv, ImportResult, CsvImportError

result = import_csv(open("march.csv", encoding="utf-8").read(), profile, rules, existing)
result.transactions   # new Transactions, in file order
result.duplicates     # Transactions built from rows that were imported before, in file order
result.errors         # [(row_number, message), ...] in file order
```

`import_csv(text, profile, rules=None, existing=())`: `profile` is an `ImportProfile` or profile text; `rules`
is a `RuleSet`, rules text, or `None`; `existing` is any iterable of `Transaction`s already in the book.

**Reading the file.** A leading BOM is ignored. The first `skip_rows` lines (split at `\n`, `\r\n` or `\r`) are
thrown away. The rest is ordinary CSV with the profile's delimiter and `"` as the quote: a quoted field may
contain the delimiter and line breaks, `""` inside quotes is one quote, and lines end in `\n` or `\r\n`.
With a header, the first non-blank record is the header; if a column the profile names is not in it,
`import_csv` raises `CsvImportError` (naming the column) and imports nothing, and so it does for a file with no
header at all. An empty file with `has_header = no` gives an empty result. Blank lines and records whose cells
are all blank are ignored, and so are extra cells at the end of a row.

**Row numbers** are line numbers in the file (the first line is 1; skipped lines, the header and blank lines
count): the line a record starts on, so a quoted field spanning lines pushes the next record's number up by that
many.

**Each row** becomes a transaction or an error:

- *Date*: the cell, trimmed, must match `date_format` completely and be a real date.
- *Payee*: required; the cell with every run of whitespace (line breaks too) turned into one space, trimmed. An
  empty payee is an error. The narration is cleaned the same way, `""` if there is no column or the row is short.
- *Amount* (`amount_column`): an optional `+` or `-`, digits, and optionally the decimal separator and digits. If
  a thousands separator is set it may separate groups of exactly three digits after a first group of one to
  three (`1.234.567,89`, never `12.34.567`); ungrouped digits are fine too. `(12,50)` means minus 12.50 (no sign
  inside the parentheses). Anything else, an empty cell, or more decimal places than the currency has (`1.505`
  for EUR, `1.5` for JPY) is an error. With `debit_column`/`credit_column` the amount is credit minus debit, a
  blank one counting as nothing: a row with both filled, or neither, is an error. Then `negate` flips the sign.
  An amount of zero is an error.
- The bank posting is the amount (profile currency) on `account`; the other posting is the opposite amount on the
  counter account. The transaction has `id` `None`, the profile's `flag` and `tags`, and no posting notes.
- *Rules*: if there are rules, the first matching one is looked for with `payee`, `narration` (cleaned), `date`
  and `amount` (the bank posting's, signed). Its `account` is the counter account, its `payee`, `narration` and
  `flag` replace the row's, and its tags are added to the profile's (sorted). No `account` from a rule means
  `default_account`; if there is neither, the row is an error.
- A row too short for a needed column is an error naming the column as the profile wrote it.

A bad row is `(row_number, message)` in `errors` and affects no other row. The message names the problem, and for a
bad date or amount contains the offending cell text as in the file (trimmed).

**Recognising rows I already imported.** The key of a transaction is its date, the amount (with its currency) of its
first posting on the profile's `account`, and its payee (after the rules), letter for letter; a transaction in
`existing` with no posting on that account is ignored. The n-th row of the file with a given key is a duplicate when `existing` holds at least
n transactions with that key, and new otherwise. So importing a file against what it produced before makes all
its rows duplicates, two identical coffees on one day both import the first time, and if one of them is already
in the book exactly one of the two is new. A row that fails never takes part. Duplicates are only reported, never
in `transactions`.

Putting the new transactions into the book is a separate step; the import itself does not look at the book, nor at
whether the accounts exist.

## Budgets

I want to say "no more than 400 a month on food" and then ask, for any stretch of time, how I am doing. That is
the `tallybook.budgets` module; the commands and the web interface come later, on top of it.

```python
from datetime import date
from tallybook.budgets import Budget, BudgetError, BudgetLine, budget_status
from tallybook.money import Money

food = Budget("Expenses:Food", "month", Money.parse("400.00 USD"), date(2024, 1, 1))
for line in budget_status([food], ledger, Period.parse("2024-03")):
    print(line.pattern, line.actual, line.remaining, line.percent, line.over)
```

### A budget

`Budget(pattern, period_kind, amount, start)` is an immutable value (hashable, equal when its four fields are).

- `pattern` is text that selects accounts, see below.
- `period_kind` is exactly `"month"`, `"quarter"` or `"year"`: calendar months, quarters (January to March, April
  to June, July to September, October to December) and years.
- `amount` is a `Money`: how much I may spend in each such period. It must be greater than zero.
- `start` is a `datetime.date`. The budget is in force from the calendar period that contains `start`, whole
  (a `start` of 2024-03-20 on a monthly budget means March 2024 is the first month, with its full allowance).
  Periods before that one have no budget at all.

Building a `Budget` with a bad pattern (text or not), a `period_kind` that is not one of the three words, an amount
that is not a `Money` or is zero or negative, or a `start` that is not a `date` raises `BudgetError`, a
`tallybook.errors.ValidationError` (code `validation`) whose message says what was wrong.

### Which accounts a budget watches

A pattern is an account path in which any segment may be `*`, meaning "any one segment". Every other segment is an
ordinary account name segment (an upper-case letter, then letters, digits, `_` or `-`), separated by `:`. Nothing
else is allowed: an empty pattern, an empty segment, a lower-case segment, `**` or `Expenses:Fo*` is a
`BudgetError`. (Budget patterns are not the account patterns of queries or the chart: no `**`.)

An account matches a pattern when the pattern's segments match the first segments of the account's path: the
account is what the pattern names, or lies anywhere below it. So `Expenses:Food` matches `Expenses:Food` and
`Expenses:Food:Dining:Cafe` but not `Expenses:Foods` and not `Expenses`; `Expenses` matches every expense
account; `Expenses:*:Dining` matches `Expenses:Food:Dining`, `Expenses:Fun:Dining` and anything below them;
`Expenses:*` matches `Expenses:Food` but not `Expenses` alone.

Only expense accounts (root segment `Expenses`) are ever counted. A pattern that can only match other kinds of
account, such as `Income`, is allowed and simply never has any spending.

Only postings in the budget's own currency count. A posting in another currency to a matching account is
ignored (nothing is converted, even when the ledger knows exchange rates).

### The status of budgets

`budget_status(budgets, ledger, period)` takes a list of `Budget`, a `tallybook.ledger.Ledger` and a
`tallybook.dates.Period`, and returns a list of `BudgetLine`. The ledger is not changed.

The spending of a budget in the period is the sum of the amounts of all postings dated within the period (both
ends included) that go to a matching expense account in the budget's currency. An expense is positive, so a
refund (a negative posting) lowers the spending and the total can even be negative. The spending is also kept per
account.

**Allowance in the period.** The period I ask about need not be the budget's own kind of period, or a whole
number of them. Take every calendar period of the budget's kind (the one containing `start` and later ones) that
overlaps the asked period; each counts for `overlapping days / days in that calendar period`; add those fractions
and multiply the budget amount by the sum; round once, to a whole minor unit, to the nearest with an exact half
going away from zero (half a cent becomes a cent). Examples, all with a start on or before the period:

| budget | asked period | allowance |
|---|---|---|
| 300.00 USD month | `2024-03` | 300.00 USD |
| 300.00 USD month | `2024-03-01..2024-03-15` | 145.16 USD (15 of 31 days) |
| 100.00 USD month | `2024-Q1` | 300.00 USD |
| 100.00 USD month | `2024-01-15..2024-02-14` | 103.11 USD (17/31 + 14/29 of a month) |
| 900.00 USD quarter | `2024-02` | 286.81 USD (29 of the 91 days of Q1 2024) |
| 1200.00 USD year | `2024-Q1` | 298.36 USD (91 of 366 days) |
| 1200 JPY year | `2024-03` | 102 JPY (101.64 rounded) |

A budget whose first calendar period starts after the asked period ends is not in force and gets no line at all
in the result. One that starts inside the asked period counts only from its first calendar period on (a yearly
budget of 1200.00 USD that starts 2024-01-01, asked about `2023-12-01..2024-01-31`, gives 31/366 of the year:
101.64 USD).

**The lines.** A `BudgetLine` is an immutable value with these attributes:

| attribute | meaning |
|---|---|
| `pattern`, `period_kind` | copied from the budget |
| `budget` | the `Money` allowance for the asked period, as above |
| `actual` | `Money`, the spending, in the budget's currency (zero when there is none) |
| `remaining` | `Money`, `budget - actual` (negative when overspent) |
| `percent` | a `decimal.Decimal` with exactly one decimal place: `actual / budget * 100` |
| `over` | `True` when `actual` is strictly greater than `budget`, else `False` |
| `accounts` | a tuple of `(account_path, Money)` pairs, one for each matching expense account whose spending in the period is not zero, sorted by path as plain text |

`percent` is rounded to the nearest tenth with an exact half going away from zero (0.25 becomes `0.3`, -0.25
becomes `-0.3`; a result of zero is `0.0`, never `-0.0`). For example, 0.01 USD against a 4.00 USD allowance is
0.25 percent and shows `0.3`; 0.05 USD is 1.25 percent, `1.3`; 0.03 USD is 0.75 percent, `0.8`; 340.00 against
400.00 is `85.0`, 450.00 is `112.5`, nothing spent is `0.0`, a refund-only period gives a negative percent such as
`-2.5`. If the allowance itself came out as zero (a tiny budget asked about a short period), `percent` is `0.0`
when nothing was spent and `100.0` otherwise.

`BudgetLine.to_dict()` gives the JSON-able form, with these keys: `pattern`, `period_kind`, `budget`,
`actual`, `remaining` (each money as `{"amount": "340.00", "currency": "USD"}`), `percent` (text, such as
`"85.0"`), `over` (a boolean) and `accounts` (a list of `{"account": ..., "amount": {money}}` in the same order
as the tuple).

**Order.** The lines come sorted by `pattern` (plain text order), then by period kind in the order month,
quarter, year, then by `start`. Budgets equal on all three keep the order I gave them in.

**Several budgets.** Each budget gets its own line and counts independently: if two budgets match the same account
(say `Expenses` and `Expenses:Food`) the same spending is in both lines, and two exactly alike budgets give two
identical lines.

### Examples worth checking

With a ledger holding, in March 2024, 250.00 USD of spending on `Expenses:Food:Groceries`, 90.00 USD on
`Expenses:Food:Dining` and a refund of 10.00 USD on `Expenses:Food:Groceries`, the budget above (400.00 USD a
month from 2024-01-01) over `2024-03` gives `actual` 330.00 USD, `remaining` 70.00 USD, `percent` `82.5`, `over`
False and `accounts` equal to `(("Expenses:Food:Dining", 90.00 USD), ("Expenses:Food:Groceries", 240.00 USD))`. A 300.00 USD budget gives `remaining` -30.00 USD, `percent` `110.0`, `over` True; one exactly used up is not over (`100.0`).

## Recurring transactions

Rent, the phone bill, the yearly insurance, a standing order to the savings account: they happen on a rhythm and
I am tired of typing them in. In `tallybook.recurring` I want to write the rhythm in plain words, attach a
transaction as a template, and get dated copies of it for any stretch of time I ask about. This module only works
out the dates and the copies; storing them (and never making a copy twice) is the storage layer's job.

```python
from datetime import date
from tallybook.recurring import Recurring, parse_schedule, occurrences, expand

rent = Recurring("rent", "monthly on 1", template, start=date(2024, 1, 1))
occurrences(rent, date(2024, 3, 1), date(2024, 5, 31))    # [2024-03-01, 2024-04-01, 2024-05-01]
expand([rent, phone], date(2024, 3, 1), date(2024, 3, 31))  # dated Transactions
```

All dates are `datetime.date`; nothing here looks at the clock.

### The schedule words

`parse_schedule(text)` returns a `Schedule` and understands exactly these shapes:

| text | meaning |
|---|---|
| `daily` | every day |
| `weekly on mon` | every Monday; the day is `mon tue wed thu fri sat sun` |
| `monthly on 5` | the 5th of every month; a number from 1 to 31 |
| `monthly on last` | the last day of every month |
| `yearly on 03-15` | every 15 March; `MM-DD`, two digits each |
| `every 2 weeks from 2024-01-03` | the given date, then every 2 weeks after it |
| `every 3 months from 2024-01-31` | the given date, then every 3 months after it |

The `every` form is `every N UNIT from DATE`: `N` is a whole number of at least 1, `UNIT` is `days`, `weeks`,
`months` or `years` (or the singular `day`, `week`, `month`, `year`, with any `N`), and `DATE` is a real
`YYYY-MM-DD` date.

Capitals and the amount of blank space between the words or around the text do not matter (`Monthly On LAST` is
fine). Anything that is not one of these shapes (`daily on mon`, `weekly`, `monthly on 0`, `monthly on 32`,
`weekly on someday`, `yearly on 13-01`, `yearly on 02-30`, `yearly on 3-15`, `every 0 days from 2024-01-01`,
`every 2 weeks`, `every 2 fortnights from 2024-01-01`, `every 2 weeks from 2024-02-30`, an empty text, a value
that is not text) raises `RecurringError`, a `tallybook.errors.ValidationError` (code `validation`), whose message
names the shapes that are allowed.

A `Schedule` is an immutable, hashable value; schedules that mean the same are equal (`Daily` and `daily`, or
`every 1 week from 2024-01-03` and `every 1 weeks from 2024-01-03`). `str(schedule)` is the canonical text: lower
case, single spaces, `monthly on last`, `yearly on 03-15` with two digits, and in the `every` form the unit
singular when `N` is 1 and plural otherwise (`every 1 week from 2024-01-03`, `every 2 weeks from 2024-01-03`).
Parsing the canonical text gives back an equal schedule.

`schedule.between(start, end)` is the list of the schedule's own dates from `start` to `end`, both included,
ascending (a Schedule knows nothing about a series' start, end or count).

### Which dates a schedule produces

- `daily`: every day. `weekly on mon`: every date that is a Monday.
- `monthly on N`: the Nth day of every month; a month too short for it gets its last day, so `monthly on 31` gives
  31 Jan, 29 Feb 2024, 31 Mar, 30 Apr and `monthly on 30` gives 28 Feb 2023. `monthly on last` is the last day
  whatever the length.
- `yearly on MM-DD`: that day every year; `yearly on 02-29` gives 29 Feb in leap years and 28 Feb in the others.
- `every N days from D` and `every N weeks from D` (a week is 7 days): D, D plus N days (or weeks), plus twice
  that, and so on; nothing before D. `every 10 days from 2024-01-01` gives 1, 11, 21, 31 January, 10 February.
- `every N months from D` and `every N years from D` (a year is 12 months): the k-th date is D moved forward by
  k times N months, counted from D itself and not from the previous date, the day clamped to the end of the month
  when needed; nothing before D. So `every 1 months from 2024-01-31` gives 01-31, 02-29, 03-31, 04-30, 05-31 (no
  drift to the 30th), `every 3 months from 2024-01-31` gives 2024-01-31, 04-30, 07-31, 10-31, 2025-01-31, and
  `every 1 years from 2024-02-29` gives 2024-02-29, then 28 Feb 2025, 2026 and 2027, then 2028-02-29.

### A recurring item

`Recurring(name, schedule, template, start, end=None, count=None)`:

- `name`: text of ASCII letters, digits, `-` and `_`, not beginning with `-` or `_` (`rent`, `phone-bill`, `2024_tax`).
- `schedule`: a `Schedule`, or text, which is parsed with `parse_schedule` (so a bad text raises
  `RecurringError`). The attribute `.schedule` is always a `Schedule`.
- `template`: a `tallybook.model.Transaction`. Its own date means nothing; its payee, narration, flag, tags and
  postings are what the copies are made from.
- `start`: the first day the series may produce a date. `end`: the last day, included, or `None`. `count`: the
  most dates the series ever produces, or `None`; it counts the dates produced from `start` on, so it never
  depends on which stretch of time is asked about later.

The attributes `.name .schedule .template .start .end .count` are readable. Items with equal attributes are equal.
Anything wrong (a name that does not fit, a schedule that is not a `Schedule` or text, a template that is not a
`Transaction`, a `start` that is not a date, an `end` that is not a date or is before `start`, a `count` that is
not an `int` of at least 1, `True` included) is a `RecurringError`.

`occurrences(rec, start, end)` returns the dates of the series within the window `start` to `end`, both
included, ascending, as a list (an `end` before `start` gives `[]`). The series is the schedule's dates that are
on or after `rec.start`, up to and including `rec.end` if there is one, and no more than `rec.count` of them,
counted from the first. Some consequences:

- A start on a day the schedule hits includes that day (`weekly on mon` from Monday 2024-01-01 gives 2024-01-01
  first); `monthly on 5` starting 2024-02-10 gives 2024-03-05 first.
- With `count=3`, a January start and `monthly on 5`, the dates are 5 Jan, 5 Feb, 5 Mar, even when I ask only
  about April to June (nothing comes back then).
- `end` and `count` both apply; whichever stops the series first wins.
- The `every` forms keep the rhythm of the date after `from` even if the item starts later: `every 2 weeks from
  2024-01-03` with `start=2024-01-20` gives 2024-01-31, 2024-02-14, 2024-02-28... (and never anything before
  2024-01-03, even when `start` is earlier).

### Copies of the template

`expand(recs, start, end)` returns a list of new `Transaction` objects, one for every date of every item in the
window, ordered by date, then item name (plain text order), then the item's position in `recs`. A copy has:

- `date` the occurrence date; `payee`, `narration` and `flag` equal to the template's; `id` `None`;
- `postings`: a new list holding the template's postings in order (a posting without an amount stays without one);
- `tags`: a tuple of the template's tags plus the tag `recurring`, each once, sorted.

The template is never changed, and changing a copy's list of postings changes neither the template nor the other
copies. `instantiate(rec, on)` builds the single copy dated `on` the same way (it does not check that `on` is one
of the item's dates).

For example, with a template tagged `home`, `expand([rent], date(2024, 2, 1), date(2024, 3, 31))` for the item
above gives two transactions dated 2024-02-01 and 2024-03-01, each with tags `("home", "recurring")`.

### Two more helpers

`next_occurrence(rec, after)` returns the first date of the series (`start`, `end` and `count` applied as for
`occurrences`) strictly after the date `after`, or `None` when the series has no more dates. For `monthly on 5`
starting 2024-01-01, `after` 2024-02-05 gives 2024-03-05 and `after` 2023-06-01 gives 2024-01-05.

`describe(schedule)` says a schedule in words for a person:

| schedule | text |
|---|---|
| `daily` | `every day` |
| `weekly on mon` | `every Monday` (`Tuesday`, `Wednesday`, `Thursday`, `Friday`, `Saturday`, `Sunday`) |
| `monthly on 5` | `on the 5th of every month` |
| `monthly on last` | `on the last day of every month` |
| `yearly on 03-15` | `every year on 15 March` |
| `every 2 weeks from 2024-01-03` | `every 2 weeks from 2024-01-03` |
| `every 1 month from 2024-01-31` | `every month from 2024-01-31` |

A day of the month is an English ordinal (1st, 2nd, 3rd, 4th, 11th, 12th, 13th, 21st, 22nd, 23rd, 31st); a day in
`yearly on` is a plain number (`every year on 5 July`). In the `every` form a step of 1 drops the number and uses
the singular unit (`every day from DATE`, `every week`, `every month`, `every year`); other steps keep the number
and the plural unit (`every 3 months from ...`).

## Reports

This is what I really want the tool for: look at the book and tell me where I stand. In `tallybook.reports` I
want six reports, each a plain Python `dict` I can `json.dumps` straight away, a function that draws any of them as
text, and one that turns them into CSV.

```python
from tallybook.reports import (trial_balance, balance_sheet, income_statement, cashflow, register, net_worth,
                               render_text, report_to_csv, ReportError)

report = income_statement(ledger, Period.parse("2024-03"))
print(render_text(report), end="")
```

Every report function takes a `tallybook.ledger.Ledger` first and does not change it. `ReportError` is a
`tallybook.errors.ValidationError` (code `validation`).

### Conventions all reports share

- A report `dict` contains only dicts, lists, strings, booleans, `None` and integers. Its key `"report"` is
  `"trial_balance"`, `"balance_sheet"`, `"income_statement"`, `"cashflow"`, `"register"` or `"net_worth"`.
- Money is always `{"amount": "12.50", "currency": "USD"}` (amount text with the currency's own number of
  decimals, a leading `-` when negative, no thousands separators). Dates are `"YYYY-MM-DD"` text.
- The type of an account comes from its first path segment: `Assets` asset, `Liabilities` liability, `Equity`
  equity, `Income` income, `Expenses` expense.
- Lists of accounts are sorted by account path as plain text, character by character (`Expenses:Food-X` comes
  before `Expenses:Food:Alpha` because `-` sorts before `:`), then by currency code; lists of money per currency by
  currency code. Postings are never rolled up into parent accounts unless stated.
- A zero balance is left out of an account list. (Lists of money per currency are described report by report.)
- Dates mean whole days, both ends of a `Period` included. A "balance on D" counts every posting dated on or
  before D.
- Percentages are text with exactly one decimal (`"5.7"`, `"100.0"`, `"-2.5"`), rounded to the nearest tenth of a
  percent, an exact half going away from zero (0.25 becomes `0.3`); a zero result is `"0.0"`, never `"-0.0"`.
- Converting to one currency (`convert_to="EUR"`) uses the exchange rates the ledger knows: its attribute `rates`,
  the `RateTable` it was created with (an empty table if none), at the rate in force on the date given below, one
  amount at a time, as the currency module converts money. A missing rate raises the currency module's own
  `CurrencyError` as it is, and so does a `convert_to` that is not a known currency.

### The sample book used below

Accounts `Assets:Bank:Checking`, `Assets:Cash`, `Liabilities:Card`, `Equity:Opening`, `Income:Salary`,
`Expenses:Food`, `Expenses:Rent`; all USD. The transactions, with ids 1 to 8 in this order:

| id | date | payee | postings |
|---|---|---|---|
| 1 | 2024-01-01 | Opening | Checking +1000.00, Equity:Opening -1000.00 |
| 2 | 2024-03-01 | Acme | Checking +2500.00, Income:Salary -2500.00 |
| 3 | 2024-03-02 | Market | Expenses:Food +42.50, Checking -42.50 |
| 4 | 2024-03-05 | Landlord | Expenses:Rent +900.00, Liabilities:Card -900.00 |
| 5 | 2024-03-10 | ATM | Assets:Cash +100.00, Checking -100.00 |
| 6 | 2024-03-12 | Corner | Expenses:Food +12.00, Assets:Cash -12.00 |
| 7 | 2024-04-02 | Card payoff | Liabilities:Card +900.00, Checking -900.00 |
| 8 | 2024-04-03 | Market | Expenses:Food +30.00, Checking -30.00 |

### trial_balance(ledger, as_of)

`as_of` is a date, or `None` for every posting. The result:

```
{"report": "trial_balance", "as_of": "2024-03-31",
 "accounts": [{"account": "Assets:Cash", "type": "asset", "debit": {money}, "credit": null}, ...],
 "totals": [{"currency": "USD", "debit": {money}, "credit": {money}, "balanced": true}]}
```

`as_of` is `null` when `None` was given. `accounts` has one entry per account and currency whose balance is not
zero: a positive balance is in `debit` (`credit` is `null`), a negative one as its absolute value in `credit`
(`debit` is `null`). `totals` has one entry per currency appearing in `accounts`: the sum of the debits, the sum of
the credits, and `balanced`, true when the two are equal. For the sample book on 2024-03-31 the single total is
4400.00 and 4400.00. An empty ledger gives empty lists.

### balance_sheet(ledger, as_of, convert_to=None, today=None)

```
{"report": "balance_sheet", "as_of": "2024-03-31", "currency": null,
 "assets":      {"accounts": [{"account": "Assets:Cash", "balance": {money}}, ...], "total": [{money}, ...]},
 "liabilities": {"accounts": [...], "total": [...]},
 "equity":      {"accounts": [...], "retained_earnings": [{money}, ...], "total": [...]},
 "balanced": true}
```

- `as_of` is a date or `None` (everything); `currency` is `convert_to` or `null`.
- Assets, liabilities and equity each list the accounts of that type with a non-zero balance, one entry per
  account and currency. An asset balance is the sum of its postings; a liability or equity balance has its sign
  turned round, so money owed is positive.
- `retained_earnings` is income less expenses of every posting up to `as_of`, per currency, as a list of money
  sorted by currency without zero results. It is part of `equity.total`, which makes the sheet balance.
- `total` of a section is a list with the sum of the section's lines for each currency that has a line (for
  equity also the retained earnings), sorted by currency; `[]` when the section has nothing.
- `balanced` is true when for every currency `assets.total` equals `liabilities.total` plus `equity.total`
  (a missing currency counts as zero).
- With `convert_to`: every account line is converted separately at the rate on `as_of` (a line already in
  `convert_to` is left as it is) and becomes `{"account", "balance": converted money, "original": the money
  before converting}`; each retained-earnings amount is converted separately and they are added into a single
  entry (a list of one) when any was non-zero; every `total` is then a list of exactly one money in `convert_to`,
  zero if the section is empty. `balanced` is computed on the converted figures. Converting needs a date:
  `convert_to` with `as_of=None` is a `ReportError`.
- `today` is accepted for the day the command line and the web interface will pass, and has no effect.

### income_statement(ledger, period, convert_to=None)

```
{"report": "income_statement", "start": "2024-03-01", "end": "2024-03-31", "currency": null,
 "income":   {"accounts": [{"account": "Income:Salary", "amount": {money}, "percent": "100.0"}], "total": [{money}]},
 "expenses": {"accounts": [...same line shape...], "total": [{money}]},
 "net": [{money}]}
```

Only postings dated within `period` to income or expense accounts count. An income amount has its sign turned
round (earning 2500.00 is `2500.00`), an expense is as it is. Each section lists one line per account and
currency with a non-zero amount; `percent` is the line's share of the section total in the same currency (`"0.0"`
when that total is zero; a negative line, a refund, gives a negative percentage). `total` is the list of section
sums per currency that have a line, `[]` when there is none. `net` has, for every currency in either total, income
less expenses, sorted by currency (zero included).

With `convert_to` each line is converted separately at the rate on the last day of the period and gets an
`"original"` key holding the money before converting; the totals and `net` are then single-entry lists in
`convert_to` (zero if empty), and the percentages are shares of the converted totals.

### cashflow(ledger, period)

Cash means all asset accounts together; what went in and out is told by the account on the other side of each
transaction. For every transaction dated in the period, work per currency: sum its postings to asset accounts;
when that sum is not zero, every posting of the same currency to a non-asset account moves the opposite of its own
amount into the category that account names (a salary posting of -2500.00 puts +2500.00 in, an expense posting of
+54.50 puts -54.50, a card payoff posting of +900.00 on `Liabilities:Card` puts -900.00). A transaction that only
moves money between asset accounts (sum zero) contributes nothing. Then, per account and currency, the
contributions of the period are added: a positive result is an inflow, a negative one an outflow (shown as a
positive amount), zero is left out.

```
{"report": "cashflow", "start": "2024-03-01", "end": "2024-03-31",
 "opening": [{money}], "inflows": [{"account": "Income:Salary", "amount": {money}}],
 "outflows": [{"account": ..., "amount": {money}}], "total_in": [{money}], "total_out": [{money}],
 "net": [{money}], "closing": [{money}]}
```

`opening` is the asset balance before the period starts, `closing` the one after its last day, `net` the change
(`total_in - total_out`, equal to `closing - opening`). The money lists (`opening`, `total_in`, `total_out`, `net`,
`closing`) have one entry for every currency of any asset posting dated on or before the end of the period (zero
included), sorted by currency; `inflows` and `outflows` are sorted by account then currency. In the sample, March has
opening 1000.00, inflow Salary 2500.00, outflow Food 54.50 (the transfer to Cash cancels, Cash spending counts),
closing 3445.50; April has opening 3445.50, no inflow, outflows Food 30.00 and `Liabilities:Card` 900.00, closing
2515.50.

### register(ledger, account, period=None, rollup=False)

The postings of one account, in order, with a running balance. `account` must exist in the ledger's chart (a
parent such as `Assets` exists when a sub-account does), otherwise `ReportError`. Without `rollup` only postings to
exactly that account are listed; with `rollup=True` also those to accounts below it.

```
{"report": "register", "account": "Assets:Bank:Checking", "rollup": false, "start": "2024-03-01", "end": "2024-03-31",
 "opening": [{money}], "rows": [{"date": "2024-03-01", "id": 2, "payee": "Acme", "narration": "",
   "account": "Assets:Bank:Checking", "amount": {money}, "balance": {money}}, ...], "closing": [{money}]}
```

`start` and `end` are the period's days, or `null` without a period (then every posting is listed). `rows` are
ordered by date, then transaction id, then the posting's place in its transaction; with a period, only postings
inside it. `balance` is the running balance of that row's currency over the selected accounts, from `opening`
through this row. `opening` is the balance of the selection before `start` (zero when there is no period);
`closing` is the balance after the last row of the period (nothing later counts). Both are lists with one money
for every currency of any selected posting dated on or before `end`, zero included, sorted by currency.

### net_worth(ledger, period, step="month")

How my wealth moved over time. `step` is `"week"`, `"month"`, `"quarter"` or `"year"` (anything else is a
`ReportError`). The steps are exactly those `tallybook.dates.periods(period.start, period.end, step)` gives (whole
calendar steps touching `period`, the first and last not cut down to it); a point is made for the end of each.

```
{"report": "net_worth", "start": "2024-01-15", "end": "2024-04-10", "step": "month",
 "points": [{"date": "2024-01-31", "assets": [{money}], "liabilities": [{money}], "net": [{money}]}, ...]}
```

`start` and `end` are the period's. Each point has `date`, the last day of the step, and three lists of money with
one entry per currency of any asset or liability posting dated on or before that date (zero included), sorted by
currency: `assets` the sum of the asset balances, `liabilities` the sum of the liability balances turned positive
(money owed), `net` the first less the second. A date before any asset or liability posting gives empty lists.
For the sample book and `2024-01-15..2024-04-10` the points are 2024-01-31 (assets 1000.00, liabilities 0.00, net
1000.00), 2024-02-29 (the same), 2024-03-31 (3445.50, 900.00, 2545.50) and 2024-04-30 (2515.50, 0.00, 2515.50).

### report_to_csv(report)

`report_to_csv(report)` turns any report dict into CSV for a spreadsheet: the report's table part, written as
`tallybook.export.to_csv` does (a header record, then one record per line item). Money is split into a `currency`
column and an amount column of plain amount text; totals are not included; percent cells are the plain percent
text (`5.7`). A value that is not a report dict is a `ReportError`.

| report | columns, in order | records |
|---|---|---|
| trial balance | `account,type,currency,debit,credit` | one per entry of `accounts`; the side that is null is empty |
| balance sheet | `section,account,currency,balance` | the lines of assets, liabilities, equity (section names `assets`, `liabilities`, `equity`), in that order, then one record per retained-earnings amount with section `equity` and account `Retained earnings` |
| income statement | `section,account,currency,amount,percent` | income lines (`income`) then expense lines (`expenses`) |
| cash flow | `section,account,currency,amount` | `opening` records (empty account), `in` records, `out` records, `closing` records (empty account) |
| register | `date,id,payee,narration,account,currency,amount,balance` | one per row (`id` empty when none); opening and closing are not included |
| net worth | `date,currency,assets,liabilities,net` | one per point and currency |

For the sample book the balance sheet on 2024-03-31 begins `section,account,currency,balance`,
`assets,Assets:Bank:Checking,USD,3357.50`, and ends with `equity,Retained earnings,USD,1545.50`; the March income
statement has `income,Income:Salary,USD,2500.00,100.0` and `expenses,Expenses:Food,USD,54.50,5.7`.

### render_text(report)

`render_text(report)` takes any dict made by the functions above and returns its text; any other value (or a dict
whose `"report"` is not one of the six) is a `ReportError`. All text is built with `render_table` from the export
module. A money is written `amount currency` with one space (`3357.50 USD`), a percent as its text plus `%`
(`5.7%`); a converted line shows its converted `balance`/`amount`, not the original. Each text is a title line, an
empty line, and the table, where a column with nothing to say has an empty-string cell. "A block" below is a run
of rows; between two blocks that have rows there is one row of empty cells.

| report | title line | table |
|---|---|---|
| trial balance | `Trial balance as of 2024-03-31` (`Trial balance` when `as_of` is null) | columns `Account Type Debit Credit`, `llrr`: a row per account (empty cell for the null side), then a row `Total`, empty type, debit sum, credit sum for each total |
| balance sheet | `Balance sheet as of 2024-03-31` (`Balance sheet` without a date), plus ` (in EUR)` when converted | columns `Account Balance`, `lr`: block `Assets` (a row with just that word, a row `  ` + account and balance per account, then `Total assets` and the amount per total), block `Liabilities` (`Total liabilities`), block `Equity` (accounts, `  Retained earnings` per retained-earnings amount, `Total equity`) |
| income statement | `Income statement 2024-03-01 to 2024-03-31`, plus ` (in EUR)` when converted | columns `Account Amount Percent`, `lrr`: block `Income` (heading row, `  ` + account with amount and `5.7%`, `Total income` rows without a percent), block `Expenses` (`Total expenses`), block of `Net income` rows with the amounts of `net` |
| cash flow | `Cash flow 2024-03-01 to 2024-03-31` | columns `Account Amount`, `lr`: block of `Opening balance` rows; block `Money in` (heading, `  ` + account lines, `Total money in` rows); block `Money out` (`Total money out`); block of `Net change` rows then `Closing balance` rows |
| net worth | `Net worth 2024-01-15 to 2024-04-10 (by month)` | columns `Date Assets Liabilities Net`, `lrrr`: a row per point and currency (date, then the three amounts); a point without currencies is one row with just its date |
| register | `Register Assets:Bank:Checking`, plus ` (with sub-accounts)` if rollup, plus ` 2024-03-01 to 2024-03-31` if there is a period | columns `Date Id Payee Account Amount Balance`, `llllrr`: a row per opening amount with `Opening balance` in the Payee column and the amount in Balance; a row per register row (date, id or empty, payee, account, amount, balance); `Closing balance` rows likewise |

A `Liabilities` block with nothing in it is just its heading row. The balance sheet on 2024-03-31, the March 2024
income statement and register, exactly:

```
Balance sheet as of 2024-03-31

Account                     Balance
----------------------  -----------
Assets
  Assets:Bank:Checking  3357.50 USD
  Assets:Cash             88.00 USD
Total assets            3445.50 USD

Liabilities
  Liabilities:Card       900.00 USD
Total liabilities        900.00 USD

Equity
  Equity:Opening        1000.00 USD
  Retained earnings     1545.50 USD
Total equity            2545.50 USD
```

```
Income statement 2024-03-01 to 2024-03-31

Account               Amount  Percent
---------------  -----------  -------
Income
  Income:Salary  2500.00 USD   100.0%
Total income     2500.00 USD

Expenses
  Expenses:Food    54.50 USD     5.7%
  Expenses:Rent   900.00 USD    94.3%
Total expenses    954.50 USD

Net income       1545.50 USD
```

```
Register Assets:Bank:Checking 2024-03-01 to 2024-03-31

Date        Id  Payee            Account                    Amount      Balance
----------  --  ---------------  --------------------  -----------  -----------
                Opening balance                                     1000.00 USD
2024-03-01  2   Acme             Assets:Bank:Checking  2500.00 USD  3500.00 USD
2024-03-02  3   Market           Assets:Bank:Checking   -42.50 USD  3457.50 USD
2024-03-10  5   ATM              Assets:Bank:Checking  -100.00 USD  3357.50 USD
                Closing balance                                     3357.50 USD
```

And the cash flow for March:

```
Cash flow 2024-03-01 to 2024-03-31

Account               Amount
---------------  -----------
Opening balance  1000.00 USD

Money in
  Income:Salary  2500.00 USD
Total money in   2500.00 USD

Money out
  Expenses:Food    54.50 USD
Total money out    54.50 USD

Net change       2445.50 USD
Closing balance  3445.50 USD
```

## Export, and the plain text tables

I want to get my transactions out of the book in two formats other tools can read, and I want every text report
(they come next) laid out by one table routine that I can also call myself. All of it is `tallybook.export`:

```python
from tallybook.export import transactions_to_csv, transactions_to_json, render_table

open("march.csv", "w", encoding="utf-8", newline="").write(transactions_to_csv(txs))
print(render_table(["Name", "Qty"], [["Apple", 3], ["Kiwi", 12]], "lr"), end="")
```

`txs` is any iterable of `tallybook.model.Transaction`. These functions only read them, do not sort (the order is
the order I give), return text and never write files.

### CSV

`transactions_to_csv(txs)` returns one record per **posting**, so a transaction with three postings is three
records. The first record is always the header, exactly:

```
id,date,flag,payee,narration,tags,account,amount,currency,note
```

Each following record has these ten fields, in this order:

| field | content |
|---|---|
| `id` | the transaction's id as a decimal number, empty when it has none (`None`) |
| `date` | `YYYY-MM-DD` |
| `flag` | `*` or `!` |
| `payee`, `narration` | as stored |
| `tags` | the tags sorted as plain text and joined with `;` (no spaces); empty for none |
| `account` | the posting's account path |
| `amount` | the amount without the currency, with the currency's own number of decimals and a leading `-` when negative, no thousands separators (`4.50`, `-4.50`, `900` for yen) |
| `currency` | the currency code |
| `note` | the posting's note |

The first six fields repeat on every record of a transaction. A posting without an amount gives empty `amount`
and `currency`. A transaction with no postings gives one record with its first six fields and the last four
empty. No transactions give only the header record.

Quoting is minimal. A field is wrapped in double quotes if, and only if, it contains a comma, a double quote, a
carriage return or a line feed; a double quote inside it is doubled. Spaces or tabs alone never cause quoting,
and non-ASCII text is written as it is. Records end with a single `\n` (never `\r\n`), the last one too. So a book
with a coffee in it gives

```
id,date,flag,payee,narration,tags,account,amount,currency,note
7,2024-03-01,!,"Café, Bäcker","say ""hi""",a;lunch,Expenses:Food,4.50,USD,"a, b"
7,2024-03-01,!,"Café, Bäcker","say ""hi""",a;lunch,Assets:Cash,-4.50,USD,
```

`to_csv(headers, rows)` is the same writer for any table of cells: header texts, then rows of cells; a cell is
written with `str()` except `None`, which is an empty field. Same quoting and line endings, header first.

### JSON

`transactions_to_json(txs)` returns a JSON array with one object per transaction, in the given order:

```
{"id": 7, "date": "2024-03-01", "flag": "!", "payee": "Café, Bäcker", "narration": "say \"hi\"",
 "tags": ["a", "lunch"],
 "postings": [{"account": "Expenses:Food", "amount": {"amount": "4.50", "currency": "USD"}, "note": "a, b"}, ...]}
```

`id` is `null` when the transaction has none. `tags` is a list, sorted as plain text, each tag once. A posting's
`amount` is the money object `{"amount": "4.50", "currency": "USD"}` (amount text as in the CSV), or `null` for a
posting without one. Postings keep their order. The text is made like every JSON document in this project:
`json.dumps(value, indent=2, sort_keys=True, ensure_ascii=False)` plus one `\n`; no transactions give `[]` and a
newline.

Three helpers make the same pieces available alone: `money_to_dict(money)` (the object above, `None` for
`None`), `transaction_to_dict(tx)` (one transaction object as a dict) and `to_json(value)` (the text exactly as
above, for any JSON-able value).

### Tables

`render_table(headers, rows, align=None)` returns fixed-width text.

- `headers` and `rows` may be any iterables (list, tuple, generator); each row must have exactly as many cells
  as there are headers. A cell is shown as `str(cell)`, except `None` which is empty. A tab, a carriage return or a
  line feed inside a cell is shown as one space each, so a cell is always one line.
- `align` is `None` (every column left aligned) or a string, list or tuple with one letter per column, `"l"` or
  `"r"`: `"lrr"` or `["l", "r", "r"]`. A letter other than those two, or a length that is not the number of
  columns, is an `ExportError`, and so is a row with the wrong number of cells. `tallybook.export.ExportError` is a
  `tallybook.errors.ValidationError` (code `validation`).
- A column is as wide as the longest of its title and its cells, a text's width being its `len()`.
- The first line is the titles, the second a rule of `-` as wide as each column, then one line per row. Cells are
  padded to the column width on the right when the column is left aligned and on the left when right aligned
  (titles too), and joined with **two spaces**. Trailing spaces are then removed from every line. Every line, the
  last included, ends with `\n`.
- No rows give the titles and the rule only. No headers at all give the empty string (and then rows are not
  looked at).

For instance `render_table(["Name", "Qty", "Price"], [["Apple", 3, "1.50"], ["Kiwi", 12, "10.25"], ["Ünï", None, "x\ty"]], "lrr")`
is

```
Name   Qty  Price
-----  ---  -----
Apple    3   1.50
Kiwi    12  10.25
Ünï           x y
```

The text reports described in the next section are built by putting their numbers into this routine.

### A few more rules, to be exact

- `str()` of a cell is taken as it is (`3`, `True`, `1.50`); text is never shortened or wrapped, however wide.
- The `flag` is written as stored; `tags` may arrive as a tuple or a list and may repeat a tag, which is then
  written once.
- Exporting does not validate the book: a transaction that does not balance is exported as it is.

### Reading the JSON back

`transactions_from_json(text)` is the inverse of `transactions_to_json`: it takes that text (or any JSON of the
same shape) and returns a list of `Transaction` objects, so `transactions_from_json(transactions_to_json(txs))
== list(txs)` for transactions whose tags are already sorted and unrepeated. The result holds:

- `date` parsed from `YYYY-MM-DD`, `payee`, and `postings` (each a `Posting` with its `account`, an `amount`
  that is a `Money` built from the money object, or `None` for `null`, and its `note`);
- `id`: the number, or `None` for `null` or a missing key; `flag`: the text, `*` when missing; `narration` and a
  posting's `note`: the text, empty when missing; `tags`: a tuple of the tags, sorted, each once, empty when
  missing.

`date`, `payee` and `postings` (a list, may be empty) are required. Everything else wrong is an `ExportError`.
Its message starts with where it happened, `transaction 2` (counting from 1) or `transaction 2 posting 1` (a
problem with the text as a whole has no position): the text is not JSON, the JSON is not an array, an item is not
an object, a key the format does not know (in a transaction or a posting), a `date` that is not a real
`YYYY-MM-DD` date, an `id` that is not `null` or a whole number of at least 1 (a boolean is not a number), a
`flag` other than `*` or `!`, `payee`, `narration` or a `note` that is not text, `tags` that are not a list of
text, a posting whose `account` is missing or is not text, an amount that is neither `null` nor an object with
exactly the keys `amount` and `currency` (both text) that make valid money (`"4.505"` for USD, an unknown
currency code and similar are errors). The empty array gives `[]`.

## The book file: `tallybook.storage`

The whole book lives in one SQLite file (Python's `sqlite3`) that I can copy, back up and mail to my accountant. A class `Store` sits under the command line and the web API, and I use it from scripts: `from tallybook.storage import Store, LATEST_VERSION`; `LATEST_VERSION` is `4`. Old books of mine (made by earlier versions, and by hand) must keep working, so this section says exactly what the file looks like; I will build such files with `sqlite3` and open them with your code.

### Opening and creating

`Store.open(path, create=False)` returns a `Store`; `path` is text or a path object.

| Situation | Result |
|---|---|
| file missing, `create=False` | `NotFoundError` |
| file missing, `create=True` | created and brought to `LATEST_VERSION`; a missing parent directory is a `NotFoundError` |
| file exists, `create=True` | opened as is: nothing erased, nothing migrated (but see the empty file below) |
| not a SQLite file (a text file, say), or a directory | `ConflictError` |
| a SQLite file with tables but no version marker (somebody else's database) | `ConflictError` |
| a book whose version is higher than `LATEST_VERSION` | `ConflictError`, nothing touched |
| an empty SQLite file (zero bytes) | opens at version 0; with `create=True` it is migrated to the latest version |

A `Store` is a context manager (leaving the block closes it) and has `close()`; afterwards every operation raises `ConflictError`. Several `Store` objects may read the same file at once; a writer waits up to five seconds for another writer, then fails with `ConflictError`.

### The version and the migrations

The schema version is SQLite's `PRAGMA user_version`; `store.version` reports it. Opening an older book does **not** change it: `store.version` is smaller than `LATEST_VERSION`, and every operation except `version`, `migrate()` and `close()` raises `ConflictError` with the message ``database is at version 2, run `tallybook db migrate` `` (the real number). `store.migrate()` applies the missing steps in order and returns the versions it applied (`[3, 4]`; `[]` when current). Each step runs in its own transaction together with its version bump, so a failing step leaves the file exactly at the version before it (earlier steps stay applied) and `migrate()` raises `ConflictError` with a message starting `migration to version N failed:`. There are no down-migrations and no other bookkeeping table.

Dates are stored as `YYYY-MM-DD` text, money as an integer count of minor units plus a currency code. Table and column names are exact.

**Version 1** (the first release)

```sql
CREATE TABLE accounts (path TEXT PRIMARY KEY, type TEXT NOT NULL, currency TEXT, opened TEXT,
                       note TEXT NOT NULL DEFAULT '');
CREATE TABLE transactions (id INTEGER PRIMARY KEY AUTOINCREMENT, date TEXT NOT NULL, payee TEXT NOT NULL,
                           narration TEXT NOT NULL DEFAULT '', cleared INTEGER NOT NULL DEFAULT 1);
CREATE TABLE postings (id INTEGER PRIMARY KEY AUTOINCREMENT,
                       tx_id INTEGER NOT NULL REFERENCES transactions(id) ON DELETE CASCADE,
                       seq INTEGER NOT NULL, account TEXT NOT NULL REFERENCES accounts(path),
                       minor INTEGER NOT NULL, currency TEXT NOT NULL);
```

(plus indexes on `transactions(date, id)` and `postings(tx_id, seq)`, which a hand-built file may lack). `accounts.currency` was free text: lower-case, padded with blanks, or empty. `cleared` is 1 (cleared) or 0 (pending). The postings of a transaction are numbered by `seq` from 0.

**Version 2** adds `tags`, `transactions.flag` and `postings.note`:

```sql
CREATE TABLE tags (tx_id INTEGER NOT NULL REFERENCES transactions(id) ON DELETE CASCADE, tag TEXT NOT NULL,
                   PRIMARY KEY (tx_id, tag));
ALTER TABLE transactions ADD COLUMN flag TEXT NOT NULL DEFAULT '*';
ALTER TABLE postings ADD COLUMN note TEXT NOT NULL DEFAULT '';
```

The step turns `cleared` into the flag: 1 becomes `'*'`, 0 becomes `'!'`; a `cleared` that is not 0 or 1 (or is NULL) makes the step fail and change nothing. The `cleared` column stays; from version 2 on the store keeps it `1` for flag `*` and `0` for `!`, but never reads it. Existing postings get the empty note; no existing transaction gets tags.

**Version 3** adds `rates` and `accounts.closed`:

```sql
CREATE TABLE rates (src TEXT NOT NULL, dst TEXT NOT NULL, on_date TEXT NOT NULL, rate_text TEXT NOT NULL,
                    PRIMARY KEY (src, dst, on_date));
ALTER TABLE accounts ADD COLUMN closed TEXT;
```

The step cleans `accounts.currency` and `postings.currency`: trim blanks, upper-case. An account currency empty after trimming becomes NULL. Anything else that is not exactly three letters after cleaning (`dollars`) makes the step fail and change nothing; so does an empty posting currency. Existing accounts get `closed` NULL.

**Version 4** adds five empty tables and touches no existing row:

```sql
CREATE TABLE budgets (pattern TEXT NOT NULL, period_kind TEXT NOT NULL, minor INTEGER NOT NULL,
                      currency TEXT NOT NULL, start_date TEXT NOT NULL, PRIMARY KEY (pattern, period_kind));
CREATE TABLE recurring (name TEXT PRIMARY KEY, schedule TEXT NOT NULL, template TEXT NOT NULL,
                        start_date TEXT NOT NULL, end_date TEXT, max_count INTEGER, materialized_through TEXT);
CREATE TABLE rules (id INTEGER PRIMARY KEY CHECK (id = 1), body TEXT NOT NULL);
CREATE TABLE settings (key TEXT PRIMARY KEY, value TEXT NOT NULL);
CREATE TABLE import_keys (key TEXT PRIMARY KEY, tx_id INTEGER NOT NULL REFERENCES transactions(id) ON DELETE CASCADE);
```

A step that cannot create its tables (one of that name already exists, say) fails and changes nothing. A book created from nothing goes through all four steps, so it ends up exactly like a migrated one. Foreign keys are enforced, but deleting a transaction must also remove its postings, tags and import key in a book whose old tables lack the cascades.

### Accounts

Accounts are validated by `Chart.add`, so the same errors arise (invalid path, wrong type, unknown currency, existing path).

- `add_account(path, type=None, currency=None, opened=None, note="") -> Account` stores it and returns the stored `Account`; `get_account(path) -> Account` (`NotFoundError`).
- `accounts(type=None, under=None, currency=None, include_closed=True) -> list[Account]` sorted by path. `type` is `asset`, `liability`, `equity`, `income` or `expense` (else `ValidationError`); `under` keeps that account and everything below it; `currency` keeps accounts of that currency; `include_closed=False` drops closed ones. Only accounts that were added are listed, not parents that merely exist as part of a longer path.
- `count_accounts(...)`: the same filters, returns a number.
- `chart() -> Chart`: a fresh in-memory chart of the stored accounts, closed ones closed.
- `close_account(path, on) -> Account` closes the account as of `on` (usable that day). `NotFoundError` for an unknown account; closing twice or before the opening date is the chart's error; closing earlier than a posting already in the account is a `ConflictError`.
- `set_account_note(path, note) -> Account`; `delete_account(path)` removes an account nothing has posted to (`ConflictError` otherwise, `NotFoundError` if unknown).

### Transactions

- `add_transaction(tx) -> Transaction` (the shared record) validates through a `Ledger` over the stored chart and rates, so the ledger's rules and `LedgerError` apply. Nothing is stored on failure. The result has its `id`, filled-in amounts, and tags sorted without duplicates. An `id` on the input is ignored. Ids are 1, 2, 3 ... and never handed out again, even after the highest was deleted.
- `transactions(query=None, limit=None, offset=0) -> list` in order of `(date, id)`. `query` is query text or a parsed `Query` (an `account:` pattern in query text that matches no account of the book is a `QueryError`); blank or `None` means everything. The filter comes first, then `offset` are skipped, then at most `limit` are returned. `limit` and `offset` are whole numbers of at least 0, else `ValidationError`; only `limit` may be `None` (unlimited).
- `count_transactions(query=None) -> int` counts what `transactions(query)` returns without paging; `has_import_key(key) -> bool`.
- `get_transaction(id)` (`NotFoundError`); `delete_transaction(id) -> Transaction` removes it with its postings, tags and import key and returns what was removed (`NotFoundError` if absent).
- `ledger() -> Ledger`: an in-memory ledger of the whole book (stored ids kept); changing it does not change the book.
- `add_transactions(txs, keys=None) -> BulkAdd` adds many, all or nothing; the result has `.added` (the stored transactions) and `.skipped` (the input positions skipped). `keys` is one text per transaction (else `ValidationError`); a transaction whose key is already an import key, or was recorded earlier in the same call, is skipped; the key of each added one is recorded. If any transaction is invalid nothing at all is added, and the error (otherwise the ledger's own) has a `.detail` dictionary with `"index"`, the position of the bad one.

### Rates, budgets, recurring items

- Rates: `set_rate(src, dst, rate_text, on)` (checked by `RateTable.set`; the same pair and day replaces; the text is kept as given), `remove_rate(src, dst, on)` (`NotFoundError`), `rate_rows() -> [(src, dst, date, rate_text)]` sorted, `rate_table() -> RateTable`.
- Budgets: `add_budget(budget)`, `remove_budget(pattern, period_kind)`, `budgets() -> list[Budget]` sorted by pattern, then period kind. There is one budget per pattern and period kind: adding the pair again is a `ConflictError`; removing a missing one a `NotFoundError`.
- Recurring: `add_recurring(rec)` takes a `Recurring` (name unique, else `ConflictError`) and does not check its accounts against the book; the schedule is stored as its canonical text (`str(schedule)`), the template as JSON. `remove_recurring(name)` (`NotFoundError`; transactions already made stay). `recurring() -> list[Recurring]` sorted by name, each equal to what was added. `materialized_through(name) -> date or None` (`NotFoundError` for an unknown name).
- `materialize(upto=None, today=None) -> list[Transaction]` turns the occurrences of every stored series into real transactions. The horizon is `upto`, or `today` if `upto` is missing, or the earlier of the two when both are given; with neither it is a `ValidationError`. A series is materialized from its start through the horizon, but never again for days already covered: each series remembers the horizon of its last run in `materialized_through` (it only moves forward). So the same horizon twice returns `[]` the second time, and a later horizon yields only the new days. Transactions are made with the `recurring` module's `instantiate` (so they carry the tag `recurring`), added in date order (ties by series name) through the validation of `add_transaction`, and returned with ids. If any one is invalid, nothing is stored and no series advances.

### Rules, settings, profiles

- `set_rules(text)` validates with `parse_rules` (its error surfaces, nothing changes) and replaces the stored rules, text kept as given. `rules_text() -> str` (empty when never set), `rules() -> RuleSet`.
- `get_setting(key, default=None)`, `set_setting(key, value)` (non-empty text key, text value; anything else `ValidationError`), `delete_setting(key)` (a missing key is fine), `settings() -> dict` sorted by key. The last value set for a key wins.
- Import profiles are kept as settings named `profile.NAME`: `set_profile(name, text)` (name `[A-Za-z0-9][A-Za-z0-9_-]*`, else `ValidationError`; text checked by `parse_profile`), `profile_text(name)` (`NotFoundError`), `profiles() -> sorted names`, `remove_profile(name)` (`NotFoundError`).

### CSV import and journals

`import_csv(text, profile, apply_rules=True) -> ImportOutcome` imports a bank CSV. `profile` is a stored profile name, profile text, or an `ImportProfile`; a string made only of characters allowed in a profile name is a name (`NotFoundError` if none is stored). The stored rules are applied unless `apply_rules=False`; rows the book already has count as duplicates (the `csvimport` rule, run against the stored transactions). The outcome has `.added` (stored transactions), `.duplicates` and `.errors`; if any row has an error nothing is stored and `.added` is empty. Each imported transaction records an import key like `2024-03-01|Shop|Assets:Bank|-500 USD|1` (date, payee, account and amount of its first posting in minor units, then `n`, counting identical rows within the file from 1), so importing the same rows twice never doubles them while two identical rows within one file stay two transactions; deleting a transaction frees its key.

`journal() -> Journal` returns the whole book (accounts, rates as `(src, dst, date, rate_text)`, transactions). `load_journal(journal) -> list[Transaction]` adds a journal's accounts (with their opening and closing dates), rates and transactions all-or-nothing; an account that already exists is an error.

### Health, backup, status

`check() -> list[str]` looks for damage the store itself never causes (a hand-edited or half-copied file) and returns a sorted list of readable problems, empty when the book is sound: a failing SQLite integrity check, postings, tags or import keys pointing to a missing transaction, a transaction without postings, postings on an account that is not stored, a transaction whose postings do not sum to zero in some currency. `backup(dest)` copies the whole book, consistently, into the new file `dest` while the book stays open; an existing `dest` is a `ConflictError` and is left untouched, a missing directory a `NotFoundError`.

`info() -> dict` has `path` (as given to `open`), `version` and the row counts `accounts`, `transactions`, `postings`, `rates`, `budgets`, `recurring`.

## The command line

What I touch every day is a program: one command, `tallybook`, that works on a book file and prints plain text I can read, or JSON I can pipe. `python -m tallybook` is exactly the same program. The code lives in the package `tallybook.cli`; `from tallybook.cli.main import main` gives me `main(argv=None) -> int`, which runs one command line (`argv` is the arguments *without* the program name, default `sys.argv[1:]`) and returns the exit status.

The command line is a thin skin over the library: where an earlier section says what a thing means (what a posting must satisfy, how a period is written, how a query reads) the command uses it unchanged, and a library error becomes the command's error message. This section says exactly what I type and what I get back, because my scripts read it.

### The shape of a command line

```
tallybook [--db FILE] [--today DATE] COMMAND [WORD] [ARGUMENTS and --options]
```

| Global option | Meaning |
|---|---|
| `--db FILE` | the book file. Default: `TALLYBOOK_DB` if set and not empty, else `tallybook.db` in the current directory. |
| `--today DATE` | what "today" is. Default: the real date. Everything that needs "today", and only that, uses it. A malformed date is exit 1 before anything after it is looked at. |
| `--version` | prints `tallybook 1.0.0` and stops, exit 0. |
| `-h`, `--help` | prints usage on standard output and stops, exit 0. The text starts with `usage: tallybook` and names every command. `tallybook COMMAND [WORD] --help` prints that command's usage, starting `usage: tallybook COMMAND ...`; `tallybook GROUP --help` (`account`, say) lists its words. |

The global options come first, read from left to right (each at most once); after the command's own words they are no longer recognised. A command is one word (`init`) or a group word and a subcommand (`account add`); `calc` has up to three words (`calc money parse`).

How a command's own arguments are read:

- `--name value` and `--name=value` both work. An option that takes a value takes the *next* argument as its value, whatever it looks like (`--note -5` is fine; so is an empty `--note ""`). A flag (`--json`) takes no value and `--json=1` is a mistake. `--` ends the options: everything after it is a plain argument.
- The only one-dash options are `-h` (help) and `-p` (the same as `--posting`). Every other argument that begins with a single dash (`-5`, `-`, `-1/3`, `-5.00 USD`) is an ordinary value, so negative amounts need no quoting tricks. A lone `-` means standard input where a file is expected.
- Options and plain arguments may be mixed in any order. Names are exact (no abbreviations). An option may be given once, except `--tag` and `--posting`/`-p`, which repeat.
- In the usage lines of this section `[ ]` marks what is optional and `...` what may repeat; an option shown without brackets is required.
- Amounts with their currency are **one** argument: `"12.50 USD"`. Dates are `YYYY-MM-DD`; periods are the forms of the dates section (`2024-03`, `2024-Q1`, `2024`, `2024-03-01..2024-03-31`).

**Exit status and messages.** 0 means done. 1 means the program refused: one line `tallybook: <message>` on standard error and **nothing at all** on standard output. 2 means the command line itself is wrong: an unknown command or word, a group without its word, an unknown option, an option missing its value, a missing required option, a missing or surplus plain argument, an option given twice, a flag given a value, no command at all. The message goes to standard error, starts `tallybook: ` and is followed by a second line `Try 'tallybook --help'.`; again nothing on standard output. Such mistakes are found before any file or book is touched. *Everything else is exit 1*, in particular every wrong value (a malformed date, amount, path, number, period; a file that cannot be read or is not UTF-8 text) and every library error; the message after `tallybook: ` is the library's own wherever there is one. There is never a traceback. If whatever reads my output stops early (`tallybook tx list | head -1`) the program ends quietly with status 0.

**Output.** As everywhere: UTF-8, `\n` line ends, no trailing spaces, one final newline. A table is drawn by `render_table` (export section). The listing commands take `--json` and print the usual JSON document; an empty list is `[]` with `--json` and no output at all without. A transaction in JSON is the object of the export section.

**Whole numbers** in arguments (`--limit`, `--offset`, `--count`, `--port`, transaction ids, the numbers of `calc`) are decimal digits, optionally preceded by `-` where a negative number makes sense, at most 18 digits. Anything else (`+5`, `1.5`, `1e3`, `abc`, `""`) is exit 1. Counted words in messages are always plural (`1 rules`, `1 transactions`, `0 duplicates`).

**The book.** Every command except `init`, the help and version options, and everything under `calc` works on the book file. A missing file is exit 1 with ``no such database: FILE (run `tallybook init`)``; a book of an older schema is exit 1 with the storage section's ``database is at version 2, run `tallybook db migrate` ``. Every command that changes the book is all or nothing.

### Creating and checking the book

| Command | What it does and prints |
|---|---|
| `init` | creates the book if there is none and prints `created FILE (version 4)` (FILE exactly as given with `--db` or in `TALLYBOOK_DB`, else `tallybook.db`). An older book is migrated: `migrated FILE from version 2 to 4`; a current one: `FILE is up to date (version 4)`. A file that is not a book is exit 1 and untouched. |
| `db version` | prints the schema version number, e.g. `4`. Works on an old book too. |
| `db migrate` | migrates and prints one line `applied version 3` per step, or `database is up to date (version 4)`. |
| `db info` | the lines `path: ...`, `version: 4`, `accounts: N`, `transactions: N`, `postings: N`, `rates: N`, `budgets: N`, `recurring: N` in that order; `--json` the same as one object. |
| `db check` | `ok` when the book is sound; otherwise the problems of `check()`, one per line, with exit status 1 (the one failure that also prints on standard output). |
| `db backup DEST` | copies the book to the new file `DEST` and prints `backed up to DEST`. |
| `serve [--host HOST] [--port N]` | serves the book over HTTP (next section) until SIGTERM or SIGINT, then exits 0. Defaults `127.0.0.1` and `8765`; `--port 0` picks a free port; the largest is 65535. The server prints its own first line. The book is checked first, so a missing book or an old schema fails as above before anything is served. |

### Accounts

| Command | Meaning |
|---|---|
| `account add PATH [--currency CUR] [--open DATE] [--note TEXT]` | adds the account (the chart's rules apply) and prints `added account PATH`. |
| `account list [--type TYPE] [--under PATH] [--currency CUR] [--open-only] [--json]` | the storage section's `accounts()`, closed ones included unless `--open-only`. Table columns `Account Type Currency Opened Closed Note`, all left aligned, empty where there is nothing. JSON: a list of `{"path", "type", "currency", "opened", "closed", "note"}` (`null` for what is missing). |
| `account show PATH [--json]` | the lines `path: ...`, `type: ...`, `currency: USD` (`any` when none), `opened: DATE` (`none`), `closed: DATE` (`none`), `note: ...` (just `note:` when empty), and `balance: 957.50 USD` (several currencies separated by `, `, in order of currency code; `none` when the balance is zero or empty). The balance counts the account and everything below it, over every posting. JSON: the object of `account list` plus `"balance"`, a list of money in order of currency code. |
| `account close PATH [--on DATE]` | closes the account as of the date (default: today) and prints `closed account PATH on DATE`. |

### Transactions

A posting on the command line is **one** argument, in the shape of a journal posting: `ACCOUNT`, or `ACCOUNT AMOUNT CURRENCY`, optionally followed by `; a note`. The note starts at the first `;` (blank before it or not) and is trimmed; white space between the other parts does not matter. Anything else is exit 1.

| Command | Meaning |
|---|---|
| `tx add PAYEE [--date DATE] [--narration TEXT] [--flag F] [--tag TAG]... [-p POSTING]... [--json]` | adds a transaction through the store (the ledger's rules apply); date defaults to today, flag to `*`. Prints `added transaction 7` (the id), or with `--json` the stored transaction. |
| `tx list [--query QUERY] [--limit N] [--offset N] [--json]` | the transactions in order of date and id, filtered by the query, then offset, then limited (the storage rules). Table `Id Date Flag Payee Narration Tags`, `Id` right aligned, the rest left, tags written `#food #lunch` (sorted). JSON: the list of transaction objects. |
| `tx show ID [--json]` | prints `; id 7` and then the transaction exactly as the journal writer writes it (`format_transaction`). JSON: the object. |
| `tx delete ID` | deletes it and prints `deleted transaction 7`. An unknown id is exit 1. |
| `query QUERY [--limit N] [--offset N] [--json] [--count]` | the listing of `tx list --query`, the query being a required plain argument; `--count` prints only how many transactions match (`3`), ignoring limit and offset. |
| `export [--format csv\|json\|journal] [--query QUERY]` | the transactions (those matching the query, if given) as `transactions_to_csv` (the default) or `transactions_to_json`; `journal` prints the *whole* book as journal text and refuses `--query`. Any other format is exit 1. |
| `journal export` | the whole book as journal text (accounts, rates, transactions), same as `export --format journal`. |
| `journal import FILE` | reads a journal file (`-` is standard input), checks its writing (`FILE: line 3: ...`, FILE being `standard input` for `-`) and adds its accounts, rates and transactions, all or nothing. Prints `imported 3 accounts, 1 rates, 12 transactions` (what the file held). |

Example:

```
$ tallybook --db b.db tx add Market --date 2024-03-02 --tag food -p "Expenses:Food 42.50 USD ; veg" -p Assets:Bank
added transaction 2
$ tallybook --db b.db tx list
Id  Date        Flag  Payee   Narration  Tags
--  ----------  ----  ------  ---------  -----
 1  2024-01-01  *     Opening
 2  2024-03-02  *     Market             #food
$ tallybook --db b.db tx show 2
; id 2
2024-03-02 * "Market" #food
  Expenses:Food   42.50 USD  ; veg
  Assets:Bank    -42.50 USD
```

### Bank statements, profiles and rules

| Command | Meaning |
|---|---|
| `import FILE (--profile NAME \| --profile-file FILE) [--no-rules]` | imports a bank CSV (`-` is standard input) with the stored profile `NAME` or the profile in a file, as the storage section's `import_csv` does (stored rules applied unless `--no-rules`). Neither or both profile options: exit 2. Prints `imported 5 transactions, 2 duplicates`. If any row is bad nothing is imported: exit 1 with the line `tallybook: 2 rows could not be imported, nothing was imported` on standard error, followed by one line `row 7: <message>` per bad row. |
| `profile add NAME FILE` | stores the profile in `FILE` (checked) under `NAME`; prints `stored profile NAME`. |
| `profile list [--json]` | the stored names, one per line, sorted (JSON: a list of names). |
| `profile show NAME` | prints the stored text (a final newline added when it lacks one). |
| `profile remove NAME` | removes it; prints `removed profile NAME`. |
| `rules set FILE` | stores the rules in `FILE` (checked; `-` is standard input) and prints `stored 3 rules`. |
| `rules show` | prints the stored rules text (final newline added if missing; nothing when there are none). |

### Rates, budgets, recurring entries

| Command | Meaning |
|---|---|
| `rate set FROM TO RATE [--on DATE]` | records the rate (date defaults to today) and prints `set 1 USD = 0.92 EUR on 2024-03-01`. |
| `rate list [--json]` | table `From To Date Rate`, aligned `lllr`, in the order of the storage section's `rate_rows()`, the rate text as it was set. JSON: `{"from", "to", "date", "rate"}` objects. |
| `rate remove FROM TO [--on DATE]` | removes that day's rate (default today); prints `removed rate USD -> EUR on 2024-03-01`. |
| `budget add PATTERN AMOUNT [--per KIND] [--start DATE]` | `AMOUNT` is money in one argument, `KIND` is `month` (default), `quarter` or `year`, `--start` defaults to today. Prints `added budget Expenses:Food 400.00 USD per month`. |
| `budget list [--json]` | table `Pattern Per Amount Start`, aligned `llrl`. JSON: `{"pattern", "period_kind", "amount", "start"}` objects. |
| `budget remove PATTERN [--per KIND]` | prints `removed budget PATTERN per month`. |
| `budget status [--period PERIOD] [--json]` | the `budget_status` lines for the period (default: the calendar month containing today) as a table `Pattern Per Budget Actual Remaining Percent Over`, aligned `llrrrrl`: money as `400.00 USD`, the percent with a `%` (`82.5%`), and `over` in the last column for an overspent budget (else empty). JSON: the `to_dict()` of each line. |
| `recurring add NAME SCHEDULE PAYEE [--start DATE] [--end DATE] [--count N] [--narration TEXT] [--flag F] [--tag TAG]... [-p POSTING]...` | the template is built like `tx add`'s transaction; `--start` defaults to today. Nothing is checked against the book until the item produces transactions. Prints `added recurring NAME`. |
| `recurring list [--json]` | table `Name Schedule Start End Count Through Payee`, all left aligned (`Through` is the day it was last materialized through; the schedule in canonical text). JSON: objects `{"name", "schedule", "start", "end", "count", "materialized_through", "template": {"payee", "narration", "flag", "tags", "postings"}}`. |
| `recurring remove NAME` | prints `removed recurring NAME`. |
| `recurring materialize [--upto DATE] [--json]` | the storage section's `materialize` (without `--upto` the horizon is today); prints `created 2 transactions` (JSON: the list of them). |

### Reports

`report trial-balance [--as-of DATE]`, `report balance-sheet [--as-of DATE] [--convert CUR]`, `report income-statement [--period PERIOD] [--convert CUR]`, `report cashflow [--period PERIOD]` and `report register ACCOUNT [--period PERIOD] [--rollup]` run the reports of the reports section on the book and print `render_text(report)`, or with `--json` the report dict. Defaults: the trial balance takes every posting, the balance sheet is as of today, the income statement and the cash flow cover the calendar month containing today, the register lists everything. Report errors (unknown account, missing rate, ...) are exit 1.

### Taking the library for a walk: `calc`

Everything under `calc` works without a book: it ignores `--db`, and its output is decided by the arguments and files alone. I use it to try things and to check your arithmetic against mine, so the formats below are exact. In every one a wrong value or a library error is exit 1, a wrong command line exit 2, and a journal, profile, rules or statement file may be `-` for standard input.

**Money.** All amounts are written `AMOUNT CUR` in one argument.

| Command | Prints |
|---|---|
| `calc money parse MONEY` | the minor units and the code: `calc money parse "12.50 USD"` prints `1250 USD`. |
| `calc money format MINOR CUR` | `calc money format -5 USD` prints `-0.05 USD`. |
| `calc money add A B` / `calc money sub A B` | the sum / difference as `AMOUNT CUR` (different currencies are exit 1). |
| `calc money scale MONEY RATIO` | the amount times a ratio, `N` or `N/D` (whole numbers, either may be negative; `D` zero is exit 1), rounded as `Money.scale` does: `calc money scale "10.00 USD" 1/3` prints `3.33 USD`. |
| `calc money allocate MONEY W1 W2 ...` | the parts of `Money.allocate`, one `AMOUNT CUR` per line (at least one weight, else exit 2). |
| `calc money convert MONEY TO RATE` | converts at one rate (how many `TO` one unit buys; the rate text rules of the currency section), rounded as the rate table does: `calc money convert "10.00 USD" JPY 150.5` prints `1505 JPY`. Converting to its own currency is exit 1. |

**Dates.**

| Command | Prints |
|---|---|
| `calc date parse DATE` | the date and its weekday in English: `2024-03-01 Friday`. |
| `calc date add-months DATE N` | `add_months`, as `YYYY-MM-DD`; `N` may be negative. |
| `calc date period PERIOD` | five lines: `start: 2024-03-01`, `end: 2024-03-31`, `days: 31`, `label: 2024-03`, `next: 2024-04` (the following period's label; none inside the calendar: exit 1). |
| `calc date periods START END STEP` | the label of each period of `periods()` (`STEP` is `week`, `month`, `quarter` or `year`), one per line; more than 5000 periods is exit 1. |
| `calc schedule SCHEDULE --from D --to D [--start D] [--end D] [--count N]` | the dates a recurring item with that schedule has inside the window `--from` to `--to`, one per line: the series starts at `--start` (default `--from`), stops after `--end` and after `--count` dates, as `occurrences()` says. A `--to` before `--from` gives an empty window, not an error. If the span from the earlier of `--from` and `--start` to `--to` is longer than 40000 days, exit 1. |

**Accounts, rates, rules.**

| Command | Prints |
|---|---|
| `calc account check PATH` | for a valid path the lines `path: Assets:Bank`, `type: asset`, `parent: Assets` (`none` for a root); an invalid path is exit 1. |
| `calc account match PATTERN PATH` | `yes` or `no` (`path_matches`); a bad pattern is exit 1. |
| `calc rules FILE [--payee TEXT] [--narration TEXT] [--amount MONEY] [--date DATE]` | which rule of the rules file wins for those fields (a field I leave out is absent, as in `RuleSet.apply`): `no match`, or the lines `rule: 3` (its line number) and then, only for what it sets and in this order, `account: ...`, `payee: ...`, `narration: ...`, `flag: ...`, `tags: coffee,salary` (comma separated, no space); an empty value leaves just `narration:`. |

**Journal files.** `--journal FILE` (required where shown) is a journal as the journal section describes; its book is `parse_journal(text).to_ledger()`, so a journal that does not balance or posts to an undeclared account is exit 1 (`FILE: line N: ...` for a writing mistake).

| Command | Prints |
|---|---|
| `calc journal check FILE` | reads the file and checks it as a book: `ok: 7 accounts, 1 rates, 4 transactions`. |
| `calc journal format FILE` | the canonical text of `format_journal(parse_journal(text))`, without checking the book-keeping; the empty text for an empty file. |
| `calc query QUERY --journal FILE [--json]` | the journal book's transactions matching the query, in the listing format of `tx list` (ids 1, 2, ... in file order, as the ledger assigns them). An `account:` pattern matching no account of the journal is exit 1. |
| `calc rate FROM TO --journal FILE --on DATE` | the rate the journal's rates give, as `NUMERATOR/DENOMINATOR` of the exact fraction in lowest terms: `23/25`. No rate is exit 1. |
| `calc budget PATTERN AMOUNT --journal FILE --period PERIOD [--per KIND] [--start DATE]` | one budget measured over the period, printed as `budget status` prints (or `--json`); `--per` defaults to `month` and `--start` to the first day of the period. When the budget is not in force in the period nothing is printed (`[]` with `--json`). |
| `calc report KIND [ACCOUNT] --journal FILE [--as-of DATE] [--period PERIOD] [--convert CUR] [--rollup] [--json]` | the report `KIND` (`trial-balance`, `balance-sheet`, `income-statement`, `cashflow`, `register`) of the journal book, with the defaults and the text of the `report` commands. Options that do not belong to the kind are ignored. `ACCOUNT` is required for `register` (else exit 2) and ignored otherwise; an unknown `KIND` is exit 2. |
| `calc csv PROFILE_FILE CSV_FILE [--rules FILE]` | what importing the statement would produce, as `format_journal` of a journal holding only the new transactions (the empty text for a statement without rows). Rows are read as the CSV section says, without any book (so no duplicates); a bad row is exit 1 with `row N: message` lines on standard error. |

A statement turned into journal text (profile `date_column = Date`, `payee_column = Payee`, `amount_column = Amount`, `currency = USD`, `account = Assets:Bank`, `default_account = Expenses:Misc`; statement `Date,Payee,Amount` / `2024-03-01,Shop,-5.00`):

```
$ tallybook calc csv profile.txt statement.csv
2024-03-01 * "Shop"
  Assets:Bank    -5.00 USD
  Expenses:Misc   5.00 USD
```

## The web API

I want to reach my book from other programs (a spreadsheet macro, a phone shortcut, a little dashboard) without them knowing about SQLite: a small web server on the same book file as the command line, speaking JSON over HTTP. It is for my own machine: no passwords, no TLS, no web pages, standard library only (`http.server`).

From the shell it is `tallybook --db book.db serve --port 8080`. The function behind it is `from tallybook.api.server import serve`, `serve(db_path, host="127.0.0.1", port=0, today=None)`; port 0 means any free port.

### Starting and stopping

- Before anything is printed `serve` opens the book once and checks it as every command does: a missing file, a file that is not a tallybook book, or a book needing `db migrate` raises the storage module's error and no server is started.
- Once it listens, `serve` prints exactly one line on standard output, flushed: `tallybook listening on http://127.0.0.1:PORT` with the real port (also when `port` was 0). Nothing else is ever printed on standard output (no access log), and a request answered with an error prints nothing anywhere (no log line, no traceback).
- It serves until SIGINT or SIGTERM, then closes the socket; `serve` returns 0 and the command exits with status 0, without a traceback.
- Every request is answered in its own thread and opens the book for itself, so several requests at once are fine and the file is not held open between requests. Two writers at once are serialised by the storage layer. Whatever is written is committed before the answer is sent.
- `today` (a `datetime.date`; the command line's `--today`) is what "today" means to the two requests that need it, named below; `None` is the real date.

### What a request and an answer look like

- Every answer has a `Content-Length`, and the connection is closed after it. JSON answers are UTF-8 with `Content-Type: application/json; charset=utf-8`, written as everywhere in tallybook (`json.dumps(obj, indent=2, sort_keys=True, ensure_ascii=False)` plus one newline). The few text answers (reports with `format=text`, the journal and CSV exports) have `Content-Type: text/plain; charset=utf-8`, or `text/csv; charset=utf-8` for CSV. Money is `{"amount": "12.50", "currency": "USD"}`, dates are `"YYYY-MM-DD"`, a transaction is the shape of the Export section (`id`, `date`, `flag`, `payee`, `narration`, `tags` sorted, `postings` of `account`, `amount`, `note`). An answer to `HEAD` has no body.
- **Paths.** The path is split at `/` and every piece is percent-decoded on its own, so an account path can be written `/accounts/Assets:Bank:Checking` or `/accounts/Assets%3ABank%3AChecking` (`%2F` is part of a piece, not a separator). Paths are case sensitive. A trailing slash or an empty piece (`/accounts/`, `/transactions//1`) makes the path unknown. Nothing after a `#` counts.
- **Query string.** `?name=value&name2=value2`, percent-decoded, `+` is a space. A name given twice: the last counts. An empty value (`?q=`) is given, as the empty text. Names the request does not use are ignored. A yes/no parameter takes `true`, `false`, `yes`, `no`, `1` or `0`, in any case; anything else is an error.
- **Bodies.** `POST` and `PUT` send a JSON object, UTF-8, with `Content-Type: application/json` (a parameter such as `charset` after a semicolon is fine, the type is not case sensitive). An empty body counts as `{}`. An unknown field (`unknown field: colour`), a missing required field and a field of the wrong type are errors; an optional field given as `null` is the same as not given. The body of a `GET` or `DELETE` is ignored; `DELETE` says what to delete in the query string, and all its parameters are required.
- **Amounts** that I send (in a posting, a budget) are either the object `{"amount": "12.50", "currency": "USD"}` (exactly these two text fields) or the text `"12.50 USD"`, read as `Money.of` and `Money.parse` do. A posting may leave `amount` out (or `null`); it is then worked out as in the ledger.
- **Whole numbers in the query** (`limit`, `offset`) are plain digits, 0 up to 9223372036854775807; anything else (`-1`, `2.5`, `ten`, a sign, the empty text) is an error.

### Mistakes: status codes and the error body

An error answer has an HTTP status and a JSON body `{"error": "<message>"}`; I rely on the message only being non-empty text. The status:

| what went wrong | status |
|---|---|
| a `parse` or `validation` error (see below) | 400 |
| a `not_found` error: no such account, transaction, rate, budget, recurring item, profile, or a missing book file | 404 |
| a `conflict` error: duplicates, a book file busy for more than five seconds, closing an account that has later postings | 409 |
| a path that does not exist | 404 |
| a path that exists but not with this verb (`DELETE /health`, `PATCH /accounts`, `HEAD`, `OPTIONS`...) | 405, with `Allow:` listing that path's verbs in alphabetical order joined by `, ` (`GET, POST`) |
| a body over 1 MiB (1048576 bytes; exactly that is fine) | 413 (the client must still get its answer although it sent the whole body) |
| a non-empty body on a `POST` or `PUT` of a type the request does not take (no type counts as wrong) | 415 |
| a `Content-Length` that is not a whole number, or a request line the server cannot read | 400 |

The checks are made in this order and the first problem found is the answer: the path (404), the verb (405), the body length (413) and type (415), whether the body is JSON, and only then the book and the library. A request is never half done: when an error is answered nothing was changed.

The kind of error is the library's. A date that is not `YYYY-MM-DD` is a `DateError` (parse), a period, query, rules file or schedule that does not read is that module's error, an amount that does not parse is a `MoneyError` (validation), a transaction the ledger refuses is a `LedgerError` (validation), a duplicate account, budget or recurring name is a conflict, and so on as the library sections say. What the API checks itself is the shape of the request: a body that is not valid UTF-8 or not valid JSON is a parse error; a body that is JSON but not an object, a missing, unknown or wrongly typed field, a missing or unusable query parameter and an unknown `format` are validation errors. A wrong `count` or name is whatever the recurring module says.

### Overview

| path | verbs |
|---|---|
| `/health`, `/accounts/<path>`, `/budgets/status`, `/export`, `/reports/trial-balance`, `/reports/balance-sheet`, `/reports/income-statement`, `/reports/cashflow`, `/reports/register` | `GET` |
| `/accounts`, `/transactions` | `GET`, `POST` |
| `/accounts/<path>/close`, `/recurring/materialize`, `/import` | `POST` |
| `/transactions/<id>` | `DELETE`, `GET` |
| `/rates` | `DELETE`, `GET`, `PUT` |
| `/budgets`, `/recurring` | `DELETE`, `GET`, `POST` |
| `/rules` | `GET`, `PUT` |

### Health

`GET /health` answers 200 `{"status": "ok", "version": "1.0.0", "schema_version": 4}`: the program version and the book's schema version (as `Store.version`).

### Accounts

An account is `{"path": "Assets:Bank:Checking", "type": "asset", "currency": "USD" or null, "opened": "2024-01-01" or null, "closed": "2024-06-30" or null, "note": ""}`.

- `GET /accounts` answers 200 with the accounts sorted by path, as `Store.accounts` returns them (only added accounts, not parents that merely exist as part of a longer path). Optional filters: `type` (`asset`, `liability`, `equity`, `income`, `expense`; another word is an error), `under` (that account and everything below it), `currency`, `include_closed` (yes/no, default yes).
- `POST /accounts` with `{"path": ..., "type": ..., "currency": ..., "opened": "2024-01-01", "note": ...}` (only `path` required) adds the account (`Chart.add`'s checks apply) and answers 201 with it. An existing path is a 409.
- `GET /accounts/<path>` answers 200 with the account; 404 when there is none (a parent that only exists as part of a longer path is no account).
- `POST /accounts/<path>/close` with `{"on": "2024-06-30"}` closes the account as of that day (`Store.close_account`) and answers 200 with the account. Without `on` it is today (the server's `today`, else the real date). 404 for an unknown account.

### Transactions

- `GET /transactions` lists transactions ordered by date and id. `q` is query text (left out or empty: everything), then `offset` (default 0) are skipped and at most `limit` kept (default: no limit). The answer is 200 `{"items": [transaction, ...], "total": N, "limit": L, "offset": O}`: `total` is how many transactions match `q` before paging, `limit` the number asked for or `null`, `offset` the offset used. A query that does not read is an error.
- `POST /transactions` with `{"date": "2024-03-01", "payee": "Acme", "narration": "", "flag": "*", "tags": ["a"], "postings": [{"account": "Assets:Cash", "amount": "-12.50 USD", "note": ""}, ...]}` (`date`, `payee`, `postings` required; `narration` defaults to the empty text, `flag` to `*`, `tags` to none, a posting's `note` to the empty text) adds it through the store and answers 201 with the stored transaction: its new `id`, tags sorted and unique, an omitted amount filled in. There is no `id` field to send. The ledger's rules apply and an invalid transaction stores nothing.
- `GET /transactions/<id>` answers 200 with the transaction. The id is digits only (leading zeros do not matter); anything else, and any number that is not a stored id, is a 404.
- `DELETE /transactions/<id>` removes it and answers 200 with the removed transaction (404 if absent).

### Rates

A rate is `{"src": "USD", "dst": "EUR", "date": "2024-03-01", "rate": "0.9200"}`; `rate` is the text as it was set.

- `GET /rates` answers 200 with the rates sorted by `src`, `dst`, `date`.
- `PUT /rates` with all four fields (`rate` must be text, checked as `RateTable.set` does) records the rate, replacing one of the same pair and day, and answers 200 with the rate.
- `DELETE /rates?src=USD&dst=EUR&date=2024-03-01` removes that rate and answers 200 with it; 404 if there is none.

### Budgets

A budget is `{"pattern": "Expenses:Food", "period_kind": "month", "amount": {money}, "start": "2024-01-01"}`.

- `GET /budgets` answers 200 with the budgets sorted by pattern, then period kind.
- `POST /budgets` with all four fields (the amount in either form) adds one and answers 201 with it; the budget module's checks apply. A second budget for the same pattern and period kind is a 409.
- `DELETE /budgets?pattern=Expenses:Food&period_kind=month` removes it and answers 200 with it; 404 if there is none.
- `GET /budgets/status?period=2024-03` (`period` required, read by `Period.parse`) answers 200 with the `BudgetLine.to_dict()` of each stored budget in force in that period (the others give no line), in the order `budget_status` returns them.

### Recurring items

A recurring item is `{"name": "rent", "schedule": "monthly on 1", "start": "2024-01-01", "end": null, "count": null, "template": {"payee": "Flat", "narration": "", "flag": "*", "tags": [], "postings": [{"account": ..., "amount": {money} or null, "note": ""}, ...]}}`. `schedule` is shown in its canonical text.

- `GET /recurring` answers 200 with the items sorted by name.
- `POST /recurring` with `name`, `schedule`, `start`, `template` (and optionally `end` and `count`) adds one and answers 201 with it. The template has `payee` and `postings` (required), `narration`, `flag`, `tags`, built like a transaction without a date (postings may leave out amounts; nothing is checked against the book until the item produces transactions). The recurring module's checks apply; an existing name is a 409.
- `DELETE /recurring?name=rent` removes the item (what it produced stays) and answers 200 with it; 404 if there is none.
- `POST /recurring/materialize` with `{"upto": "2024-06-30"}` (the field and the whole body are optional) runs `Store.materialize` and answers 200 `{"added": [transaction, ...]}` in the order the store made them. The horizon is `upto` and today, whichever is earlier (just today without `upto`), as the storage section says; a second run adds nothing (`{"added": []}`). If one is invalid, nothing is stored.

### Reports

`GET /reports/<name>` (`trial-balance`, `balance-sheet`, `income-statement`, `cashflow`, `register`) answers 200 with the report dict as the report section describes it, for the whole book. All take `format=json` (default) or `format=text` (`render_text` of the report as `text/plain; charset=utf-8`); any other format (and `format=` empty) is an error.

| report | parameters |
|---|---|
| `trial-balance` | `as_of` (a date; left out: all postings) |
| `balance-sheet` | `as_of` (a date; left out: all postings), `convert_to` (a currency code) |
| `income-statement` | `period` (required), `convert_to` |
| `cashflow` | `period` (required) |
| `register` | `account` (required), `period`, `rollup` (yes/no, default no) |

`period` is read by `Period.parse`. The rest is what the report functions do: a missing exchange rate or an unknown account in `register` is their `ReportError` or `CurrencyError` (validation), `balance-sheet` with `convert_to` but no `as_of` too. The server passes its `today` to `balance_sheet`, where it has no effect.

### Importing a bank file

`POST /import` adds the rows of a bank statement as `Store.import_csv` does (stored rules applied, rows I already have counted as duplicates, nothing stored if any row is bad). The statement comes in one of two ways:

- the CSV itself as the body with `Content-Type: text/csv` or `text/plain` (UTF-8), the profile in the query: `?profile=NAME` (required; a stored profile name or the text of a profile, as `Store.import_csv` understands it) and optionally `apply_rules` (yes/no, default yes);
- or a JSON body `{"csv": "<the file as text>", "profile": "<name or profile text>", "apply_rules": true}` with `Content-Type: application/json` (`csv` and `profile` required, `apply_rules` an optional JSON boolean); the query string is then ignored.

An empty body is the empty file. The answer is 200 `{"added": [transaction, ...], "duplicates": [transaction, ...]}` (duplicates are not stored: their `id` is `null`). If some rows are bad nothing is imported and the answer is a validation error whose message starts `import failed: ` followed by `row N: <message>` for each bad row, joined by `; `. An unknown stored profile is a 404; a profile or file the import module refuses is its parse error.

### Rules

`GET /rules` answers 200 `{"rules": "<the stored rules text, or the empty text>"}`. `PUT /rules` with `{"rules": "<text>"}` stores it as given (it must read as rules, else nothing changes and the rules module's error is the answer) and answers 200 with the same shape.

### Exporting

`GET /export?format=json|csv|journal` (default `json`, an empty `format=` is an error) answers 200 with the whole book's transactions as the export section writes them: `json` a JSON list of transactions, `csv` `transactions_to_csv` (`text/csv`), `journal` the whole book (accounts, rates, transactions) as `format_journal(Store.journal())` writes it (`text/plain`). Another format is an error.

