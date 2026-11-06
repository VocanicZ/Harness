"""The book file itself: init, the schema (`db ...`), the period lock and the web interface."""
import os

from .. import _phase
from ..dates import parse_date
from ..storage import LATEST_VERSION, Store
from .args import Arg, Command, Opt
from .common import CliError, Output, json_text, whole_number


def init(ctx, args):
    path = ctx.db_path
    existed = os.path.exists(path)
    store = Store.open(path, create=True)
    try:
        if not existed:
            return "created %s (version %d)\n" % (path, store.version)
        before = store.version
        if before < LATEST_VERSION:
            store.migrate()
            return "migrated %s from version %d to %d\n" % (path, before, store.version)
        return "%s is up to date (version %d)\n" % (path, before)
    finally:
        store.close()


def db_version(ctx, args):
    return "%d\n" % ctx.store().version


def db_migrate(ctx, args):
    store = ctx.store()
    applied = store.migrate()
    if not applied:
        return "database is up to date (version %d)\n" % store.version
    return "".join("applied version %d\n" % v for v in applied)


def db_info(ctx, args):
    info = ctx.store().info()
    if args.flag("json"):
        return json_text(info)
    order = ["path", "version", "accounts", "transactions", "postings", "rates", "budgets", "recurring"]
    return "".join("%s: %s\n" % (key, info[key]) for key in order)


def db_check(ctx, args):
    problems = ctx.store().check()
    if not problems:
        return "ok\n"
    return Output("".join(p + "\n" for p in problems), 1)


def db_backup(ctx, args):
    ctx.store().backup(args.args["DEST"])
    return "backed up to %s\n" % args.args["DEST"]


# ---------------------------------------------------------------- the period lock (after the change request)

def lock_show(ctx, args):
    day = ctx.store().lock_date()
    return "%s\n" % (day.isoformat() if day else "none")


def lock_set(ctx, args):
    day = parse_date(args.args["DATE"])
    ctx.store().set_lock(day)
    return "locked through %s\n" % day.isoformat()


def lock_clear(ctx, args):
    ctx.store().set_lock(None)
    return "lock cleared\n"


# ---------------------------------------------------------------- the web interface

def serve(ctx, args):
    host = args.opt("host", "127.0.0.1")
    port = whole_number(args.opt("port", "8765"), "port")
    if port > 65535:
        raise CliError("invalid port '%d': expected 0 to 65535" % port)
    ctx.store().info()                      # fail early with the usual messages: no book, old schema
    ctx.close()
    try:
        from ..api.server import serve as run_server
    except ImportError:
        raise CliError("the web interface is not available in this build")
    today = ctx.today() if ctx.today_text is not None else None
    run_server(ctx.db_path, host, port, today=today)
    return ""


def commands():
    out = [
        Command(("init",), "create the book, or bring an older one up to date", init),
        Command(("db", "version"), "print the schema version of the book", db_version),
        Command(("db", "migrate"), "bring an older book up to the latest schema", db_migrate),
        Command(("db", "info"), "print the book's path, version and row counts", db_info, opts=[Opt("json")]),
        Command(("db", "check"), "look for damage in the book file", db_check),
        Command(("db", "backup"), "copy the whole book into a new file", db_backup, args=[Arg("DEST")]),
        Command(("serve",), "serve the book over HTTP until stopped", serve,
                opts=[Opt("host", "HOST"), Opt("port", "PORT")]),
    ]
    if not _phase.PRE:
        out += [
            Command(("lock", "show"), "print the lock date, or none", lock_show),
            Command(("lock", "set"), "lock the books through a date", lock_set, args=[Arg("DATE")]),
            Command(("lock", "clear"), "remove the lock", lock_clear),
        ]
    return out
