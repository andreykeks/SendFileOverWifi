# Receive File protocol, version 1

This document defines discovery and batch upload for **Send File** clients on
Android and other OSes.

## Scope

The client and receiver must be connected to the same IPv4 Wi-Fi LAN. This is a foreground, local-network protocol. All byte order is network order (big-endian).

Discovery uses **mDNS / DNS-SD**. File transfer uses TCP with **TLS 1.3** and
HTTP/1.1. Plain HTTP is not permitted.

## Device identity and trust

Each application installation generates a persistent device key pair and a
self-signed TLS certificate. The private key must be stored in the platform's
secure key storage and must not be included in application backups. A device's
identity is its public-key fingerprint, not its IPv4 address, TCP port,
hostname or DNS-SD service name.

Every upload uses mutually authenticated TLS 1.3: both the sender and receiver
present their certificates. The receiver's TCP listener is therefore a TLS
listener. mDNS only provides an untrusted route to a candidate IPv4 address and
port; it does not establish device identity.

Every upload derives a short authentication string (SAS) after the TLS
handshake, and both applications display it. On the first connection between
two devices, each side accepts the peer's self-signed certificate for that
connection only. The user must compare the two displayed SAS values and confirm
that they match before the receiver accepts the upload. A mismatch or
cancellation closes the connection, stores no trust record and does not accept
the file. For a trusted peer, the receiver still displays the new SAS in its
consent prompt; the stored certificate fingerprint authenticates the peer.

The SAS is calculated as follows:

1. Obtain 32 bytes from the TLS 1.3 exporter with label
   `EXPORTER-SendFile-v1-SAS` and an empty context.
2. Take the first 20 bits of the exporter output.
3. Encode those bits as four uppercase symbols using the Crockford Base32
   alphabet: `0123456789ABCDEFGHJKMNPQRSTVWXYZ`.

The SAS is derived anew from every TLS session and is cryptographically
unpredictable. Four Base32 symbols provide 20 bits (1,048,576 possible values).
It is a comparison value, not a password and must never be transmitted as an
HTTP header or a DNS-SD TXT record.

After a successful first confirmation, each device stores the peer's public-key
fingerprint in its local trusted-devices store. For all later uploads, the TLS
peer certificate must match that stored fingerprint. A changed or unknown key
requires a new explicit confirmation; a changed IPv4 address or TCP port does
not. The user can remove a trusted device, which makes its next connection a
first connection again.

## mDNS / DNS-SD discovery

A receiver advertises itself on the local Wi-Fi network using DNS-Based Service Discovery (Bonjour / mDNS).

- Service type: `_sendfile._tcp.local.`
- Transport: TCP; the DNS-SD SRV port is the TLS-protected HTTP upload port.
- TXT `v`: advertised protocol version, currently ASCII decimal `1`.
- TXT `t`: required session token: the same unpadded Base64URL form of the receiver's 8 random bytes that is used by the HTTP header.

The receiver opens its TCP listener before registering the DNS-SD service and unregisters the service before closing the listener. It must generate a new token for every receiving session. A sender browses `_sendfile._tcp.local.` for 8 seconds, resolves the newest discovered service, validates `t`, host and port, and then sends the upload request below. The current protocol version is `v1`. If TXT `v` is missing or has an unknown value, the sender ignores that value and attempts the `v1` flow. mDNS discovery and TXT records are visible to devices on the local network; this token prevents accidental uploads but is not encryption or authentication.

## Transfer offer and storage reservation

One transfer contains one or more files. Before sending any file bytes, the
sender sends an offer with the complete manifest. The receiver checks the
manifest, reserves storage for the complete set and asks the user for consent.
The sender must not start file upload until the offer has been accepted.

Open TCP to the advertised IP and port, complete the TLS 1.3 trust flow above,
then send this request inside that TLS connection:

```http
POST /v1/offer HTTP/1.1
Host: 192.168.1.20:50000
Content-Type: application/json
Content-Length: <exact JSON length>
X-SendFile-Device-Name: Alice’s iPhone
X-Receive-File-Token: AQIDBAUGBwg

{
  "files": [
    { "path": "Photos/vacation%20photo.jpg", "size": "9123456", "sha256": "<64-lowercase-hex-digits>", "createdAt": "2026-10-11T14:32:10.123Z", "modifiedAt": "2026-10-11T14:32:10.123Z", "mimeType": "image/jpeg" },
    { "path": "Videos/video.mp4", "size": "4567890123", "sha256": "<64-lowercase-hex-digits>", "createdAt": "2026-10-10T08:00:00Z", "modifiedAt": "2026-10-11T09:15:00Z", "mimeType": "video/mp4" }
  ]
}
```

Offer requirements:

- `X-SendFile-Device-Name` is optional UTF-8 display metadata from the
  sender's local configuration. The receiver may store it as the visible name
  for the peer's already verified public-key fingerprint, but it is never an
  identity or trust input. Unknown implementations ignore this header.
- `files` contains one or more entries in the order in which they will be
  uploaded.
- `path` is a relative UTF-8 path. Each path segment is percent-encoded as an
  RFC 3986 URL component and segments are separated by `/`. It must contain at
  least one non-empty segment and must not be absolute or contain `.`, `..`,
  backslashes, or an encoded path separator. Its final segment preserves or
  restores the file extension.
- `size` is a non-negative base-10 integer encoded as a JSON string. Strings
  avoid loss of precision on platforms whose JSON number type cannot represent
  large integers exactly.
- `sha256` is required and is the lowercase hexadecimal SHA-256 digest of the
  complete source file: exactly 64 ASCII hexadecimal digits. The sender
  calculates it before sending the offer.
- `createdAt`, `modifiedAt` and `mimeType` are optional metadata. Date values
  are UTC RFC 3339 / ISO 8601 timestamps, with optional fractional seconds;
  `mimeType` is an IANA media type. A sender omits metadata it cannot determine
  reliably. Receivers that do not recognize these fields ignore them, so their
  addition does not change the `v1` protocol version.
- When the receiver's "Preserve file dates" setting is enabled, it attempts to
  apply `createdAt` and `modifiedAt` after SHA-256 verification and final
  placement. It may retain `mimeType` as safe type metadata where the platform
  supports that. A filesystem that cannot set one of these values must still
  complete the transfer successfully.
- Do not transmit executable permissions, read-only or hidden flags, owners,
  groups, ACLs, quarantine data, resource forks, alternate data streams or
  arbitrary extended attributes. Received files are ordinary writable, visible
  files regardless of the source file's flags.
- The sender must calculate every size and the sum of all sizes before sending
  the offer. Files with an unknown size cannot be sent.
- The protocol sets no application-level maximum for an individual file or the
  complete transfer. Each platform may still be constrained by its filesystem,
  source provider or integer limits.
- The receiver must calculate the required space from the manifest, account for
  its staging overhead, and reserve that space before accepting the offer. A
  free-space check alone is insufficient if another process could consume the
  space before upload completes.
- Only one accepted or paused transfer may exist at a receiver at a time. If a
  transfer already exists, the receiver rejects a new offer with
  `409 Another Offer Is Pending`.
- The receiver resolves a unique destination path for every manifest entry
  before accepting the offer. If two entries in the same manifest resolve to
  the same path, every entry after the first is renamed by inserting ` (2)`,
  ` (3)` and so on before the final extension.
- For every resolved path that already exists at the receiver, the receiver
  calculates its SHA-256. If it equals the manifest `sha256`, the entry is
  marked `already-present` and its bytes are not uploaded. If it differs, the
  incoming entry is renamed using the same ` (N)` rule and retained as a new
  file. This search continues until a non-conflicting path is found.
- Storage reservation excludes entries marked `already-present`.

After user consent and successful reservation, the receiver responds:

```http
202 Offer Accepted
X-Receive-File-Transfer: <opaque-random-transfer-id>
Content-Type: application/json
Content-Length: <exact JSON length>

{
  "files": [
    { "index": 0, "path": "Photos/vacation%20photo.jpg", "state": "uploading" },
    { "index": 1, "path": "Videos/video.mp4", "state": "already-present" }
  ]
}
```

The sender uploads only entries whose state is `uploading`. It retains the
returned resolved `path` only for display; the receiver uses it as the final
relative path beneath its chosen destination directory.

If space cannot be reserved, the receiver responds `507 Insufficient Storage`
without accepting any file bytes. A declined offer returns `403 Declined`; an
invalid manifest returns `400 Bad Request`.

## Chunk upload and resumption

After a `202 Offer Accepted`, upload every manifest entry in order as fixed
4,194,304-byte chunks, except for a file's final chunk, which can be smaller.
The sender may use the TLS connection that accepted the offer or reconnect and
resume it later. The request for the first chunk of manifest entry `0` is:

```http
PATCH /v1/transfers/<opaque-random-transfer-id>/files/0 HTTP/1.1
Host: 192.168.1.20:50000
Content-Type: application/octet-stream
Content-Length: 4194304
X-Receive-File-Token: AQIDBAUGBwg
X-Receive-File-Offset: 0

<4,194,304 raw file bytes>
```

Requirements:

- `Content-Length` is required, decimal, and equals the number of bytes in the
  current chunk. Each non-final chunk is exactly 4,194,304 bytes; the final
  chunk contains the remaining bytes and may be zero bytes for a zero-length
  file.
- `X-Receive-File-Offset` is required, decimal, non-negative and equals the
  next byte offset expected by the receiver for that file. A chunk must not
  extend beyond the manifest `size`. No 1 GiB or other application-level limit
  is applied to a file or transfer.
- The receiver must use the decoded resolved manifest `path` as the actual
  relative path beneath its chosen destination directory, creating required
  subdirectories. The file extension must be present in the URL passed to
  preview, open-in-place, or sharing APIs. Storing bytes under an extensionless
  temporary UUID and retaining the path only as display metadata is
  non-compliant: iOS and other systems use the URL extension to determine the
  file type.
- `X-Receive-File-Token` must exactly equal the Base64URL token from the advertisement.
- The transfer identifier must exactly equal the value returned by the offer.
- The receiver accepts chunk, skip and completion requests only when the TLS client
  certificate has the public-key fingerprint bound to that transfer.
- The receiver writes a chunk atomically: it advances the recorded offset only
  after the complete chunk has been durably written. Bytes from an interrupted
  chunk are discarded or truncated to the last recorded offset.
- The receiver responds `204 Chunk Received` only after the exact chunk bytes
  have been stored, with `X-Receive-File-Next-Offset` set to the next expected
  decimal offset. For a final chunk, it first verifies the staged file's
  SHA-256 against the manifest. The sender then uploads the next chunk or the
  first chunk of the next file.
- If the final SHA-256 does not match, the receiver discards the staged file,
  marks that manifest entry as skipped, releases its reserved space and returns
  `422 File Changed`. The sender must not retry, restart or offer resume for
  that file; it continues with the remaining entries.
- If the sender detects that its source file changed or became unavailable
  before its final chunk, it skips the entry by sending `DELETE` to the same
  file URL with the transfer token. The receiver discards that entry's staging
  data, releases its reserved space and returns `204 File Skipped`.
- If an offset is not the next expected value, the receiver returns
  `409 Offset Mismatch` and `X-Receive-File-Next-Offset`; the sender must query
  the transfer state before retrying.
- TLS 1.3 is required. Do not use plain HTTP, TLS versions earlier than 1.3,
  chunked transfer encoding, redirects, compression or HTTP/2 in v1.
- Keep the connection open while the receiver displays its consent prompt.
  Clients should use at least a 90-second response timeout.

### Transfer state and resume

The receiver persists the transfer identifier, accepted manifest, per-file
state and next offset, staging files, storage reservation and sender public-key
fingerprint.
It retains this state for 24 hours after the offer or last successfully written
chunk. On expiry, cancellation or a failed finalization, it deletes the staging
files and releases the reservation. Expiry cleanup is silent: it sends no
notification to either user.

The sender may cancel an incomplete transfer by sending:

```http
DELETE /v1/transfers/<opaque-random-transfer-id> HTTP/1.1
Host: 192.168.1.20:50000
X-Receive-File-Token: <current mDNS token>
```

The receiver accepts cancellation only from the TLS client certificate bound to
the transfer. It deletes all incomplete staging files, releases the reservation
and returns `204 Transfer Cancelled`. The receiver's local `Clear` action has
the same effect. If the sender cannot reach the receiver to cancel, it removes
its local transfer state; the receiver retains its state until the user clears
it or the 24-hour expiry is reached.

If the receiver cannot write a later chunk because free storage became
insufficient after reservation, it preserves confirmed chunks, marks the
transfer `paused-no-space` and returns `507 Insufficient Storage`. It does not
accept further chunks until space is available. The sender displays its
paused-transfer actions; the receiver displays `No free space` and lets the
user free storage or use `Clear`.

To resume after a lost connection, the sender discovers the receiver again,
creates a new TLS 1.3 connection, validates the receiver's stored public-key
fingerprint and requests the transfer state:

```http
GET /v1/transfers/<opaque-random-transfer-id> HTTP/1.1
Host: 192.168.1.20:50000
X-Receive-File-Token: <current mDNS token>
```

The receiver accepts this request only when the TLS client certificate has the
same public-key fingerprint as the sender that created the offer. A successful
response is `200 Transfer Status` with UTF-8 JSON:

```json
{
  "state": "uploading",
  "files": [
    { "index": 0, "size": "9123456", "nextOffset": "4194304", "state": "uploading" },
    { "index": 1, "size": "4567890123", "nextOffset": "0", "state": "uploading" }
  ]
}
```

The top-level `state` is `uploading` or `paused-no-space`. A sender must not
upload more chunks while it is `paused-no-space`; after the user frees storage,
the sender requests state again and uploads only if the receiver changes it to
`uploading`. Each `files[].state` is `uploading`, `received`,
`already-present`, or `skipped`.

The sender resumes each file at its returned `nextOffset`. It must be able to
read the source file again from that offset; if the source is unavailable,
changed or cannot be reread, that file is skipped and is not offered for resume.
The receiver returns `410 Transfer Expired` when the state no longer exists, `403
Declined` when the sender certificate does not match, and `409 Offset Mismatch`
when the sender's view is stale. A new mDNS IPv4 address, TCP port or session
token does not invalidate a transfer; the current discovered token is used for
every request on the new connection.

After all manifest entries are either fully received with a matching SHA-256,
marked `already-present`, or marked skipped, the sender completes the transfer:

```http
POST /v1/transfers/<opaque-random-transfer-id>/complete HTTP/1.1
Host: 192.168.1.20:50000
Content-Length: 0
X-Receive-File-Token: AQIDBAUGBwg
```

`201 Received` means every file in the set was received with a matching SHA-256
or was already present with a matching SHA-256. If one or more files were
skipped, the receiver returns `207 Transfer Completed With Skipped Files` and a
JSON list of their indexes and reasons; the sender must report those files to
the user and must not offer resume for them.
`403 Declined` means the user rejected it; `401 Invalid session token` means
discover the receiver again; `409 Another offer is pending` means retry after a
new discovery; `507 Insufficient Storage` means space could not be reserved or
became insufficient during upload; `400` denotes a malformed or incomplete request. After the final response, the
connection closes.

## Client flow

1. Browse `_sendfile._tcp.local.` and resolve the newest matching service as described in the mDNS client flow below.
2. Ask the sender for one or more files, calculate their exact sizes and total,
   establish TCP and complete mutually
   authenticated TLS 1.3.
3. Display the SAS on both devices. For an unknown peer, compare it before
   continuing; for a trusted peer, require its stored public-key fingerprint
   to match.
4. Send the offer. While waiting for user consent and storage reservation,
   display “Waiting for approval on Receive File”.
5. After `202 Offer Accepted`, upload each file in manifest order as chunks,
   then send the completion request. If the connection is lost, display a
   resume action; only after the user selects it, rediscover the receiver,
   request the transfer state and continue from its returned offsets.
6. Treat only `201` as success. Never retry a request automatically: a retry
   can produce a second user prompt.

### mDNS client flow

1. Browse `_sendfile._tcp.local.` for 8 seconds on the active local Wi-Fi interface.
2. Resolve the newest service and obtain its IPv4 address, SRV port and TXT fields.
3. Require non-empty `t`; ignore an unknown TXT `v`, open TLS 1.3 to the
   resolved host and port, then send the offer and all upload requests using `t` unchanged as
   `X-Receive-File-Token`.
4. Keep the connection open while the receiver requests consent; apply the
   response and no-auto-retry rules described above.

## Diagnostics required in Send File

During development, the client must write these events to its local debug log:

1. mDNS browse start and finish on the active local Wi-Fi interface.
2. Every discovered `_sendfile._tcp.local.` service and the result of its
   resolution: device name, IPv4 address, SRV port, TXT version and whether a
   token is present.
3. The precise rejection reason: unresolved service, missing or unsupported
   TXT version, missing token, or malformed IPv4 address or port.
4. Offer manifest count and total byte size; each file's leaf name, size and
   status; storage-reservation result; TCP and TLS connection target; TLS
   peer-fingerprint validation result; transfer-session status; response status;
   and timeout/error.

Logs must not contain tokens, SAS codes, private or public keys, file content,
or full file paths. No log, diagnostic, analytics or other data is transmitted
outside the local device.

Receive File writes equivalent receiver diagnostics to the system log. To
diagnose a pairing, compare the receiver publishing events with a successful
client discovery, then verify the TXT version, host and port.
