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
	set -- "$dist"/responder_*_linux_"$arch".tar.gz
	if [ "$#" -ne 1 ] || [ ! -f "$1" ]; then
		echo "expected exactly one Linux $arch archive in $dist" >&2
		exit 1
	fi
	archive=$1
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

echo "release archives verified"
