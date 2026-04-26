# HeidiSQL CSLOG Customization Notes

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
