#!/usr/bin/env bash

# Function to show an informational message
function msg() {
    echo -e "\e[1;32m$@\e[0m"
}

#
# Preparing Build
#
function preparing_build() {
	# Installing prerequiresites
	export DEBIAN_FRONTEND=noninteractive
	apt-get update
	apt-get install -y bc binutils-dev bison build-essential ca-certificates ccache clang cmake curl file flex git libelf-dev libssl-dev lld make ninja-build python3 python3-dev texinfo u-boot-tools xz-utils zlib1g-dev gcc g++ patchelf

	# Set .gitconfig
	git config --global user.name "$GH_USER"
	git config --global user.email "$GH_EMAIL"

	# Build a newer version of CMake to satisfy LLVM's requirements
	curl -L https://gitlab.kitware.com/cmake/cmake/-/archive/v3.18.0/cmake-v3.18.0.tar.gz | tar xzf -
	pushd cmake-v3.18.0
	./bootstrap --parallel=$(nproc)
	make -j$(nproc)
	make install
	popd

	# Clone build scripts
	git clone --depth 1 "https://github.com/$GH_BUILD_REPO" build
	cd build

	# Clone LLVM and apply fixup patches *before* building
	git clone --depth 1 "https://github.com/llvm/llvm-project"
	if [ -n "$(echo patches/*.patch)" ]; then
    	pushd llvm-project
    	git apply -3 ../patches/*.patch
    	popd
	fi
}

#
# Building Toolchain
#
function build_toolchain() {
	# Don't touch repo if running on CI
	[ -z "$GH_RUN_ID" ] && repo_flag="--shallow-clone" || repo_flag="--no-update"

	# Build LLVM
	msg "Building LLVM..."
	./build-llvm.py \
		--clang-vendor "EternalX" \
		--targets "ARM;AArch64" \
		"$repo_flag"

	# Build binutils
	msg "Building binutils..."
	./build-binutils.py --targets arm aarch64

	# Remove unused products
	msg "Removing unused products..."
	rm -fr install/include
	rm -f install/lib/*.a install/lib/*.la

	# Strip remaining products
	msg "Stripping remaining products..."
	for f in $(find install -type f -exec file {} \; | grep 'not stripped' | awk '{print $1}'); do
		strip ${f: : -1}
	done

	# Set executable rpaths so setting LD_LIBRARY_PATH isn't necessary
	msg "Setting library load paths for portability..."
	for bin in $(find install -mindepth 2 -maxdepth 3 -type f -exec file {} \; | grep 'ELF .* interpreter' | awk '{print $1}'); do
		# Remove last character from file output (':')
		bin="${bin: : -1}"

		echo "$bin"
		patchelf --set-rpath '$ORIGIN/../lib' "$bin"
	done
}

#
# Pushing Prebuilt
#
function push_prebuilt() {
	# Generate build info
	rel_date="$(date "+%Y%m%d")" # ISO 8601 format
	rel_friendly_date="$(date "+%B %-d, %Y")" # "Month day, year" format
	clang_version="$(install/bin/clang --version | head -n1 | cut -d' ' -f4)"

	# Generate release info
	builder_commit="$(git rev-parse HEAD)"
	pushd llvm-project
	llvm_commit="$(git rev-parse HEAD)"
	short_llvm_commit="$(cut -c-8 <<< $llvm_commit)"
	popd

	llvm_commit_url="https://github.com/llvm/llvm-project/commit/$llvm_commit"
	binutils_ver="$(ls | grep "^binutils-" | sed "s/binutils-//g")"

	# Update Git repository
	git clone "https://$GH_USER:$GH_TOKEN@github.com/$GH_REL_REPO" rel_repo
	pushd rel_repo
	rm -fr *
	cp -r ../install/* .
	# Keep files that aren't part of the toolchain itself
	git checkout README.md LICENSE
	git add .
	git commit -am "Update to $rel_date build
LLVM commit: $llvm_commit_url
binutils version: $binutils_ver
Builder commit: https://github.com/$GH_BUILD_REPO/commit/$builder_commit"
	git push
	popd
}

preparing_build
build_toolchain
push_prebuilt
