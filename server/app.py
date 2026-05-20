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

            -- Embeddings are keyed by the SHA-256 of the concatenated
            -- document text so we can reuse a cached vector whenever the
            -- grouping yields a document with the same content.
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


_init_schema()


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


class Document:
    """One temporally-contiguous chunk of entries, merged across clients."""

    __slots__ = ("started_at", "ended_at", "entries")

    def __init__(self, started_at: float, ended_at: float):
        self.started_at = started_at
        self.ended_at = ended_at
        self.entries: list[dict] = []

    @property
    def text(self) -> str:
        return " ".join(e["text"] for e in self.entries).strip()

    @property
    def client_ids(self) -> list[str]:
        seen: list[str] = []
        for e in self.entries:
            if e["client_id"] not in seen:
                seen.append(e["client_id"])
        return seen

    def to_dict(self) -> dict:
        text = self.text
        snippet = text if len(text) <= 240 else text[:237] + "..."
        return {
            "doc_id": _text_hash(f"{self.started_at:.3f}|{self.ended_at:.3f}|{len(self.entries)}"),
            "text_hash": _text_hash(text),
            "started_at": self.started_at,
            "ended_at": self.ended_at,
            "entry_count": len(self.entries),
            "client_ids": self.client_ids,
            "snippet": snippet,
        }


def compute_documents(
    conn: sqlite3.Connection,
    client_id: Optional[str] = None,
    gap_seconds: float = DOCUMENT_GAP_SECONDS,
) -> list[Document]:
    """Walk all entries in time order and group them into documents.

    A new document starts when the gap between an entry's `started_at` and
    the running document's `ended_at` exceeds `gap_seconds`. Grouping is
    cross-client by default — pass `client_id` to scope to one device."""
    sql = (
        "SELECT client_id, seq, file_id, source, started_at, ended_at, text "
        "FROM entries"
    )
    args: list = []
    if client_id:
        sql += " WHERE client_id = ?"
        args.append(client_id)
    sql += " ORDER BY started_at"
    rows = conn.execute(sql, args).fetchall()

    docs: list[Document] = []
    current: Optional[Document] = None
    for cid, seq, fid, src, started, ended, text in rows:
        if current is None or started - current.ended_at > gap_seconds:
            if current is not None:
                docs.append(current)
            current = Document(started_at=started, ended_at=ended)
        current.ended_at = max(current.ended_at, ended)
        current.entries.append({
            "client_id": cid, "seq": seq, "file_id": fid, "source": src,
            "started_at": started, "ended_at": ended, "text": text,
        })
    if current is not None:
        docs.append(current)
    return docs


def _ensure_doc_embedding(conn: sqlite3.Connection, text: str) -> Optional[np.ndarray]:
    """Return (and cache) the normalized embedding for a document's text."""
    if not text:
        return None
    h = _text_hash(text)
    row = conn.execute(
        "SELECT embedding, dim FROM doc_embeddings WHERE text_hash = ?",
        (h,),
    ).fetchone()
    if row is not None:
        return np.frombuffer(row[0], dtype=np.float32).reshape((row[1],))
    vec = EMBEDDER.encode([text])[0]
    conn.execute(
        """
        INSERT OR REPLACE INTO doc_embeddings(text_hash, embedding, dim, updated_at)
        VALUES (?, ?, ?, ?)
        """,
        (h, vec.tobytes(), int(vec.shape[0]), time.time()),
    )
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
            conn.execute("BEGIN IMMEDIATE")
            try:
                for seq, payload in decoded:
                    if seq in existing:
                        continue
                    conn.execute(
                        """
                        INSERT INTO entries(client_id, seq, file_id, source, started_at, ended_at, text, received_at)
                        VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                        """,
                        (
                            batch.client_id,
                            seq,
                            str(payload.get("file_id", "")),
                            str(payload.get("source", "")),
                            float(payload.get("started_at", now)),
                            float(payload.get("ended_at", now)),
                            str(payload.get("text", "")),
                            now,
                        ),
                    )
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
    """Plain substring (case-insensitive) search over entry text."""
    like = f"%{q.lower()}%"
    sql = (
        "SELECT client_id, seq, file_id, source, started_at, ended_at, text "
        "FROM entries WHERE LOWER(text) LIKE ?"
    )
    args: list = [like]
    if client_id:
        sql += " AND client_id = ?"
        args.append(client_id)
    sql += " ORDER BY started_at DESC LIMIT ?"
    args.append(limit)
    with db() as conn:
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
    gap_seconds: Optional[float] = Query(None, ge=1.0, le=86400.0),
) -> DocumentSearchResponse:
    """Cross-client semantic search.

    The server groups all entries (or one client's, with `client_id=…`) into
    documents using `gap_seconds` (default `AL_DOCUMENT_GAP_SECONDS`), then
    ranks documents by cosine similarity to the query."""
    gap = gap_seconds if gap_seconds is not None else DOCUMENT_GAP_SECONDS
    with db() as conn:
        docs = compute_documents(conn, client_id=client_id, gap_seconds=gap)
        vecs: list[np.ndarray] = []
        kept_docs: list[Document] = []
        for doc in docs:
            vec = _ensure_doc_embedding(conn, doc.text)
            if vec is None:
                continue
            vecs.append(vec)
            kept_docs.append(doc)

    if not vecs:
        return DocumentSearchResponse(hits=[])

    query_vec = EMBEDDER.encode([q])[0]
    matrix = np.vstack(vecs)
    # Vectors are normalized → cosine == dot product.
    scores = matrix @ query_vec
    top_idx = np.argsort(-scores)[:limit]

    hits: list[DocumentHit] = []
    for i in top_idx:
        doc = kept_docs[int(i)]
        d = doc.to_dict()
        d["score"] = float(scores[int(i)])
        hits.append(DocumentHit(**d))
    return DocumentSearchResponse(hits=hits)


@app.get("/documents", response_model=DocumentListResponse, dependencies=[Depends(require_psk)])
def list_documents(
    client_id: Optional[str] = None,
    limit: int = Query(50, ge=1, le=500),
    offset: int = Query(0, ge=0),
    gap_seconds: Optional[float] = Query(None, ge=1.0, le=86400.0),
) -> DocumentListResponse:
    """Return server-computed documents, newest first, paginated."""
    gap = gap_seconds if gap_seconds is not None else DOCUMENT_GAP_SECONDS
    with db() as conn:
        docs = compute_documents(conn, client_id=client_id, gap_seconds=gap)
    docs.sort(key=lambda d: d.started_at, reverse=True)
    window = docs[offset:offset + limit]
    return DocumentListResponse(documents=[DocumentHit(**d.to_dict()) for d in window])


@app.get("/search/hybrid", response_model=DocumentSearchResponse, dependencies=[Depends(require_psk)])
def hybrid_search(
    q: str = Query(..., min_length=1),
    client_id: Optional[str] = None,
    limit: int = Query(20, ge=1, le=500),
    offset: int = Query(0, ge=0),
    gap_seconds: Optional[float] = Query(None, ge=1.0, le=86400.0),
    alpha: float = Query(0.7, ge=0.0, le=1.0),
) -> DocumentSearchResponse:
    """Score each document by a blend of substring frequency and cosine
    similarity, then return them ranked. `alpha` weights the semantic side;
    `1 - alpha` weights the textual side. Documents with zero on both
    signals are dropped."""
    gap = gap_seconds if gap_seconds is not None else DOCUMENT_GAP_SECONDS
    needle = q.lower().strip()
    with db() as conn:
        docs = compute_documents(conn, client_id=client_id, gap_seconds=gap)
        vecs: list[np.ndarray] = []
        kept: list[Document] = []
        for doc in docs:
            vec = _ensure_doc_embedding(conn, doc.text)
            if vec is None:
                continue
            vecs.append(vec)
            kept.append(doc)

    if not vecs:
        return DocumentSearchResponse(hits=[])

    matrix = np.vstack(vecs)
    semantic_scores = matrix @ EMBEDDER.encode([q])[0]

    # Substring frequency, normalized by document length so long files
    # don't crowd out tight matches.
    text_scores = np.zeros(len(kept), dtype=np.float32)
    if needle:
        for i, doc in enumerate(kept):
            haystack = doc.text.lower()
            if not haystack:
                continue
            count = haystack.count(needle)
            if count == 0:
                continue
            text_scores[i] = float(count) / max(len(haystack.split()), 1)

    # Normalize text scores to [0, 1] so alpha-mixing is meaningful.
    max_text = float(text_scores.max()) if text_scores.size else 0.0
    if max_text > 0:
        text_norm = text_scores / max_text
    else:
        text_norm = text_scores

    combined = alpha * semantic_scores + (1.0 - alpha) * text_norm

    # Keep anything with any signal — semantic alone is fine.
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
def get_document(
    doc_id: str,
    client_id: Optional[str] = None,
    gap_seconds: Optional[float] = Query(None, ge=1.0, le=86400.0),
) -> dict:
    """Fetch the full entry list for one server-computed document.
    Documents are deterministic given the same `gap_seconds` and entry set,
    so the `doc_id` from a recent `/search/semantic` or `/documents` call
    will resolve as long as the underlying data hasn't shifted."""
    gap = gap_seconds if gap_seconds is not None else DOCUMENT_GAP_SECONDS
    with db() as conn:
        docs = compute_documents(conn, client_id=client_id, gap_seconds=gap)
    for doc in docs:
        d = doc.to_dict()
        if d["doc_id"] == doc_id:
            return {**d, "entries": doc.entries}
    raise HTTPException(status_code=404, detail="document not found")


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
