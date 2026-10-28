#!/usr/bin/env bash
# Generates concept images (stage 2) or 3D models (stage 3) for critters with the Higgsfield CLI.
#
#   tools/assets/generate.sh images dusk_mouse lantern_snail ...   # front view first
#   tools/assets/generate.sh views  dusk_mouse ...                 # side + back from the approved front
#   tools/assets/generate.sh model  dusk_mouse ...                 # 3D, only after Gate 1
#
# SAFE BY DEFAULT: prints the commands without running them. To actually spend credits:
#   DRY_RUN=0 tools/assets/generate.sh images dusk_mouse
#
# BEFORE FIRST USE: confirm model ids and flags in the Higgsfield CLI docs (they change), and
# set them below. Run `higgsfield auth login` once.

set -euo pipefail

IMAGE_MODEL="${IMAGE_MODEL:-SET_ME_image_model_id}"     # a model that accepts reference images
MODEL_3D="${MODEL_3D:-multi_image_to_3d}"                # multi-view image to 3D
STYLE_REFS=(assets/clean/_style/ref-01.png assets/clean/_style/ref-02.png assets/clean/_style/ref-03.png)
DRY_RUN="${DRY_RUN:-1}"

mode="${1:-}"; shift || true
if [[ -z "$mode" || $# -eq 0 ]]; then
  sed -n '2,13p' "$0"; exit 1
fi

run() {
  if [[ "$DRY_RUN" == "1" ]]; then
    printf 'DRY RUN: '; printf '%q ' "$@"; printf '\n'
  else
    "$@"
  fi
}

ref_flags=()
for r in "${STYLE_REFS[@]}"; do
  if [[ -f "$r" ]]; then ref_flags+=(--image "$r"); fi
done
if [[ "$mode" != "model" && ${#ref_flags[@]} -eq 0 ]]; then
  echo "No style references in assets/clean/_style/. Do Stage 0 of docs/asset-pipeline.md first." >&2
  [[ "$DRY_RUN" == "1" ]] || exit 1
fi

for id in "$@"; do
  job="assets/jobs/$id"
  raw="assets/raw/$id"
  [[ -d "$job" ]] || { echo "No job for $id. Run: lune run tools/assets/build_prompts.luau" >&2; exit 1; }
  mkdir -p "$raw"

  case "$mode" in
    images)
      echo "== $id: front view + icon"
      run higgsfield generate create "$IMAGE_MODEL" --prompt "$(cat "$job/front.txt")" "${ref_flags[@]}" --wait
      run higgsfield generate create "$IMAGE_MODEL" --prompt "$(cat "$job/icon.txt")" "${ref_flags[@]}" --wait
      echo "   Save the chosen front as $raw/front.png and the icon as $raw/icon.png"
      ;;
    views)
      [[ -f "$raw/front.png" || "$DRY_RUN" == "1" ]] || { echo "Approve and save $raw/front.png first" >&2; exit 1; }
      echo "== $id: side + back from the approved front"
      run higgsfield generate create "$IMAGE_MODEL" --prompt "$(cat "$job/side.txt") Same character as the reference." --image "$raw/front.png" --wait
      run higgsfield generate create "$IMAGE_MODEL" --prompt "$(cat "$job/back.txt") Same character as the reference." --image "$raw/front.png" --wait
      echo "   Save them as $raw/side.png and $raw/back.png"
      ;;
    model)
      for v in front side back; do
        [[ -f "$raw/$v.png" || "$DRY_RUN" == "1" ]] || { echo "Missing $raw/$v.png (Gate 1 not passed?)" >&2; exit 1; }
      done
      echo "== $id: 3D model from front, side, back"
      run higgsfield generate create "$MODEL_3D" --image "$raw/front.png" --image "$raw/side.png" --image "$raw/back.png" --should_texture true --wait
      echo "   Save the GLB as $raw/model.glb, then follow Stage 4 cleanup"
      ;;
    *)
      echo "Unknown mode: $mode (use images | views | model)" >&2; exit 1 ;;
  esac
  echo "   Log it in assets/generation-log.md"
done
