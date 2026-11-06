"""The SQLite connection: opening a book file, the schema version marker, and explicit write transactions."""
import contextlib
import os
import sqlite3

from ..errors import ConflictError, NotFoundError

BUSY_SECONDS = 5.0


class Database:
    """One open connection. Autocommit mode; every write goes through `transaction()` so a failure changes nothing."""

    def __init__(self, conn, path):
        self.conn = conn
        self.path = path
        self._depth = 0

    @classmethod
    def open(cls, path, create, newest):
        """Open `path`. A missing file is NotFoundError unless `create`; a file that is not a SQLite database, or is a
        SQLite database that is not a tallybook one, or is newer than `newest`, is a ConflictError."""
        path = os.fspath(path)
        if os.path.isdir(path):
            raise ConflictError("%s is a directory, not a tallybook database" % path)
        if not os.path.exists(path):
            if not create:
                raise NotFoundError("no such database: %s" % path)
            folder = os.path.dirname(os.path.abspath(path))
            if not os.path.isdir(folder):
                raise NotFoundError("no such directory: %s" % folder)
        conn = None
        try:
            conn = sqlite3.connect(path, timeout=BUSY_SECONDS, isolation_level=None)
            conn.row_factory = sqlite3.Row
            version = conn.execute("PRAGMA user_version").fetchone()[0]
            tables = conn.execute("SELECT count(*) FROM sqlite_master").fetchone()[0]
            conn.execute("PRAGMA foreign_keys = ON")
        except sqlite3.Error as exc:
            if conn is not None:
                conn.close()
            raise ConflictError("%s is not a tallybook database (%s)" % (path, exc))
        problem = None
        if version > newest:
            problem = "database is at version %d, newer than this program understands (%d)" % (version, newest)
        elif version == 0 and tables:
            problem = "%s is not a tallybook database (it has tables but no schema version)" % path
        if problem:
            conn.close()
            raise ConflictError(problem)
        return cls(conn, path)

    # -- plumbing ------------------------------------------------------------------------------------------------

    @property
    def is_open(self):
        return self.conn is not None

    def execute(self, sql, params=()):
        return self.conn.execute(sql, params)

    def all(self, sql, params=()):
        return self.conn.execute(sql, params).fetchall()

    def one(self, sql, params=()):
        return self.conn.execute(sql, params).fetchone()

    def scalar(self, sql, params=()):
        return self.conn.execute(sql, params).fetchone()[0]

    def user_version(self):
        return self.scalar("PRAGMA user_version")

    def close(self):
        if self.conn is not None:
            self.conn.close()
            self.conn = None

    @contextlib.contextmanager
    def transaction(self):
        """All-or-nothing write section. Nested sections join the outermost one; an exception rolls everything back."""
        if self._depth:
            self._depth += 1
            try:
                yield self
            finally:
                self._depth -= 1
            return
        try:
            self.conn.execute("BEGIN IMMEDIATE")
        except sqlite3.OperationalError as exc:
            raise ConflictError("the database is busy: %s" % exc)
        self._depth = 1
        try:
            yield self
        except BaseException:
            self._depth = 0
            self.conn.execute("ROLLBACK")
            raise
        else:
            self._depth = 0
            self.conn.execute("COMMIT")
