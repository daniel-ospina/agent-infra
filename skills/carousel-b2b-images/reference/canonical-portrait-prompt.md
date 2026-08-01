# Canonical Portrait Prompt — Daniel Ospina

## Reference Images (ALWAYS include all three)

1. **Character sheet** (`docs/carousels/character-sheet.png`) — facial identity, outfits, expressions
2. **Canonical face** (`docs/carousels/canonical-face-reference.jpeg`) — target face accuracy: "this is exactly what my face should look like" (v5, best face quality, ignore the cropping — face accuracy only)
3. **Canonical portrait** (`docs/carousels/canonical-portrait-reference.jpeg`) — target quality: composition, lighting, depth, background, overall vibe (v12, full image quality)

Always pass ALL THREE as image references. The canonical portrait shows the model "this is what a good result looks like."

# Canonical Portrait Prompt — Daniel Ospina (v5 base, v7 refinements)

This prompt is built on v5 (best face quality: age 37, looking younger, very precise) with three fixes:
1. Full face visible (no cropping)
2. Background realism (uneven lighting, real imperfections, not a staged set)
3. Slightly reduced skin texture (subtle, not clinical)

## Full Prompt

```
Editorial portrait. Use reference image as ABSOLUTE source of truth for facial identity.

COMPOSITION: Subject on RIGHT third of frame. Subject's ENTIRE head and shoulders fully visible within frame — no cropping of face or hair. Large empty negative space on LEFT — plain wall, window area, or open table space with no important elements. This space is for text overlay. Some empty space at bottom. Subject roughly right 40%, left 60% empty.

Expression: comfortable, at ease. Like he's listening to someone across the table tell an interesting story. Slight natural warmth in the face — not smiling, not tense, not posed. Just relaxed and present. Mouth naturally closed or very subtly upturned. No tension in jaw or forehead.

Eyes: natural eyes with small round catchlight in the UPPER HALF of each eye — window reflection above pupil, not centered. Iris subtle texture, not hyper-detailed. Sclera natural off-white. Eyelashes slightly clumped. Eyes alive but not piercing or staring. Gaze soft toward camera.

Skin: natural photo-quality skin. Pores and texture visible but subtle — not clinical, not hyper-detailed. Like a good iPhone photo, not a dermatology closeup. Some areas slightly softer. Real skin, not rendered skin.

BACKGROUND REALISM CRITICAL: The cafe must feel like a real place, not a staged set. Uneven lighting — brighter near windows, darker in corners. Mix of light temperatures — warm bulbs in back, daylight from windows. Some chairs slightly pulled out, a tablecloth not perfectly straight, a poster slightly crooked on the wall. Real imperfections of a working cafe. NOT a showroom. NOT perfectly arranged. NOT uniformly lit. Background people if any should be in natural poses, not all facing the same way. Depth falloff: things further away are softer and darker (iPhone portrait, not lens bokeh).

Lighting on subject: face lit by window from left/front — brighter. Background ambient room light — dimmer, warmer. Different exposures for foreground and background.

Camera: iPhone photo. JPEG quality, slightly warm. Not HDR. Not clinical.

No plastic skin. No AI glow. No studio lighting. No perfect background. No uniform lighting. No centered composition. No facial distortion. No tense expression. No staring eyes. No cropping face.
```

## Iteration History

| Version | What worked | What didn't |
|---------|------------|-------------|
| v1 | — | Random face, curly hair, eyebrow scar |
| v2 | — | Face slightly deformed |
| v3 | — | Too hyper-realistic, eyes dry, room staged |
| v4 | iPhone feel, depth, lived-in cafe | Eyes slightly off, expression tense |
| v5 ✅ | **BEST FACE** — age 37, looks younger, very precise | Face cropped/half out of frame |
| v6 | Face fully visible | Lost some of v5's face quality, too much skin texture |
| v7 | v5 face + full visibility + background realism + less skin texture | Current |

## Key Principles

- Character sheet reference is ESSENTIAL — never generate without it
- v5's expression prompt was perfect: "comfortable, at ease, like listening to someone tell a story"
- Backgrounds need explicit anti-AI instructions: uneven lighting, imperfections, NOT a showroom
- Skin should be "iPhone photo quality" not "dermatology closeup"
- Composition: 40% right (subject), 60% left (negative space)


## Image-to-Image Editing Technique

For subtle adjustments to an already-good image, use image-to-image editing instead of regenerating from scratch. Pass the current best image as the primary reference:

```
Using this image as base reference: keep EVERYTHING identical — same expression,
same face, same lighting, same background, same depth of field, same composition.

ONLY FIX: [specific single change — be extremely precise and minimal]
```

**Success rate:** ~2/3 attempts. Works well for: expression tweaks, surface lighting fixes.  
**Risk:** Sometimes the model goes wild (demon eyes, destroyed backgrounds). Never use for very subtle color changes — accept minor imperfections over risking the entire image.

## Final Canonical Version: v12

v12 is the production-ready prompt. Built on v9 (best depth/background/lighting) with 
image-to-image refinement for expression (v11) and surface lighting (v12).

Key image-to-image chain:
- v9 → v11: expression 10% more discerning (image-to-image ✅)
- v11 → v12: table surface lighting fixed (image-to-image ✅)
- v12 → v13: eye color attempt (FAILED — demon eyes, makeup) ❌
