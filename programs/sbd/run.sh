#!/bin/bash
set -euo pipefail

system="$1"
nodes="$2"
numproc_node="$3"
nthreads="$4"
n_ranks=$((nodes * numproc_node))

source "${PWD}/scripts/bk_functions.sh"

RESULTS_DIR="${PWD}/results"
WORK_DIR="${PWD}/sbd_run"
ARTIFACT="${PWD}/artifacts/diag"

mkdir -p "${RESULTS_DIR}"
: > "${RESULTS_DIR}/result"

if [[ ! -x "${ARTIFACT}" ]]; then
  echo "Required artifact not found or not executable: ${ARTIFACT}" >&2
  exit 1
fi

rm -rf "${WORK_DIR}"
mkdir -p "${WORK_DIR}"

cp "${PWD}/artifacts/fcidump.txt" "${WORK_DIR}/"
cp "${PWD}/artifacts/h2o-1em4-alpha.txt" "${WORK_DIR}/"

cd "${WORK_DIR}"

case "${system}" in
  Fugaku)
    export OMP_NUM_THREADS="${nthreads}"
    ;;
  *)
    echo "Unknown system: ${system}" >&2
    exit 1
    ;;
esac

layout_task=4
layout_adet=4
layout_bdet=4

case "${n_ranks}" in
  4)   layout_task=1; layout_adet=2; layout_bdet=2 ;;
  8)   layout_task=2; layout_adet=2; layout_bdet=2 ;;
  16)  layout_task=4; layout_adet=2; layout_bdet=2 ;;
  32)  layout_task=4; layout_adet=4; layout_bdet=2 ;;
  64)  layout_task=4; layout_adet=4; layout_bdet=4 ;;
  *)
    # Default to task-only if unlisted; caller should verify this is sensible.
    layout_task="${n_ranks}"
    layout_adet=1
    layout_bdet=1
    ;;
esac

touch .run_marker

run_sbd() {
  local logfile="$1"
  shift
  mpiexec -n "${n_ranks}" "$@" > "${logfile}" 2>&1
}

run_sbd_or_diagnose() {
  local logfile="$1"
  shift
  if run_sbd "${logfile}" "$@"; then
    return 0
  fi
  echo "SBD run failed" >&2
  echo "---- ${logfile} tail ----" >&2
  tail -n 80 "${logfile}" >&2 || true
  echo "---- per-rank output files ----" >&2
  find . -maxdepth 5 -type f -newer .run_marker \
    \( -name 'stdout*' -o -name 'stderr*' \) \
    -exec echo "---- {} tail ----" \; -exec tail -n 20 {} \; 2>/dev/null || true
  exit 1
}

run_sbd_or_diagnose diag.log \
  "${ARTIFACT}" \
  --task_comm_size "${layout_task}" \
  --adet_comm_size "${layout_adet}" \
  --bdet_comm_size "${layout_bdet}" \
  --fcidump fcidump.txt \
  --adetfile h2o-1em4-alpha.txt \
  --method 0 --block 10 --iteration 4 --tolerance 1.0e-8 --rdm 0 \
  --carryover_type 0 --init 0 --shuffle 0

# Fujitsu MPI may redirect per-rank output to output.<JOBID>/ directories.
# If diag.log is empty or missing the marker, search those files as fallback.
logfile="diag.log"
if ! grep -q "Elapsed time for diagonalization" "${logfile}" 2>/dev/null; then
  found_log=$(find . -maxdepth 5 -type f -newer .run_marker -name 'stdout*' | sort | head -n 1)
  if [[ -n "${found_log}" ]]; then
    logfile="${found_log}"
  fi
fi

if ! grep -q "Elapsed time for diagonalization" "${logfile}"; then
  echo "SBD success marker not found" >&2
  echo "---- ${logfile} tail ----" >&2
  tail -n 80 "${logfile}" >&2 || true
  echo "---- per-rank output files ----" >&2
  find . -maxdepth 5 -type f -newer .run_marker \
    \( -name 'stdout*' -o -name 'stderr*' \) \
    -exec echo "---- {} tail ----" \; -exec tail -n 20 {} \; 2>/dev/null || true
  exit 1
fi

davidson_time=$(grep "Elapsed time for davidson" "${logfile}" | awk '{print $NF}')
diag_time=$(grep "Elapsed time for diagonalization" "${logfile}" | awk '{print $NF}')
helper_time=$(grep "Elapsed time for helper construction" "${logfile}" | awk '{print $NF}')
init_time=$(grep "Elapsed time for init" "${logfile}" | awk '{print $NF}')

bk_emit_result \
  --fom "${davidson_time}" \
  --fom-unit s \
  --fom-version "davidson_time" \
  --exp "h2o-cc-pvdz-1em4" \
  --nodes "${nodes}" \
  --numproc-node "${numproc_node}" \
  --nthreads "${nthreads}" >> "${RESULTS_DIR}/result"

bk_emit_section helper "${helper_time}"
bk_emit_section init "${init_time}"
bk_emit_section diagonalization "${diag_time}"
bk_emit_section davidson "${davidson_time}"
