"""The reference answers two briefs: the original one (phase "pre") and the one after the mid-run change request
(phase "post", the default and the final grade). TALLYBOOK_PHASE=pre selects the original behaviour. The three
places that differ import PRE from here: money.round_div (half up / half even), the period lock (absent / present),
and the API error body (a string and 400 / an object and 422)."""
import os

PRE = os.environ.get("TALLYBOOK_PHASE") == "pre"
