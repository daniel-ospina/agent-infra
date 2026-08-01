# Brand Tokens

> **Single source of truth:** `scripts/tokens.json`

Color values are defined in `tokens.json` and consumed by `build_carousel.cjs`. Any hex value used in CSS must reference a CSS custom property (e.g., `var(--purple)`). Raw hex values in templates are replaced at build time by the `tokenize()` function.
