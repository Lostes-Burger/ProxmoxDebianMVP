#!/usr/bin/env bash

set -euo pipefail

sync_catalog_repo() {
  local repo_url="$1"
  local branch="$2"
  local target_dir="$3"

  log_info "Synchronisiere App-Catalog aus $repo_url (Branch: $branch)"

  mkdir -p "$target_dir"

  if [[ ! -d "$target_dir/.git" ]]; then
    if ! git clone --depth=1 --branch "$branch" "$repo_url" "$target_dir"; then
      log_error "Catalog Clone fehlgeschlagen, verwende lokale Fallback-Rollen"
      return 0
    fi
    return 0
  fi

  if ! git -C "$target_dir" fetch --depth=1 origin "$branch"; then
    log_error "Catalog Fetch fehlgeschlagen, verwende letzten funktionierenden Stand"
    return 0
  fi

  if ! git -C "$target_dir" reset --hard "origin/$branch"; then
    log_error "Catalog Reset fehlgeschlagen, verwende letzten funktionierenden Stand"
    return 0
  fi

  log_info "Catalog erfolgreich aktualisiert"
}
