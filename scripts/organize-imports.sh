#!/usr/bin/env bash
#
# organize-imports.sh -- let JDTLS manage a Java file's imports: remove
# unused ones, add missing (unambiguous) ones, and sort them, via Eglot's
# `eglot-code-action-organize-imports' (the `source.organizeImports' code
# action). Saves the buffer and prints the resulting import block.
#
# Use this instead of hand-editing import lines: write code using bare class
# names, run this once, then build-check.sh.
#
# Usage:
#   organize-imports.sh <project-root> <target-java-file> [cold-start-timeout-seconds]
#   (default cold-start timeout: DEFAULT_COLD_TIMEOUT in lib.sh)
#
# Exit codes:
#   0  finished -- stdout says whether imports changed, then the import block
#   1  usage error (or the buffer has unsaved changes -- see 6)
#   2  emacsclient unreachable
#   3  timed out waiting for JDTLS to attach (cold start)
#   6  the target's Emacs buffer has unsaved edits; refusing to overwrite them
#   7  buffer is not managed by an Eglot server (or the code action failed)
#   8  Emacs stopped responding (main thread wedged)

set -u -o pipefail
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

usage() {
  cat >&2 <<EOF
Usage: organize-imports.sh <project-root> <target-java-file> [cold-start-timeout=$DEFAULT_COLD_TIMEOUT]

  project-root        absolute path to the Maven project root (has pom.xml/mvnw)
  target-java-file    absolute path to the .java file whose imports to organize
EOF
}

if [ "$#" -lt 2 ]; then
  usage
  exit 1
fi

PROJECT_ROOT_RAW=$1
TARGET_FILE_RAW=$2
COLD_TIMEOUT=${3:-$DEFAULT_COLD_TIMEOUT}

PROJECT_ROOT=$(abspath "$PROJECT_ROOT_RAW") || { echo "ERROR: no such project-root: $PROJECT_ROOT_RAW" >&2; exit 1; }
TARGET_FILE=$(abspath "$TARGET_FILE_RAW") || { echo "ERROR: no such target-java-file: $TARGET_FILE_RAW" >&2; exit 1; }

echo "==> checking Emacs server..." >&2
ping_emacs || exit $?

# Ensures a JDTLS server is attached for this project (cold start if needed).
find_or_open_buffer || exit $?

RESULT_FILE=$(mktemp)
form=$(render_form '
(progn
  (require (quote eglot))
  (let ((buf (find-file-noselect "@@FILE@@"))
        (out "@@OUT@@"))
    (with-current-buffer buf
      (cond
       ((buffer-modified-p)
        (write-region "UNSAVED" nil out nil (quote silent)))
       (t
        ;; Pick up edits made on disk (Edit tool) since the buffer was read.
        (unless (verify-visited-file-modtime buf)
          (revert-buffer :ignore-auto :noconfirm :preserve-modes))
        (unless (bound-and-true-p eglot--managed-mode)
          (eglot--maybe-activate-editing-mode))
        (if (not (bound-and-true-p eglot--managed-mode))
            (write-region "UNMANAGED" nil out nil (quote silent))
          (let ((before (buffer-substring-no-properties (point-min) (point-max))))
            (condition-case err
                (progn
                  (eglot-code-action-organize-imports (point-min))
                  (let ((changed (not (string= before (buffer-substring-no-properties
                                                       (point-min) (point-max))))))
                    (when changed (save-buffer))
                    (write-region
                     (concat (if changed "CHANGED" "UNCHANGED") "\n"
                             (save-excursion
                               (goto-char (point-min))
                               (let (lines)
                                 (while (re-search-forward "^import .*$" nil t)
                                   (push (match-string 0) lines))
                                 (mapconcat (function identity) (nreverse lines) "\n"))))
                     nil out nil (quote silent))))
              (error (write-region (format "ERROR %s" (error-message-string err))
                                   nil out nil (quote silent)))))))))
    t))
' '@@FILE@@' "$TARGET_FILE" '@@OUT@@' "$RESULT_FILE")
eeval "$form" $((DEFAULT_COLD_TIMEOUT / 5)) >/dev/null
if [ $? -eq 124 ]; then
  echo "ERROR: Emacs stopped responding during organize-imports. Wedged main thread -- check the target Emacs directly." >&2
  rm -f "$RESULT_FILE"
  exit 8
fi

result=$(cat "$RESULT_FILE")
rm -f "$RESULT_FILE"
first=${result%%$'\n'*}

case "$first" in
  UNSAVED)
    echo "ERROR: $TARGET_FILE has unsaved edits in its Emacs buffer; not touching it. Save or revert it in Emacs first." >&2
    exit 6 ;;
  UNMANAGED)
    echo "ERROR: $TARGET_FILE is not managed by an Eglot server (JDTLS not attached to this buffer)." >&2
    exit 7 ;;
  ERROR*)
    echo "ERROR: organize-imports failed: ${first#ERROR }" >&2
    exit 7 ;;
  CHANGED)   echo "Imports: CHANGED (file saved)" ;;
  UNCHANGED) echo "Imports: UNCHANGED" ;;
  *)         echo "ERROR: unexpected result: $result" >&2; exit 7 ;;
esac
echo
echo "Import block for $(basename "$TARGET_FILE"):"
if [ "$result" = "$first" ]; then
  echo "(no imports)"
else
  printf '%s\n' "${result#*$'\n'}"
fi
