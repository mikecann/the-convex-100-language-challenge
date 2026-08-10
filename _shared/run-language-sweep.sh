#!/bin/sh

set -eu

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
mode=${1:-}

if test -n "$(git -C "$repo_root" status --porcelain --untracked-files=all)"; then
  printf '%s\n' \
    "Refusing to run from a dirty worktree." \
    "Commit the reviewed source first so every PASS belongs to an exact head." >&2
  exit 2
fi
source_commit=$(git -C "$repo_root" rev-parse HEAD)

case "$mode" in
  test | verify-all) ;;
  *)
    printf '%s\n' \
      "Usage: $0 <test|verify-all> [language ...]" \
      "" \
      "AUDIT_DIR=/existing/directory resumes an earlier sweep." >&2
    exit 2
    ;;
esac
shift

if test -n "${AUDIT_DIR:-}"; then
  audit_dir=$AUDIT_DIR
  mkdir -p "$audit_dir"
else
  audit_dir=$(mktemp -d "${TMPDIR:-/tmp}/100-convex-clients-$mode.XXXXXX")
fi

language_file="$audit_dir/languages.txt"
summary_file="$audit_dir/summary.tsv"

if test "$#" -gt 0; then
  : > "$language_file"
  for language in "$@"; do
    if test ! -f "$repo_root/$language/Dockerfile"; then
      printf 'Unknown implemented language: %s\n' "$language" >&2
      exit 2
    fi
    printf '%s\n' "$language" >> "$language_file"
  done
elif test ! -s "$language_file"; then
  find "$repo_root" -mindepth 2 -maxdepth 2 -name manifest.yaml -print \
    | sort \
    | sed "s#^$repo_root/##; s#/manifest.yaml##" \
    > "$language_file"
fi

touch "$summary_file"
total=$(wc -l < "$language_file" | tr -d ' ')

printf 'AUDIT_DIR %s\n' "$audit_dir"
printf 'MODE %s TOTAL %s SOURCE %s\n' "$mode" "$total" "$source_commit"

# Keep the roster on a dedicated descriptor. Some Docker commands read stdin,
# and allowing them to inherit the loop's descriptor silently skips languages.
exec 3< "$language_file"
index=0
while IFS= read -r language <&3; do
  index=$((index + 1))

  if awk -F '\t' -v language="$language" -v source="$source_commit" \
      '$1 == language && $2 == "PASS" && $3 == source { found = 1 }
       END { exit !found }' \
      "$summary_file"; then
    printf 'SKIP %03d/%03d %s already-passed\n' "$index" "$total" "$language"
    continue
  fi

  log_file="$audit_dir/$language.log"
  started=$(date +%s)
  printf 'START %03d/%03d %s\n' "$index" "$total" "$language"

  set +e
  "$repo_root/run" "$mode" "$language" </dev/null >"$log_file" 2>&1
  status=$?
  set -e

  elapsed=$(($(date +%s) - started))
  if test "$status" -eq 0; then
    printf '%s\tPASS\t%s\t%s\n' \
      "$language" "$source_commit" "$elapsed" >> "$summary_file"
    printf 'PASS %03d/%03d %s elapsed=%ss\n' \
      "$index" "$total" "$language" "$elapsed"
  else
    printf '%s\tFAIL(%s)\t%s\t%s\n' \
      "$language" "$status" "$source_commit" "$elapsed" \
      >> "$summary_file"
    printf 'FAIL %03d/%03d %s rc=%s elapsed=%ss log=%s\n' \
      "$index" "$total" "$language" "$status" "$elapsed" "$log_file" >&2
    tail -n 60 "$log_file" >&2
  fi
done

printf 'SUMMARY %s\n' "$summary_file"
awk -F '\t' -v source="$source_commit" \
  '$3 == source { latest[$1] = $2 }
   END {
     for (language in latest) count[latest[language]]++
     for (status in count) print status, count[status]
   }' \
  "$summary_file" \
  | sort
