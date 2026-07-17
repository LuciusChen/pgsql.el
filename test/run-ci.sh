#!/usr/bin/env bash
set -euo pipefail

repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
emacs_bin=${EMACS:-emacs}

usage() {
  cat <<'EOF'
Usage: ./test/run-ci.sh [TARGET...]

Targets:
  all            Run unit tests and every non-live quality gate.
  unit           Run deterministic ERT tests.
  byte-compile   Byte-compile implementation and tests with zero warnings.
  checkdoc       Run checkdoc on the distributable package file.
  package-lint   Run package-lint on the distributable package file.
  live           Run PostgreSQL live tests using PGSQL_TEST_* variables.
EOF
}

run_emacs() {
  "$emacs_bin" -Q --batch -L "$repo" -L "$repo/test" "$@"
}

run_unit() {
  run_emacs -l ert -l pgsql-test \
    --eval '(ert-run-tests-batch-and-exit t)'
}

run_byte_compile() {
  local status=0
  (
    cd "$repo"
    run_emacs --eval '(setq byte-compile-error-on-warn t)' \
      -f batch-byte-compile pgsql.el test/pgsql-test.el test/pgsql-live-test.el
  ) || status=$?
  rm -f "$repo/pgsql.elc" \
    "$repo/test/pgsql-test.elc" \
    "$repo/test/pgsql-live-test.elc"
  return "$status"
}

run_checkdoc() {
  (
    cd "$repo"
    run_emacs \
      --eval "(require 'checkdoc)" \
      --eval "(checkdoc-file \"pgsql.el\")" \
      --eval "(dolist (name '(\"*Warnings*\" \"*warn*\")) (when-let* ((buffer (get-buffer name))) (with-current-buffer buffer (goto-char (point-min)) (when (re-search-forward \"^Warning\" nil t) (princ (buffer-string)) (kill-emacs 1)))))"
  )
}

run_package_lint() {
  (
    cd "$repo"
    run_emacs \
      --eval "(require 'package)" \
      --eval "(package-initialize)" \
      -l package-lint \
      -f package-lint-batch-and-exit \
      pgsql.el
  )
}

run_live() {
  run_emacs -l ert -l pgsql-live-test \
    --eval '(ert-run-tests-batch-and-exit t)'
}

run_target() {
  case "$1" in
    all)
      run_unit
      run_byte_compile
      run_checkdoc
      run_package_lint
      ;;
    unit) run_unit ;;
    byte-compile) run_byte_compile ;;
    checkdoc) run_checkdoc ;;
    package-lint) run_package_lint ;;
    live) run_live ;;
    -h|--help) usage ;;
    *)
      usage >&2
      exit 2
      ;;
  esac
}

if (($# == 0)); then
  set -- all
fi

for target in "$@"; do
  run_target "$target"
done
