#!/usr/bin/env bash
if [ -z "${BASH_VERSION:-}" ]; then
  echo "ERROR: structure-lint.sh must be run with bash" >&2
  exit 2
fi

set -euo pipefail

# =========================
# Repo Structure Linter
# Rules requested:
# - lowercase only
# - words separated with underscores
# - no spaces
# - no unicode (ASCII-only)
# - no leading hyphens
# - short and descriptive (enforced as max length)
#
# Checks:
# - required/forbidden paths
# - naming convention for files + dirs
# - duplicate basenames (same filename in multiple places)
# - duplicate content (same sha256) for small text-like files
#
# Usage:
#   bash scripts/lint-structure.sh
# =========================

ROOT="${GITHUB_WORKSPACE:-$(pwd)}"
cd "$ROOT"

fail=0
log() { printf '%s\n' "$*"; }
bad() { printf 'ERROR: %s\n' "$*" >&2; fail=1; }

# -------------------------
# Config (edit these)
# -------------------------

REQUIRED_PATHS=(
  "pyproject.toml"
  ".github/workflows"
)

FORBIDDEN_PATHS=(
  "__pycache__"
  ".pytest_cache"
  ".mypy_cache"
  ".venv"
  "venv"
  "dist"
  "build"
  "node_modules"
)

# Enforce "short and descriptive" via max length on each path segment (file/dir name)
MAX_SEGMENT_LEN=32

# Strict "lowercase + underscores" rule:
# - letters: a-z only
# - digits allowed
# - underscores allowed between words
# - no leading/trailing underscore
# - no double underscores (prevents ugly names)
SEGMENT_REGEX='^[a-z0-9]+(_[a-z0-9]+)*$'

# File names: same rule for base, plus extension also lowercase/digits only (optional)
# Examples:
#   good: my_module.py, api_v1.yaml, dockerfile (if you include in ALLOW_SPECIAL_FILENAMES)
#   bad: MyFile.py, my-file.py, my__file.py, my file.py, café.py
EXT_REGEX='^[a-z0-9]+$'

# Special-case filenames that do NOT fit the rule but you still want to allow
# (Keep this list short; prefer renaming to match the convention.)
ALLOW_SPECIAL_FILENAMES=(
  "Dockerfile"
  "Makefile"
  "LICENSE"
  "README.md"
  ".gitignore"
  ".gitattributes"
)

# Skip paths from checks (relative)
SKIP_PATH_REGEX='^(\.shared-repo/|\.git/|\.venv/|venv/|node_modules/|dist/|build/|site-packages/|\.ruff_cache/|\.mypy_cache/|\.pytest_cache/)'

# Duplicate basename allowlist
ALLOW_DUPLICATE_BASENAMES=(
  "__init__.py"
  "dockerfile"
  "readme.md"
  "license"
)

# Duplicate content hashing
MAX_HASH_BYTES=$((2 * 1024 * 1024)) # 2 MiB
HASH_GLOBS=(
  "*.py"
  "*.sh"
  "*.yml"
  "*.yaml"
  "*.md"
  "*.toml"
  "Dockerfile"
)

# -------------------------
# Helpers
# -------------------------
exists() { [[ -e "$1" ]]; }

lower() {
  # Lowercase in a locale-safe way
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]'
}

is_ascii() {
  local s="$1"
  LC_ALL=C printf '%s' "$s" | grep -q '[^ -~]' && return 1
  return 0
}


has_space() {
  local s="$1"
  [[ "$s" == *" "* ]]
}

has_leading_hyphen() {
  local s="$1"
  [[ "$s" == -* ]]
}

should_skip_relpath() {
  local rel="$1"
  [[ "$rel" =~ $SKIP_PATH_REGEX ]]
}

is_allowed_special_filename() {
  local base="$1"
  for a in "${ALLOW_SPECIAL_FILENAMES[@]}"; do
    [[ "$base" == "$a" ]] && return 0
  done
  return 1
}

is_allowed_duplicate_basename() {
  local base_lc
  base_lc="$(lower "$1")"
  for a in "${ALLOW_DUPLICATE_BASENAMES[@]}"; do
    [[ "$base_lc" == "$a" ]] && return 0
  done
  return 1
}

check_segment_common_rules() {
  local seg="$1"
  local kind="$2"     # "file" | "dir"
  local rel="$3"      # full relative path for error messaging

  # No spaces
  if has_space "$seg"; then
    bad "Name contains spaces ($kind): $rel"
    return
  fi

  # No unicode (ASCII only)
  if ! is_ascii "$seg"; then
    bad "Name contains non-ASCII characters ($kind): $rel"
    return
  fi

  # No leading hyphens
  if has_leading_hyphen "$seg"; then
    bad "Name starts with '-' ($kind): $rel"
    return
  fi

  # Must be lowercase (no uppercase allowed)
  if [[ "$seg" != "$(lower "$seg")" ]]; then
    bad "Name contains uppercase letters ($kind): $rel"
    return
  fi

  # Length constraint
  if (( ${#seg} > MAX_SEGMENT_LEN )); then
    bad "Name too long (${#seg} > ${MAX_SEGMENT_LEN}) ($kind): $rel"
    return
  fi
}

check_dir_name() {
  local seg="$1"
  local rel="$2"
  check_segment_common_rules "$seg" "dir" "$rel"

  # Allow dot-directories like .github without enforcing SEGMENT_REGEX
  if [[ "$seg" == .* ]]; then
    return
  fi

  if ! [[ "$seg" =~ $SEGMENT_REGEX ]]; then
    bad "Bad directory name (use lowercase_underscore): $rel"
  fi
}

check_file_name() {
  local seg="$1"
  local rel="$2"

  # Allow a short special-case list (e.g. Dockerfile, Makefile, LICENSE, README.md)
  # Must happen BEFORE common rules (since common rules raise uppercase errors).
  if is_allowed_special_filename "$seg"; then
    return
  fi

  # Allow dotfiles (but still enforce lowercase/ascii/no spaces/no leading hyphen/length)
  # If you truly want dotfiles exempt from common rules, keep this before common rules.
  if [[ "$seg" == .* ]]; then
    return
  fi

  # Now enforce common rules on everything else
  check_segment_common_rules "$seg" "file" "$rel"

  # Split base + extension (only last dot)
  local base ext
  if [[ "$seg" == *.* ]]; then
    base="${seg%.*}"
    ext="${seg##*.}"
    if ! [[ "$base" =~ $SEGMENT_REGEX ]]; then
      bad "Bad filename base (use lowercase_underscore): $rel"
    fi
    if ! [[ "$ext" =~ $EXT_REGEX ]]; then
      bad "Bad file extension (lowercase/digits only): $rel"
    fi
  else
    if ! [[ "$seg" =~ $SEGMENT_REGEX ]]; then
      bad "Bad filename (use lowercase_underscore): $rel"
    fi
  fi
}


# -------------------------
# 1) Required / forbidden
# -------------------------
for p in "${REQUIRED_PATHS[@]}"; do
  exists "$p" || bad "Missing required path: $p"
done

for p in "${FORBIDDEN_PATHS[@]}"; do
  if exists "$p"; then
    bad "Forbidden path exists (delete it or add to excludes): $p"
  fi
done

# -------------------------
# 2) Naming conventions
# -------------------------
# Check every path segment for dirs/files (excluding skipped paths)
while IFS= read -r path; do
  rel="${path#./}"
  # Skip root "."
  [[ "$rel" == "." ]] && continue

  # Skip configured paths
  if [[ -d "$path" ]]; then
    should_skip_relpath "$rel/" && continue
  else
    should_skip_relpath "$rel" && continue
  fi

  seg="$(basename "$rel")"

  if [[ -d "$path" ]]; then
    check_dir_name "$seg" "$rel"
  else
    check_file_name "$seg" "$rel"
  fi
done < <(find . -mindepth 1 -print)

# -------------------------
# 3) Duplicate basenames
# -------------------------
declare -A base_to_paths

while IFS= read -r f; do
  rel="${f#./}"
  should_skip_relpath "$rel" && continue

  base="$(basename "$rel")"
  base_lc="$(lower "$base")"

  if is_allowed_duplicate_basename "$base_lc"; then
    continue
  fi

  if [[ -n "${base_to_paths[$base_lc]:-}" ]]; then
    base_to_paths["$base_lc"]+=$'\n'"$rel"
  else
    base_to_paths["$base_lc"]="$rel"
  fi
done < <(find . -type f -print)

for base_lc in "${!base_to_paths[@]}"; do
  count="$(printf '%s\n' "${base_to_paths[$base_lc]}" | wc -l | tr -d ' ')"
  if (( count > 1 )); then
    bad "Duplicate filename detected: $base_lc appears in multiple locations:"$'\n'"$(printf '%s\n' "${base_to_paths[$base_lc]}")"
  fi
done

# -------------------------
# 4) Duplicate content (sha256)
# -------------------------
tmp_list="$(mktemp)"
trap 'rm -f "$tmp_list"' EXIT

for g in "${HASH_GLOBS[@]}"; do
  find . -type f -name "$g" -print >> "$tmp_list" || true
done

declare -A hash_to_paths
while IFS= read -r f; do
  [[ -z "$f" ]] && continue
  rel="${f#./}"
  should_skip_relpath "$rel" && continue

  size="$(wc -c < "$f" | tr -d ' ')"
  (( size > MAX_HASH_BYTES )) && continue

  h="$(sha256sum "$f" | awk '{print $1}')"
  if [[ -n "${hash_to_paths[$h]:-}" ]]; then
    hash_to_paths["$h"]+=$'\n'"$rel"
  else
    hash_to_paths["$h"]="$rel"
  fi
done < "$tmp_list"

for h in "${!hash_to_paths[@]}"; do
  count="$(printf '%s\n' "${hash_to_paths[$h]}" | wc -l | tr -d ' ')"
  if (( count > 1 )); then
    bad "Duplicate file content detected (same sha256):"$'\n'"$(printf '%s\n' "${hash_to_paths[$h]}")"
  fi
done

# -------------------------
# Result
# -------------------------
if (( fail == 0 )); then
  log "Structure lint passed."
else
  exit 1
fi
