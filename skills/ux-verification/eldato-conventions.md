# Eldato Conventions — ux-verification

## References
- **Component catalog:** `docs/teams/eldato-app-team/ux/component_catalog.md`
- **Design tokens:** `text-primary`, `bg-card` (semantic, not hardcoded colors)

## Full Audit (UX=high)
- **Tool:** `ux-path-auditor` skill (Playwright-based path audit)
- **Viewports:** desktop (1280px), mobile (375px)

## Pipeline
- **Invoked by:** `test-routing` when UI changes detected
- **Consumed by:** `code-review` Step 0.3 (checks UX report)
- **Eldato rule:** A component that duplicates an existing catalog component is a bug
