"""Each transform on one sample input (a snapshot of what the seed does), the table model and the command line."""
import os, subprocess, sys, tempfile, unittest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
from tabula import engine


SNAPSHOT = [
    ('upper', '  Héllo, World 42 "x" ', None, '  HÉLLO, WORLD 42 "X" '),
    ('lower', '  Héllo, World 42 "x" ', None, '  héllo, world 42 "x" '),
    ('title', '  Héllo, World 42 "x" ', None, '  Héllo, World 42 "X" '),
    ('capitalize', '  Héllo, World 42 "x" ', None, '  héllo, world 42 "x" '),
    ('swapcase', '  Héllo, World 42 "x" ', None, '  hÉLLO, wORLD 42 "X" '),
    ('strip', '  Héllo, World 42 "x" ', None, 'Héllo, World 42 "x"'),
    ('lstrip', '  Héllo, World 42 "x" ', None, 'Héllo, World 42 "x" '),
    ('rstrip', '  Héllo, World 42 "x" ', None, '  Héllo, World 42 "x"'),
    ('reverse', '  Héllo, World 42 "x" ', None, ' "x" 24 dlroW ,olléH  '),
    ('squeeze', '  Héllo, World 42 "x" ', None, 'Héllo, World 42 "x"'),
    ('nospace', '  Héllo, World 42 "x" ', None, 'Héllo,World42"x"'),
    ('digits', '  Héllo, World 42 "x" ', None, '42'),
    ('letters', '  Héllo, World 42 "x" ', None, 'HélloWorldx'),
    ('alnum', '  Héllo, World 42 "x" ', None, 'HélloWorld42x'),
    ('punct_free', '  Héllo, World 42 "x" ', None, '  Héllo World 42 x '),
    ('slug', '  Héllo, World 42 "x" ', None, 'h-llo-world-42-x'),
    ('snake', '  Héllo, World 42 "x" ', None, 'h_llo_world_42_x'),
    ('kebab', '  Héllo, World 42 "x" ', None, 'h-llo-world-42-x'),
    ('camel', '  Héllo, World 42 "x" ', None, 'HLloWorld42X'),
    ('initials', '  Héllo, World 42 "x" ', None, 'HW4"'),
    ('first_word', '  Héllo, World 42 "x" ', None, 'Héllo,'),
    ('last_word', '  Héllo, World 42 "x" ', None, '"x"'),
    ('length', '  Héllo, World 42 "x" ', None, '22'),
    ('words', '  Héllo, World 42 "x" ', None, '4'),
    ('vowels', '  Héllo, World 42 "x" ', None, '2'),
    ('ascii_fold', '  Héllo, World 42 "x" ', None, '  Hello, World 42 "x" '),
    ('nfc', '  Héllo, World 42 "x" ', None, '  Héllo, World 42 "x" '),
    ('nfd', '  Héllo, World 42 "x" ', None, '  Héllo, World 42 "x" '),
    ('quote', '  Héllo, World 42 "x" ', None, '"  Héllo, World 42 ""x"" "'),
    ('unquote', '  Héllo, World 42 "x" ', None, '  Héllo, World 42 "x" '),
    ('blank_to_dash', '  Héllo, World 42 "x" ', None, '  Héllo, World 42 "x" '),
    ('dash_to_blank', '  Héllo, World 42 "x" ', None, '  Héllo, World 42 "x" '),
    ('is_empty', '  Héllo, World 42 "x" ', None, 'no'),
    ('is_number', '  Héllo, World 42 "x" ', None, 'no'),
    ('is_upper', '  Héllo, World 42 "x" ', None, 'no'),
    ('hash_len', '  Héllo, World 42 "x" ', None, '23'),
    ('prefix', 'alpha-beta-gamma', '-', '-alpha-beta-gamma'),
    ('suffix', 'alpha-beta-gamma', '-', 'alpha-beta-gamma-'),
    ('wrap', 'alpha-beta-gamma', '-', '-alpha-beta-gamma-'),
    ('remove', 'alpha-beta-gamma', '-', 'alphabetagamma'),
    ('remove_chars', 'alpha-beta-gamma', '-', 'alphabetagamma'),
    ('keep_chars', 'alpha-beta-gamma', '-', '--'),
    ('default', 'alpha-beta-gamma', '-', 'alpha-beta-gamma'),
    ('strip_prefix', 'alpha-beta-gamma', '-', 'alpha-beta-gamma'),
    ('strip_suffix', 'alpha-beta-gamma', '-', 'alpha-beta-gamma'),
    ('before', 'alpha-beta-gamma', '-', 'alpha'),
    ('after', 'alpha-beta-gamma', '-', 'beta-gamma'),
    ('starts_with', 'alpha-beta-gamma', '-', 'no'),
    ('ends_with', 'alpha-beta-gamma', '-', 'no'),
    ('contains', 'alpha-beta-gamma', '-', 'yes'),
    ('icontains', 'alpha-beta-gamma', '-', 'yes'),
    ('count_of', 'alpha-beta-gamma', '-', '2'),
    ('join_chars', 'alpha-beta-gamma', '-', 'a-l-p-h-a---b-e-t-a---g-a-m-m-a'),
    ('split_first', 'alpha-beta-gamma', '-', 'alpha'),
    ('split_last', 'alpha-beta-gamma', '-', 'gamma'),
    ('equals', 'alpha-beta-gamma', '-', 'no'),
    ('pad_left', 'alpha beta', '4', 'alpha beta'),
    ('pad_right', 'alpha beta', '4', 'alpha beta'),
    ('center', 'alpha beta', '4', 'alpha beta'),
    ('zero_fill', '42', '4', '0042'),
    ('truncate', 'alpha beta', '4', 'alph'),
    ('take_right', 'alpha beta', '4', 'beta'),
    ('drop_left', 'alpha beta', '4', 'a beta'),
    ('drop_right', 'alpha beta', '4', 'alpha '),
    ('repeat', 'alpha beta', '4', 'alpha betaalpha betaalpha betaalpha beta'),
    ('word', 'alpha beta', '4', ''),
    ('abs', '-12.345', None, '12.345'),
    ('neg', '-12.345', None, '12.345'),
    ('floor', '-12.345', None, '-13'),
    ('ceil', '-12.345', None, '-12'),
    ('trunc', '-12.345', None, '-12'),
    ('round0', '-12.345', None, '-12'),
    ('sign', '-12.345', None, '-1'),
    ('square', '-12.345', None, '152.399025'),
    ('cube', '-12.345', None, '-1881.365963625'),
    ('half', '-12.345', None, '-6.1725'),
    ('double', '-12.345', None, '-24.690'),
    ('inc', '-12.345', None, '-11.345'),
    ('dec', '-12.345', None, '-13.345'),
    ('frac', '-12.345', None, '0.345'),
    ('percent', '-12.345', None, '-1234.500'),
    ('permille', '-12.345', None, '-12345.000'),
    ('cents', '-12.345', None, '-1235'),
    ('is_even', '42', None, 'yes'),
    ('is_positive', '-12.345', None, 'no'),
    ('is_zero', '-12.345', None, 'no'),
    ('add', '-12.345', '4', '-8.345'),
    ('sub', '-12.345', '4', '-16.345'),
    ('mul', '-12.345', '4', '-49.380'),
    ('div', '-12.345', '7', '-1.76357142857142857142857142857142857142857142857142857142857'),
    ('mod', '-12.345', '7', '-5.345'),
    ('min_of', '-12.345', '4', '-12.345'),
    ('max_of', '-12.345', '4', '4'),
    ('diff', '-12.345', '4', '16.345'),
    ('scale', '-12.345', '4', '-0.4938'),
    ('round_to', '-12.345', '2', '-12.35'),
    ('floor_to', '-12.345', '7', '-14'),
    ('ceil_to', '-12.345', '7', '-7'),
    ('gt', '-12.345', '4', 'no'),
    ('lt', '-12.345', '4', 'yes'),
    ('ge', '-12.345', '4', 'no'),
]


class TransformTests(unittest.TestCase):
    def test_snapshot(self):
        for name, value, arg, want in SNAPSHOT:
            with self.subTest(name):
                self.assertEqual(engine.TRANSFORMS[name](value, arg), want)

    def test_upper(self):
        self.assertEqual(engine.TRANSFORMS['upper']('  Héllo, World 42 "x" ', None), '  HÉLLO, WORLD 42 "X" ')

    def test_lower(self):
        self.assertEqual(engine.TRANSFORMS['lower']('  Héllo, World 42 "x" ', None), '  héllo, world 42 "x" ')

    def test_title(self):
        self.assertEqual(engine.TRANSFORMS['title']('  Héllo, World 42 "x" ', None), '  Héllo, World 42 "X" ')

    def test_capitalize(self):
        self.assertEqual(engine.TRANSFORMS['capitalize']('  Héllo, World 42 "x" ', None), '  héllo, world 42 "x" ')

    def test_swapcase(self):
        self.assertEqual(engine.TRANSFORMS['swapcase']('  Héllo, World 42 "x" ', None), '  hÉLLO, wORLD 42 "X" ')

    def test_strip(self):
        self.assertEqual(engine.TRANSFORMS['strip']('  Héllo, World 42 "x" ', None), 'Héllo, World 42 "x"')

    def test_lstrip(self):
        self.assertEqual(engine.TRANSFORMS['lstrip']('  Héllo, World 42 "x" ', None), 'Héllo, World 42 "x" ')

    def test_rstrip(self):
        self.assertEqual(engine.TRANSFORMS['rstrip']('  Héllo, World 42 "x" ', None), '  Héllo, World 42 "x"')

    def test_reverse(self):
        self.assertEqual(engine.TRANSFORMS['reverse']('  Héllo, World 42 "x" ', None), ' "x" 24 dlroW ,olléH  ')

    def test_squeeze(self):
        self.assertEqual(engine.TRANSFORMS['squeeze']('  Héllo, World 42 "x" ', None), 'Héllo, World 42 "x"')

    def test_nospace(self):
        self.assertEqual(engine.TRANSFORMS['nospace']('  Héllo, World 42 "x" ', None), 'Héllo,World42"x"')

    def test_digits(self):
        self.assertEqual(engine.TRANSFORMS['digits']('  Héllo, World 42 "x" ', None), '42')

    def test_letters(self):
        self.assertEqual(engine.TRANSFORMS['letters']('  Héllo, World 42 "x" ', None), 'HélloWorldx')

    def test_alnum(self):
        self.assertEqual(engine.TRANSFORMS['alnum']('  Héllo, World 42 "x" ', None), 'HélloWorld42x')

    def test_punct_free(self):
        self.assertEqual(engine.TRANSFORMS['punct_free']('  Héllo, World 42 "x" ', None), '  Héllo World 42 x ')

    def test_slug(self):
        self.assertEqual(engine.TRANSFORMS['slug']('  Héllo, World 42 "x" ', None), 'h-llo-world-42-x')

    def test_snake(self):
        self.assertEqual(engine.TRANSFORMS['snake']('  Héllo, World 42 "x" ', None), 'h_llo_world_42_x')

    def test_kebab(self):
        self.assertEqual(engine.TRANSFORMS['kebab']('  Héllo, World 42 "x" ', None), 'h-llo-world-42-x')

    def test_camel(self):
        self.assertEqual(engine.TRANSFORMS['camel']('  Héllo, World 42 "x" ', None), 'HLloWorld42X')

    def test_initials(self):
        self.assertEqual(engine.TRANSFORMS['initials']('  Héllo, World 42 "x" ', None), 'HW4"')

    def test_first_word(self):
        self.assertEqual(engine.TRANSFORMS['first_word']('  Héllo, World 42 "x" ', None), 'Héllo,')

    def test_last_word(self):
        self.assertEqual(engine.TRANSFORMS['last_word']('  Héllo, World 42 "x" ', None), '"x"')

    def test_length(self):
        self.assertEqual(engine.TRANSFORMS['length']('  Héllo, World 42 "x" ', None), '22')

    def test_words(self):
        self.assertEqual(engine.TRANSFORMS['words']('  Héllo, World 42 "x" ', None), '4')

    def test_vowels(self):
        self.assertEqual(engine.TRANSFORMS['vowels']('  Héllo, World 42 "x" ', None), '2')

    def test_ascii_fold(self):
        self.assertEqual(engine.TRANSFORMS['ascii_fold']('  Héllo, World 42 "x" ', None), '  Hello, World 42 "x" ')

    def test_nfc(self):
        self.assertEqual(engine.TRANSFORMS['nfc']('  Héllo, World 42 "x" ', None), '  Héllo, World 42 "x" ')

    def test_nfd(self):
        self.assertEqual(engine.TRANSFORMS['nfd']('  Héllo, World 42 "x" ', None), '  Héllo, World 42 "x" ')

    def test_quote(self):
        self.assertEqual(engine.TRANSFORMS['quote']('  Héllo, World 42 "x" ', None), '"  Héllo, World 42 ""x"" "')

    def test_unquote(self):
        self.assertEqual(engine.TRANSFORMS['unquote']('  Héllo, World 42 "x" ', None), '  Héllo, World 42 "x" ')

    def test_blank_to_dash(self):
        self.assertEqual(engine.TRANSFORMS['blank_to_dash']('  Héllo, World 42 "x" ', None), '  Héllo, World 42 "x" ')

    def test_dash_to_blank(self):
        self.assertEqual(engine.TRANSFORMS['dash_to_blank']('  Héllo, World 42 "x" ', None), '  Héllo, World 42 "x" ')

    def test_is_empty(self):
        self.assertEqual(engine.TRANSFORMS['is_empty']('  Héllo, World 42 "x" ', None), 'no')

    def test_is_number(self):
        self.assertEqual(engine.TRANSFORMS['is_number']('  Héllo, World 42 "x" ', None), 'no')

    def test_is_upper(self):
        self.assertEqual(engine.TRANSFORMS['is_upper']('  Héllo, World 42 "x" ', None), 'no')

    def test_hash_len(self):
        self.assertEqual(engine.TRANSFORMS['hash_len']('  Héllo, World 42 "x" ', None), '23')

    def test_prefix(self):
        self.assertEqual(engine.TRANSFORMS['prefix']('alpha-beta-gamma', '-'), '-alpha-beta-gamma')

    def test_suffix(self):
        self.assertEqual(engine.TRANSFORMS['suffix']('alpha-beta-gamma', '-'), 'alpha-beta-gamma-')

    def test_wrap(self):
        self.assertEqual(engine.TRANSFORMS['wrap']('alpha-beta-gamma', '-'), '-alpha-beta-gamma-')

    def test_remove(self):
        self.assertEqual(engine.TRANSFORMS['remove']('alpha-beta-gamma', '-'), 'alphabetagamma')

    def test_remove_chars(self):
        self.assertEqual(engine.TRANSFORMS['remove_chars']('alpha-beta-gamma', '-'), 'alphabetagamma')

    def test_keep_chars(self):
        self.assertEqual(engine.TRANSFORMS['keep_chars']('alpha-beta-gamma', '-'), '--')

    def test_default(self):
        self.assertEqual(engine.TRANSFORMS['default']('alpha-beta-gamma', '-'), 'alpha-beta-gamma')

    def test_strip_prefix(self):
        self.assertEqual(engine.TRANSFORMS['strip_prefix']('alpha-beta-gamma', '-'), 'alpha-beta-gamma')

    def test_strip_suffix(self):
        self.assertEqual(engine.TRANSFORMS['strip_suffix']('alpha-beta-gamma', '-'), 'alpha-beta-gamma')

    def test_before(self):
        self.assertEqual(engine.TRANSFORMS['before']('alpha-beta-gamma', '-'), 'alpha')

    def test_after(self):
        self.assertEqual(engine.TRANSFORMS['after']('alpha-beta-gamma', '-'), 'beta-gamma')

    def test_starts_with(self):
        self.assertEqual(engine.TRANSFORMS['starts_with']('alpha-beta-gamma', '-'), 'no')

    def test_ends_with(self):
        self.assertEqual(engine.TRANSFORMS['ends_with']('alpha-beta-gamma', '-'), 'no')

    def test_contains(self):
        self.assertEqual(engine.TRANSFORMS['contains']('alpha-beta-gamma', '-'), 'yes')

    def test_icontains(self):
        self.assertEqual(engine.TRANSFORMS['icontains']('alpha-beta-gamma', '-'), 'yes')

    def test_count_of(self):
        self.assertEqual(engine.TRANSFORMS['count_of']('alpha-beta-gamma', '-'), '2')

    def test_join_chars(self):
        self.assertEqual(engine.TRANSFORMS['join_chars']('alpha-beta-gamma', '-'), 'a-l-p-h-a---b-e-t-a---g-a-m-m-a')

    def test_split_first(self):
        self.assertEqual(engine.TRANSFORMS['split_first']('alpha-beta-gamma', '-'), 'alpha')

    def test_split_last(self):
        self.assertEqual(engine.TRANSFORMS['split_last']('alpha-beta-gamma', '-'), 'gamma')

    def test_equals(self):
        self.assertEqual(engine.TRANSFORMS['equals']('alpha-beta-gamma', '-'), 'no')

    def test_pad_left(self):
        self.assertEqual(engine.TRANSFORMS['pad_left']('alpha beta', '4'), 'alpha beta')

    def test_pad_right(self):
        self.assertEqual(engine.TRANSFORMS['pad_right']('alpha beta', '4'), 'alpha beta')

    def test_center(self):
        self.assertEqual(engine.TRANSFORMS['center']('alpha beta', '4'), 'alpha beta')

    def test_zero_fill(self):
        self.assertEqual(engine.TRANSFORMS['zero_fill']('42', '4'), '0042')

    def test_truncate(self):
        self.assertEqual(engine.TRANSFORMS['truncate']('alpha beta', '4'), 'alph')

    def test_take_right(self):
        self.assertEqual(engine.TRANSFORMS['take_right']('alpha beta', '4'), 'beta')

    def test_drop_left(self):
        self.assertEqual(engine.TRANSFORMS['drop_left']('alpha beta', '4'), 'a beta')

    def test_drop_right(self):
        self.assertEqual(engine.TRANSFORMS['drop_right']('alpha beta', '4'), 'alpha ')

    def test_repeat(self):
        self.assertEqual(engine.TRANSFORMS['repeat']('alpha beta', '4'), 'alpha betaalpha betaalpha betaalpha beta')

    def test_word(self):
        self.assertEqual(engine.TRANSFORMS['word']('alpha beta', '4'), '')

    def test_abs(self):
        self.assertEqual(engine.TRANSFORMS['abs']('-12.345', None), '12.345')

    def test_neg(self):
        self.assertEqual(engine.TRANSFORMS['neg']('-12.345', None), '12.345')

    def test_floor(self):
        self.assertEqual(engine.TRANSFORMS['floor']('-12.345', None), '-13')

    def test_ceil(self):
        self.assertEqual(engine.TRANSFORMS['ceil']('-12.345', None), '-12')

    def test_trunc(self):
        self.assertEqual(engine.TRANSFORMS['trunc']('-12.345', None), '-12')

    def test_round0(self):
        self.assertEqual(engine.TRANSFORMS['round0']('-12.345', None), '-12')

    def test_sign(self):
        self.assertEqual(engine.TRANSFORMS['sign']('-12.345', None), '-1')

    def test_square(self):
        self.assertEqual(engine.TRANSFORMS['square']('-12.345', None), '152.399025')

    def test_cube(self):
        self.assertEqual(engine.TRANSFORMS['cube']('-12.345', None), '-1881.365963625')

    def test_half(self):
        self.assertEqual(engine.TRANSFORMS['half']('-12.345', None), '-6.1725')

    def test_double(self):
        self.assertEqual(engine.TRANSFORMS['double']('-12.345', None), '-24.690')

    def test_inc(self):
        self.assertEqual(engine.TRANSFORMS['inc']('-12.345', None), '-11.345')

    def test_dec(self):
        self.assertEqual(engine.TRANSFORMS['dec']('-12.345', None), '-13.345')

    def test_frac(self):
        self.assertEqual(engine.TRANSFORMS['frac']('-12.345', None), '0.345')

    def test_percent(self):
        self.assertEqual(engine.TRANSFORMS['percent']('-12.345', None), '-1234.500')

    def test_permille(self):
        self.assertEqual(engine.TRANSFORMS['permille']('-12.345', None), '-12345.000')

    def test_cents(self):
        self.assertEqual(engine.TRANSFORMS['cents']('-12.345', None), '-1235')

    def test_is_even(self):
        self.assertEqual(engine.TRANSFORMS['is_even']('42', None), 'yes')

    def test_is_positive(self):
        self.assertEqual(engine.TRANSFORMS['is_positive']('-12.345', None), 'no')

    def test_is_zero(self):
        self.assertEqual(engine.TRANSFORMS['is_zero']('-12.345', None), 'no')

    def test_add(self):
        self.assertEqual(engine.TRANSFORMS['add']('-12.345', '4'), '-8.345')

    def test_sub(self):
        self.assertEqual(engine.TRANSFORMS['sub']('-12.345', '4'), '-16.345')

    def test_mul(self):
        self.assertEqual(engine.TRANSFORMS['mul']('-12.345', '4'), '-49.380')

    def test_div(self):
        self.assertEqual(engine.TRANSFORMS['div']('-12.345', '7'), '-1.76357142857142857142857142857142857142857142857142857142857')

    def test_mod(self):
        self.assertEqual(engine.TRANSFORMS['mod']('-12.345', '7'), '-5.345')

    def test_min_of(self):
        self.assertEqual(engine.TRANSFORMS['min_of']('-12.345', '4'), '-12.345')

    def test_max_of(self):
        self.assertEqual(engine.TRANSFORMS['max_of']('-12.345', '4'), '4')

    def test_diff(self):
        self.assertEqual(engine.TRANSFORMS['diff']('-12.345', '4'), '16.345')

    def test_scale(self):
        self.assertEqual(engine.TRANSFORMS['scale']('-12.345', '4'), '-0.4938')

    def test_round_to(self):
        self.assertEqual(engine.TRANSFORMS['round_to']('-12.345', '2'), '-12.35')

    def test_floor_to(self):
        self.assertEqual(engine.TRANSFORMS['floor_to']('-12.345', '7'), '-14')

    def test_ceil_to(self):
        self.assertEqual(engine.TRANSFORMS['ceil_to']('-12.345', '7'), '-7')

    def test_gt(self):
        self.assertEqual(engine.TRANSFORMS['gt']('-12.345', '4'), 'no')

    def test_lt(self):
        self.assertEqual(engine.TRANSFORMS['lt']('-12.345', '4'), 'yes')

    def test_ge(self):
        self.assertEqual(engine.TRANSFORMS['ge']('-12.345', '4'), 'no')
    def test_every_transform_has_a_snapshot(self):
        self.assertEqual(sorted(engine.TRANSFORMS), sorted(row[0] for row in SNAPSHOT))

    def test_bad_arguments(self):
        for name, arg in [('upper', 'x'), ('add', None), ('add', 'abc'), ('pad_left', '-1'), ('prefix', None), ('div', '0')]:
            with self.subTest(name, arg=arg):
                with self.assertRaises(engine.TabulaError):
                    engine.TRANSFORMS[name]('5', arg)

    def test_numbers_must_be_numbers(self):
        for text in ('', 'abc', '1e3', '1,000', '--1'):
            with self.subTest(text):
                with self.assertRaises(engine.TabulaError):
                    engine.TRANSFORMS['abs'](text)


class TableTests(unittest.TestCase):
    def test_parse(self):
        t = engine.parse_text('\ufeffa,b\r\n1,"x,y"\r\n\r\n3,4\r\n', 'f.csv')
        self.assertEqual((t.columns, t.rows), (['a', 'b'], [['1', 'x,y'], ['3', '4']]))

    def test_mistakes_name_file_and_line(self):
        for text, want in [('a,b\n1\n', 'f.csv: line 2: expected 2 fields, found 1'), ('a,a\n', 'f.csv: line 1: duplicate column name'),
                           ('a,\n', 'f.csv: line 1: empty column name'), ('', 'f.csv: no header line')]:
            with self.subTest(text):
                with self.assertRaises(engine.TabulaError) as cm:
                    engine.parse_text(text, 'f.csv')
                self.assertEqual(str(cm.exception), want)

    def test_render(self):
        t = engine.Table(['name', 'n'], [['a b', '1'], ['ccc', '22']])
        self.assertEqual(engine.render(t), 'name  n\na b   1\nccc   22\n')
        self.assertEqual(engine.render(t, 'csv'), 'name,n\na b,1\nccc,22\n')
        self.assertEqual(engine.render(t, 'json'), '[{"name": "a b", "n": "1"}, {"name": "ccc", "n": "22"}]\n')


class CliTests(unittest.TestCase):
    def run_cli(self, *argv, files=None):
        with tempfile.TemporaryDirectory() as d:
            for k, v in (files or {}).items():
                with open(os.path.join(d, k), 'w', encoding='utf-8', newline='') as fh:
                    fh.write(v)
            env = dict(os.environ, PYTHONPATH=os.path.join(os.path.dirname(os.path.abspath(__file__)), '..'))
            p = subprocess.run([sys.executable, '-m', 'tabula'] + list(argv), cwd=d, env=env, capture_output=True, text=True)
            return p.returncode, p.stdout, p.stderr

    def test_commands(self):
        f = {'t.csv': 'name,qty\nax,3\nby,10\ncz,7\n'}
        for argv, rc, out in [(('show', 't.csv'), 0, 'name  qty\nax    3\nby    10\ncz    7\n'),
                              (('head', 't.csv', '1'), 0, 'name  qty\nax    3\n'),
                              (('--format', 'csv', 'cols', 't.csv'), 0, 'position,column\n1,name\n2,qty\n'),
                              (('apply', 't.csv', 'qty', 'add:1', 'mul:2', '--format=csv'), 0, 'name,qty\nax,8\nby,22\ncz,16\n'),
                              (('apply', 't.csv', 'name', 'upper', '--format', 'json'), 0, '[{"name": "AX", "qty": "3"}, {"name": "BY", "qty": "10"}, {"name": "CZ", "qty": "7"}]\n'),
                              (('show', 'missing.csv'), 1, ''), (('apply', 't.csv', 'nope', 'upper'), 1, ''),
                              (('apply', 't.csv', 'name', 'add:1'), 1, ''), (('bogus',), 2, ''), ((), 2, ''), (('show', '--wat', 't.csv'), 2, '')]:
            with self.subTest(argv):
                got = self.run_cli(*argv, files=f)
                self.assertEqual((got[0], got[1]), (rc, out))
                self.assertEqual(bool(got[2]), rc != 0)


if __name__ == '__main__':
    unittest.main()
