# shellcheck shell=bash
# What scripts/voice-service.sh, embedding-service.sh and routing-model-service.sh
# share: a model file fetched at a pinned revision and kept only when its bytes
# are the pinned ones. They fetched `resolve/main` and kept whatever came back
# (2026-10-04 review).

# download_model URL SHA256 FILE DESCRIPTION leaves FILE holding the bytes whose
# SHA-256 is SHA256: it keeps an installed file that already does, and otherwise
# downloads URL and refuses anything else.
download_model() {
  local url=$1 sha256=$2 file=$3 description=$4 actual

  if [[ -s $file && $(shasum -a 256 "$file" | cut -d' ' -f1) == "$sha256" ]]; then
    return 0
  fi

  echo "Downloading $description to $(dirname "$file")"
  curl -fL --retry 3 -o "$file.partial" "$url" || {
    rm -f "$file.partial"
    return 1
  }
  actual=$(shasum -a 256 "$file.partial" | cut -d' ' -f1)
  if [[ $actual != "$sha256" ]]; then
    rm -f "$file.partial"
    echo "$url did not hold the pinned bytes (SHA-256 $actual, wanted $sha256); nothing was installed." >&2
    return 1
  fi
  mv -f "$file.partial" "$file"
}
