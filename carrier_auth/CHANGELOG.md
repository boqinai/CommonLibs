## 0.1.0

- Extract standalone Android/iOS carrier authorization, lifecycle cleanup, timeout and concurrency handling.
- Inject host agreements, labels and appearance; never fetch configuration or log in an account.
- Reuse the pinned vendor binary without starting fusion scenes or automatically sending SMS.

- Clarify SDK ownership: project runtime dependency + compileOnly API, with a standalone example and Android/iOS native CI builds.
- Preserve pending Android authorization across configuration reattachment; close on permanent detach.
- Limit native diagnostics to debuggable hosts and avoid retaining the iOS plugin through the close fallback.
