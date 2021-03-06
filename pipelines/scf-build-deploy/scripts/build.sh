#!/bin/bash

set -euxo pipefail

BASE_DIR="$(pwd)"

# Start Docker Daemon (and set a trap to stop it once this script is done)
echo 'DOCKER_OPTS="--data-root /scratch/docker --max-concurrent-downloads 10"' >/etc/default/docker
service docker start
service docker status
trap 'service docker stop' EXIT
sleep 10

echo "${DOCKER_TEAM_PASSWORD_RW}" | docker login --username "${DOCKER_TEAM_USERNAME}" --password-stdin

pushd scf-pub-github-repo
source .envrc

# Add safe-guard: We should only build images if the current fissile version
# matched the one SUSE wants us to use for the respective SCF version in use.
REQUIRED_FISSILE_VERSION=$(source ./bin/common/versions.sh && echo "${FISSILE_VERSION}")
REQUIRED_FISSILE_COMMIT_SHA="$(grep -Eo '[A-Za-z0-9]{7}$' <<<"${REQUIRED_FISSILE_VERSION}")"
echo "Required fissile version: ${REQUIRED_FISSILE_VERSION}"

# Add workaround, because latest stable scf version(2.13.3) needs to use old fissile git
# repo
pushd "$(mktemp -d)" >/dev/null
( mkdir -p src && \
  export GOPATH=$PWD && \
  export PATH="$PATH:$GOPATH/bin" && \
  git clone https://github.com/SUSE/fissile $GOPATH/src/github.com/SUSE/fissile && \
  cd $GOPATH/src/github.com/SUSE/fissile && \
  perl -pi -e "s/github.com\/golang\/lint\/golint/golang.org\/x\/lint\/golint/g" make/tools && \
  git checkout "${REQUIRED_FISSILE_COMMIT_SHA}" && \
  make tools docker-deps build && \
  cp -p build/linux-amd64/fissile /usr/local/bin/fissile )
popd >/dev/null

# pushd "$(mktemp -d)" >/dev/null
# ( mkdir -p src && \
#   export GOPATH=$PWD && \
#   export PATH="$PATH:$GOPATH/bin" && \
#   go get -d code.cloudfoundry.org/fissile || true && \
#   cd $GOPATH/src/code.cloudfoundry.org/fissile && \
#   git checkout "${REQUIRED_FISSILE_COMMIT_SHA}" && \
#   make tools docker-deps build && \
#   cp -p build/linux-amd64/fissile /usr/local/bin/fissile )
# popd >/dev/null

echo "[INFO] fissile version: $(fissile version)"

SCF_VERSION="$(git describe --tags)"

make docker-deps

# export FISSILE_DOCKER_REGISTRY="${REGISTRY_ENDPOINT}"
export FISSILE_DOCKER_USERNAME="${DOCKER_TEAM_USERNAME}"
export FISSILE_DOCKER_PASSWORD="${DOCKER_TEAM_PASSWORD_RW}"
export FISSILE_DOCKER_ORGANIZATION="${REGISTRY_NAMESPACE}"

make releases \
  compile \
  images
popd

echo "Process locally generated Helm Charts"
HELM_TMP_DIR="$(mktemp --directory)"
mkdir -p ${HELM_TMP_DIR}/kube ${HELM_TMP_DIR}/helm
cp -rp scf-pub-github-repo/output/kube ${HELM_TMP_DIR}/kube/cf
cp -rp scf-pub-github-repo/src/uaa-fissile-release/kube ${HELM_TMP_DIR}/kube/uaa
cp -rp scf-pub-github-repo/output/helm ${HELM_TMP_DIR}/helm/cf
cp -rp scf-pub-github-repo/src/uaa-fissile-release/helm ${HELM_TMP_DIR}/helm/uaa
TARGET_TGZ="$(realpath helm-chart-store)/scf-${SCF_VERSION}-helm.tar.gz"
pushd ${HELM_TMP_DIR}
tar -czf ${TARGET_TGZ} helm kube
popd

echo "Pushing Docker images ..."
docker images --format "{{.Repository}}:{{.Tag}}" | grep "${REGISTRY_NAMESPACE}/" | while read -r DOCKER_IMAGE_AND_TAG; do
  docker push "${DOCKER_IMAGE_AND_TAG}"
done
  