# Testing

- 2024-05-06 `flutter test` — failed: Flutter cache lockfile at /Users/leokent/develop/flutter/bin/cache/lockfile not writable; tests did not run.
- 2024-05-06 `flutter test` — failed again with same lockfile permission issue; new tests (watchdog timeout) not executed.
- 2025-12-09 `flutter test` — failed: Flutter SDK lockfile (/Users/leokent/develop/flutter/bin/cache/lockfile) not writable for current user; no tests executed.
- 2025-12-09 `flutter test` — failed again with identical lockfile permission error; user reports chown applied but runner仍无法写入该文件。
