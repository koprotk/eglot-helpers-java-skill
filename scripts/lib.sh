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

# Per-call ceiling for emacsclient --eval, in seconds. A healthy call
# returns in well under a second -- this exists purely to catch an Emacs
# whose main thread is wedged (a synchronous LSP/JDTLS call that never
# returns is the recurring cause here) so a polling loop can detect that
# and fail fast instead of treating "no answer yet" the same as "not ready
# yet" and burning its own timeout budget one hung eval at a time. Override
# per-call by passing a second argument to eeval, or globally via the
# EMACSCLIENT_TIMEOUT env var.
EMACSCLIENT_TIMEOUT=${EMACSCLIENT_TIMEOUT:-20}

# eeval FORM [TIMEOUT_SECONDS]
# stdout is whatever emacsclient printed. Exit status:
#   0    emacsclient returned normally (its own reply, unexamined)
#   124  FORM did not come back within TIMEOUT_SECONDS -- Emacs itself is
#        unresponsive, not merely "still working". Killing our side does
#        NOT abort the evaluation on the Emacs side (emacsclient --eval has
#        no cancel signal) -- Emacs can stay wedged for anything that talks
#        to it afterwards too. Callers must check for 124 explicitly and
#        bail rather than keep polling.
#   *    whatever emacsclient itself exited with (e.g. connection refused)
eeval() {
  local form=$1
  local timeout_s=${2:-$EMACSCLIENT_TIMEOUT}
  if command -v timeout >/dev/null 2>&1; then
    timeout "$timeout_s" emacsclient --eval "$form"
    return $?
  fi
  if command -v gtimeout >/dev/null 2>&1; then
    gtimeout "$timeout_s" emacsclient --eval "$form"
    return $?
  fi
  # Stock macOS ships neither `timeout` nor `gtimeout` (that's coreutils) --
  # do the same job by hand: background the call, poll for it to finish,
  # hard-kill and report 124 if it outlives the budget.
  local out
  out=$(mktemp)
  emacsclient --eval "$form" >"$out" 2>&1 &
  local pid=$! waited=0
  while kill -0 "$pid" 2>/dev/null; do
    if [ "$waited" -ge "$timeout_s" ]; then
      kill -9 "$pid" 2>/dev/null
      wait "$pid" 2>/dev/null
      rm -f "$out"
      return 124
    fi
    sleep 1
    waited=$((waited + 1))
  done
  wait "$pid"
  local rc=$?
  cat "$out"
  rm -f "$out"
  return "$rc"
}

ping_emacs() {
  eeval 'nil' >/dev/null 2>&1
  local rc=$?
  case "$rc" in
    0) return 0 ;;
    124)
      echo "ERROR: emacsclient timed out after ${EMACSCLIENT_TIMEOUT}s on a trivial eval -- Emacs is running but its main thread is stuck (a wedged synchronous call, often JDTLS/eglot, is the usual cause). Fix that in the target Emacs directly (C-g, M-x eglot-reconnect, or restart JDTLS) before retrying." >&2
      return 8
      ;;
    *)
      echo "ERROR: emacsclient can't reach an Emacs server. Is (server-start) active in the target Emacs?" >&2
      return 2
      ;;
  esac
}

# eglot_alive FILE -> prints t (bare symbol, matching every other t/nil
# check in this file -- NOT the string "t") if FILE's buffer has a live
# Eglot server (the LSP connection's process is still running), nil
# otherwise. Exit status follows eeval's -- 124 means Emacs itself didn't
# answer, which is a different failure than "answered nil" and must be
# handled separately.
#
# NOTE: an earlier version of this form returned the elisp string
# literals "t"/"nil" instead of the bare symbols t/nil. emacsclient prints
# strings with their quotes, so callers doing `[ "$alive" = "t" ]` were
# comparing against the literal 3 characters "t" (quote-t-quote) and it
# never matched -- eglot_alive reported "dead" on every call, alive or
# not. Bare symbols print unquoted, matching e.g. find_or_open_buffer's
# `(and (eglot-current-server) t)` below.
eglot_alive() {
  local form
  form=$(render_form '
(let ((buf (get-file-buffer "@@FILE@@")))
  (and buf
       (with-current-buffer buf
         (let ((s (and (fboundp (quote eglot-current-server)) (eglot-current-server))))
           (and s (let ((proc (jsonrpc--process s)))
                    (and proc (process-live-p proc) t)))))))
' '@@FILE@@' "$1")
  eeval "$form"
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
  local find_raw
  find_raw=$(eeval "$find_form")
  if [ $? -eq 124 ]; then
    echo "ERROR: Emacs didn't respond to a trivial buffer lookup (no reply within ${EMACSCLIENT_TIMEOUT}s) -- its main thread is wedged, not just slow. Check the target Emacs directly." >&2
    return 8
  fi
  BUFFER_FILE=$(unquote "$find_raw")

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
    local ready rc
    ready=$(eeval "$ready_form")
    rc=$?
    if [ "$rc" -eq 124 ]; then
      echo "ERROR: Emacs stopped responding while waiting for JDTLS to attach (no reply within ${EMACSCLIENT_TIMEOUT}s on a trivial check) -- not going to keep polling a wedged Emacs for the rest of the cold-start budget. Check the target Emacs directly." >&2
      return 8
    fi
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
