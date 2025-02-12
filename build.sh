#!/usr/bin/env bash

set -euxo pipefail

GITHUB_USERNAME=ammmze
DOCKER_REGISTRY="ghcr.io/${GITHUB_USERNAME}"
TALOS_VERSION=v1.2.0-alpha.0
GASKET_VERSION=97aeba584efd18983850c36dcf7384b0185284b3

# todo: get whereever script is
INIT_DIR="${PWD}"

function check_installed {
    for arg in "$@"; do
        if ! command -v "$arg" &> /dev/null; then
            echo "$arg was not found. Please install $arg."
            exit 1
        fi
    done
}

function checkout {
    local url="$1"
    local dest="$2"
    local ref="$3"

    if [ ! -d "${dest}" ]; then
        git clone "${url}" "${dest}"
        cd "${dest}"
    else
        cd "${dest}"
        git fetch origin
        git reset --hard
    fi

    git checkout "${ref}"
}

function get_pkgs_kernel_version {
    PKGS_DIR="$1"
    KERNEL_PREPARE_PKG_YAML="${PKGS_DIR}/kernel/prepare/pkg.yaml"
    if [ ! -f "${KERNEL_PREPARE_PKG_YAML}" ]; then
        echo "Could not find ${KERNEL_PREPARE_PKG_YAML}."
        exit 1
    fi
    LINUX_MAJOR_MINOR=$(grep 'https://cdn.kernel.org/pub/linux/kernel' "${KERNEL_PREPARE_PKG_YAML}" | sed -En 's/^.*linux-([0-9]+\.[0-9]+)\.[0-9]+\.tar.xz/\1/p')

    if [ -z "${LINUX_MAJOR_MINOR}" ]; then
        echo "Could not extract linux version from ${KERNEL_PREPARE_PKG_YAML}"
        exit 1
    fi
    echo "${LINUX_MAJOR_MINOR}"
}

# check if dependencies are installed
check_installed git make docker yq sed

# ensure work directory is present
WORK_DIR="${INIT_DIR}/work"
mkdir -p "${WORK_DIR}"

# grab talos pkgs at the requested version
checkout https://github.com/talos-systems/pkgs "${WORK_DIR}/pkgs" "${TALOS_VERSION}"

# extract the major.minor version from the kernel/prepare/pkg.yaml
LINUX_MAJOR_MINOR="$(get_pkgs_kernel_version "${WORK_DIR}/pkgs")"

# grab linux kernel at the version from pkgs
checkout https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git "${WORK_DIR}/linux" "v${LINUX_MAJOR_MINOR}"

# grab gasket as the requested version
checkout https://github.com/google/gasket-driver "${WORK_DIR}/gasket" "${GASKET_VERSION}"

# replace staging in-tree gasket (if present) with requested version of gasket
cp -fr "${WORK_DIR}/gasket/src" "${WORK_DIR}/linux/drivers/staging/gasket"

# create patch file that adds gasket to the kernel sources
mkdir -p "${WORK_DIR}/pkgs/kernel/kernel/patches"
cd "${WORK_DIR}/linux"
git add -A
git diff --cached --no-prefix > "${WORK_DIR}/pkgs/kernel/kernel/patches/gasket.patch"

# using a pre-defined patch, add the patch to the pkg.yaml...meta isn't it
cd "${WORK_DIR}/pkgs"
patch -p0 < ../../prepare.gasket.patch

echo 'CONFIG_STAGING_GASKET_FRAMEWORK=y' >> "${WORK_DIR}/pkgs/kernel/build/config-amd64"
echo 'CONFIG_STAGING_APEX_DRIVER=y' >> "${WORK_DIR}/pkgs/kernel/build/config-amd64"

# build kernel image
make kernel PLATFORM=linux/amd64 USERNAME="${GITHUB_USERNAME}" PUSH=false

# build installer
cd "${INIT_DIR}"
IMAGE_NAME="${DOCKER_REGISTRY}/talos-installer:$TALOS_VERSION"
DOCKER_BUILDKIT=0 docker build \
    --build-arg TALOS_VERSION="${TALOS_VERSION}" \
    --build-arg KERNEL_REGISTRY="${DOCKER_REGISTRY}" \
    --build-arg KERNEL_IMAGE_TAG="TBD" \
    --build-arg RM="/lib/modules" \
    -t "$IMAGE_NAME" \
    .
# docker push "$IMAGE_NAME"