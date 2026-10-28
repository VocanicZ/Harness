# release_fixture.sh — fake GitHub releases served over file:// for the update/install tests
# (PRD #274). Sourced after helpers.sh. Nothing here touches the network: curl reads file:// URLs.
#   rel_server <dir>            point HARNESS_API_URL / HARNESS_BASE_URL at <dir>
#   rel_publish <dir> <tag>     harness-<tag>.tar.gz built from THIS checkout's engine files, plus
#                               VERSION and scripts/release-marker.sh (prints <tag>), and its SHA256SUMS
#   rel_latest <dir> <tag|"">   what releases/latest answers; "" = no release published yet
#   rel_install_at <dir> <tag>  a host already on <tag>, laid out as install.sh lays it out
# Every file it writes lives under <dir> (the archive is staged in <dir>/.build), so a test that
# removes its own temp root leaves nothing behind (#294).
FIXTURE_ENGINE_SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
rel_server(){ mkdir -p "$1/download"
  export HARNESS_API_URL="file://$1/latest.json" HARNESS_BASE_URL="file://$1/download"; }
rel_publish(){ local srv="$1" tag="$2" st; st="$srv/.build/harness-$tag"; rm -rf "$st"; mkdir -p "$st"
  ( cd "$FIXTURE_ENGINE_SRC" && tar -cf - bin scripts prompts skill plugins install.sh update.sh ) | tar -xf - -C "$st"
  printf '%s\n%040d\n' "$tag" 0 > "$st/VERSION"
  printf '#!/usr/bin/env bash\necho %s\n' "$tag" > "$st/scripts/release-marker.sh"
  mkdir -p "$srv/download/$tag"
  tar -C "$(dirname "$st")" -czf "$srv/download/$tag/harness-$tag.tar.gz" "harness-$tag"
  ( cd "$srv/download/$tag" && sha256sum "harness-$tag.tar.gz" > SHA256SUMS ); }
rel_latest(){ if [[ -n "$2" ]]; then printf '{"tag_name":"%s"}\n' "$2"; else printf '{"message":"Not Found"}\n'; fi > "$1/latest.json"; }
rel_install_at(){ local h="${HARNESS_HOME:?}"; mkdir -p "$h/releases"
  tar -xzf "$1/download/$2/harness-$2.tar.gz" -C "$h/releases"; mv -T "$h/releases/harness-$2" "$h/releases/$2"
  ln -sfn "releases/$2" "$h/engine"; echo "$2" >> "$h/releases/.installed"; }
