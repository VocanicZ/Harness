"""The HTTP API: `serve` runs a small JSON server over one book file. The pieces are `server` (sockets, framing,
signals), `router` (paths, verbs, error bodies) and `handlers` (one function per resource)."""
from .server import serve

__all__ = ["serve"]
