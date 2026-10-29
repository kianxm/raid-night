#!/usr/bin/env bash
# Stage 0 of docs/asset-pipeline.md: style exploration images, text-prompted only (no refs yet).
#
#   tools/assets/stage0_style.sh            # dry run: prints every prompt and command
#   tools/assets/stage0_style.sh cost       # asks Higgsfield for the exact cost of each job (free)
#   tools/assets/stage0_style.sh prompts    # writes each prompt to a file, for MCP generation
#   DRY_RUN=0 tools/assets/stage0_style.sh  # spends credits: one image per job, no retries
#
# Every prompt starts from the STYLE block and ends with the AVOID block, both taken from the
# critter's built job files (assets/jobs/<id>/front.txt), so they always match the style bible.
# One lever varies across the set: presentation and lighting.
#   turnaround  front.txt verbatim: evenly lit, plain mid-grey (the production format)
#   night       in-world: moonlight key, warm lamp pool, blue-violet fog, navy background, soft glow
#   icon        icon.txt verbatim: three-quarter view, soft rim light
#   night_tier  in-world with the tier's glow strength (Legendary: strong glow, aura, motes)
#
# Outputs go to assets/raw/_style/ (git-ignored). Run from the repo root.

set -euo pipefail

IMAGE_MODEL="${IMAGE_MODEL:-seedream_v4_5}"
QUALITY="${QUALITY:-high}"
DRY_RUN="${DRY_RUN:-1}"
OUT="assets/raw/_style"
mode="${1:-run}"

# n|critter|variant
JOBS=(
  "01|dusk_mouse|turnaround"
  "02|dusk_mouse|night"
  "03|dusk_mouse|icon"
  "04|static_crab|turnaround"
  "05|static_crab|night"
  "06|static_crab|icon"
  "07|abyss_angler|turnaround"
  "08|abyss_angler|night"
  "09|abyss_angler|icon"
  "10|abyss_angler|night_tier"
)

build_prompt() {
  local id="$1" variant="$2" job="assets/jobs/$1"
  local front style avoid name look glow others
  front="$(cat "$job/front.txt")"
  style="${front%% Character:*}"
  avoid="Avoid ${front##* Avoid }"
  name="$(jq -r .name "$job/brief.json")"
  look="$(jq -r .look "$job/brief.json")"
  glow="$(jq -r '.palette[0]' "$job/brief.json")"
  others="$(jq -r '.palette[1:] | join(", ")' "$job/brief.json")"
  local scene="Three-quarter view, full body, on a dark cobblestone street at night. Cool moonlight key light from above, a warm lamp pool on the ground, light blue-violet fog, dark navy #0B1026 background."
  case "$variant" in
    turnaround) printf '%s' "$front" ;;
    icon) cat "$job/icon.txt" ;;
    night) printf '%s Character: %s, %s. %s Its one glowing feature glows softly in %s; other colors %s. %s' \
      "$style" "$name" "$look" "$scene" "$glow" "$others" "$avoid" ;;
    night_tier) printf '%s Character: %s, %s. %s Its one glowing feature glows strongly in %s with a soft aura and a few floating light motes, so it pops through the fog; other colors %s. %s' \
      "$style" "$name" "$look" "$scene" "$glow" "$others" "$avoid" ;;
    *) echo "Unknown variant $variant" >&2; exit 1 ;;
  esac
}

mkdir -p "$OUT"
for entry in "${JOBS[@]}"; do
  IFS='|' read -r n id variant <<<"$entry"
  prompt="$(build_prompt "$id" "$variant")"
  base="$OUT/style-$n-$id-$variant"
  echo "== style-$n $id ($variant)"
  if [[ "$mode" == "prompts" ]]; then
    # Trial accounts can only generate through the Higgsfield MCP: write the prompts for it.
    printf '%s\n' "$prompt" >"$base.prompt.txt"
    echo "   wrote $base.prompt.txt"
    continue
  fi
  if [[ "$mode" == "cost" ]]; then
    higgsfield generate cost "$IMAGE_MODEL" --prompt "$prompt" --quality "$QUALITY"
    continue
  fi
  if [[ "$DRY_RUN" == "1" ]]; then
    printf 'DRY RUN: higgsfield generate create %q --prompt %q --quality %q --wait --json\n' \
      "$IMAGE_MODEL" "$prompt" "$QUALITY"
    continue
  fi
  printf '%s\n' "$prompt" >"$base.prompt.txt"
  # One attempt only. A failure still counts toward the budget; never re-roll here.
  if ! higgsfield --json generate create "$IMAGE_MODEL" --prompt "$prompt" --quality "$QUALITY" \
    --wait >"$base.json" 2>"$base.err"; then
    # Stop the whole batch: CLI errors are usually systematic (auth, plan, flags), and every
    # later call would hit the same wall and count toward the budget too.
    echo "   FAILED (counted, not retried): see $base.err. Stopping the batch." >&2
    exit 1
  fi
  url="$(grep -Eo 'https://[^"]+\.(png|jpg|jpeg|webp)' "$base.json" | head -1 || true)"
  if [[ -z "$url" ]]; then
    echo "   No image URL in $base.json (counted, not retried)" >&2
    continue
  fi
  ext="${url##*.}"
  curl -fsSL "$url" -o "$base.$ext"
  [[ "$ext" == "png" ]] || sips -s format png "$base.$ext" --out "$base.png" >/dev/null
  echo "   saved $base.png"
done
