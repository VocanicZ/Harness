"""Plain data records shared by every module. No behaviour beyond construction and equality."""
from dataclasses import dataclass, field
from datetime import date
from typing import List, Optional, Tuple

from .money import Money

ACCOUNT_TYPES = ("asset", "liability", "equity", "income", "expense")


@dataclass(frozen=True)
class Posting:
    account: str
    amount: Money
    note: str = ""


@dataclass
class Transaction:
    date: date
    payee: str
    narration: str = ""
    postings: List[Posting] = field(default_factory=list)
    tags: Tuple[str, ...] = ()
    flag: str = "*"                 # "*" cleared, "!" pending
    id: Optional[int] = None        # set by storage


@dataclass
class Account:
    path: str
    type: str
    currency: Optional[str] = None  # None: any currency
    opened: Optional[date] = None
    closed: Optional[date] = None
    note: str = ""
