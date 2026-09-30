#!/bin/bash
# shellcheck disable=SC2034

# Product identity shipped with the installed payload.  Keep this file small:
# installers and runtime components source it instead of maintaining their own
# product or beta version constants.
PRODUCT_VERSION="5.1.3"
BETA_VERSION="7"

UU_SHORT_COMMIT() {
  local commit="${1:-}"
  [[ "$commit" =~ ^[0-9a-f]{40}$ ]] && printf '%s' "${commit:0:7}"
}

UU_FORMAT_BUILD_IDENTITY() {
  local version="${1:-}" branch="${2:-}" beta="${3:-}" commit="${4:-}"
  local identity="$version" short_commit
  [[ -n "$identity" ]] || identity="unknown"
  case "$branch" in
    beta)
      [[ "$beta" =~ ^[0-9]+$ ]] && identity+=" Beta $beta" || identity+=" beta"
      ;;
    develop) identity+=" develop" ;;
  esac
  short_commit=$(UU_SHORT_COMMIT "$commit")
  [[ "$branch" == beta || "$branch" == develop ]] && [[ -n "$short_commit" ]] && identity+=" · $short_commit"
  printf '%s' "$identity"
}

UU_FORMAT_PRODUCT_IDENTITY() {
  printf 'Ultimate Updater %s\n' "$(UU_FORMAT_BUILD_IDENTITY "$@")"
}
