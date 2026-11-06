"""The chart of accounts: account add | list | show | close."""
from .args import Arg, Command, Opt
from .common import account_to_dict, json_text, money_list, optional_date, table


def account_add(ctx, args):
    store = ctx.store()
    account = store.add_account(args.args["PATH"], currency=args.opt("currency"),
                                opened=optional_date(args.opt("open")), note=args.opt("note", ""))
    return "added account %s\n" % account.path


def account_list(ctx, args):
    accounts = ctx.store().accounts(type=args.opt("type"), under=args.opt("under"), currency=args.opt("currency"),
                                    include_closed=not args.flag("open-only"))
    if args.flag("json"):
        return json_text([account_to_dict(a) for a in accounts])
    rows = [[a.path, a.type, a.currency or "", a.opened.isoformat() if a.opened else "",
             a.closed.isoformat() if a.closed else "", a.note] for a in accounts]
    if not rows:
        return ""
    return table(["Account", "Type", "Currency", "Opened", "Closed", "Note"], rows)


def account_show(ctx, args):
    store = ctx.store()
    account = store.get_account(args.args["PATH"])
    balance = list(store.ledger().balance(account.path, rollup=True).values())
    if args.flag("json"):
        data = account_to_dict(account)
        data["balance"] = money_list(balance)
        return json_text(data)
    lines = [
        "path: %s" % account.path,
        "type: %s" % account.type,
        "currency: %s" % (account.currency or "any"),
        "opened: %s" % (account.opened.isoformat() if account.opened else "none"),
        "closed: %s" % (account.closed.isoformat() if account.closed else "none"),
        "note: %s" % account.note,
        "balance: %s" % (", ".join(str(m) for m in balance) or "none"),
    ]
    return "".join(line.rstrip() + "\n" for line in lines)


def account_close(ctx, args):
    day = optional_date(args.opt("on"), ctx.today())
    account = ctx.store().close_account(args.args["PATH"], day)
    return "closed account %s on %s\n" % (account.path, day.isoformat())


def commands():
    return [
        Command(("account", "add"), "add an account to the chart", account_add, args=[Arg("PATH")],
                opts=[Opt("currency", "CUR"), Opt("open", "DATE"), Opt("note", "TEXT")]),
        Command(("account", "list"), "list the accounts", account_list,
                opts=[Opt("type", "TYPE"), Opt("under", "PATH"), Opt("currency", "CUR"), Opt("open-only"),
                      Opt("json")]),
        Command(("account", "show"), "show one account and its balance", account_show, args=[Arg("PATH")],
                opts=[Opt("json")]),
        Command(("account", "close"), "close an account as of a date", account_close, args=[Arg("PATH")],
                opts=[Opt("on", "DATE")]),
    ]
