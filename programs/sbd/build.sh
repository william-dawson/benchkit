#!/bin/bash
set -euo pipefail

system="$1"

REPO_URL="https://github.com/r-ccs-cms/sbd"
REPO_DIR="SBD"
BUILD_DIR="build-benchkit"
ARTIFACT_DIR="${PWD}/artifacts"
RESULTS_DIR="${PWD}/results"
BUILD_LOG_DIR="${RESULTS_DIR}/sbd_build_logs"

source scripts/bk_functions.sh

mkdir -p "${ARTIFACT_DIR}"
mkdir -p "${BUILD_LOG_DIR}"
bk_fetch_source "${REPO_URL}" "${REPO_DIR}" "main"

cd "${REPO_DIR}"
rm -rf "${BUILD_DIR}"
mkdir -p "${BUILD_DIR}"

common_cmake_args=(
  -DCMAKE_BUILD_TYPE=Release
  -DSBD_GPU_BACKEND=none
)

print_log_summary() {
  local logfile="$1"
  grep -E "CMake (version|command|error|warning)|Built target|Linking CXX executable|error:|ERROR" "${logfile}" \
    | tail -n 80 || true
}

run_logged() {
  local label="$1"
  local logfile="$2"
  shift 2

  echo "${label}; full log: ${logfile}"
  if "$@" > "${logfile}" 2>&1; then
    print_log_summary "${logfile}"
    return 0
  fi

  echo "${label} failed; full log: ${logfile}" >&2
  echo "---- ${logfile} tail ----" >&2
  tail -n 160 "${logfile}" >&2 || true
  exit 1
}

case "${system}" in
  Fugaku)
    cmake_args=(
      "${common_cmake_args[@]}"
      -DCMAKE_CXX_COMPILER=mpiFCCpx
      -DCMAKE_CXX_FLAGS="-Nclang -stdlib=libc++ -Kfast"
    )
    ;;
  *)
    echo "Unknown system: ${system}" >&2
    exit 1
    ;;
esac

run_logged "Configuring SBD" "${BUILD_LOG_DIR}/${system}_configure.log" \
  cmake -Wno-dev -S . -B "${BUILD_DIR}" "${cmake_args[@]}"

run_logged "Building SBD" "${BUILD_LOG_DIR}/${system}_build.log" \
  cmake --build "${BUILD_DIR}" --target tpb_diag --parallel 8

tpb_bin=$(find "${BUILD_DIR}" -type f -name diag -perm -u+x | head -n 1)
if [[ -z "${tpb_bin}" ]]; then
  tpb_bin=$(find "${BUILD_DIR}" -type f -name diag | head -n 1)
fi
if [[ -z "${tpb_bin}" || ! -f "${tpb_bin}" ]]; then
  echo "SBD tpb_diag executable not found under ${BUILD_DIR}" >&2
  exit 1
fi

cp "${tpb_bin}" "${ARTIFACT_DIR}/diag"

# Stage benchmark inputs into artifacts so run.sh can retrieve them on the
# compute node even when the source tree is not present (cross-build mode).
cp "data/h2o/fcidump.txt" "${ARTIFACT_DIR}/fcidump.txt"
cp "data/h2o/h2o-1em4-alpha.txt" "${ARTIFACT_DIR}/h2o-1em4-alpha.txt"
