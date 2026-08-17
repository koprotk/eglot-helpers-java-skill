#!/usr/bin/env bash
# lib.sh — shared helpers for the eglot-java-test skill scripts.
# Sourced, not executed directly.
#
# IMPORTANT: `emacsclient --eval` evaluates in the Emacs *server/daemon*
# process, which does NOT inherit the calling shell's environment — a
# `getenv` inside the eval'd form sees the daemon's env, not anything
# `export`ed here. So every value that needs to reach Elisp must be spliced
# directly into the form text as a literal string (via elquote/render_form
# below), never passed through the environment.

abspath() {
  local p="$1"
  if [ -d "$p" ]; then
    (cd "$p" && pwd -P)
  else
    local dir base
    dir=$(cd "$(dirname "$p")" && pwd -P) || return 1
    base=$(basename "$p")
    printf '%s/%s' "$dir" "$base"
  fi
}

# Strip one layer of Lisp's prin1 double-quoting from a returned string.
# Good enough for filesystem paths/buffer names, which don't contain '"'.
unquote() {
  local s=$1
  s=${s#\"}
  s=${s%\"}
  printf '%s' "$s"
}

eeval() {
  emacsclient --eval "$1"
}

ping_emacs() {
  if ! eeval 'nil' >/dev/null 2>&1; then
    echo "ERROR: emacsclient can't reach an Emacs server. Is (server-start) active in the target Emacs?" >&2
    return 2
  fi
}

# Escape a raw string for safe embedding inside a double-quoted Elisp string
# literal (backslash and double-quote only — these are filesystem paths and
# identifiers, not arbitrary text).
elquote() {
  local s=$1
  s=${s//\\/\\\\}
  s=${s//\"/\\\"}
  printf '%s' "$s"
}

# render_form TEMPLATE PLACEHOLDER1 VALUE1 [PLACEHOLDER2 VALUE2 ...]
# Literal (non-regex) substring substitution — each VALUE is elisp-escaped
# before being spliced in. Pick placeholders that can't collide with real
# path/identifier content (e.g. "@@ROOT@@").
render_form() {
  local form=$1
  shift
  while [ "$#" -ge 2 ]; do
    local ph=$1 val
    val=$(elquote "$2")
    form=${form//$ph/$val}
    shift 2
  done
  printf '%s' "$form"
}

# Sets BUFFER_FILE to a .java file under PROJECT_ROOT that JDTLS manages —
# reuses one already open if found, otherwise opens TARGET_FILE and waits
# (up to COLD_TIMEOUT seconds) for eglot-ensure to attach.
# PROJECT_ROOT, TARGET_FILE, COLD_TIMEOUT must already be set (plain bash
# vars — no export needed, everything is spliced in literally).
# Returns non-zero (and prints to stderr) on cold-start timeout.
find_or_open_buffer() {
  echo "==> looking for an existing JDTLS-managed buffer under $PROJECT_ROOT..." >&2
  local find_form
  find_form=$(render_form '
(progn
  (require (quote cl-lib))
  (require (quote eglot) nil t)
  (let ((root (file-name-as-directory (expand-file-name "@@ROOT@@"))))
    (or (cl-loop for b in (buffer-list)
                 for f = (buffer-file-name b)
                 when (and f
                           (string-prefix-p root (expand-file-name f))
                           (string-suffix-p ".java" f)
                           (with-current-buffer b
                             (and (fboundp (quote eglot-current-server))
                                  (eglot-current-server))))
                 return f)
        "")))
' '@@ROOT@@' "$PROJECT_ROOT")
  BUFFER_FILE=$(unquote "$(eeval "$find_form")")

  if [ -n "$BUFFER_FILE" ]; then
    echo "==> found managed buffer: $BUFFER_FILE" >&2
    return 0
  fi

  echo "==> none managed yet — opening $TARGET_FILE and calling eglot-ensure..." >&2
  BUFFER_FILE=$TARGET_FILE
  local open_form
  open_form=$(render_form '
(progn
  (require (quote eglot) nil t)
  (with-current-buffer (find-file-noselect "@@FILE@@")
    (eglot-ensure)))
' '@@FILE@@' "$BUFFER_FILE")
  eeval "$open_form" >/dev/null

  echo "==> waiting for JDTLS to attach (cold start can take minutes on a large project)..." >&2
  local ready_form
  ready_form=$(render_form '
(with-current-buffer (get-file-buffer "@@FILE@@")
  (and (eglot-current-server) t))
' '@@FILE@@' "$BUFFER_FILE")
  local elapsed=0
  while :; do
    local ready
    ready=$(eeval "$ready_form")
    [ "$ready" = "t" ] && break
    if [ "$elapsed" -ge "$COLD_TIMEOUT" ]; then
      echo "ERROR: timed out after ${COLD_TIMEOUT}s waiting for JDTLS to attach to $BUFFER_FILE" >&2
      return 3
    fi
    sleep 2
    elapsed=$((elapsed + 2))
    echo "    ...still waiting (${elapsed}s elapsed)" >&2
  done
  echo "==> JDTLS attached." >&2
}
