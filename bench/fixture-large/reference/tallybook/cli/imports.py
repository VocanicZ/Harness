"""Bank statements: import, profile add | list | show | remove, rules set | show."""
from ..csvimport import parse_profile
from ..rules import parse_rules
from .args import Arg, Command, Opt, UsageError
from .common import CliError, json_text, read_text, with_newline


def import_csv(ctx, args):
    stored_name, profile_file = args.opt("profile"), args.opt("profile-file")
    if (stored_name is None) == (profile_file is None):
        raise UsageError("give exactly one of --profile NAME and --profile-file FILE")
    store = ctx.store()
    csv_text = read_text(args.args["FILE"], "statement")
    profile = stored_name if stored_name is not None else parse_profile(read_text(profile_file, "profile"))
    outcome = store.import_csv(csv_text, profile, apply_rules=not args.flag("no-rules"))
    if outcome.errors:
        detail = "".join("row %d: %s\n" % (row, message) for row, message in outcome.errors)
        raise CliError("%d rows could not be imported, nothing was imported\n%s" % (len(outcome.errors),
                                                                                   detail.rstrip("\n")))
    return "imported %d transactions, %d duplicates\n" % (len(outcome.added), len(outcome.duplicates))


def profile_add(ctx, args):
    store = ctx.store()
    store.set_profile(args.args["NAME"], read_text(args.args["FILE"], "profile"))
    return "stored profile %s\n" % args.args["NAME"]


def profile_list(ctx, args):
    names = ctx.store().profiles()
    if args.flag("json"):
        return json_text(names)
    return "".join(n + "\n" for n in names)


def profile_show(ctx, args):
    return with_newline(ctx.store().profile_text(args.args["NAME"]))


def profile_remove(ctx, args):
    ctx.store().remove_profile(args.args["NAME"])
    return "removed profile %s\n" % args.args["NAME"]


def rules_set(ctx, args):
    store = ctx.store()
    text = read_text(args.args["FILE"], "rules")
    count = len(parse_rules(text))
    store.set_rules(text)
    return "stored %d rules\n" % count


def rules_show(ctx, args):
    return with_newline(ctx.store().rules_text())


def commands():
    return [
        Command(("import",), "import a bank statement (CSV) with a stored or given profile", import_csv,
                args=[Arg("FILE")], opts=[Opt("profile", "NAME"), Opt("profile-file", "FILE"), Opt("no-rules")]),
        Command(("profile", "add"), "store an import profile under a name", profile_add,
                args=[Arg("NAME"), Arg("FILE")]),
        Command(("profile", "list"), "list the stored profiles", profile_list, opts=[Opt("json")]),
        Command(("profile", "show"), "print a stored profile", profile_show, args=[Arg("NAME")]),
        Command(("profile", "remove"), "remove a stored profile", profile_remove, args=[Arg("NAME")]),
        Command(("rules", "set"), "replace the categorisation rules with a file's", rules_set, args=[Arg("FILE")]),
        Command(("rules", "show"), "print the stored rules", rules_show),
    ]
