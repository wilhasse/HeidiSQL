# HeidiSQL CSLOG Customization Notes

This document records the behavior that differs from the upstream HeidiSQL
release in the CSLOG build. It is intended as internal maintenance notes for
future upgrades and merges.

## Custom Build Identity

The CSLOG build is installed separately from the normal HeidiSQL installation.
It uses the custom application label `HeidiSQL CSLOG`, a separate install
folder, and a separate registry/profile area so users can keep the normal
HeidiSQL available for rollback or unmanaged connections.

The window title includes the CSLOG build marker and Git revision so support can
confirm which customized binary is running.

## Startup Flow

CSLOG startup intentionally differs from upstream HeidiSQL:

- client update check runs before AD authentication;
- if an update is available, the user is notified and the update proceeds;
- if another HeidiSQL CSLOG instance from the same install path is running, the
  update is blocked and this instance closes;
- after update handling, centralized AD authentication runs;
- after authentication, the API-managed session catalog is synchronized.

Normal HeidiSQL installed in another directory should not block CSLOG updates.

## Centralized AD Session Reuse

The backend issues the real AD authentication token expiration through
`expires_at`. In production this is currently configured in `csmonitorsql` as
`auth_session_ttl_seconds: 57600`, which means 16 hours.

The backend also returns `cache_reuse_until`, controlled by
`auth_session_cache_reuse_seconds`. The current value is 14400 seconds, or 4
hours.

Important behavior:

- `cache_reuse_until` limits only automatic reuse from the local encrypted
  HeidiSQL cache when opening another instance or restarting HeidiSQL.
- If HeidiSQL is already open and the user is actively using the application,
  the in-memory AD token remains valid until the backend `expires_at` value.
- This is intentional: active users are not forced to log in again while they
  are working inside the same HeidiSQL process.
- If the backend rejects the token, for example after manual revocation or
  true expiration, HeidiSQL clears the local cache and asks for AD login again.
- If the user cancels the expired-session login dialog, HeidiSQL CSLOG closes
  the application.

To force existing sessions to reauthenticate immediately, expire or delete rows
from `csbuild.monitor_sql_auth_sessions` and remove the local cache file:

```bat
del "%APPDATA%\HeidiSQL CSLOG\central_auth.dat"
```

Backend session table:

```sql
UPDATE csbuild.monitor_sql_auth_sessions
SET expires_at = NOW()
WHERE actor_id = 'wil';
```

## API-Managed Session Catalog

The session list is synchronized from `csmonitorsql` using the connection
catalog endpoint. API-managed sessions are organized directly under the customer
folder.

Display rules:

- folder: customer name;
- normal label: `CUSTOMER - BASE - ENVIRONMENT`;
- `Outro` label with comment: `CUSTOMER - BASE - Outro (comment)`;
- duplicate display names receive numeric suffixes such as `2`, `3`;
- removed API sessions are archived under `OBSOLETAS API` instead of being
  deleted immediately.

The catalog does not return database passwords. It only provides connection
identity and logical DB user. Passwords are resolved later at connection time.

## Managed Credentials

Before connecting to a managed MySQL/MariaDB target, HeidiSQL asks the backend
for effective DB credentials. The session manager still displays the logical
configured user, but the runtime connection can use a backend-returned user and
password only in memory.

If the backend says the target is managed and credentials cannot be resolved,
the connection is blocked. Saved local passwords are not overwritten by the
catalog or credential resolution.

## SQL Monitoring And Approval

Editor SQL and supported grid writes are sent to the central SQL monitor.

Behavior by statement type:

- `SELECT`: logged/audited only.
- `INSERT`: logged and follows the production confirmation flow when applicable.
- `UPDATE` and `DELETE`: approval-gated by the backend.
- other SQL: logged/audited only.

If a guarded write cannot reach the monitor API, HeidiSQL fails closed and does
not execute the batch. For audit-only statements, API failure is non-blocking
and the query can continue with a warning.

The ticket number is sent to the backend when present. `Teste` databases do not
require a ticket in the client; backend rules remain authoritative.

## Environment Rules

Environment is detected from the API-managed session metadata/name.

- `Producao`: write operations require the central validation flow and show a
  final production confirmation before execution.
- `Espelho`: write operations are blocked locally for editor and grid paths.
- `Teste`: write operations can execute without client-side ticket requirement.
- `Outro`: treated as managed and can write through the protected flow, but is
  not treated visually as production unless configured by color preferences.

The toolbar shows the active `Assessoria Base`. Production targets are shown
with stronger red/bold styling.

## Grid Editing

Grid editing is handled as a pending batch, not row by row.

- editing one or more rows keeps changes pending locally;
- applying/posting changes sends the batch through the SQL monitor flow once;
- cancelling grid edits rolls back all pending grid changes as a set;
- running another query while grid edits are pending is blocked until the user
  posts or cancels the grid changes.

This avoids silently losing edits when the result grid is refreshed.

## User Prompts

Additional confirmations were added for CSLOG safety:

- AD login dialog is centered and pre-fills the Windows username;
- changing from one active connection to a different connection asks for
  confirmation and shows the target;
- first selection/opening of a connection does not show the change warning;
- SQL write dialog highlights the execution target;
- production writes show a final confirmation after central validation;
- connection error dialogs show the target session that failed, not the
  currently active connection.

## Managed Session Colors

Preferences include a `CSLOG` tab for API-managed session colors by
environment:

- `Producao`;
- `Espelho`;
- `Teste`;
- `Outro`.

If an environment color is set, it overrides the session-specific background
color for API-managed sessions of that environment. If no environment color is
configured, the session-specific color can still be used.

## Installer And Runtime Files

`install-cslog.bat` installs the CSLOG build to its own folder, configures the
monitor API settings, enables centralized AD auth, installs locale files, and
copies MySQL authentication plugins.

The plugin copy is required for accounts using authentication plugins such as
`caching_sha2_password`.

## Build And Deploy

`build.bat` supports CSLOG-specific build behavior:

- `SKIP_TX_PULL=1` skips Transifex downloads and reuses existing locale files;
- `ENABLE_SIGN=1` enables signing through the configured signing API;
- `DEPLOY_UPDATE=1` publishes the update manifest and binary after signing.

The updater manifest is used by the pre-login update check. Users are notified
when an update is available and the update proceeds without a `No` option.
