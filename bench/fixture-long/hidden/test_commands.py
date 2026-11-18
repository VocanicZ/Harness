"""The seven new commands and the four old ones, one table per command. A row is (name, files, command line, exit status,
expected standard output for status 0 / substrings of standard error otherwise)."""
from common import make_class

T = "name,qty,price\nax,3,2.50\nby,10,1.25\nax,7,\ncz,10,3\nBo,9,0.5\n"
HDR = "name,qty,price\n"
CSV = ["--format", "csv"]
GROUP_IN = "k,v\na,0.10\na,0.20\nb,+5\nb,10.50\n"
ROUND_IN = "k,v\na,0.10\na,0.20\nb,5\nb,10.50\nc,1.005\nc,1.015\nd,0.125\nd,0.125\ne,2.675\n"
JL = "id,name,city\n1,ann,Leeds\n2,bob,York\n3,cy,Hull\n2,bob2,Bath\n"
JR = "id,city,score\n2,X,5\n1,Y,7\n2,Z,9\n4,W,1\n"
PIV = "region,q,amt\nN,Q2,2.5\nS,Q1,5\nN,Q1,10\nN,Q1,0.5\nE,Q2,4\n"
DUP = "k,v,w\na,1,x\nb,2,y\na,3,z\nc,4,y\nb,5,x\na,1,x\n"

SORT = [
    ("text_by_code_point", {"t.csv": T}, ["sort", "t.csv", "name"] + CSV, 0, HDR + "Bo,9,0.5\nax,3,2.50\nax,7,\nby,10,1.25\ncz,10,3\n"),
    ("text_compare_of_numbers", {"t.csv": T}, ["sort", "t.csv", "qty"] + CSV, 0, HDR + "by,10,1.25\ncz,10,3\nax,3,2.50\nax,7,\nBo,9,0.5\n"),
    ("numeric", {"t.csv": T}, ["sort", "t.csv", "qty:num"] + CSV, 0, HDR + "ax,3,2.50\nax,7,\nBo,9,0.5\nby,10,1.25\ncz,10,3\n"),
    ("desc_is_stable", {"t.csv": T}, ["sort", "t.csv", "qty:desc:num"] + CSV, 0, HDR + "by,10,1.25\ncz,10,3\nBo,9,0.5\nax,7,\nax,3,2.50\n"),
    ("two_keys", {"t.csv": T}, ["sort", "t.csv", "qty:num:desc", "name:desc"] + CSV, 0, HDR + "cz,10,3\nby,10,1.25\nBo,9,0.5\nax,7,\nax,3,2.50\n"),
    ("header_only", {"t.csv": HDR}, ["sort", "t.csv", "name"] + CSV, 0, HDR),
    ("json_output", {"t.csv": "a,b\n2,x\n1,y\n"}, ["--format=json", "sort", "t.csv", "a:num"], 0, '[{"a": "1", "b": "y"}, {"a": "2", "b": "x"}]\n'),
    ("not_a_number", {"t.csv": T}, ["sort", "t.csv", "price:num"], 1, ["t.csv: row 3: column 'price'"]),
    ("unknown_column", {"t.csv": T}, ["sort", "t.csv", "nope"], 1, ["nope"]),
    ("no_key", {"t.csv": T}, ["sort", "t.csv"], 2, ["sort"]),
    ("repeated_modifier", {"t.csv": T}, ["sort", "t.csv", "qty:num:num"], 2, ["sort"]),
]
FILTER = [
    ("greater_equal", {"t.csv": T}, ["filter", "t.csv", "qty>=9"] + CSV, 0, HDR + "by,10,1.25\ncz,10,3\nBo,9,0.5\n"),
    ("numbers_compare_as_numbers", {"t.csv": T}, ["filter", "t.csv", "qty>2"] + CSV, 0, T),
    ("equal_and_not_equal", {"t.csv": T}, ["filter", "t.csv", "name==ax"] + CSV, 0, HDR + "ax,3,2.50\nax,7,\n"),
    ("not_equal", {"t.csv": T}, ["filter", "t.csv", "name!=ax"] + CSV, 0, HDR + "by,10,1.25\ncz,10,3\nBo,9,0.5\n"),
    ("contains_ignores_case", {"t.csv": T}, ["filter", "t.csv", "name~B"] + CSV, 0, HDR + "by,10,1.25\nBo,9,0.5\n"),
    ("one_point_zero_equals_one", {"t.csv": "n\n1.0\n1\n01\nx\n"}, ["filter", "t.csv", "n==1"] + CSV, 0, "n\n1.0\n1\n01\n"),
    ("a_cell_that_is_not_a_number_compares_as_text", {"t.csv": T}, ["filter", "t.csv", "price<=1.25"] + CSV, 0, HDR + "by,10,1.25\nax,7,\nBo,9,0.5\n"),
    ("all_must_hold", {"t.csv": T}, ["filter", "t.csv", "name==ax", "qty>5"] + CSV, 0, HDR + "ax,7,\n"),
    ("text_compare_by_code_point", {"t.csv": T}, ["filter", "t.csv", "name<ax"] + CSV, 0, HDR + "Bo,9,0.5\n"),
    ("first_operator_wins", {"t.csv": T}, ["filter", "t.csv", "name==a>b"] + CSV, 0, HDR),
    ("nothing_left_prints_the_header", {"t.csv": T}, ["filter", "t.csv", "qty>100"] + CSV, 0, HDR),
    ("no_operator", {"t.csv": T}, ["filter", "t.csv", "name"], 2, ["filter"]),
    ("no_column_name", {"t.csv": T}, ["filter", "t.csv", "==x"], 2, ["filter"]),
    ("no_condition", {"t.csv": T}, ["filter", "t.csv"], 2, ["filter"]),
    ("unknown_column", {"t.csv": T}, ["filter", "t.csv", "nope==1"], 1, ["nope"]),
]
GROUP = [
    ("every_aggregate", {"t.csv": T}, ["group", "t.csv", "name", "count", "sum:qty", "min:qty", "max:qty", "mean:qty"] + CSV, 0,
     "name,count,sum_qty,min_qty,max_qty,mean_qty\nax,2,10,3,7,5.00\nby,1,10,10,10,10.00\ncz,1,10,10,10,10.00\nBo,1,9,9,9,9.00\n"),
    ("sums_are_exact_and_as_written", {"t.csv": GROUP_IN}, ["group", "t.csv", "k", "sum:v", "min:v", "max:v"] + CSV, 0,
     "k,sum_v,min_v,max_v\na,0.30,0.10,0.20\nb,15.50,5,10.50\n"),
    ("mean_rounds_half_up", {"t.csv": ROUND_IN}, ["group", "t.csv", "k", "mean:v"] + CSV, 0,
     "k,mean_v\na,0.15\nb,7.75\nc,1.01\nd,0.13\ne,2.68\n"),
    ("count_reads_no_other_column", {"t.csv": T}, ["group", "t.csv", "name", "count"] + CSV, 0, "name,count\nax,2\nby,1\ncz,1\nBo,1\n"),
    ("text_output", {"t.csv": T}, ["group", "t.csv", "name", "count"], 0, "name  count\nax    2\nby    1\ncz    1\nBo    1\n"),
    ("not_a_number", {"t.csv": T}, ["group", "t.csv", "name", "sum:price"], 1, ["t.csv: row 3: column 'price'"]),
    ("unknown_by", {"t.csv": T}, ["group", "t.csv", "nope", "count"], 1, ["nope"]),
    ("unknown_aggregate_column", {"t.csv": T}, ["group", "t.csv", "name", "sum:nope"], 1, ["nope"]),
    ("no_aggregate", {"t.csv": T}, ["group", "t.csv", "name"], 2, ["group"]),
    ("not_an_aggregate", {"t.csv": T}, ["group", "t.csv", "name", "avg:qty"], 2, ["group"]),
    ("aggregate_without_column", {"t.csv": T}, ["group", "t.csv", "name", "sum"], 2, ["group"]),
    ("repeated_aggregate", {"t.csv": T}, ["group", "t.csv", "name", "count", "count"], 2, ["group"]),
]
JOIN = [
    ("inner", {"l.csv": JL, "r.csv": JR}, ["join", "l.csv", "r.csv", "id"] + CSV, 0,
     "id,name,city,city_right,score\n1,ann,Leeds,Y,7\n2,bob,York,X,5\n2,bob,York,Z,9\n2,bob2,Bath,X,5\n2,bob2,Bath,Z,9\n"),
    ("left", {"l.csv": JL, "r.csv": JR}, ["join", "l.csv", "r.csv", "id", "--kind", "left"] + CSV, 0,
     "id,name,city,city_right,score\n1,ann,Leeds,Y,7\n2,bob,York,X,5\n2,bob,York,Z,9\n3,cy,Hull,,\n2,bob2,Bath,X,5\n2,bob2,Bath,Z,9\n"),
    ("kind_before_the_command", {"l.csv": JL, "r.csv": JR}, ["--kind=left", "join", "l.csv", "r.csv", "id"] + CSV, 0,
     "id,name,city,city_right,score\n1,ann,Leeds,Y,7\n2,bob,York,X,5\n2,bob,York,Z,9\n3,cy,Hull,,\n2,bob2,Bath,X,5\n2,bob2,Bath,Z,9\n"),
    ("values_match_exactly", {"l.csv": "id,a\n01,x\nA,y\n", "r.csv": "id,b\n1,p\na,q\n"}, ["join", "l.csv", "r.csv", "id"] + CSV, 0, "id,a,b\n"),
    ("same_file_twice", {"l.csv": "id,v\n1,a\n"}, ["join", "l.csv", "l.csv", "id"] + CSV, 0, "id,v,v_right\n1,a,a\n"),
    ("name_twice_after_the_suffix", {"l.csv": "id,score,score_right\n1,2,3\n", "r.csv": "id,score\n1,4\n"}, ["join", "l.csv", "r.csv", "id"], 1, []),
    ("key_missing_on_the_right", {"l.csv": JL, "r.csv": "x,y\n1,2\n"}, ["join", "l.csv", "r.csv", "id"], 1, ["id"]),
    ("bad_kind", {"l.csv": JL, "r.csv": JR}, ["join", "l.csv", "r.csv", "id", "--kind", "outer"], 2, ["--kind"]),
    ("kind_without_value", {"l.csv": JL, "r.csv": JR}, ["join", "l.csv", "r.csv", "id", "--kind"], 2, ["--kind"]),
    ("two_arguments", {"l.csv": JL, "r.csv": JR}, ["join", "l.csv", "r.csv"], 2, ["join"]),
]
PIVOT = [
    ("sums_by_pair", {"t.csv": PIV}, ["pivot", "t.csv", "region", "q", "amt"] + CSV, 0, "region,Q2,Q1\nN,2.5,10.5\nS,0,5\nE,4,0\n"),
    ("text_output", {"t.csv": PIV}, ["pivot", "t.csv", "region", "q", "amt"], 0, "region  Q2   Q1\nN       2.5  10.5\nS       0    5\nE       4    0\n"),
    ("row_and_column_the_same", {"t.csv": PIV}, ["pivot", "t.csv", "q", "q", "amt"], 2, ["pivot"]),
    ("empty_column_value", {"t.csv": "r,c,v\na,x,1\nb,,2\n"}, ["pivot", "t.csv", "r", "c", "v"], 1, ["t.csv: row 2: column 'c': empty value"]),
    ("a_value_named_like_the_row_column", {"t.csv": "k,c,v\na,k,1\n"}, ["pivot", "t.csv", "k", "c", "v"], 1, ["k"]),
    ("not_a_number", {"t.csv": "r,c,v\na,x,1\nb,x,two\n"}, ["pivot", "t.csv", "r", "c", "v"], 1, ["t.csv: row 2: column 'v'"]),
    ("unknown_column", {"t.csv": PIV}, ["pivot", "t.csv", "region", "q", "nope"], 1, ["nope"]),
    ("three_arguments", {"t.csv": PIV}, ["pivot", "t.csv", "region", "q"], 2, ["pivot"]),
]
DEDUPE = [
    ("first_by_default", {"t.csv": DUP}, ["dedupe", "t.csv", "k"] + CSV, 0, "k,v,w\na,1,x\nb,2,y\nc,4,y\n"),
    ("keep_last_in_place_of_the_last", {"t.csv": DUP}, ["dedupe", "t.csv", "k", "--keep", "last"] + CSV, 0, "k,v,w\nc,4,y\nb,5,x\na,1,x\n"),
    ("keep_equals_form", {"t.csv": DUP}, ["dedupe", "--keep=last", "t.csv", "k"] + CSV, 0, "k,v,w\nc,4,y\nb,5,x\na,1,x\n"),
    ("two_keys_first", {"t.csv": DUP}, ["dedupe", "t.csv", "k", "v"] + CSV, 0, "k,v,w\na,1,x\nb,2,y\na,3,z\nc,4,y\nb,5,x\n"),
    ("two_keys_last", {"t.csv": DUP}, ["dedupe", "t.csv", "k", "v", "--keep", "last"] + CSV, 0, "k,v,w\nb,2,y\na,3,z\nc,4,y\nb,5,x\na,1,x\n"),
    ("text_equality", {"t.csv": "k\n1\n01\n1.0\n1\n"}, ["dedupe", "t.csv", "k"] + CSV, 0, "k\n1\n01\n1.0\n"),
    ("no_key", {"t.csv": DUP}, ["dedupe", "t.csv"], 2, ["dedupe"]),
    ("bad_keep", {"t.csv": DUP}, ["dedupe", "t.csv", "k", "--keep", "middle"], 2, ["--keep"]),
    ("unknown_column", {"t.csv": DUP}, ["dedupe", "t.csv", "nope"], 1, ["nope"]),
]
STATS = [
    ("two_columns_in_the_order_asked", {"t.csv": T}, ["stats", "t.csv", "price", "qty"] + CSV, 0,
     "column,count,min,max,mean,median\nprice,4,0.5,3,1.81,1.88\nqty,5,3,10,7.80,9.00\n"),
    ("half_up", {"t.csv": "v\n1.24\n1.25\n"}, ["stats", "t.csv", "v"] + CSV, 0, "column,count,min,max,mean,median\nv,2,1.24,1.25,1.25,1.25\n"),
    ("odd_count_median", {"t.csv": "v\n5\n1\n3\n"}, ["stats", "t.csv", "v"] + CSV, 0, "column,count,min,max,mean,median\nv,3,1,5,3.00,3.00\n"),
    ("empty_cells_are_left_out", {"t.csv": "a,b\n1,\n2, \n"}, ["stats", "t.csv", "b", "a"] + CSV, 0,
     "column,count,min,max,mean,median\nb,0,,,,\na,2,1,2,1.50,1.50\n"),
    ("not_a_number", {"t.csv": T}, ["stats", "t.csv", "name"], 1, ["t.csv: row 1: column 'name'"]),
    ("unknown_column", {"t.csv": T}, ["stats", "t.csv", "nope"], 1, ["nope"]),
    ("no_column", {"t.csv": T}, ["stats", "t.csv"], 2, ["stats"]),
]
OLD = [
    ("show", {"t.csv": "a,b\r\n1,\"x,y\"\r\n"}, ["show", "t.csv"], 0, "a  b\n1  x,y\n"),
    ("byte_order_mark_and_blank_lines", {"t.csv": b"\xef\xbb\xbfa,b\n\n1,2\n"}, ["--format", "json", "show", "t.csv"], 0, '[{"a": "1", "b": "2"}]\n'),
    ("head", {"t.csv": T}, ["head", "t.csv", "2"] + CSV, 0, HDR + "ax,3,2.50\nby,10,1.25\n"),
    ("cols", {"t.csv": T}, ["cols", "t.csv"] + CSV, 0, "position,column\n1,name\n2,qty\n3,price\n"),
    ("apply", {"t.csv": T}, ["apply", "t.csv", "qty", "add:1", "mul:2"] + CSV, 0, "name,qty,price\nax,8,2.50\nby,22,1.25\nax,16,\ncz,22,3\nBo,20,0.5\n"),
    ("ragged_row_names_the_line", {"t.csv": "a,b\n1,2\n3\n"}, ["show", "t.csv"], 1, ["t.csv: line 3"]),
    ("missing_file", {}, ["show", "nope.csv"], 1, ["nope.csv"]),
    ("not_utf8", {"t.csv": b"a\n\xff\n"}, ["show", "t.csv"], 1, ["UTF-8"]),
    ("no_command", {}, [], 2, ["tabula"]),
    ("unknown_command", {}, ["bogus"], 2, ["bogus"]),
    ("unknown_option", {"t.csv": T}, ["show", "--wat", "t.csv"], 2, ["--wat"]),
    ("bad_format", {"t.csv": T}, ["show", "t.csv", "--format", "xml"], 2, ["--format"]),
    ("a_key_starting_with_a_dash_is_a_usage_error", {"t.csv": T}, ["sort", "t.csv", "-x"], 2, ["-x"]),
]

for _name, _cases in (("SortTests", SORT), ("FilterTests", FILTER), ("GroupTests", GROUP), ("JoinTests", JOIN), ("PivotTests", PIVOT),
                      ("DedupeTests", DEDUPE), ("StatsTests", STATS), ("ExistingCommandTests", OLD)):
    globals()[_name] = make_class(_name, _cases)
