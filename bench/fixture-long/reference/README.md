# tabula

Small tools for CSV tables, standard library only (Python 3.9 or newer).

    tabula [--format text|csv|json] COMMAND ARGS...

Commands: `show`, `head`, `cols`, `apply`, `sort`, `filter`, `group`, `join`, `pivot`, `dedupe`, `stats` (see `docs/transforms.md` for the transforms).
Everything lives in `tabula/engine.py`: the table model, the transforms, the output formats and the commands.
A command is a function `cmd_NAME(args, opts)` returning a `Table`, registered in `COMMANDS`.
Mistakes in a file or a request exit 1 with `tabula: <message>` on stderr; a badly shaped command line exits 2.
Run the tests with `python -m unittest discover tests`.
