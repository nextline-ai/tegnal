# Working in this repository

## Validation: keep it proportional to the change

The user prioritizes short feedback time. This policy applies to every AI agent.

- Do not run the full unit suite, full UI suite, all test plans, or a device matrix unless the user explicitly requests that scope. A small change, commit, or PR does not imply permission for a full regression run.
- Start with the diff and choose the smallest useful check. Documentation, copy, assets, and simple styling usually need inspection or a build, not a test run. Do not run smoke tests automatically for every edit.
- For logic changes, select the affected test method(s), or one relevant test class when necessary. Use `python3 script/test.py --only ClassName/testMethod` or `--scope <feature>`. Preview with `--dry-run`.
- UI automation is opt-in for the affected behavior: select individual methods with `--only TEGNALUITests/ClassName/testMethod`. Do not run an entire UI class just because a view changed. Prefer the corresponding unit test when it covers the behavior.
- Stop after the relevant check passes. Do not expand to other tests, repeat a successful build, clean DerivedData, collect coverage, or retry tests without a concrete reason.
- If a check fails, distinguish the change from an existing failure or simulator/tool issue. Report unrelated failures; do not broaden the task into fixing them.
- State what was checked and what was intentionally not run. Never imply that a focused check validated the whole app.

`TEGNAL` defaults to the three-test `Smoke` plan as a fallback for an unfiltered Xcode test command. This is not a requirement to run it. `Unit` and `UI` plans are available for explicitly selected checks. Live network/iCloud/device validation schemes are only for an explicitly requested integration check and must also use `-only-testing` filters.

See [docs/testing.md](docs/testing.md) for commands and feature mapping. Keep `native-ios/project.yml` and generated shared schemes in sync when changing test configuration.

## Simulators

- Reuse an existing simulator. Default: iPhone 18 Pro on iOS 27.0.
- Use iPad Pro 11-inch (M5) only for tablet-specific changes and iPhone Duo only for fold/resizing-specific changes. These are alternatives, not a routine test matrix.
- Do not create simulator devices, download runtimes, or enable parallel test workers by default. Parallel simulator testing creates extra clones and consumes disk space.
- Preserve the user's existing uncommitted changes and simulator app data on the retained devices.
