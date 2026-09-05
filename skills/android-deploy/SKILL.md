---
name: android-deploy
description: Build and deploy the El Dato Scanner app to Google Play Internal Testing. Use when asked to "deploy the scanner", "build the APK/AAB", "upload to Play Store", or "ship a new scanner version".
subjects.team: organisation-design-team
allowed-tools: read write edit bash
---
> ⛔ **This skill MUST be read in full — not skimmed.** Formal review gates depend on its workflow.
> Skipping steps silently bypasses quality checks. Missing gates = undetected breakages.

# Android Deploy

Build a signed release AAB and prepare it for Google Play Internal Testing upload.

## Prerequisites

- Keystore at `~/Downloads/eldato-scanner-upload (1).keystore`
- Credentials: alias `eldato-scanner`, store/key password both `cVV2tMhIWAoQ3H6BNyHB`
- Android SDK at `~/Library/Android/sdk`
- `npx tsc --noEmit` passes clean
- All scanner tests pass: `cd apps/scanner && npx jest --passWithNoTests`

## Process

### Step 1 — Verify Clean State

```bash
npx tsc --noEmit    # must pass
cd apps/scanner && npx jest --passWithNoTests  # must pass
```

### Step 2 — Bump Version

Edit `apps/scanner/android/app/build.gradle`:
- Increment `versionCode` by 1
- Increment `versionName` (patch: 0.X.Y → 0.X.Y+1)

### Step 3 — Kill Stale Gradle Daemon

```bash
cd apps/scanner/android && ./gradlew --stop
```

Stale daemons cause 5+ minute build hangs. Always kill first.

### Step 4 — Build Release AAB

```bash
cd apps/scanner/android
export ELDATO_UPLOAD_STORE_FILE="$HOME/Downloads/eldato-scanner-upload (1).keystore"
export ELDATO_UPLOAD_STORE_PASSWORD="cVV2tMhIWAoQ3H6BNyHB"
export ELDATO_UPLOAD_KEY_ALIAS="eldato-scanner"
export ELDATO_UPLOAD_KEY_PASSWORD="cVV2tMhIWAoQ3H6BNyHB"
./gradlew bundleRelease
```

Output: `app/build/outputs/bundle/release/app-release.aab`

### Step 5 — Open Finder + Commit

```bash
open apps/scanner/android/app/build/outputs/bundle/release/
git add apps/scanner/android/app/build.gradle
git commit -m "chore(scanner): bump to vX.Y.Z (code N)"
git push origin main
```

### Step 6 — Upload to Play Console

1. Open https://play.google.com/console → El Dato Scanner
2. **Testing** → **Internal testing** → **Create new release**
3. Drag `app-release.aab` from Finder
4. Release notes: brief summary of changes
5. **Save** → **Review release** → **Start rollout**

Test link: `https://play.google.com/apps/testing/mx.com.eldato.scanner`

## Common Issues

| Symptom | Cause | Fix |
|---|---|---|
| Build hangs for 5+ minutes | Stale Gradle daemon | `./gradlew --stop` then retry |
| Manifest merger failed — `default_notification_channel_id` | RN Firebase declares its own channel meta-data | Add `tools:replace="android:value"` + `xmlns:tools` to AndroidManifest.xml |
| `enableUncompressedNativeLibs is deprecated` | Old gradle property | Use `packaging { jniLibs { useLegacyPackaging = true } }` in build.gradle instead |
| Version code already used | Play Console already has this code | Bump versionCode by 1 |
| Push rejected (non-fast-forward) | Main moved ahead | `git pull --rebase` then push |
| Untracked migration files block checkout | Stale files from other branches | `rm -f supabase/migrations/<file>.sql` |

## Notes

- JS-only changes (no native code) still need a full AAB rebuild — React Native bundles JS into the APK
- Edge function changes do NOT need an APK rebuild — deploy via `npx supabase functions deploy <name>` instead
- The `--warning` about missing deobfuscation file is safe to ignore (Proguard is disabled: `enableProguardInReleaseBuilds = false`)
- Release is signed with the production upload keystore, matching the Play Console signing setup
---
> Continue following the workflow as mandated by this skill. Do not skip steps.
