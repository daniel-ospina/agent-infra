# OpenRouter Configuration

## API

Single OpenAI-compatible endpoint. All models accessible with one API key.

```
POST https://openrouter.ai/api/v1/chat/completions
Authorization: Bearer $OPENROUTER_API_KEY
Content-Type: application/json
```

```json
{
  "model": "google/gemini-3.1-flash-image-preview",
  "messages": [{ "role": "user", "content": "prompt here" }],
  "modalities": ["image"],
  "image_config": { "aspect_ratio": "4:5", "image_size": "2K" }
}
```

## Model Selection

| Model | ID | Quality | Speed | Cost/image | Use Case |
|-------|-----|---------|-------|-----------|----------|
| Nano Banana 2 | `google/gemini-3.1-flash-image-preview` | High | Fast | ~$0.05 | **Default** — best quality/speed balance |
| Nano Banana Pro | `google/gemini-3-pro-image-preview` | Best | Medium | ~$0.10 | Complex scenes, text in images |
| FLUX.2 Klein | `black-forest-labs/flux-2-klein` | Good | Fastest | ~$0.016 | Bulk generation, cheapest |
| FLUX.2 Pro | `black-forest-labs/flux-2-pro` | High | Medium | ~$0.045 | Professional quality |
| Seedream 4.5 | `bytedance-seed/seedream-4.5` | Good | Fast | $0.04 | Flat-rate, predictable cost |

## Fallback Chain

1. Try Nano Banana 2 (default)
2. If unavailable → try FLUX.2 Pro
3. If unavailable → try Seedream 4.5
4. If all fail → surface error with `errors_handled: false`

## Aspect Ratios

| Ratio | Dimensions | Use |
|-------|-----------|-----|
| `4:5` | 896×1152 | Instagram carousel/single post (default) |
| `1:1` | 1024×1024 | Square posts |
| `9:16` | 768×1344 | Stories, Reels |
| `3:4` | 864×1184 | Closest to full-bleed portrait |

## Cost per Carousel

For a 10-slide carousel with ~5 photo slides, 3 options each = 15 generations:

| Model | Cost |
|-------|------|
| FLUX.2 Klein | ~$0.24 |
| Nano Banana 2 | ~$0.75 |
| Nano Banana Pro | ~$1.50 |

## Environment

- API key: `$OPENROUTER_API_KEY` (required)
- No additional setup — single key, all models
