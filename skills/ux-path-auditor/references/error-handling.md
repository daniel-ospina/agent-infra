# Error Handling Reference

| Situation | Action |
|---|---|
| `browser_navigate` times out on a step | Log `WARN: timeout at {route} (step {i}, journey {id})`, skip remaining checks for this screen, continue to next step |
| Login fails | Log `WARN: auth login failed`, skip all auth-state steps, continue with unauth steps |
| `browser_snapshot` returns empty/blank | Retry once after 2 seconds; if still empty, record a `broken-nav` finding with `dom_excerpt: "(empty snapshot)"` |
| `browser_evaluate` throws (overflow check) | Log `WARN: overflow check failed at {route} — JS evaluate error`; skip `mobile-overflow` for this screen |
| Form submit triggers navigation during `form-validation-gap` check | Navigate back to the form screen before continuing remaining checks; record a `form-validation-gap` finding |
| `path-map.json` is malformed or unreadable | Halt with BLOCKED message (see workflow/01-setup.md Step 0) |
| Output directory does not exist | Pre-created by the `ux-qa` orchestrator. If running standalone, create manually: `mkdir -p {output_dir}` |
| `UX_QA_EMAIL` / `UX_QA_PASSWORD` not set and auth steps required | Halt with BLOCKED message (see workflow/01-setup.md Inputs section) |
