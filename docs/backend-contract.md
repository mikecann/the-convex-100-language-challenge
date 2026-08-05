# Approved counter-room backend contract

Michael approved the dedicated Convex schema and pilot implementation on
5 August 2026. This document freezes the exact pilot data model and public
function surface before deployment.

## Tables

### `rooms`

| Field | Convex validator | Purpose |
| --- | --- | --- |
| `name` | `v.string()` | Random per-run room identifier. |
| `count` | `v.number()` | Current counter value. |
| `lastLanguage` | `v.union(v.string(), v.null())` | Last client that applied an increment. |
| `latestRunId` | `v.union(v.string(), v.null())` | Last applied idempotency key. |
| `updatedAt` | `v.number()` | Server-side update timestamp in milliseconds. |

Index: `by_name` on `["name"]`.

### `events`

| Field | Convex validator | Purpose |
| --- | --- | --- |
| `room` | `v.string()` | Room identifier. |
| `runId` | `v.string()` | Idempotency key supplied by the harness. |
| `language` | `v.string()` | Language slug that initiated the increment. |
| `createdAt` | `v.number()` | Server-side event timestamp in milliseconds. |

Indexes:

- `by_room_and_run_id` on `["room", "runId"]`.
- `by_room` on `["room"]` for bounded evidence queries.

The pilot does not add auth tables, public cleanup functions, scheduled jobs, or
unbounded event reads. Deterministic local deployments are disposable. Hosted
smoke tests use random room names and retain only small pilot evidence.

## Public functions

### `demo:state`

Query arguments:

```json
{ "room": "string" }
```

Returns the existing room state or a zero-valued virtual state without writing:

```json
{
  "room": "string",
  "count": 0,
  "lastLanguage": null,
  "latestRunId": null,
  "updatedAt": null
}
```

### `demo:increment`

Mutation arguments:

```json
{ "room": "string", "language": "string", "runId": "string" }
```

The mutation checks `events.by_room_and_run_id`. A repeated `runId` returns the
current room state with `applied: false`. A new `runId` atomically inserts one
event, increments the room once, and returns `applied: true` with the new state.

### `demo:greet`

Action arguments:

```json
{ "language": "string" }
```

Returns a deterministic JSON object containing the language and greeting. It
does not call an external service, so action conformance is not coupled to a
third-party API.

### `demo:echo`

Query arguments contain a JSON-safe `value`. The function logs one deterministic
line and returns the value unchanged. It exercises nested values and keeps
function logs distinct from results.

### `demo:fail`

Query arguments contain a string `code`. The function throws a structured
`ConvexError` with that code and a deterministic message. It exists only to
verify application-error handling.

### `demo:requiresNonzero`

Reactive query arguments contain a room name. It throws a structured
`ROOM_EMPTY` error while the room is absent or zero, then returns the room state
after an increment. This verifies that a failed subscription stays active and
can recover.

## Deployment topology

- Deterministic conformance: pinned local Convex deployment in Docker.
- Compatibility smoke: dedicated hosted Convex development deployment.
- No unrelated development or production deployment is in scope.
- No deploy key or admin credential is baked into an image or committed file.
