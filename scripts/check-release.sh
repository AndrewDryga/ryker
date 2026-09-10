#!/bin/sh
set -eu

dist=${1:-dist}
tag=${2:-}
checksums="$dist/checksums.txt"

if [ ! -s "$checksums" ]; then
	echo "missing release checksums: $checksums" >&2
	exit 1
fi

if [ -n "$tag" ]; then
	bundle="$checksums.bundle"
	if [ ! -s "$bundle" ]; then
		echo "missing release signature bundle: $bundle" >&2
		exit 1
	fi
	if ! command -v cosign >/dev/null 2>&1; then
		echo "cosign is required to verify a signed release" >&2
		exit 1
	fi
	cosign verify-blob "$checksums" \
		--bundle "$bundle" \
		--certificate-identity "https://github.com/AndrewDryga/responder/.github/workflows/release.yml@refs/tags/$tag" \
		--certificate-oidc-issuer https://token.actions.githubusercontent.com
fi

if command -v sha256sum >/dev/null 2>&1; then
	(cd "$dist" && sha256sum --check checksums.txt)
else
	(cd "$dist" && shasum -a 256 --check checksums.txt)
fi

set -- "$dist"/responder_*_elixir_linux_amd64.tar.gz
if [ "$#" -ne 1 ] || [ ! -f "$1" ]; then
	echo "expected exactly one Linux amd64 Elixir archive in $dist" >&2
	exit 1
fi

archive=$1
archive_name=${archive##*/}
version=${archive_name#responder_}
version=${version%_elixir_linux_amd64.tar.gz}
archive_sha256=$(awk -v file="$archive_name" '$2 == file { print $1 }' "$checksums")

if ! printf '%s\n' "$version" | grep -Eq '^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$'; then
	echo "$archive_name does not contain a safe release version" >&2
	exit 1
fi

if ! printf '%s\n' "$archive_sha256" | grep -Eq '^[0-9a-f]{64}$'; then
	echo "checksums.txt does not name exactly one trusted Elixir archive" >&2
	exit 1
fi

for helper in install-elixir-release.sh check-elixir-release.sh activate-elixir-release.sh; do
	if [ ! -x "$dist/$helper" ]; then
		echo "release is missing executable $helper" >&2
		exit 1
	fi
	digest=$(awk -v file="$helper" '$2 == file { print $1 }' "$checksums")
	if ! printf '%s\n' "$digest" | grep -Eq '^[0-9a-f]{64}$'; then
		echo "checksums.txt does not name exactly one trusted $helper" >&2
		exit 1
	fi
done

scripts/check-elixir-release.sh "$archive" "$version" "$archive_sha256" --archive-only

echo "release archive verified"
