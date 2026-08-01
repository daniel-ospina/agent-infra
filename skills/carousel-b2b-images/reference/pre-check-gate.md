# Image Quality Pre-Check Gate

Before presenting any generated image to the user, run this automated checklist. If any check FAILS, auto-regenerate with adjusted prompt (up to 3 attempts). Only present to user when all checks PASS or 3 attempts exhausted.

## Automated Checks

### 1. Face Integrity (CRITICAL — auto-reject)
- [ ] Full head and shoulders visible — not cropped or cut off
- [ ] Eyes look natural — no demon eyes, no makeup, no glowing pupils
- [ ] Expression is human — not frozen, not exaggerated, not uncanny
- [ ] Face matches character sheet identity (same bone structure, features)
- **Fail action:** Regenerate with stronger "ENTIRE head and shoulders fully visible, no cropping" instruction

### 2. Depth of Field (CRITICAL — auto-reject)
- [ ] Subject is in focus
- [ ] Background is progressively softer with distance
- [ ] NOT everything in sharp focus (collage look)
- [ ] Ceiling/far elements are blurred, not sharp
- **Fail action:** Regenerate with stronger "DEPTH OF FIELD IS CRITICAL" instruction

### 3. Background Realism (WARN — surface to user with note)
- [ ] No glowing lightbulbs in daylight scenes
- [ ] Surfaces have natural wear (wood grain, slight discoloration) — not uniform
- [ ] No perfectly clean/showroom look
- [ ] No destroyed/dilapidated walls (over-corrected messiness)
- **Fail action:** Warn user "Background looks AI-generated" but still present

### 4. Lighting (WARN)
- [ ] Subject and background have different exposures (not uniformly lit)
- [ ] Face lit naturally — not studio, not flat
- [ ] No AI glow/halo effect around subject
- **Fail action:** Warn but present

### 5. Skin Texture (WARN)
- [ ] Not hyper-detailed (dermatology closeup)
- [ ] Not plastic/airbrushed
- [ ] Natural iPhone photo quality
- **Fail action:** Warn but present

## Regeneration Strategy

```
Attempt 1: Full prompt from canonical-portrait-prompt.md
  → Run checklist
  → If face or depth FAILS → Attempt 2
  → If only WARNs → present to user with notes

Attempt 2: Add stronger emphasis on failed checks + include v12 as reference
  → Run checklist
  → If still FAILS face or depth → Attempt 3

Attempt 3: Image-to-image from v12 reference, only change scene/expression
  → Run checklist
  → If still FAILS → present to user with "⚠️ Could not auto-fix after 3 attempts"
```

## Cost Impact

- Best case: 1 generation ($0.10)
- Average case: 1-2 generations ($0.10-0.20)
- Worst case: 3 generations ($0.30)
- Per 10-slide carousel (~5 photo slides): $0.50-1.50
