#!/usr/bin/env bash
#
# build-check.sh -- "does it still compile" check. Runs exactly one thing:
# `eglot-helpers-java-mvn-build-project-skiptests' (`mvnw clean package
# -DskipTests -U'), waits for the Maven compilation buffer to finish, and
# prints its output. No JDTLS/java/buildWorkspace, no Flymake, and no
# JDTLS cold start: the target file is opened without Eglot.
#
# Caveat: `mvnw clean' deletes target/classes outside Eclipse's resource
# API and can corrupt the JDTLS workspace cache of a live JDTLS session in
# the same project (ObjectNotFoundException at next startup).
#
# Usage:
#   build-check.sh <project-root> <target-java-file> [build-timeout-seconds]
#   (default: DEFAULT_BUILD_TIMEOUT below)
#
# Exit codes (about ORCHESTRATION, not compile outcome -- a failed Maven
# build still exits 0; that's real signal in the printed output):
#   0  finished -- stdout has the full mvn compilation buffer
#   1  usage error
#   2  emacsclient unreachable
#   4  no compilation buffer appeared within 10s of triggering the build
#   5  build-timeout exceeded waiting for the build to finish
#   8  Emacs stopped responding (main thread wedged)

set -u -o pipefail
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

DEFAULT_BUILD_TIMEOUT=900

usage() {
  cat >&2 <<EOF
Usage: build-check.sh <project-root> <target-java-file> [build-timeout=$DEFAULT_BUILD_TIMEOUT]

  project-root        absolute path to the Maven project root (has pom.xml/mvnw)
  target-java-file    absolute path to a .java file in the project (sets the build's buffer/directory)
EOF
}

if [ "$#" -lt 2 ]; then
  usage
  exit 1
fi

PROJECT_ROOT_RAW=$1
TARGET_FILE_RAW=$2
BUILD_TIMEOUT=${3:-$DEFAULT_BUILD_TIMEOUT}

PROJECT_ROOT=$(abspath "$PROJECT_ROOT_RAW") || { echo "ERROR: no such project-root: $PROJECT_ROOT_RAW" >&2; exit 1; }
TARGET_FILE=$(abspath "$TARGET_FILE_RAW") || { echo "ERROR: no such target-java-file: $TARGET_FILE_RAW" >&2; exit 1; }

echo "==> checking Emacs server..." >&2
ping_emacs || exit $?

echo "==> running eglot-helpers-java-mvn-build-project-skiptests (mvnw clean package -DskipTests -U)" >&2
trigger_form=$(render_form '
(with-current-buffer (find-file-noselect "@@FILE@@")
  (eglot-helpers-java-mvn-build-project-skiptests))
' '@@FILE@@' "$TARGET_FILE")
eeval "$trigger_form" >/dev/null
if [ $? -eq 124 ]; then
  echo "ERROR: Emacs stopped responding while triggering the mvn build. Wedged main thread -- check the target Emacs directly." >&2
  exit 8
fi

  echo "==> locating the mvn compilation buffer..." >&2
  find_comp_form=$(render_form '
(progn
  (require (quote cl-lib))
  (let ((root (file-name-as-directory (expand-file-name "@@ROOT@@"))))
    (or (cl-loop for b in (buffer-list)
                 when (and (buffer-live-p b)
                           (with-current-buffer b
                             (and (or (derived-mode-p (quote compilation-mode))
                                      (bound-and-true-p compilation-shell-minor-mode))
                                  default-directory
                                  (string-prefix-p root (expand-file-name default-directory)))))
                 return (buffer-name b))
        "")))
' '@@ROOT@@' "$PROJECT_ROOT")

  elapsed=0
  COMP_BUFFER=""
  while [ "$elapsed" -lt 10 ]; do
    COMP_BUFFER=$(unquote "$(eeval "$find_comp_form")")
    [ -n "$COMP_BUFFER" ] && break
    sleep 1
    elapsed=$((elapsed + 1))
  done

  if [ -z "$COMP_BUFFER" ]; then
    echo "ERROR: no compilation buffer appeared under $PROJECT_ROOT within 10s of triggering the mvn build" >&2
    exit 4
  fi
  echo "==> mvn compilation buffer: $COMP_BUFFER" >&2

  SENTINEL_FILE=$(mktemp)
  rm -f "$SENTINEL_FILE"
  hook_form=$(render_form '
(with-current-buffer (get-buffer "@@BUF@@")
  (if (process-live-p (get-buffer-process (current-buffer)))
      (add-hook (quote compilation-finish-functions)
                (lambda (_buf _msg) (write-region "done" nil "@@SENTINEL@@" nil (quote silent)))
                nil t)
    (write-region "done" nil "@@SENTINEL@@" nil (quote silent)))
  t)
' '@@BUF@@' "$COMP_BUFFER" '@@SENTINEL@@' "$SENTINEL_FILE")
  eeval "$hook_form" >/dev/null

  echo "==> waiting for the mvn build to finish (timeout ${BUILD_TIMEOUT}s)..." >&2
  HEALTH_INTERVAL=10
  elapsed=0
  since_health=0
  while [ ! -f "$SENTINEL_FILE" ]; do
    if [ "$elapsed" -ge "$BUILD_TIMEOUT" ]; then
      echo "ERROR: build-timeout (${BUILD_TIMEOUT}s) exceeded waiting for $COMP_BUFFER to finish" >&2
      rm -f "$SENTINEL_FILE"
      exit 5
    fi
    if [ "$since_health" -ge "$HEALTH_INTERVAL" ]; then
      since_health=0
      ping_emacs >/dev/null 2>&1
      if [ $? -eq 8 ]; then
        echo "ERROR: Emacs stopped responding while waiting for $COMP_BUFFER to finish (no reply within ${EMACSCLIENT_TIMEOUT}s on a trivial check). Not safe to keep waiting on a wedged Emacs -- check it directly." >&2
        rm -f "$SENTINEL_FILE"
        exit 8
      fi
    fi
    sleep 1
    elapsed=$((elapsed + 1))
    since_health=$((since_health + 1))
  done
  rm -f "$SENTINEL_FILE"

  OUTPUT_FILE=$(mktemp)
  dump_form=$(render_form '
(with-current-buffer (get-buffer "@@BUF@@")
  (write-region (point-min) (point-max) "@@OUT@@" nil (quote silent)))
' '@@BUF@@' "$COMP_BUFFER" '@@OUT@@' "$OUTPUT_FILE")
  eeval "$dump_form" >/dev/null

  echo "Build status: see mvn output below for pass/fail"
  echo
  cat "$OUTPUT_FILE"
  rm -f "$OUTPUT_FILE"
  exit 0
