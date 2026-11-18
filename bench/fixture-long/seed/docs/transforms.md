# Transforms

`tabula apply FILE COLUMN TRANSFORM...` runs each transform, left to right, over every value of one column.
A transform is `name` or `name:ARG`; the argument is everything after the first colon.



## upper

The value in upper case.

- argument: none
- example: upper applied to '  Héllo, World 42 "x" ' gives '  HÉLLO, WORLD 42 "X" '.
- used as: `tabula apply FILE COLUMN upper`

## lower

The value in lower case.

- argument: none
- example: lower applied to '  Héllo, World 42 "x" ' gives '  héllo, world 42 "x" '.
- used as: `tabula apply FILE COLUMN lower`

## title

Each word capitalised.

- argument: none
- example: title applied to '  Héllo, World 42 "x" ' gives '  Héllo, World 42 "X" '.
- used as: `tabula apply FILE COLUMN title`

## capitalize

The first letter upper, the rest lower.

- argument: none
- example: capitalize applied to '  Héllo, World 42 "x" ' gives '  héllo, world 42 "x" '.
- used as: `tabula apply FILE COLUMN capitalize`

## swapcase

Upper and lower case swapped.

- argument: none
- example: swapcase applied to '  Héllo, World 42 "x" ' gives '  hÉLLO, wORLD 42 "X" '.
- used as: `tabula apply FILE COLUMN swapcase`

## strip

Without leading and trailing whitespace.

- argument: none
- example: strip applied to '  Héllo, World 42 "x" ' gives 'Héllo, World 42 "x"'.
- used as: `tabula apply FILE COLUMN strip`

## lstrip

Without leading whitespace.

- argument: none
- example: lstrip applied to '  Héllo, World 42 "x" ' gives 'Héllo, World 42 "x" '.
- used as: `tabula apply FILE COLUMN lstrip`

## rstrip

Without trailing whitespace.

- argument: none
- example: rstrip applied to '  Héllo, World 42 "x" ' gives '  Héllo, World 42 "x"'.
- used as: `tabula apply FILE COLUMN rstrip`

## reverse

The characters in reverse order.

- argument: none
- example: reverse applied to '  Héllo, World 42 "x" ' gives ' "x" 24 dlroW ,olléH  '.
- used as: `tabula apply FILE COLUMN reverse`

## squeeze

Runs of whitespace collapsed to one space.

- argument: none
- example: squeeze applied to '  Héllo, World 42 "x" ' gives 'Héllo, World 42 "x"'.
- used as: `tabula apply FILE COLUMN squeeze`

## nospace

All whitespace removed.

- argument: none
- example: nospace applied to '  Héllo, World 42 "x" ' gives 'Héllo,World42"x"'.
- used as: `tabula apply FILE COLUMN nospace`

## digits

Only the digits.

- argument: none
- example: digits applied to '  Héllo, World 42 "x" ' gives '42'.
- used as: `tabula apply FILE COLUMN digits`

## letters

Only the letters.

- argument: none
- example: letters applied to '  Héllo, World 42 "x" ' gives 'HélloWorldx'.
- used as: `tabula apply FILE COLUMN letters`

## alnum

Only letters and digits.

- argument: none
- example: alnum applied to '  Héllo, World 42 "x" ' gives 'HélloWorld42x'.
- used as: `tabula apply FILE COLUMN alnum`

## punct_free

Punctuation removed.

- argument: none
- example: punct_free applied to '  Héllo, World 42 "x" ' gives '  Héllo World 42 x '.
- used as: `tabula apply FILE COLUMN punct_free`

## slug

Lower case words joined by dashes.

- argument: none
- example: slug applied to '  Héllo, World 42 "x" ' gives 'h-llo-world-42-x'.
- used as: `tabula apply FILE COLUMN slug`

## snake

Lower case words joined by underscores.

- argument: none
- example: snake applied to '  Héllo, World 42 "x" ' gives 'h_llo_world_42_x'.
- used as: `tabula apply FILE COLUMN snake`

## kebab

Lower case words joined by dashes (same as slug).

- argument: none
- example: kebab applied to '  Héllo, World 42 "x" ' gives 'h-llo-world-42-x'.
- used as: `tabula apply FILE COLUMN kebab`

## camel

Words run together, each capitalised.

- argument: none
- example: camel applied to '  Héllo, World 42 "x" ' gives 'HLloWorld42X'.
- used as: `tabula apply FILE COLUMN camel`

## initials

The first letter of each word, upper case.

- argument: none
- example: initials applied to '  Héllo, World 42 "x" ' gives 'HW4"'.
- used as: `tabula apply FILE COLUMN initials`

## first_word

The first word.

- argument: none
- example: first_word applied to '  Héllo, World 42 "x" ' gives 'Héllo,'.
- used as: `tabula apply FILE COLUMN first_word`

## last_word

The last word.

- argument: none
- example: last_word applied to '  Héllo, World 42 "x" ' gives '"x"'.
- used as: `tabula apply FILE COLUMN last_word`

## length

The number of characters.

- argument: none
- example: length applied to '  Héllo, World 42 "x" ' gives '22'.
- used as: `tabula apply FILE COLUMN length`

## words

The number of words.

- argument: none
- example: words applied to '  Héllo, World 42 "x" ' gives '4'.
- used as: `tabula apply FILE COLUMN words`

## vowels

The number of vowels.

- argument: none
- example: vowels applied to '  Héllo, World 42 "x" ' gives '2'.
- used as: `tabula apply FILE COLUMN vowels`

## ascii_fold

Accents dropped, other non-ASCII removed.

- argument: none
- example: ascii_fold applied to '  Héllo, World 42 "x" ' gives '  Hello, World 42 "x" '.
- used as: `tabula apply FILE COLUMN ascii_fold`

## nfc

Composed Unicode form.

- argument: none
- example: nfc applied to '  Héllo, World 42 "x" ' gives '  Héllo, World 42 "x" '.
- used as: `tabula apply FILE COLUMN nfc`

## nfd

Decomposed Unicode form.

- argument: none
- example: nfd applied to '  Héllo, World 42 "x" ' gives '  Héllo, World 42 "x" '.
- used as: `tabula apply FILE COLUMN nfd`

## quote

Wrapped in double quotes, inner quotes doubled.

- argument: none
- example: quote applied to '  Héllo, World 42 "x" ' gives '"  Héllo, World 42 ""x"" "'.
- used as: `tabula apply FILE COLUMN quote`

## unquote

The quotes of a quoted value removed.

- argument: none
- example: unquote applied to '  Héllo, World 42 "x" ' gives '  Héllo, World 42 "x" '.
- used as: `tabula apply FILE COLUMN unquote`

## blank_to_dash

An empty value shown as a dash.

- argument: none
- example: blank_to_dash applied to '  Héllo, World 42 "x" ' gives '  Héllo, World 42 "x" '.
- used as: `tabula apply FILE COLUMN blank_to_dash`

## dash_to_blank

A lone dash shown as empty.

- argument: none
- example: dash_to_blank applied to '  Héllo, World 42 "x" ' gives '  Héllo, World 42 "x" '.
- used as: `tabula apply FILE COLUMN dash_to_blank`

## is_empty

Yes when the value is empty or blank.

- argument: none
- example: is_empty applied to '  Héllo, World 42 "x" ' gives 'no'.
- used as: `tabula apply FILE COLUMN is_empty`

## is_number

Yes when the value is a plain number.

- argument: none
- example: is_number applied to '  Héllo, World 42 "x" ' gives 'no'.
- used as: `tabula apply FILE COLUMN is_number`

## is_upper

Yes when every letter is upper case.

- argument: none
- example: is_upper applied to '  Héllo, World 42 "x" ' gives 'no'.
- used as: `tabula apply FILE COLUMN is_upper`

## hash_len

The number of UTF-8 bytes.

- argument: none
- example: hash_len applied to '  Héllo, World 42 "x" ' gives '23'.
- used as: `tabula apply FILE COLUMN hash_len`

## prefix

The argument put before the value.

- argument: text
- example: prefix:- applied to 'alpha-beta-gamma' gives '-alpha-beta-gamma'.
- used as: `tabula apply FILE COLUMN prefix:ARG`

## suffix

The argument put after the value.

- argument: text
- example: suffix:- applied to 'alpha-beta-gamma' gives 'alpha-beta-gamma-'.
- used as: `tabula apply FILE COLUMN suffix:ARG`

## wrap

The argument put on both sides.

- argument: text
- example: wrap:- applied to 'alpha-beta-gamma' gives '-alpha-beta-gamma-'.
- used as: `tabula apply FILE COLUMN wrap:ARG`

## remove

Every occurrence of the argument removed.

- argument: text
- example: remove:- applied to 'alpha-beta-gamma' gives 'alphabetagamma'.
- used as: `tabula apply FILE COLUMN remove:ARG`

## remove_chars

Every character that is in the argument removed.

- argument: text
- example: remove_chars:- applied to 'alpha-beta-gamma' gives 'alphabetagamma'.
- used as: `tabula apply FILE COLUMN remove_chars:ARG`

## keep_chars

Only the characters that are in the argument.

- argument: text
- example: keep_chars:- applied to 'alpha-beta-gamma' gives '--'.
- used as: `tabula apply FILE COLUMN keep_chars:ARG`

## default

The argument when the value is empty.

- argument: text
- example: default:- applied to 'alpha-beta-gamma' gives 'alpha-beta-gamma'.
- used as: `tabula apply FILE COLUMN default:ARG`

## strip_prefix

The argument removed from the start when present.

- argument: text
- example: strip_prefix:- applied to 'alpha-beta-gamma' gives 'alpha-beta-gamma'.
- used as: `tabula apply FILE COLUMN strip_prefix:ARG`

## strip_suffix

The argument removed from the end when present.

- argument: text
- example: strip_suffix:- applied to 'alpha-beta-gamma' gives 'alpha-beta-gamma'.
- used as: `tabula apply FILE COLUMN strip_suffix:ARG`

## before

The text before the first argument.

- argument: text
- example: before:- applied to 'alpha-beta-gamma' gives 'alpha'.
- used as: `tabula apply FILE COLUMN before:ARG`

## after

The text after the first argument.

- argument: text
- example: after:- applied to 'alpha-beta-gamma' gives 'beta-gamma'.
- used as: `tabula apply FILE COLUMN after:ARG`

## starts_with

Yes when the value starts with the argument.

- argument: text
- example: starts_with:- applied to 'alpha-beta-gamma' gives 'no'.
- used as: `tabula apply FILE COLUMN starts_with:ARG`

## ends_with

Yes when the value ends with the argument.

- argument: text
- example: ends_with:- applied to 'alpha-beta-gamma' gives 'no'.
- used as: `tabula apply FILE COLUMN ends_with:ARG`

## contains

Yes when the value contains the argument.

- argument: text
- example: contains:- applied to 'alpha-beta-gamma' gives 'yes'.
- used as: `tabula apply FILE COLUMN contains:ARG`

## icontains

Yes when it contains the argument, case aside.

- argument: text
- example: icontains:- applied to 'alpha-beta-gamma' gives 'yes'.
- used as: `tabula apply FILE COLUMN icontains:ARG`

## count_of

How many times the argument occurs.

- argument: text
- example: count_of:- applied to 'alpha-beta-gamma' gives '2'.
- used as: `tabula apply FILE COLUMN count_of:ARG`

## join_chars

The argument put between the characters.

- argument: text
- example: join_chars:- applied to 'alpha-beta-gamma' gives 'a-l-p-h-a---b-e-t-a---g-a-m-m-a'.
- used as: `tabula apply FILE COLUMN join_chars:ARG`

## split_first

The first piece when split on the argument.

- argument: text
- example: split_first:- applied to 'alpha-beta-gamma' gives 'alpha'.
- used as: `tabula apply FILE COLUMN split_first:ARG`

## split_last

The last piece when split on the argument.

- argument: text
- example: split_last:- applied to 'alpha-beta-gamma' gives 'gamma'.
- used as: `tabula apply FILE COLUMN split_last:ARG`

## equals

Yes when the value is the argument.

- argument: text
- example: equals:- applied to 'alpha-beta-gamma' gives 'no'.
- used as: `tabula apply FILE COLUMN equals:ARG`

## pad_left

Padded with spaces on the left to N characters.

- argument: a whole number
- example: pad_left:4 applied to 'alpha beta' gives 'alpha beta'.
- used as: `tabula apply FILE COLUMN pad_left:ARG`

## pad_right

Padded with spaces on the right to N characters.

- argument: a whole number
- example: pad_right:4 applied to 'alpha beta' gives 'alpha beta'.
- used as: `tabula apply FILE COLUMN pad_right:ARG`

## center

Centred in N characters.

- argument: a whole number
- example: center:4 applied to 'alpha beta' gives 'alpha beta'.
- used as: `tabula apply FILE COLUMN center:ARG`

## zero_fill

Zero-filled on the left to N characters.

- argument: a whole number
- example: zero_fill:4 applied to '42' gives '0042'.
- used as: `tabula apply FILE COLUMN zero_fill:ARG`

## truncate

Cut to at most N characters.

- argument: a whole number
- example: truncate:4 applied to 'alpha beta' gives 'alph'.
- used as: `tabula apply FILE COLUMN truncate:ARG`

## take_right

The last N characters.

- argument: a whole number
- example: take_right:4 applied to 'alpha beta' gives 'beta'.
- used as: `tabula apply FILE COLUMN take_right:ARG`

## drop_left

Without the first N characters.

- argument: a whole number
- example: drop_left:4 applied to 'alpha beta' gives 'a beta'.
- used as: `tabula apply FILE COLUMN drop_left:ARG`

## drop_right

Without the last N characters.

- argument: a whole number
- example: drop_right:4 applied to 'alpha beta' gives 'alpha '.
- used as: `tabula apply FILE COLUMN drop_right:ARG`

## repeat

Repeated N times.

- argument: a whole number
- example: repeat:4 applied to 'alpha beta' gives 'alpha betaalpha betaalpha betaalpha beta'.
- used as: `tabula apply FILE COLUMN repeat:ARG`

## word

The Nth word, counting from 1.

- argument: a whole number
- example: word:4 applied to 'alpha beta' gives ''.
- used as: `tabula apply FILE COLUMN word:ARG`

## abs

The absolute value.

- argument: none
- example: abs applied to '-12.345' gives '12.345'.
- used as: `tabula apply FILE COLUMN abs`

## neg

The sign flipped.

- argument: none
- example: neg applied to '-12.345' gives '12.345'.
- used as: `tabula apply FILE COLUMN neg`

## floor

Rounded down to a whole number.

- argument: none
- example: floor applied to '-12.345' gives '-13'.
- used as: `tabula apply FILE COLUMN floor`

## ceil

Rounded up to a whole number.

- argument: none
- example: ceil applied to '-12.345' gives '-12'.
- used as: `tabula apply FILE COLUMN ceil`

## trunc

The whole part.

- argument: none
- example: trunc applied to '-12.345' gives '-12'.
- used as: `tabula apply FILE COLUMN trunc`

## round0

Rounded half up to a whole number.

- argument: none
- example: round0 applied to '-12.345' gives '-12'.
- used as: `tabula apply FILE COLUMN round0`

## sign

1, 0 or -1.

- argument: none
- example: sign applied to '-12.345' gives '-1'.
- used as: `tabula apply FILE COLUMN sign`

## square

The number times itself.

- argument: none
- example: square applied to '-12.345' gives '152.399025'.
- used as: `tabula apply FILE COLUMN square`

## cube

The number cubed.

- argument: none
- example: cube applied to '-12.345' gives '-1881.365963625'.
- used as: `tabula apply FILE COLUMN cube`

## half

The number divided by two.

- argument: none
- example: half applied to '-12.345' gives '-6.1725'.
- used as: `tabula apply FILE COLUMN half`

## double

The number times two.

- argument: none
- example: double applied to '-12.345' gives '-24.690'.
- used as: `tabula apply FILE COLUMN double`

## inc

One more.

- argument: none
- example: inc applied to '-12.345' gives '-11.345'.
- used as: `tabula apply FILE COLUMN inc`

## dec

One less.

- argument: none
- example: dec applied to '-12.345' gives '-13.345'.
- used as: `tabula apply FILE COLUMN dec`

## frac

The fractional part, unsigned.

- argument: none
- example: frac applied to '-12.345' gives '0.345'.
- used as: `tabula apply FILE COLUMN frac`

## percent

The number times one hundred.

- argument: none
- example: percent applied to '-12.345' gives '-1234.500'.
- used as: `tabula apply FILE COLUMN percent`

## permille

The number times one thousand.

- argument: none
- example: permille applied to '-12.345' gives '-12345.000'.
- used as: `tabula apply FILE COLUMN permille`

## cents

Pounds as pence, rounded half up.

- argument: none
- example: cents applied to '-12.345' gives '-1235'.
- used as: `tabula apply FILE COLUMN cents`

## is_even

Yes when a whole number is even.

- argument: none
- example: is_even applied to '42' gives 'yes'.
- used as: `tabula apply FILE COLUMN is_even`

## is_positive

Yes when the number is above zero.

- argument: none
- example: is_positive applied to '-12.345' gives 'no'.
- used as: `tabula apply FILE COLUMN is_positive`

## is_zero

Yes when the number is zero.

- argument: none
- example: is_zero applied to '-12.345' gives 'no'.
- used as: `tabula apply FILE COLUMN is_zero`

## add

The argument added.

- argument: a number
- example: add:4 applied to '-12.345' gives '-8.345'.
- used as: `tabula apply FILE COLUMN add:ARG`

## sub

The argument taken away.

- argument: a number
- example: sub:4 applied to '-12.345' gives '-16.345'.
- used as: `tabula apply FILE COLUMN sub:ARG`

## mul

Times the argument.

- argument: a number
- example: mul:4 applied to '-12.345' gives '-49.380'.
- used as: `tabula apply FILE COLUMN mul:ARG`

## div

Divided by the argument (an error when it is zero).

- argument: a number
- example: div:7 applied to '-12.345' gives '-1.76357142857142857142857142857142857142857142857142857142857'.
- used as: `tabula apply FILE COLUMN div:ARG`

## mod

The remainder after dividing by the argument.

- argument: a number
- example: mod:7 applied to '-12.345' gives '-5.345'.
- used as: `tabula apply FILE COLUMN mod:ARG`

## min_of

The lower of the number and the argument.

- argument: a number
- example: min_of:4 applied to '-12.345' gives '-12.345'.
- used as: `tabula apply FILE COLUMN min_of:ARG`

## max_of

The higher of the number and the argument.

- argument: a number
- example: max_of:4 applied to '-12.345' gives '4'.
- used as: `tabula apply FILE COLUMN max_of:ARG`

## diff

The distance from the argument.

- argument: a number
- example: diff:4 applied to '-12.345' gives '16.345'.
- used as: `tabula apply FILE COLUMN diff:ARG`

## scale

The argument percent of the number.

- argument: a number
- example: scale:4 applied to '-12.345' gives '-0.4938'.
- used as: `tabula apply FILE COLUMN scale:ARG`

## round_to

Rounded half up to N decimals.

- argument: a number
- example: round_to:2 applied to '-12.345' gives '-12.35'.
- used as: `tabula apply FILE COLUMN round_to:ARG`

## floor_to

Rounded down to a multiple of the argument.

- argument: a number
- example: floor_to:7 applied to '-12.345' gives '-14'.
- used as: `tabula apply FILE COLUMN floor_to:ARG`

## ceil_to

Rounded up to a multiple of the argument.

- argument: a number
- example: ceil_to:7 applied to '-12.345' gives '-7'.
- used as: `tabula apply FILE COLUMN ceil_to:ARG`

## gt

Yes when the number is above the argument.

- argument: a number
- example: gt:4 applied to '-12.345' gives 'no'.
- used as: `tabula apply FILE COLUMN gt:ARG`

## lt

Yes when the number is below the argument.

- argument: a number
- example: lt:4 applied to '-12.345' gives 'yes'.
- used as: `tabula apply FILE COLUMN lt:ARG`

## ge

Yes when the number is at least the argument.

- argument: a number
- example: ge:4 applied to '-12.345' gives 'no'.
- used as: `tabula apply FILE COLUMN ge:ARG`
