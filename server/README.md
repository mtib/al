# Al log server

Optional companion server for the Al menu-bar app. Stores encrypted
transcript lines, decrypts them on receipt, and exposes plain-text +
semantic (CPU-only embedding) search over the corpus.

Every endpoint requires a pre-shared key in the
`Authorization: Bearer <PSK>` header — including `GET /pubkey`.

## Quick start

```sh
export AL_PSK="$(openssl rand -hex 32)"
docker compose up --build -d
```

### Or pull the prebuilt image

CI publishes the image to GHCR on every push that touches `server/**`:

```sh
docker run -d --name al-server \
  -p 8088:8088 \
  -e AL_PSK="$(openssl rand -hex 32)" \
  -v al-data:/data \
  ghcr.io/mtib/al/al-server:latest
```

Set the same `AL_PSK` and the server URL (e.g. `http://localhost:8088`) in
the Al app's *Options…* window. The app fetches the server's X25519 public
key the first time it can reach the server and caches it.

### One-off without Docker

```sh
python3 -m venv .venv && source .venv/bin/activate
pip install -r requirements.txt
AL_DATA_DIR=./data AL_PSK="dev-psk" uvicorn app:app --port 8088
```

## Endpoints

| Method | Path | Notes |
|---|---|---|
| `GET`  | `/health` | Liveness, no auth. |
| `GET`  | `/pubkey` | Current X25519 pubkey + `valid_until`. Auto-rotates with overlap. |
| `POST` | `/logs` | Accepts batch of sealed entries with monotonic `seq`. |
| `GET`  | `/search?q=…&client_id=…` | Substring search over decrypted text. Multi-client by default. |
| `GET`  | `/search/semantic?q=…&client_id=…&gap_seconds=…` | Cosine-similarity search over server-computed documents. |
| `GET`  | `/documents?limit=N&gap_seconds=…` | Server-computed documents, newest first. |
| `GET`  | `/document/{doc_id}?gap_seconds=…` | Full entries for one server-computed document. |
| `GET`  | `/recent?limit=N&client_id=…` | Time-merged feed across all clients (newest first). |
| `GET`  | `/clients` | Per-client summary: entry/file count, time range. |
| `GET`  | `/files/{client_id}/{file_id}` | Full ordered entries for one client+file (debug only). |

### Server-side grouping

The server does **not** trust the client's per-file split. Each client's
on-disk transcript file rotates on idle gaps, but two clients (or one
client across rotations) can produce activity that is temporally
contiguous and should be treated as a single document.

So on every search the server walks the corpus in time order and starts a
new document whenever two consecutive entries are more than
`AL_DOCUMENT_GAP_SECONDS` apart (default 5 minutes; overridable per
request via `?gap_seconds=…`). Embeddings are cached by the SHA-256 of
the document's concatenated text, so re-grouping with the same content
reuses the cached vector.

`client_id` and `file_id` are kept on each entry as breadcrumbs but
neither one influences grouping.

### Multi-client

Multiple clients may ship to the same server simultaneously. Every row is
keyed by `(client_id, seq)` so file IDs from different clients never
collide; `/search`, `/search/semantic`, and `/recent` return merged results
across all clients unless `?client_id=…` filters to one.

### Key rotation

The server keeps a rolling set of X25519 keypairs. `GET /pubkey` returns
`valid_until` (UNIX seconds); when a key is within the rotation lead
window the next fetch returns a freshly minted key. Retired private keys
are kept around for a retention window so any in-flight ciphertexts still
decrypt — on receipt every retained key is tried.

Defaults (override via env):

| Env | Default | Meaning |
|---|---|---|
| `AL_KEY_VALID_SECONDS`  | `604800` (7 d) | `valid_until = created_at + this` |
| `AL_KEY_ROTATION_LEAD`  | `86400`  (1 d) | mint a new key once the current key has ≤ this remaining |
| `AL_KEY_RETENTION`      | `1209600` (14 d) | how long private halves are kept after expiry for decrypt |
| `AL_KEY_SWEEP_INTERVAL` | `3600`  (1 h)  | how often the background sweep runs |

### Encryption envelope

Each entry sent in `POST /logs` is the base64 of:

```
[ 32 bytes  X25519 ephemeral public key ]
[ 12 bytes  ChaCha20 nonce              ]
[  N bytes  ciphertext                  ]
[ 16 bytes  Poly1305 tag                ]
```

Symmetric key:

```
key = HKDF-SHA256(
    ikm  = X25519(ephemeral_priv, server_pub),
    salt = ephemeral_pub || server_pub,
    info = b"al-sealed-box-v1",
    L    = 32,
)
```

Plaintext is a UTF-8 JSON object:

```json
{
  "file_id":   "2026-05-20/2026-05-20T14-30-22",
  "source":    "mic",
  "started_at": 1747740625.123,
  "ended_at":   1747740627.456,
  "text":      "transcribed line ..."
}
```

The server's X25519 keypairs (current + retained) live in the
`server_keys` SQLite table under `/data/al.sqlite3`. Mount `/data` to
persist them across container restarts; deleting the row(s) will force a
fresh key on the next request.

### Search examples

```sh
PSK=...
HOST=http://localhost:8088

curl -sH "Authorization: Bearer $PSK" "$HOST/search?q=meeting"            | jq .
curl -sH "Authorization: Bearer $PSK" "$HOST/search/semantic?q=lunch%20plans" | jq .
```

## Data layout

* SQLite database at `/data/al.sqlite3` (WAL).
* Table `entries(client_id, seq, file_id, source, started_at, ended_at, text, received_at)` —
  `(client_id, seq)` is the primary key, so retries are idempotent.
* Table `file_embeddings(client_id, file_id, text_hash, embedding, dim, updated_at)` —
  one normalized 384-d vector per file, recomputed when the concatenated
  text hash changes.
* Embedding model cache at `/data/hf-cache/`.
