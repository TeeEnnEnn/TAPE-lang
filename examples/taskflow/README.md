# TaskFlow — multi-module example project

A small task tracker spread across many modules. It exercises imports
between files: constants, enums, errors, structs, free functions and
coroutines, including diamond dependencies (`task` and `task_store`
both build on `task_status`; `task_stats` builds on `task_filters`).

Cross-module interaction goes through free `pub fn`s that take structs
as parameters (e.g. `store_add(s, ...)`), plus `new`, field reads,
`try` and `match` on imported error unions.

## Layout

- `main.tape` — entrypoint: seeds demo data, drives the lifecycle
  (close / reopen / block / unblock), renders reports and asserts
  every step with `panic` checks.
- `config.tape` — shared literal constants (`APP_NAME`, `MAX_TASKS`, …).
- `models/` — domain types, each with behaviour and free-function wrappers:
  `task_status.tape`, `priority.tape`, `task_error.tape`, `user.tape`,
  `task.tape`.
- `utils/` — dependency-free helpers: `math_utils.tape`,
  `string_utils.tape`, `task_flags.tape` (bitwise flags),
  `validators.tape`.
- `services/` — orchestration over the models: `task_store.tape`
  (array-backed store with `Int | TaskError` accessors),
  `task_filters.tape`, `task_stats.tape`, `task_workflow.tape`
  (`try`-based state changes), `task_notifier.tape`,
  `task_scheduler.tape` (coroutine streams), `task_report.tape`,
  `task_seed.tape` (demo fixtures).

## Dependency graph (imports)

- `task.tape` → `task_status`, `priority`
- `validators` → `config`, `math_utils`
- `task_store` → `config`, `task_error`, `validators`
- `task_filters` → `task_store`, `task_error`, `task_status`, `task_flags`
- `task_stats` → `task_store`, `task_error`, `task_status`, `math_utils`, `task_filters`
- `task_workflow` → `task_store`, `task_error`, `task_status`, `task_flags`
- `task_notifier` → `config`, `string_utils`, `task_status`
- `task_scheduler` → `task_store`
- `task_report` → `task_store`, `task_notifier`, `string_utils`, `task_stats`
- `task_seed` → `task_store`, `task_status`, `priority`, `task_flags`, `user`
- `main.tape` → everything above

## Running

Once multi-file compilation is supported:

```sh
zig build
./zig-out/bin/TAPE_lang check examples/taskflow/main.tape
./zig-out/bin/TAPE_lang run examples/taskflow/main.tape
```

A successful run ends silently (the final `"taskflow ok";` value is
discarded); any failed expectation aborts with `panic`.
