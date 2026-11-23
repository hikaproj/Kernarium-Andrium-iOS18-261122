#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-or-later
#
# Build and package iOS IPA files for Kernarium and/or Andarium.
# All generated IPA packages and checksums are placed into the output directory.
set -eu

ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)

APP=both
CONFIGURATION=Release
OUTPUT_DIR="$ROOT_DIR/dist"
IDENTITY=
TEAM=

fail()
{
	printf '%s\n' "scripts/build-ipa.sh: $*" >&2
	exit 1
}

usage()
{
	cat <<'EOF'
Usage: scripts/build-ipa.sh [options]

Options:
  --app NAME            Application to build: both (default), Kernarium, or Andarium
  --configuration CONF  Build configuration: Release (default) or AppStore
  --output-dir PATH     Output directory for IPAs and checksums (default: dist)
  --team ID             Apple Developer Team ID (optional)
  --identity NAME       Code signing identity (optional, defaults to unsigned/ad-hoc)
  -h, --help            Show this help message
EOF
}

while [ "$#" -gt 0 ]; do
	case "$1" in
	--app)
		[ "$#" -ge 2 ] || fail "--app requires a value"
		APP=$2
		shift 2
		;;
	--configuration)
		[ "$#" -ge 2 ] || fail "--configuration requires a value"
		CONFIGURATION=$2
		shift 2
		;;
	--output-dir)
		[ "$#" -ge 2 ] || fail "--output-dir requires a value"
		OUTPUT_DIR=$2
		shift 2
		;;
	--team)
		[ "$#" -ge 2 ] || fail "--team requires a value"
		TEAM=$2
		shift 2
		;;
	--identity)
		[ "$#" -ge 2 ] || fail "--identity requires a value"
		IDENTITY=$2
		shift 2
		;;
	-h|--help)
		usage
		exit 0
		;;
	*)
		fail "unknown argument: $1"
		;;
	esac
done

case "$APP" in
both|Kernarium|Andarium) ;;
*) fail "invalid app choice: $APP (must be both, Kernarium, or Andarium)" ;;
esac

case "$CONFIGURATION" in
Release|AppStore) ;;
*) fail "invalid configuration: $CONFIGURATION (must be Release or AppStore)" ;;
esac

# Setup/verify Python environment with meson, ninja, mako, packaging, yaml
if [ -x "$ROOT_DIR/.build/gpu-tools-venv/bin/meson" ]; then
	PATH="$ROOT_DIR/.build/gpu-tools-venv/bin:$PATH"
	export PATH
	export UML_MESA_PYTHON="$ROOT_DIR/.build/gpu-tools-venv/bin/python3"
elif ! command -v meson >/dev/null 2>&1 || ! "${UML_MESA_PYTHON:-python3}" -c 'import mako, packaging, yaml' >/dev/null 2>&1; then
	printf '%s\n' "Setting up Python virtual environment for meson and GPU tools at .build/gpu-tools-venv..."
	python3 -m venv "$ROOT_DIR/.build/gpu-tools-venv"
	"$ROOT_DIR/.build/gpu-tools-venv/bin/pip" install --quiet --upgrade pip
	"$ROOT_DIR/.build/gpu-tools-venv/bin/pip" install --quiet meson ninja mako packaging pyyaml
	PATH="$ROOT_DIR/.build/gpu-tools-venv/bin:$PATH"
	export PATH
	export UML_MESA_PYTHON="$ROOT_DIR/.build/gpu-tools-venv/bin/python3"
fi

# Verify essential tools
command -v xcodebuild >/dev/null 2>&1 || fail "xcodebuild is required"
command -v cmake >/dev/null 2>&1 || fail "cmake is required"
command -v ninja >/dev/null 2>&1 || fail "ninja is required"
command -v meson >/dev/null 2>&1 || fail "meson is required (install with 'brew install meson' or pip)"
command -v zip >/dev/null 2>&1 || fail "zip is required"
command -v rsync >/dev/null 2>&1 || fail "rsync is required"
command -v pkg-config >/dev/null 2>&1 || fail "pkg-config is required (install with 'brew install pkg-config')"

BUILD_DIR="$ROOT_DIR/.build/ipa-build"
mkdir -p "$BUILD_DIR" "$OUTPUT_DIR"

# Configure local signing settings if missing
mkdir -p "$ROOT_DIR/GuestHost/Config"
if [ ! -f "$ROOT_DIR/GuestHost/Config/Signing.local.xcconfig" ]; then
	if [ -n "$TEAM" ]; then
		echo "DEVELOPMENT_TEAM = $TEAM" > "$ROOT_DIR/GuestHost/Config/Signing.local.xcconfig"
	else
		echo "DEVELOPMENT_TEAM = " > "$ROOT_DIR/GuestHost/Config/Signing.local.xcconfig"
	fi
fi

if [ -n "$IDENTITY" ]; then
	SIGNING_ARGS="CODE_SIGN_IDENTITY=$IDENTITY"
else
	SIGNING_ARGS="CODE_SIGNING_ALLOWED=NO CODE_SIGN_IDENTITY= CODE_SIGNING_REQUIRED=NO"
fi

# Ensure storage and compression XCFrameworks exist
if [ ! -d "$ROOT_DIR/.build/dependencies/ios-storage/GPTFDisk.xcframework" ]; then
	if [ ! -f "$ROOT_DIR/external/sources/gptfdisk/Makefile.kernarium" ]; then
		"$ROOT_DIR/dependencies/prepare.sh" --product ios-storage
	fi
	"$ROOT_DIR/dependencies/build-ios-storage.sh"
fi

if [ ! -d "$ROOT_DIR/.build/dependencies/ios-zstd/LibZstd.xcframework" ]; then
	if [ ! -f "$ROOT_DIR/external/sources/zstd/lib/Makefile" ]; then
		"$ROOT_DIR/dependencies/prepare.sh" --product ios-compression
	fi
	"$ROOT_DIR/dependencies/build-ios-zstd.sh"
fi

# Ensure Apple GPU device prefix exists
DEVICE_GPU_PREFIX="$ROOT_DIR/.build/dependencies/apple-gpu-vulkan-experiment/ios-device-arm64"
if [ ! -d "$DEVICE_GPU_PREFIX/Frameworks/KosmicKrisp.framework" ]; then
	if [ ! -f "$ROOT_DIR/external/sources/mesa/meson.build" ]; then
		"$ROOT_DIR/dependencies/prepare.sh" --product apple-gpu-vulkan-experiment
	fi
	"$ROOT_DIR/dependencies/build-apple-gpu.sh" --platform ios --prefix "$DEVICE_GPU_PREFIX"
fi

# Ensure iOS Network prefix exists if Kernarium is being built
if [ "$APP" = "both" ] || [ "$APP" = "Kernarium" ]; then
	DEVICE_NETWORK_PREFIX="$ROOT_DIR/.build/dependencies/ios-device-arm64/network"
	if [ ! -d "$DEVICE_NETWORK_PREFIX/lib" ]; then
		if [ ! -f "$ROOT_DIR/external/sources/glib-ios/meson.build" ]; then
			"$ROOT_DIR/dependencies/prepare.sh" --product ios-network
		fi
		"$ROOT_DIR/dependencies/build-ios-network.sh" --platform ios --prefix "$DEVICE_NETWORK_PREFIX"
	fi
fi

# Helper function to archive and package IPA
package_ipa()
{
	target_name=$1
	project_file=$2
	scheme=$3

	printf '%s\n' "=== Archiving $target_name ($CONFIGURATION) ==="
	archive_path="$BUILD_DIR/$target_name.xcarchive"
	rm -rf "$archive_path"

	# Build archive
	# shellcheck disable=SC2086
	xcodebuild archive \
		-project "$project_file" \
		-scheme "$scheme" \
		-configuration "$CONFIGURATION" \
		-destination 'generic/platform=iOS' \
		-archivePath "$archive_path" \
		$SIGNING_ARGS

	app_path=$(find "$archive_path/Products/Applications" -maxdepth 1 -name "*.app" | head -n 1)
	[ -n "$app_path" ] && [ -d "$app_path" ] || fail "failed to find .app in $archive_path"

	printf '%s\n' "=== Packaging $target_name.ipa ==="
	payload_dir="$BUILD_DIR/payload_$target_name"
	rm -rf "$payload_dir"
	mkdir -p "$payload_dir/Payload"
	cp -R "$app_path" "$payload_dir/Payload/"

	ipa_file="$OUTPUT_DIR/$target_name.ipa"
	rm -f "$ipa_file"
	(cd "$payload_dir" && zip -r -y -q "$ipa_file" Payload)
	rm -rf "$payload_dir"
	printf '%s\n' "Created $ipa_file"

	if [ -d "$archive_path/dSYMs" ] && [ "$(ls -A "$archive_path/dSYMs")" ]; then
		dsym_zip="$OUTPUT_DIR/$target_name.dSYM.zip"
		rm -f "$dsym_zip"
		(cd "$archive_path" && zip -r -y -q "$dsym_zip" dSYMs)
		printf '%s\n' "Created $dsym_zip"
	fi
}

# Build Andarium
if [ "$APP" = "both" ] || [ "$APP" = "Andarium" ]; then
	if [ ! -d "$ROOT_DIR/.build/kernarium-xcframeworks/KRuntime_Android_6_18_4K.framework" ]; then
		cmake --preset kernarium-ios-device-android
		cmake --build --preset kernarium-ios-device-android
		"$ROOT_DIR/Kernarium/scripts/package-ios-frameworks.sh" --runtimes android
	fi

	mkdir -p "$ROOT_DIR/.build/andarium-system"
	if [ -d "$ROOT_DIR/.build/android/releases" ] && [ "$(ls -A "$ROOT_DIR/.build/android/releases")" ]; then
		"$ROOT_DIR/Andarium/scripts/stage-system-image.py" || true
	fi

	package_ipa Andarium "$ROOT_DIR/Andarium/Andarium.xcodeproj" Andarium
fi

# Build Kernarium
if [ "$APP" = "both" ] || [ "$APP" = "Kernarium" ]; then
	if [ ! -d "$ROOT_DIR/.build/kernarium-xcframeworks/KRuntime_6_18_4K.framework" ]; then
		cmake --preset kernarium-ios-device
		cmake --build --preset kernarium-ios-device
		if [ ! -d "$ROOT_DIR/.build/kernarium-xcframeworks/KRuntime_Android_6_18_4K.framework" ]; then
			cmake --preset kernarium-ios-device-android
			cmake --build --preset kernarium-ios-device-android
		fi
		"$ROOT_DIR/Kernarium/scripts/package-ios-frameworks.sh" --sdk device --runtimes all
	fi

	package_ipa Kernarium "$ROOT_DIR/Kernarium/Kernarium.xcodeproj" Kernarium
fi

# Generate SHA256SUMS.txt
if ls "$OUTPUT_DIR"/*.ipa >/dev/null 2>&1; then
	printf '%s\n' "=== Generating SHA256SUMS.txt ==="
	(cd "$OUTPUT_DIR" && shasum -a 256 *.ipa > SHA256SUMS.txt)
	cat "$OUTPUT_DIR/SHA256SUMS.txt"
fi

printf '%s\n' "Build and packaging completed successfully!"
