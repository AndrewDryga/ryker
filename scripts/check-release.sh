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

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT HUP INT TERM

case "$(uname -s):$(uname -m)" in
Linux:x86_64) native=amd64 ;;
Linux:aarch64 | Linux:arm64) native=arm64 ;;
*) native= ;;
esac

for arch in amd64 arm64; do
	archive=
	archive_count=0

	for candidate in "$dist"/responder_*_linux_"$arch".tar.gz; do
		[ -f "$candidate" ] || continue

		case "${candidate##*/}" in
		*_elixir_linux_*) continue ;;
		esac

		archive=$candidate
		archive_count=$((archive_count + 1))
	done

	if [ "$archive_count" -ne 1 ]; then
		echo "expected exactly one Linux $arch archive in $dist" >&2
		exit 1
	fi

	archive_name=${archive##*/}
	expected=${archive_name#responder_}
	expected=${expected%_linux_"$arch".tar.gz}
	if ! tar -tzf "$archive" | awk '
		/^\// || /(^|\/)\.\.(\/|$)/ { unsafe = 1 }
		END { exit unsafe }
	'; then
		echo "$archive contains an unsafe path" >&2
		exit 1
	fi
	extract="$tmp/$arch"
	mkdir "$extract"
	tar -xzf "$archive" -C "$extract"
	for path in \
		responder \
		README.md \
		CHANGELOG.md \
		LICENSE \
		SECURITY.md \
		config/responder.example.yaml \
		deploy/slack-app-icon.png \
		deploy/slack-app-manifest.yaml \
		deploy/nginx/responder.conf \
		deploy/systemd/responder.service \
		deploy/systemd/coop-responder.service \
		docs/operations.md \
		docs/releasing.md \
		docs/slack-app.md; do
		if [ ! -f "$extract/$path" ]; then
			echo "$archive is missing $path" >&2
			exit 1
		fi
	done
	go version -m "$extract/responder" >/dev/null
	if ! strings "$extract/responder" | grep -Fx "$expected" >/dev/null; then
		echo "$archive does not contain embedded version $expected" >&2
		exit 1
	fi
	if [ "$arch" = "$native" ]; then
		version=$("$extract/responder" version)
		if [ "$version" != "$expected" ]; then
			echo "$archive reports version $version, expected $expected" >&2
			exit 1
		fi
		"$extract/responder" help >/dev/null
	fi
done

set -- "$dist"/responder_*_elixir_linux_amd64.tar.gz
if [ "$#" -ne 1 ] || [ ! -f "$1" ]; then
	echo "expected exactly one Linux amd64 Elixir archive in $dist" >&2
	exit 1
fi

elixir_archive=$1
elixir_name=${elixir_archive##*/}
elixir_sha256=$(awk -v file="$elixir_name" '$2 == file { print $1 }' "$checksums")

if ! printf '%s\n' "$elixir_sha256" | grep -Eq '^[0-9a-f]{64}$'; then
	echo "checksums.txt does not name exactly one trusted Elixir archive" >&2
	exit 1
fi

elixir_version=$(
	tar -tzf "$elixir_archive" |
		awk -F/ '$1 == "releases" && NF == 3 && $3 == "runtime.exs" { print $2 }'
)

if ! printf '%s\n' "$elixir_version" |
	grep -Eq '^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$'; then
	echo "$elixir_archive does not contain exactly one safe release version" >&2
	exit 1
fi

scripts/check-elixir-release.sh \
	"$elixir_archive" "$elixir_version" "$elixir_sha256"

echo "release archives verified"
