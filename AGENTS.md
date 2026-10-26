# Repository instructions

- Preserve existing uncommitted changes and simulator app data.
- The following validation rules and docs/testing.md apply only to the
  native iOS app in native-ios/, not to Flutter.
- For native iOS, use the smallest useful validation; never run full suites
  or device matrices unless explicitly requested. UI automation is opt-in.
- Stop after the relevant native iOS check passes; report what was checked
  and what was intentionally not run.
- Before running native iOS tests or using its simulators, read docs/testing.md.
- If these instructions are already in context, do not reread this file.
