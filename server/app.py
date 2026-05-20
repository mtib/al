"""
Al log-shipping server.

Light-weight FastAPI service that accepts X25519-sealed transcript lines from
the Al menu-bar app, stores them in SQLite, and exposes plain-text and
semantic search over the decrypted corpus. Every endpoint — including the
public-key fetch — requires the pre-shared key in the `Authorization: Bearer`
header.

The server keeps a rolling set of X25519 keypairs. `GET /pubkey` returns the
current key plus a `valid_until` UNIX timestamp; once a key crosses the
rotation threshold the server mints a new one and returns *that*. Old keys
are kept around for a retention window so any in-flight ciphertexts can
still decrypt — on receipt we try each candidate key in turn.

Wire format for one sealed message (base64 in JSON on POST /logs):
    [ 32 bytes  X25519 ephemeral public key ]
    [ 12 bytes  ChaCha20 nonce              ]
    [  N bytes  ciphertext                  ]
    [ 16 bytes  Poly1305 tag                ]

Symmetric key:
    HKDF-SHA256(
        ikm  = X25519(ephemeral_priv, server_pub),
        salt = ephemeral_pub || server_pub,
        info = b"al-sealed-box-v1",
        L    = 32,
    )

Plaintext is a JSON object:
    {
      "file_id": "2026-05-20/2026-05-20T14-30-22",
      "source":  "mic" | "system",
      "started_at": <float seconds since epoch>,
      "ended_at":   <float seconds since epoch>,
      "text":   "..."
    }
"""
from __future__ import annotations

import asyncio
import base64
import hashlib
import json
import logging
import os
import sqlite3
import threading
import time
from contextlib import asynccontextmanager, contextmanager
from pathlib import Path
from typing import Iterator, Optional, Tuple

import numpy as np
from cryptography.exceptions import InvalidTag
from cryptography.hazmat.primitives.asymmetric.x25519 import (
    X25519PrivateKey,
    X25519PublicKey,
)
from cryptography.hazmat.primitives.ciphers.aead import ChaCha20Poly1305
from cryptography.hazmat.primitives.hashes import SHA256
from cryptography.hazmat.primitives.kdf.hkdf import HKDF
from cryptography.hazmat.primitives.serialization import (
    Encoding,
    PublicFormat,
)
from fastapi import Depends, FastAPI, Header, HTTPException, Query, status
from pydantic import BaseModel, Field


# ---------- config ----------

DATA_DIR = Path(os.environ.get("AL_DATA_DIR", "/data"))
DATA_DIR.mkdir(parents=True, exist_ok=True)

DB_PATH = DATA_DIR / "al.sqlite3"

PSK = os.environ.get("AL_PSK", "").strip()
if not PSK:
    raise SystemExit("AL_PSK environment variable is required and must be non-empty")

EMBEDDING_MODEL_NAME = os.environ.get("AL_EMBED_MODEL", "sentence-transformers/all-MiniLM-L6-v2")
HKDF_INFO = b"al-sealed-box-v1"

# Document grouping. The server merges all clients' entries into "documents"
# of temporally contiguous activity. Two consecutive entries (by start time)
# belong to the same document iff the gap between them is at most
# `DOCUMENT_GAP_SECONDS`. The client's `file_id` is retained as a hint but
# does NOT influence grouping — multiple clients with overlapping or
# back-to-back activity can be merged into a single larger document.
DOCUMENT_GAP_SECONDS = float(os.environ.get("AL_DOCUMENT_GAP_SECONDS", "300"))  # 5 min

# Key rotation. A key's *valid* window is what `/pubkey` advertises; the
# *retention* window is how long we keep its private half around to decrypt
# in-flight ciphertexts after it stops being advertised.
KEY_VALID_SECONDS = int(os.environ.get("AL_KEY_VALID_SECONDS", str(7 * 86400)))      # 7 days
KEY_ROTATION_LEAD_SECONDS = int(os.environ.get("AL_KEY_ROTATION_LEAD", str(86400)))  # 1 day
KEY_RETENTION_SECONDS = int(os.environ.get("AL_KEY_RETENTION", str(14 * 86400)))     # 14 days
KEY_SWEEP_SECONDS = int(os.environ.get("AL_KEY_SWEEP_INTERVAL", str(3600)))          # 1 hour


logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
log = logging.getLogger("al")


# ---------- sqlite ----------

# A short-lived connection per call. SQLite in WAL mode handles concurrency
# at the file level — readers don't block readers; the BUSY pragma below
# bounces writers off each other instead of hanging forever. We deliberately
# do NOT wrap this in a global threading.Lock: doing so deadlocks the moment
# one db() call is nested inside another (e.g. ingest → decrypt_envelope →
# candidate_private_keys).

@contextmanager
def db() -> Iterator[sqlite3.Connection]:
    conn = sqlite3.connect(
        DB_PATH,
        isolation_level=None,
        check_same_thread=False,
        timeout=30.0,
    )
    conn.execute("PRAGMA journal_mode = WAL")
    conn.execute("PRAGMA synchronous = NORMAL")
    conn.execute("PRAGMA foreign_keys = ON")
    conn.execute("PRAGMA busy_timeout = 5000")
    try:
        yield conn
    finally:
        conn.close()


def _init_schema() -> None:
    with db() as conn:
        conn.executescript("""
            CREATE TABLE IF NOT EXISTS entries (
                client_id   TEXT    NOT NULL,
                seq         INTEGER NOT NULL,
                file_id     TEXT    NOT NULL,
                source      TEXT    NOT NULL,
                started_at  REAL    NOT NULL,
                ended_at    REAL    NOT NULL,
                text        TEXT    NOT NULL,
                received_at REAL    NOT NULL,
                PRIMARY KEY (client_id, seq)
            );

            CREATE INDEX IF NOT EXISTS entries_file
                ON entries (client_id, file_id);
            CREATE INDEX IF NOT EXISTS entries_received_at
                ON entries (received_at);
            -- Speeds up the time-ordered walk in ingest's document binding
            -- as well as cross-client merged listings.
            CREATE INDEX IF NOT EXISTS entries_started_at
                ON entries (started_at);

            -- Materialized documents: temporally-contiguous clusters of
            -- entries across all clients, kept in sync on every ingest.
            -- See _attach_entry_to_doc / _refresh_doc_metadata.
            CREATE TABLE IF NOT EXISTS documents (
                id          INTEGER PRIMARY KEY AUTOINCREMENT,
                started_at  REAL    NOT NULL,
                ended_at    REAL    NOT NULL,
                entry_count INTEGER NOT NULL DEFAULT 0,
                text_hash   TEXT,
                snippet     TEXT
            );
            CREATE INDEX IF NOT EXISTS documents_started_at
                ON documents (started_at);
            CREATE INDEX IF NOT EXISTS documents_ended_at
                ON documents (ended_at);

            -- Embeddings are keyed by the SHA-256 of a document's
            -- concatenated text so we can reuse a cached vector whenever
            -- the grouping yields a document with the same content.
            CREATE TABLE IF NOT EXISTS doc_embeddings (
                text_hash   TEXT    PRIMARY KEY,
                embedding   BLOB    NOT NULL,
                dim         INTEGER NOT NULL,
                updated_at  REAL    NOT NULL
            );

            CREATE TABLE IF NOT EXISTS server_keys (
                id          INTEGER PRIMARY KEY AUTOINCREMENT,
                public_key  BLOB    NOT NULL,
                private_key BLOB    NOT NULL,
                created_at  REAL    NOT NULL,
                expires_at  REAL    NOT NULL
            );

            CREATE INDEX IF NOT EXISTS server_keys_expires
                ON server_keys (expires_at);
        """)

        # entries.doc_id is added lazily so an older container can roll
        # forward without losing data.
        cols = {r[1] for r in conn.execute("PRAGMA table_info(entries)").fetchall()}
        if "doc_id" not in cols:
            log.info("schema: adding entries.doc_id column")
            conn.execute("ALTER TABLE entries ADD COLUMN doc_id INTEGER")
        conn.execute("CREATE INDEX IF NOT EXISTS entries_doc_id ON entries(doc_id)")

        # FTS5 mirror of entries.text. `content='entries'` makes it an
        # external-content table sharing rowids with `entries`. Order is
        # important here: create the virtual table → backfill it from the
        # existing entries → only then add the keep-in-sync triggers.
        # If we created the triggers first, the document-grouping backfill
        # below would UPDATE entries.doc_id, fire the UPDATE trigger, and
        # attempt to delete rows from an empty FTS index — that path
        # corrupts the FTS5 b-tree ("database disk image is malformed").
        conn.execute("""
            CREATE VIRTUAL TABLE IF NOT EXISTS entries_fts USING fts5(
                text,
                content='entries',
                content_rowid='rowid',
                tokenize='unicode61 remove_diacritics 2'
            )
        """)

        fts_count = conn.execute("SELECT COUNT(*) FROM entries_fts").fetchone()[0]
        entries_count = conn.execute("SELECT COUNT(*) FROM entries").fetchone()[0]
        if fts_count < entries_count:
            log.info("schema: rebuilding FTS5 mirror (%d entries)", entries_count)
            conn.execute("INSERT INTO entries_fts(entries_fts) VALUES('rebuild')")

        conn.executescript("""
            CREATE TRIGGER IF NOT EXISTS entries_fts_ai AFTER INSERT ON entries BEGIN
              INSERT INTO entries_fts(rowid, text) VALUES (new.rowid, new.text);
            END;
            CREATE TRIGGER IF NOT EXISTS entries_fts_ad AFTER DELETE ON entries BEGIN
              INSERT INTO entries_fts(entries_fts, rowid, text) VALUES('delete', old.rowid, old.text);
            END;
            -- Skip the trigger body unless `text` actually changes. The doc-
            -- binding paths update entries.doc_id constantly; firing the FTS
            -- delete+insert for that would shred the index for no reason.
            CREATE TRIGGER IF NOT EXISTS entries_fts_au AFTER UPDATE OF text ON entries BEGIN
              INSERT INTO entries_fts(entries_fts, rowid, text) VALUES('delete', old.rowid, old.text);
              INSERT INTO entries_fts(rowid, text) VALUES (new.rowid, new.text);
            END;
        """)


_init_schema()


# ---------- one-time backfills ----------

def _backfill_documents_if_needed() -> None:
    """Group every entry currently lacking `doc_id` into materialized
    documents, in time order. Idempotent: only acts when there's something
    to do."""
    with db() as conn:
        pending = conn.execute(
            "SELECT COUNT(*) FROM entries WHERE doc_id IS NULL"
        ).fetchone()[0]
        if pending == 0:
            return
        log.info("backfill: assigning documents for %d entries", pending)
        rows = conn.execute(
            "SELECT rowid, started_at, ended_at FROM entries "
            "WHERE doc_id IS NULL ORDER BY started_at, rowid"
        ).fetchall()

        conn.execute("BEGIN IMMEDIATE")
        try:
            current_doc_id: Optional[int] = None
            current_end: float = 0.0
            touched: set[int] = set()
            for rowid, started_at, ended_at in rows:
                # Try to glue onto a pre-existing doc first (handles a
                # mid-corpus restart cleanly).
                if current_doc_id is None:
                    pred = conn.execute(
                        "SELECT id, ended_at FROM documents "
                        "WHERE ended_at <= ? ORDER BY ended_at DESC LIMIT 1",
                        (started_at,),
                    ).fetchone()
                    if pred and started_at - pred[1] <= DOCUMENT_GAP_SECONDS:
                        current_doc_id, current_end = pred[0], pred[1]

                if current_doc_id is None or started_at - current_end > DOCUMENT_GAP_SECONDS:
                    cur = conn.execute(
                        "INSERT INTO documents(started_at, ended_at, entry_count) VALUES (?, ?, 0)",
                        (started_at, ended_at),
                    )
                    current_doc_id = int(cur.lastrowid)
                    current_end = ended_at
                else:
                    current_end = max(current_end, ended_at)
                    conn.execute(
                        "UPDATE documents SET ended_at = ? WHERE id = ?",
                        (current_end, current_doc_id),
                    )
                conn.execute(
                    "UPDATE entries SET doc_id = ? WHERE rowid = ?",
                    (current_doc_id, rowid),
                )
                conn.execute(
                    "UPDATE documents SET entry_count = entry_count + 1 WHERE id = ?",
                    (current_doc_id,),
                )
                touched.add(current_doc_id)
            conn.execute("COMMIT")
        except Exception:
            conn.execute("ROLLBACK")
            raise

        for doc_id in touched:
            _refresh_doc_metadata(conn, doc_id)


_backfill_documents_if_needed()


# ---------- key rotation ----------

def _mint_key(conn: sqlite3.Connection, now: float) -> tuple[int, bytes, bytes, float]:
    priv = X25519PrivateKey.generate()
    pub_bytes = priv.public_key().public_bytes(Encoding.Raw, PublicFormat.Raw)
    priv_bytes = priv.private_bytes_raw()
    expires_at = now + KEY_VALID_SECONDS
    cursor = conn.execute(
        "INSERT INTO server_keys(public_key, private_key, created_at, expires_at) VALUES (?, ?, ?, ?)",
        (pub_bytes, priv_bytes, now, expires_at),
    )
    return int(cursor.lastrowid), pub_bytes, priv_bytes, expires_at


def current_pubkey() -> tuple[bytes, float]:
    """Return the public key clients should encrypt to right now, plus its
    `valid_until` UNIX timestamp. If the latest key is within the rotation
    lead window, mint a new one and return that instead — this way clients
    that fetch the key just before rotation get the *new* one and we don't
    have to push them off the old key mid-flight."""
    now = time.time()
    with db() as conn:
        row = conn.execute(
            "SELECT id, public_key, expires_at FROM server_keys WHERE expires_at > ? "
            "ORDER BY expires_at DESC LIMIT 1",
            (now,),
        ).fetchone()
        if row is None:
            _, pub, _, expires_at = _mint_key(conn, now)
            log.info("minted first server key (expires_at=%.0f)", expires_at)
            return pub, expires_at

        key_id, pub_bytes, expires_at = row
        remaining = expires_at - now
        if remaining <= KEY_ROTATION_LEAD_SECONDS:
            # Time to rotate: mint a new one and hand it to the caller.
            _, new_pub, _, new_expires = _mint_key(conn, now)
            log.info(
                "rotated server key (old #%d had %.0fs remaining, new expires_at=%.0f)",
                key_id, remaining, new_expires,
            )
            return new_pub, new_expires
        return pub_bytes, expires_at


def candidate_private_keys() -> list[X25519PrivateKey]:
    """All private keys we should try on decrypt: every key whose private
    half is still within the retention window. Newest first so the common
    case (fresh ciphertext, current key) hits on the first try."""
    cutoff = time.time() - KEY_RETENTION_SECONDS
    with db() as conn:
        rows = conn.execute(
            "SELECT private_key FROM server_keys WHERE expires_at > ? "
            "ORDER BY id DESC",
            (cutoff,),
        ).fetchall()
    return [X25519PrivateKey.from_private_bytes(r[0]) for r in rows]


def purge_old_keys() -> int:
    cutoff = time.time() - KEY_RETENTION_SECONDS
    with db() as conn:
        cur = conn.execute("DELETE FROM server_keys WHERE expires_at <= ?", (cutoff,))
    if cur.rowcount:
        log.info("purged %d expired server key(s)", cur.rowcount)
    return cur.rowcount


# ---------- crypto: sealed-box-style envelope ----------

def decrypt_envelope(envelope: bytes) -> bytes:
    """Decrypts a single client message. Tries every still-retained server
    private key, newest first, since the wire envelope doesn't include a
    key id."""
    if len(envelope) < 32 + 12 + 16:
        raise ValueError("envelope too short")
    ephemeral_pub_bytes = envelope[:32]
    nonce = envelope[32:44]
    ciphertext = envelope[44:]

    ephemeral_pub = X25519PublicKey.from_public_bytes(ephemeral_pub_bytes)

    last_err: Optional[Exception] = None
    for priv in candidate_private_keys():
        try:
            shared = priv.exchange(ephemeral_pub)
            server_pub_bytes = priv.public_key().public_bytes(Encoding.Raw, PublicFormat.Raw)
            sym = HKDF(
                algorithm=SHA256(),
                length=32,
                salt=ephemeral_pub_bytes + server_pub_bytes,
                info=HKDF_INFO,
            ).derive(shared)
            return ChaCha20Poly1305(sym).decrypt(nonce, ciphertext, None)
        except InvalidTag as exc:
            last_err = exc
            continue
        except Exception as exc:  # noqa: BLE001 — surface to caller
            last_err = exc
            continue
    raise ValueError(f"no server key decrypted the envelope: {last_err}")


# ---------- embeddings ----------

class Embedder:
    """Lazy CPU-only sentence-transformers wrapper. Loaded on first use."""

    def __init__(self, model_name: str):
        self.model_name = model_name
        self._model = None
        self._lock = threading.Lock()

    def _load(self):
        with self._lock:
            if self._model is None:
                from sentence_transformers import SentenceTransformer
                log.info("loading embedding model %s (CPU)", self.model_name)
                self._model = SentenceTransformer(self.model_name, device="cpu")
        return self._model

    def encode(self, texts: list[str]) -> np.ndarray:
        if not texts:
            return np.zeros((0, 384), dtype=np.float32)
        model = self._load()
        vecs = model.encode(
            texts,
            convert_to_numpy=True,
            normalize_embeddings=True,
            show_progress_bar=False,
        )
        return vecs.astype(np.float32, copy=False)


EMBEDDER = Embedder(EMBEDDING_MODEL_NAME)


def _text_hash(text: str) -> str:
    return hashlib.sha256(text.encode("utf-8")).hexdigest()


# ---------- materialized documents ----------

def _refresh_doc_metadata(conn: sqlite3.Connection, doc_id: int) -> None:
    """Recompute `text_hash`, `snippet`, and `entry_count` for one document
    by reading its entries in time order. Call after attaching, merging, or
    extending a document so subsequent reads stay consistent."""
    rows = conn.execute(
        "SELECT text FROM entries WHERE doc_id = ? ORDER BY started_at, rowid",
        (doc_id,),
    ).fetchall()
    if not rows:
        # Empty doc — clean up.
        conn.execute("DELETE FROM documents WHERE id = ?", (doc_id,))
        return
    joined = " ".join((r[0] or "").strip() for r in rows).strip()
    text_hash = _text_hash(joined) if joined else ""
    snippet = joined if len(joined) <= 240 else joined[:237] + "..."
    conn.execute(
        "UPDATE documents SET text_hash = ?, snippet = ?, entry_count = ? WHERE id = ?",
        (text_hash, snippet, len(rows), doc_id),
    )


def _attach_entry_to_doc(
    conn: sqlite3.Connection, rowid: int, started_at: float, ended_at: float
) -> int:
    """Bind one new entry to a document, creating or merging as needed.

    The rules mirror the offline grouping the server used to do on every
    read:
      - if the entry's time window overlaps an existing doc → attach
      - if it bridges two docs (gap to predecessor and successor both
        ≤ DOCUMENT_GAP_SECONDS) → merge them
      - if it joins only the predecessor or only the successor → extend
      - otherwise → start a new doc

    Returns the doc_id the entry was attached to. Caller must follow up
    with `_refresh_doc_metadata(...)` for each doc_id it touched."""
    gap = DOCUMENT_GAP_SECONDS

    within = conn.execute(
        "SELECT id, started_at, ended_at FROM documents "
        "WHERE started_at <= ? AND ended_at >= ? LIMIT 1",
        (ended_at, started_at),
    ).fetchone()
    if within is not None:
        doc_id = int(within[0])
        new_start = min(within[1], started_at)
        new_end = max(within[2], ended_at)
        if new_start != within[1] or new_end != within[2]:
            conn.execute(
                "UPDATE documents SET started_at = ?, ended_at = ? WHERE id = ?",
                (new_start, new_end, doc_id),
            )
        conn.execute("UPDATE entries SET doc_id = ? WHERE rowid = ?", (doc_id, rowid))
        return doc_id

    pred = conn.execute(
        "SELECT id, started_at, ended_at FROM documents "
        "WHERE ended_at < ? ORDER BY ended_at DESC LIMIT 1",
        (started_at,),
    ).fetchone()
    succ = conn.execute(
        "SELECT id, started_at, ended_at FROM documents "
        "WHERE started_at > ? ORDER BY started_at ASC LIMIT 1",
        (ended_at,),
    ).fetchone()
    joins_pred = pred is not None and (started_at - pred[2]) <= gap
    joins_succ = succ is not None and (succ[1] - ended_at) <= gap

    if joins_pred and joins_succ:
        target_id = int(pred[0])
        donor_id = int(succ[0])
        conn.execute(
            "UPDATE documents SET started_at = ?, ended_at = ? WHERE id = ?",
            (min(pred[1], started_at), max(succ[2], ended_at), target_id),
        )
        # Move every entry from donor → target, then drop donor.
        conn.execute(
            "UPDATE entries SET doc_id = ? WHERE doc_id = ?",
            (target_id, donor_id),
        )
        conn.execute("DELETE FROM documents WHERE id = ?", (donor_id,))
        conn.execute("UPDATE entries SET doc_id = ? WHERE rowid = ?", (target_id, rowid))
        return target_id

    if joins_pred:
        doc_id = int(pred[0])
        conn.execute(
            "UPDATE documents SET ended_at = ? WHERE id = ? AND ended_at < ?",
            (ended_at, doc_id, ended_at),
        )
        conn.execute("UPDATE entries SET doc_id = ? WHERE rowid = ?", (doc_id, rowid))
        return doc_id

    if joins_succ:
        doc_id = int(succ[0])
        conn.execute(
            "UPDATE documents SET started_at = ? WHERE id = ? AND started_at > ?",
            (started_at, doc_id, started_at),
        )
        conn.execute("UPDATE entries SET doc_id = ? WHERE rowid = ?", (doc_id, rowid))
        return doc_id

    cur = conn.execute(
        "INSERT INTO documents(started_at, ended_at, entry_count) VALUES (?, ?, 0)",
        (started_at, ended_at),
    )
    doc_id = int(cur.lastrowid)
    conn.execute("UPDATE entries SET doc_id = ? WHERE rowid = ?", (doc_id, rowid))
    return doc_id


def _document_client_ids(conn: sqlite3.Connection, doc_id: int) -> list[str]:
    rows = conn.execute(
        "SELECT DISTINCT client_id FROM entries WHERE doc_id = ? ORDER BY client_id",
        (doc_id,),
    ).fetchall()
    return [r[0] for r in rows]


def _doc_text(conn: sqlite3.Connection, doc_id: int) -> str:
    rows = conn.execute(
        "SELECT text FROM entries WHERE doc_id = ? ORDER BY started_at, rowid",
        (doc_id,),
    ).fetchall()
    return " ".join((r[0] or "").strip() for r in rows).strip()


# ---------- FTS5 query helpers ----------

_FTS_SAFE_RE = None  # populated lazily; not really needed because we quote.


def _to_fts_match(q: str) -> Optional[str]:
    """Convert a user query string into a safe FTS5 MATCH expression.

    Splits on whitespace, double-quote-escapes each token, joins with AND.
    The trailing token gets a `*` prefix wildcard so partial-word queries
    work mid-type (FTS5's prefix tokens must be alphanumeric). Empty input
    returns None — the caller should skip the FTS branch."""
    tokens = [t for t in (q or "").split() if t]
    if not tokens:
        return None
    parts: list[str] = []
    for i, tok in enumerate(tokens):
        # Strip characters FTS5 reserves; we then quote the rest to make
        # punctuation safe to embed.
        cleaned = "".join(ch for ch in tok if ch.isalnum() or ch in "_'-")
        if not cleaned:
            continue
        safe = cleaned.replace('"', '""')
        if i == len(tokens) - 1 and cleaned[-1].isalnum():
            parts.append(f'"{safe}"*')
        else:
            parts.append(f'"{safe}"')
    if not parts:
        return None
    return " ".join(parts)


class Document:
    """Lightweight view over a materialized row in the `documents` table."""

    __slots__ = ("id", "started_at", "ended_at", "entry_count", "text_hash", "snippet", "client_ids")

    def __init__(
        self,
        id: int,
        started_at: float,
        ended_at: float,
        entry_count: int,
        text_hash: Optional[str],
        snippet: Optional[str],
        client_ids: list[str],
    ):
        self.id = id
        self.started_at = started_at
        self.ended_at = ended_at
        self.entry_count = entry_count
        self.text_hash = text_hash
        self.snippet = snippet or ""
        self.client_ids = client_ids

    def to_dict(self) -> dict:
        return {
            "doc_id": str(self.id),
            "text_hash": self.text_hash or "",
            "started_at": self.started_at,
            "ended_at": self.ended_at,
            "entry_count": self.entry_count,
            "client_ids": self.client_ids,
            "snippet": self.snippet,
        }


def _load_documents(
    conn: sqlite3.Connection,
    *,
    client_id: Optional[str] = None,
    order_desc: bool = True,
    limit: Optional[int] = None,
    offset: int = 0,
    ids: Optional[list[int]] = None,
) -> list[Document]:
    """Read materialized documents from the `documents` table.

    When `client_id` is set, restrict to documents that contain at least one
    entry from that client; we use a sub-select against `entries.doc_id`
    rather than re-walking the corpus."""
    where = "1=1"
    args: list = []
    if client_id:
        where += " AND id IN (SELECT DISTINCT doc_id FROM entries WHERE client_id = ?)"
        args.append(client_id)
    if ids is not None:
        if not ids:
            return []
        placeholders = ",".join(["?"] * len(ids))
        where += f" AND id IN ({placeholders})"
        args.extend(ids)
    direction = "DESC" if order_desc else "ASC"
    sql = (
        "SELECT id, started_at, ended_at, entry_count, text_hash, snippet "
        f"FROM documents WHERE {where} ORDER BY started_at {direction}"
    )
    if limit is not None:
        sql += f" LIMIT {int(limit)} OFFSET {int(offset)}"
    rows = conn.execute(sql, args).fetchall()
    if not rows:
        return []

    doc_ids = [int(r[0]) for r in rows]
    # One round-trip to gather distinct client_ids per doc.
    placeholders = ",".join(["?"] * len(doc_ids))
    client_map: dict[int, list[str]] = {d: [] for d in doc_ids}
    for did, cid in conn.execute(
        f"SELECT doc_id, client_id FROM (SELECT DISTINCT doc_id, client_id FROM entries "
        f"WHERE doc_id IN ({placeholders})) ORDER BY doc_id, client_id",
        doc_ids,
    ).fetchall():
        client_map.setdefault(int(did), []).append(cid)

    return [
        Document(
            id=int(r[0]),
            started_at=float(r[1]),
            ended_at=float(r[2]),
            entry_count=int(r[3]),
            text_hash=r[4],
            snippet=r[5],
            client_ids=client_map.get(int(r[0]), []),
        )
        for r in rows
    ]


def _ensure_doc_embedding(
    conn: sqlite3.Connection,
    doc: Document,
) -> Optional[np.ndarray]:
    """Return (and cache) the normalized embedding for a document.

    Looks up by `text_hash` first; if the doc is unembedded (or its hash
    changed since the last cache write) we re-read its entry text and
    compute fresh."""
    if doc.entry_count <= 0:
        return None
    h = doc.text_hash or ""
    if h:
        row = conn.execute(
            "SELECT embedding, dim FROM doc_embeddings WHERE text_hash = ?",
            (h,),
        ).fetchone()
        if row is not None:
            return np.frombuffer(row[0], dtype=np.float32).reshape((row[1],))

    text = _doc_text(conn, doc.id)
    if not text:
        return None
    h = _text_hash(text)
    vec = EMBEDDER.encode([text])[0]
    conn.execute(
        """
        INSERT OR REPLACE INTO doc_embeddings(text_hash, embedding, dim, updated_at)
        VALUES (?, ?, ?, ?)
        """,
        (h, vec.tobytes(), int(vec.shape[0]), time.time()),
    )
    # If `documents.text_hash` was stale (eg. backfill in progress), pull it
    # back in sync so future lookups hit the cache cleanly.
    if doc.text_hash != h:
        conn.execute(
            "UPDATE documents SET text_hash = ? WHERE id = ?",
            (h, doc.id),
        )
        doc.text_hash = h
    return vec


# ---------- auth ----------

def require_psk(authorization: str = Header(default="")) -> None:
    expected = f"Bearer {PSK}"
    if not authorization or len(authorization) != len(expected):
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="unauthorized")
    # constant-time compare
    diff = 0
    for a, b in zip(authorization.encode(), expected.encode()):
        diff |= a ^ b
    if diff != 0:
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="unauthorized")


# ---------- pydantic models ----------

class LogEntry(BaseModel):
    seq: int = Field(..., ge=0)
    ciphertext_b64: str


class LogBatch(BaseModel):
    client_id: str = Field(..., min_length=1, max_length=128)
    batch: list[LogEntry]


class IngestAck(BaseModel):
    highest_acked_seq: int


class PubkeyResp(BaseModel):
    public_key_b64: str
    valid_until: float  # unix seconds; clients should refetch before this
    alg: str = "x25519-hkdf-sha256-chacha20poly1305"
    info: str = HKDF_INFO.decode()


class SearchHit(BaseModel):
    client_id: str
    seq: int
    file_id: str
    source: str
    started_at: float
    ended_at: float
    text: str
    score: Optional[float] = None


class SearchResponse(BaseModel):
    hits: list[SearchHit]


class DocumentHit(BaseModel):
    doc_id: str
    text_hash: str
    started_at: float
    ended_at: float
    entry_count: int
    client_ids: list[str]
    snippet: str
    score: Optional[float] = None


class DocumentSearchResponse(BaseModel):
    hits: list[DocumentHit]


class DocumentListResponse(BaseModel):
    documents: list[DocumentHit]


# ---------- background tasks ----------

@asynccontextmanager
async def lifespan(_app: FastAPI):
    # Ensure there's a current key on boot.
    current_pubkey()
    stop = asyncio.Event()

    async def sweep():
        while not stop.is_set():
            try:
                purge_old_keys()
                # Touch current_pubkey() so rotation happens on schedule
                # even if no client has fetched recently.
                current_pubkey()
            except Exception as exc:  # noqa: BLE001
                log.warning("key sweep failed: %s", exc)
            try:
                await asyncio.wait_for(stop.wait(), timeout=KEY_SWEEP_SECONDS)
            except asyncio.TimeoutError:
                pass

    task = asyncio.create_task(sweep())
    try:
        yield
    finally:
        stop.set()
        task.cancel()
        try:
            await task
        except (asyncio.CancelledError, Exception):
            pass


# ---------- app ----------

app = FastAPI(title="al log server", version="0.2.0", lifespan=lifespan)


@app.get("/health")
def health() -> dict:
    return {"ok": True}


@app.get("/pubkey", response_model=PubkeyResp, dependencies=[Depends(require_psk)])
def pubkey() -> PubkeyResp:
    pub_bytes, valid_until = current_pubkey()
    return PubkeyResp(
        public_key_b64=base64.b64encode(pub_bytes).decode(),
        valid_until=valid_until,
    )


@app.post("/logs", response_model=IngestAck, dependencies=[Depends(require_psk)])
def ingest(batch: LogBatch) -> IngestAck:
    if not batch.batch:
        # Tell the client what we already know — useful for catch-up.
        with db() as conn:
            row = conn.execute(
                "SELECT COALESCE(MAX(seq), -1) FROM entries WHERE client_id = ?",
                (batch.client_id,),
            ).fetchone()
            return IngestAck(highest_acked_seq=int(row[0]))

    items = sorted(batch.batch, key=lambda e: e.seq)
    now = time.time()

    # Decrypt every entry up front, *before* opening any transaction.
    # `decrypt_envelope` opens its own short db() to fetch candidate keys, so
    # doing it while holding a connection would have to nest db() calls.
    # On the first decrypt failure we stop and only commit the contiguous
    # prefix — preserves the at-least-once/seq-contiguous ack contract.
    decoded: list[Tuple[int, dict]] = []
    for entry in items:
        try:
            envelope = base64.b64decode(entry.ciphertext_b64, validate=True)
            plaintext = decrypt_envelope(envelope)
            payload = json.loads(plaintext.decode("utf-8"))
        except Exception as exc:  # noqa: BLE001
            log.warning("decrypt/parse failed for %s/%d: %s", batch.client_id, entry.seq, exc)
            break
        decoded.append((entry.seq, payload))

    with db() as conn:
        if decoded:
            seq_range = (decoded[0][0], decoded[-1][0])
            existing = {
                r[0]
                for r in conn.execute(
                    "SELECT seq FROM entries WHERE client_id = ? AND seq BETWEEN ? AND ?",
                    (batch.client_id, seq_range[0], seq_range[1]),
                )
            }
            touched_docs: set[int] = set()
            conn.execute("BEGIN IMMEDIATE")
            try:
                for seq, payload in decoded:
                    if seq in existing:
                        continue
                    started_at = float(payload.get("started_at", now))
                    ended_at = float(payload.get("ended_at", started_at))
                    if ended_at < started_at:
                        ended_at = started_at
                    cur = conn.execute(
                        """
                        INSERT INTO entries(client_id, seq, file_id, source, started_at, ended_at, text, received_at)
                        VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                        """,
                        (
                            batch.client_id,
                            seq,
                            str(payload.get("file_id", "")),
                            str(payload.get("source", "")),
                            started_at,
                            ended_at,
                            str(payload.get("text", "")),
                            now,
                        ),
                    )
                    new_rowid = int(cur.lastrowid)
                    doc_id = _attach_entry_to_doc(conn, new_rowid, started_at, ended_at)
                    touched_docs.add(doc_id)
                # Refresh metadata (text_hash, snippet, entry_count) once per
                # affected doc rather than once per entry — embeddings cache
                # by text_hash so a stable hash matters.
                for doc_id in touched_docs:
                    _refresh_doc_metadata(conn, doc_id)
                conn.execute("COMMIT")
            except Exception:
                conn.execute("ROLLBACK")
                raise

        row = conn.execute(
            "SELECT COALESCE(MAX(seq), -1) FROM entries WHERE client_id = ?",
            (batch.client_id,),
        ).fetchone()
        highest = int(row[0])

    return IngestAck(highest_acked_seq=highest)


@app.get("/search", response_model=SearchResponse, dependencies=[Depends(require_psk)])
def search(
    q: str = Query(..., min_length=1),
    client_id: Optional[str] = None,
    limit: int = Query(50, ge=1, le=500),
) -> SearchResponse:
    """Token-level full-text search via SQLite FTS5.

    The user query is sanitized into an FTS5 MATCH expression — each token
    is quoted and the trailing word gets a `*` so partial-word queries work
    while typing. Falls back to a plain `LOWER(text) LIKE %q%` scan when
    the query contains nothing FTS-tokenizable (e.g. only punctuation)."""
    fts_query = _to_fts_match(q)
    with db() as conn:
        if fts_query is not None:
            sql = (
                "SELECT entries.client_id, entries.seq, entries.file_id, "
                "entries.source, entries.started_at, entries.ended_at, entries.text "
                "FROM entries_fts "
                "JOIN entries ON entries.rowid = entries_fts.rowid "
                "WHERE entries_fts MATCH ?"
            )
            args: list = [fts_query]
            if client_id:
                sql += " AND entries.client_id = ?"
                args.append(client_id)
            sql += " ORDER BY entries.started_at DESC LIMIT ?"
            args.append(limit)
            rows = conn.execute(sql, args).fetchall()
        else:
            like = f"%{q.lower()}%"
            sql = (
                "SELECT client_id, seq, file_id, source, started_at, ended_at, text "
                "FROM entries WHERE LOWER(text) LIKE ?"
            )
            args = [like]
            if client_id:
                sql += " AND client_id = ?"
                args.append(client_id)
            sql += " ORDER BY started_at DESC LIMIT ?"
            args.append(limit)
            rows = conn.execute(sql, args).fetchall()
    hits = [
        SearchHit(
            client_id=r[0], seq=r[1], file_id=r[2], source=r[3],
            started_at=r[4], ended_at=r[5], text=r[6],
        )
        for r in rows
    ]
    return SearchResponse(hits=hits)


@app.get("/search/semantic", response_model=DocumentSearchResponse, dependencies=[Depends(require_psk)])
def semantic_search(
    q: str = Query(..., min_length=1),
    client_id: Optional[str] = None,
    limit: int = Query(10, ge=1, le=100),
) -> DocumentSearchResponse:
    """Rank materialized documents by cosine similarity to the query."""
    with db() as conn:
        docs = _load_documents(conn, client_id=client_id, order_desc=True)
        vecs: list[np.ndarray] = []
        kept: list[Document] = []
        for doc in docs:
            vec = _ensure_doc_embedding(conn, doc)
            if vec is None:
                continue
            vecs.append(vec)
            kept.append(doc)

    if not vecs:
        return DocumentSearchResponse(hits=[])

    query_vec = EMBEDDER.encode([q])[0]
    matrix = np.vstack(vecs)
    scores = matrix @ query_vec
    top_idx = np.argsort(-scores)[:limit]

    hits: list[DocumentHit] = []
    for i in top_idx:
        doc = kept[int(i)]
        d = doc.to_dict()
        d["score"] = float(scores[int(i)])
        hits.append(DocumentHit(**d))
    return DocumentSearchResponse(hits=hits)


@app.get("/documents", response_model=DocumentListResponse, dependencies=[Depends(require_psk)])
def list_documents(
    client_id: Optional[str] = None,
    limit: int = Query(50, ge=1, le=500),
    offset: int = Query(0, ge=0),
) -> DocumentListResponse:
    """Return materialized documents, newest first, paginated."""
    with db() as conn:
        docs = _load_documents(
            conn, client_id=client_id, order_desc=True, limit=limit, offset=offset
        )
    return DocumentListResponse(documents=[DocumentHit(**d.to_dict()) for d in docs])


@app.get("/search/hybrid", response_model=DocumentSearchResponse, dependencies=[Depends(require_psk)])
def hybrid_search(
    q: str = Query(..., min_length=1),
    client_id: Optional[str] = None,
    limit: int = Query(20, ge=1, le=500),
    offset: int = Query(0, ge=0),
    alpha: float = Query(0.7, ge=0.0, le=1.0),
) -> DocumentSearchResponse:
    """Score documents by a blend of FTS5 bm25 and cosine similarity.

    `alpha` weights the semantic side; `1 - alpha` weights the text side.
    Both scores are min/max-normalized to [0, 1] before mixing so the
    weighting is meaningful regardless of corpus size. A document needs a
    positive combined score to be returned."""
    fts_query = _to_fts_match(q)
    with db() as conn:
        # Text scores: per-document sum of bm25 across matching entries.
        # bm25() returns a *negative* relevance value (lower = more
        # relevant), so we negate it to get a "higher is better" score.
        text_scores_by_doc: dict[int, float] = {}
        if fts_query is not None:
            for did, score in conn.execute(
                """
                SELECT entries.doc_id, SUM(-fts.score) AS s
                FROM (
                    SELECT rowid, bm25(entries_fts) AS score
                    FROM entries_fts
                    WHERE entries_fts MATCH ?
                ) AS fts
                JOIN entries ON entries.rowid = fts.rowid
                WHERE entries.doc_id IS NOT NULL
                GROUP BY entries.doc_id
                """,
                (fts_query,),
            ).fetchall():
                text_scores_by_doc[int(did)] = float(score)

        docs = _load_documents(conn, client_id=client_id, order_desc=True)
        if not docs:
            return DocumentSearchResponse(hits=[])

        vecs: list[np.ndarray] = []
        kept: list[Document] = []
        for doc in docs:
            vec = _ensure_doc_embedding(conn, doc)
            if vec is None:
                continue
            vecs.append(vec)
            kept.append(doc)

    if not vecs:
        return DocumentSearchResponse(hits=[])

    matrix = np.vstack(vecs)
    semantic_scores = matrix @ EMBEDDER.encode([q])[0]

    text_scores = np.array(
        [text_scores_by_doc.get(d.id, 0.0) for d in kept], dtype=np.float32,
    )

    # Normalize each axis to [0, 1].
    def _norm(arr: np.ndarray) -> np.ndarray:
        lo = float(arr.min()) if arr.size else 0.0
        hi = float(arr.max()) if arr.size else 0.0
        if hi - lo < 1e-9:
            # All equal: keep all zero so this axis has no weight in mixing.
            return np.zeros_like(arr)
        return (arr - lo) / (hi - lo)

    sem_norm = _norm(semantic_scores)
    txt_norm = _norm(text_scores)
    combined = alpha * sem_norm + (1.0 - alpha) * txt_norm

    mask = combined > 0
    indices = np.where(mask)[0]
    ranked = indices[np.argsort(-combined[indices])]
    window = ranked[offset:offset + limit]

    hits: list[DocumentHit] = []
    for i in window:
        doc = kept[int(i)]
        d = doc.to_dict()
        d["score"] = float(combined[int(i)])
        hits.append(DocumentHit(**d))
    return DocumentSearchResponse(hits=hits)


@app.get("/document/{doc_id}", dependencies=[Depends(require_psk)])
def get_document(doc_id: str) -> dict:
    """Fetch the full entry list for one materialized document."""
    try:
        did = int(doc_id)
    except ValueError:
        raise HTTPException(status_code=404, detail="document not found")
    with db() as conn:
        docs = _load_documents(conn, ids=[did])
        if not docs:
            raise HTTPException(status_code=404, detail="document not found")
        doc = docs[0]
        entry_rows = conn.execute(
            "SELECT client_id, seq, file_id, source, started_at, ended_at, text "
            "FROM entries WHERE doc_id = ? ORDER BY started_at, rowid",
            (did,),
        ).fetchall()
    return {
        **doc.to_dict(),
        "entries": [
            {
                "client_id": r[0], "seq": r[1], "file_id": r[2], "source": r[3],
                "started_at": r[4], "ended_at": r[5], "text": r[6],
            }
            for r in entry_rows
        ],
    }


@app.get("/recent", dependencies=[Depends(require_psk)])
def recent(
    limit: int = Query(100, ge=1, le=1000),
    client_id: Optional[str] = None,
) -> dict:
    """Time-merged feed across every client (or one client if filtered).
    Entries are returned newest first by `started_at`."""
    sql = (
        "SELECT client_id, seq, file_id, source, started_at, ended_at, text "
        "FROM entries"
    )
    args: list = []
    if client_id:
        sql += " WHERE client_id = ?"
        args.append(client_id)
    sql += " ORDER BY started_at DESC LIMIT ?"
    args.append(limit)
    with db() as conn:
        rows = conn.execute(sql, args).fetchall()
    return {
        "entries": [
            {
                "client_id": r[0], "seq": r[1], "file_id": r[2], "source": r[3],
                "started_at": r[4], "ended_at": r[5], "text": r[6],
            }
            for r in rows
        ]
    }


@app.get("/clients", dependencies=[Depends(require_psk)])
def clients() -> dict:
    """Per-client summary: entry count, file count, time range."""
    with db() as conn:
        rows = conn.execute(
            """
            SELECT client_id,
                   COUNT(*)                  AS entry_count,
                   COUNT(DISTINCT file_id)   AS file_count,
                   MIN(started_at)           AS first_at,
                   MAX(started_at)           AS last_at
            FROM entries
            GROUP BY client_id
            ORDER BY last_at DESC NULLS LAST
            """
        ).fetchall()
    return {
        "clients": [
            {
                "client_id": r[0],
                "entry_count": int(r[1]),
                "file_count": int(r[2]),
                "first_at": r[3],
                "last_at": r[4],
            }
            for r in rows
        ]
    }


@app.get("/files/{client_id}/{file_id:path}", dependencies=[Depends(require_psk)])
def file_contents(client_id: str, file_id: str) -> dict:
    with db() as conn:
        rows = conn.execute(
            "SELECT seq, source, started_at, ended_at, text FROM entries "
            "WHERE client_id = ? AND file_id = ? ORDER BY seq",
            (client_id, file_id),
        ).fetchall()
    return {
        "client_id": client_id,
        "file_id": file_id,
        "entries": [
            {"seq": r[0], "source": r[1], "started_at": r[2], "ended_at": r[3], "text": r[4]}
            for r in rows
        ],
    }
