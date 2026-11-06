"""tallybook: double-entry household bookkeeping. The public names are imported lazily from their modules."""
import importlib

__version__ = "1.0.0"

_EXPORTS = {
    "errors": ["TallybookError", "ParseError", "ValidationError", "NotFoundError", "ConflictError", "LockedPeriodError"],
    "model": ["Posting", "Transaction", "Account", "ACCOUNT_TYPES"],
    "money": ["Money", "MoneyError", "parse_amount", "format_minor", "round_div"],
    "currency": ["Currency", "CURRENCIES", "currency", "RateTable", "CurrencyError"],
    "dates": ["parse_date", "format_date", "add_months", "last_day", "Period", "periods", "DateError"],
    "accounts": ["Chart", "valid_path", "parent_path", "ChartError"],
    "ledger": ["Ledger", "LedgerError"],
    "journal": ["Journal", "parse_journal", "format_journal", "format_transaction", "JournalError"],
    "query": ["Query", "parse_query", "select", "QueryError"],
    "rules": ["Rule", "RuleSet", "parse_rules", "RulesError"],
    "csvimport": ["ImportProfile", "ImportResult", "parse_profile", "import_csv", "CsvImportError"],
    "budgets": ["Budget", "BudgetLine", "budget_status", "BudgetError"],
    "recurring": ["Recurring", "Schedule", "parse_schedule", "occurrences", "expand", "RecurringError", "instantiate", "next_occurrence", "describe"],
    "reports": ["trial_balance", "balance_sheet", "income_statement", "cashflow", "register", "render_text", "ReportError", "net_worth", "report_to_csv"],
    "export": ["transactions_to_csv", "transactions_to_json", "render_table", "transactions_from_json", "to_csv", "to_json", "money_to_dict", "transaction_to_dict", "ExportError"],
    "storage": ["Store", "LATEST_VERSION"],
}
_WHERE = {name: mod for mod, names in _EXPORTS.items() for name in names}
__all__ = sorted(_WHERE) + ["__version__"]


def __getattr__(name):
    mod = _WHERE.get(name)
    if mod is None:
        raise AttributeError("module 'tallybook' has no attribute %r" % name)
    value = getattr(importlib.import_module("." + mod, __name__), name)
    globals()[name] = value
    return value
