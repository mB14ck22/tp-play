#!/bin/sh
set -eu

platform="${1:-iphoneos}"
if [ "$platform" != "iphoneos" ]; then
	echo "TP Play currently builds the core for a physical iPhone only." >&2
	exit 2
fi

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ios_dir=$(dirname "$script_dir")
repo_dir=$(dirname "$ios_dir")
build_dir="$ios_dir/.build/$platform/cmake"
output_dir="$ios_dir/.build/$platform"
python_env="$ios_dir/.build/python"
sources_dir="$ios_dir/.build/sources"
mbedtls_source="$sources_dir/mbedtls-2.28.0"
opus_source="$sources_dir/opus-1.5.2"

export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
: "${DEVELOPER_DIR:=/Volumes/XcodeSSD/Applications/Xcode.app/Contents/Developer}"
export DEVELOPER_DIR
unset SDKROOT CFLAGS CXXFLAGS CPPFLAGS LDFLAGS ARCHS

command -v cmake >/dev/null 2>&1 || { echo "cmake is required (brew install cmake)." >&2; exit 1; }
command -v ninja >/dev/null 2>&1 || { echo "ninja is required (brew install ninja)." >&2; exit 1; }
command -v protoc >/dev/null 2>&1 || { echo "protoc is required (brew install protobuf)." >&2; exit 1; }

mkdir -p "$build_dir" "$output_dir"
if [ ! -x "$python_env/bin/python" ]; then
	python3 -m venv "$python_env"
fi

if [ ! -f "$opus_source/CMakeLists.txt" ]; then
	mkdir -p "$opus_source"
	opus_archive="$sources_dir/opus-1.5.2.tar.gz"
	curl --fail --location --retry 5 --output "$opus_archive" \
		https://github.com/xiph/opus/archive/refs/tags/v1.5.2.tar.gz
	echo "9480e329e989f70d69886ded470c7f8cfe6c0667cc4196d4837ac9e668fb7404  $opus_archive" | shasum -a 256 -c -
	tar -xzf "$opus_archive" --strip-components 1 -C "$opus_source"
fi

if [ ! -f "$mbedtls_source/CMakeLists.txt" ]; then
	mkdir -p "$mbedtls_source"
	mbedtls_archive="$sources_dir/mbedtls-2.28.0.tar.gz"
	curl --fail --location --retry 5 --output "$mbedtls_archive" \
		https://github.com/Mbed-TLS/mbedtls/archive/8b3f26a5ac38d4fdccbc5c5366229f3e01dafcc0.tar.gz
	echo "f16ba9cdec40b3063854962c870f7ab6b05ff9666f0acb5965ebcb163443e998  $mbedtls_archive" | shasum -a 256 -c -
	tar -xzf "$mbedtls_archive" --strip-components 1 -C "$mbedtls_source"
fi
if ! "$python_env/bin/python" -c 'import google.protobuf; assert google.protobuf.__version__ == "7.36.0"' 2>/dev/null; then
	"$python_env/bin/python" -m pip install --disable-pip-version-check 'protobuf==7.36.0'
fi

cmake -S "$repo_dir" -B "$build_dir" -G Ninja \
	-DCMAKE_SYSTEM_NAME=iOS \
	-DCMAKE_OSX_SYSROOT=iphoneos \
	-DCMAKE_OSX_ARCHITECTURES=arm64 \
	-DCMAKE_OSX_DEPLOYMENT_TARGET=17.0 \
	-DCMAKE_BUILD_TYPE=Release \
	-DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
	-DPYTHON_EXECUTABLE="$python_env/bin/python" \
	-DBUILD_SHARED_LIBS=OFF \
	-DCHIAKI_ENABLE_TESTS=OFF \
	-DCHIAKI_ENABLE_CLI=OFF \
	-DCHIAKI_ENABLE_GUI=OFF \
	-DCHIAKI_ENABLE_ANDROID=OFF \
	-DCHIAKI_ENABLE_BOREALIS=OFF \
	-DCHIAKI_ENABLE_SETSU=OFF \
	-DCHIAKI_ENABLE_STEAMDECK_NATIVE=OFF \
	-DCHIAKI_ENABLE_STEAM_SHORTCUT=OFF \
	-DCHIAKI_ENABLE_FFMPEG_DECODER=OFF \
	-DCHIAKI_ENABLE_PI_DECODER=OFF \
	-DCHIAKI_ENABLE_RUDP=ON \
	-DCHIAKI_LIB_ENABLE_OPUS=ON \
	-DCHIAKI_LIB_OPUS_EXTERNAL_PROJECT=ON \
	-DFETCHCONTENT_SOURCE_DIR_OPUS="$opus_source" \
	-DCHIAKI_LIB_ENABLE_MBEDTLS=ON \
	-DCHIAKI_LIB_MBEDTLS_EXTERNAL_PROJECT=ON \
	-DMBEDTLS_FATAL_WARNINGS=OFF \
	-DFETCHCONTENT_SOURCE_DIR_MBEDTLS="$mbedtls_source" \
	-DCHIAKI_LIB_JSONC_EXTERNAL_PROJECT=ON \
	-DCHIAKI_LIB_MINIUPNPC_EXTERNAL_PROJECT=ON \
	-DCHIAKI_LIB_LIBEVENT_EXTERNAL_PROJECT=ON \
	-DCHIAKI_USE_SYSTEM_CURL=OFF \
	-DCHIAKI_USE_SYSTEM_NANOPB=OFF \
	-DCHIAKI_USE_SYSTEM_JERASURE=OFF \
	-DCURL_USE_SECTRANSP=ON \
	-DCURL_USE_OPENSSL=OFF \
	-DCURL_USE_LIBPSL=OFF \
	-DCURL_USE_LIBSSH2=OFF \
	-DCURL_ZLIB=OFF \
	-DCURL_BROTLI=OFF \
	-DCURL_ZSTD=OFF

cmake --build "$build_dir" --target chiaki-lib -j8

libtool -static -o "$output_dir/libTPPlayCore.a" \
	"$build_dir/lib/libchiaki.a" \
	"$build_dir/_deps/mbedtls-build/library/libmbedtls.a" \
	"$build_dir/_deps/mbedtls-build/library/libmbedx509.a" \
	"$build_dir/_deps/mbedtls-build/library/libmbedcrypto.a" \
	"$build_dir/_deps/json-c-build/libjson-c.a" \
	"$build_dir/_deps/miniupnpc-build/libminiupnpc.a" \
	"$build_dir/_deps/libevent-build/lib/libevent_core.a" \
	"$build_dir/_deps/opus-build/libopus.a" \
	"$build_dir/third-party/curl/lib/libcurl.a" \
	"$build_dir/third-party/nanopb/libprotobuf-nanopb.a" \
	"$build_dir/third-party/libjerasure.a" \
	"$build_dir/third-party/libgf_complete.a"

mkdir -p "$output_dir/include/chiaki"
cp -R "$repo_dir/lib/include/chiaki/." "$output_dir/include/chiaki/"
cp "$build_dir/lib/include/chiaki/config.h" "$output_dir/include/chiaki/config.h"

echo "Built $output_dir/libTPPlayCore.a"
