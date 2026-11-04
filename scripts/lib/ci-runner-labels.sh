#!/usr/bin/env bash
# ci-runner-labels.sh — the ONE source for the canonical CI runner label set (agent-infra#2875).
#
# WHY THIS IS A LIBRARY AND NOT TWO CONSTANTS. The starvation incident (2026-10-27) had every
# runner advertise `self-hosted,Linux,X64,self-hosted-x64` while every workflow asks
# `runs-on: ubuntu-latest`: the provisioning path registered the pool marker but NOT `ubuntu-latest`,
# and the queue sat at `queued>0 AND busy==0` — 46 runs, 0 assigned, nothing errored. The fix is
# not "add the label this once": a re-provision that reintroduces the gap is the same incident again.
# So the canonical set — the arch marker AND `ubuntu-latest` — lives in exactly ONE place, and BOTH
# consumers source it:
#
#   * the PROVISIONER (`scripts/ci_runner_pool.sh`) — registers runners with the canonical set and
#     asserts it after the registration finishes (the actual fix);
#   * the HEALER (`scripts/ci_runner_starvation.sh`) — re-asserts the canonical set on a starved
#     pool and verifies it after the write (the safety net).
#
# ⛔ `ubuntu-latest` IS PART OF THE SET BY DEFAULT. The repo's workflows use `runs-on: ubuntu-latest`,
# and the pool is the capacity those jobs land on when GitHub-hosted cannot take them. A runner that
# lacks `ubuntu-latest` is registered, advertised and idle — zero capacity, no error.
#
# PURE STRING FUNCTIONS ONLY. This file reads no GitHub state, no process table, no filesystem and
# no environment beyond the arguments it is given; every function is a predicate or a derivation
# over a label list. That is what makes it safe to source from two scripts with different I/O.

CI_RUNNER_LABEL_X64="self-hosted-x64"
CI_RUNNER_LABEL_ARM64="self-hosted-arm64"
CI_RUNNER_LABEL_UBUNTU="ubuntu-latest"

# ci_runner_pool_label <uname_m> — the arch marker for a host, or rc 1 when the arch is unknown.
# GitHub stamps ARM64/X64 from the REGISTRATION HOST; the marker is the pool label `ci_runner_gate.sh`
# selects on, and it must describe the runner (a typo is a jobless runner, not a refusal).
ci_runner_pool_label() {
  case "${1:-}" in
    x86_64|amd64) printf '%s' "$CI_RUNNER_LABEL_X64" ;;
    arm64|aarch64) printf '%s' "$CI_RUNNER_LABEL_ARM64" ;;
    *) return 1 ;;
  esac
}

# ci_runner_canonical_labels <uname_m> — the canonical set as a comma-separated `--labels` argument:
# `<marker>,ubuntu-latest`. rc 1 when the arch is unknown.
ci_runner_canonical_labels() {
  local arch
  arch="$(ci_runner_pool_label "${1:-}")" || return 1
  printf '%s,%s' "$arch" "$CI_RUNNER_LABEL_UBUNTU"
}

# ci_runner_labels_have_canonical <labels> — rc 0 when the space-separated label list contains the
# canonical set: `ubuntu-latest` AND one of the two arch markers. A runner's own marker is specific,
# but the CHECK accepts either marker so one predicate serves a runner of either architecture.
# ⛔ This is the predicate the provisioner's assertion and the healer's step-1 verification BOTH call
# ("the same check" in the issue) — a second copy is how the gap drifts back in.
ci_runner_labels_have_canonical() {
  local labels="${1:-}" l have_ubuntu=0 have_marker=0
  for l in $labels; do
    [ "$l" = "$CI_RUNNER_LABEL_UBUNTU" ] && have_ubuntu=1
    case "$l" in "$CI_RUNNER_LABEL_X64"|"$CI_RUNNER_LABEL_ARM64") have_marker=1 ;; esac
  done
  [ "$have_ubuntu" = 1 ] && [ "$have_marker" = 1 ]
}

# ci_runner_missing_canonical_labels <labels> — print, space-separated, the canonical labels the list
# lacks (empty output = the set is complete). Used to build the ADDITIVE POST body: only what is
# missing is added, and a runner with an extra custom label keeps it.
ci_runner_missing_canonical_labels() {
  local labels="${1:-}" l have_ubuntu=0 have_marker=0
  for l in $labels; do
    [ "$l" = "$CI_RUNNER_LABEL_UBUNTU" ] && have_ubuntu=1
    case "$l" in "$CI_RUNNER_LABEL_X64"|"$CI_RUNNER_LABEL_ARM64") have_marker=1 ;; esac
  done
  [ "$have_ubuntu" = 1 ] || printf '%s ' "$CI_RUNNER_LABEL_UBUNTU"
  [ "$have_marker" = 1 ] || printf '%s ' "$CI_RUNNER_LABEL_X64"
}

# ci_runner_labels_add_canonical <labels> — the label list with the missing canonical labels appended
# (space-separated in, space-separated out). Preserves any extra custom label, which is what makes a
# REPLACE (PUT) of the whole set wrong: it would drop labels the gate did not add.
ci_runner_labels_add_canonical() {
  local labels="${1:-}" missing
  missing="$(ci_runner_missing_canonical_labels "$labels")"
  missing="${missing%"${missing##*[! ]}"}"   # strip trailing spaces, keep the interior
  if [ -n "$missing" ]; then
    printf '%s %s' "$labels" "$missing"
  else
    printf '%s' "$labels"
  fi
}
