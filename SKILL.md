---
name: eglot-java-test
description: Run a Java test class or method, check that a file compiles, or pause a test at a breakpoint to inspect live state (e.g. read a page's real HTML to derive a Selenium locator), in this project through JDTLS/Eglot/dape (via emacsclient). Use after editing a .java file to verify it compiles, when asked to run a test or a specific test method, to check if a fix passes, to iterate on a Java test failure, or when you would otherwise have to ask the user to manually navigate to a screen and report back a locator/selector — as an alternative to shelling out to mvnw directly or asking the user to drive a manual debug session.
---

# eglot-java-test

Drives the user's already-running Emacs +
[`eglot-helpers-java`](https://github.com/koprotk/eglot-helpers-java) +
JDTLS via `emacsclient`, instead of cold-starting Maven from the shell.
Faster, and gives the same signal the user sees interactively.

## Installing

This repo IS the skill directory. Either:

- **Personal** (works across every project): symlink or clone it to
  `~/.claude/skills/eglot-java-test/`.
- **Project-scoped** (ships with one repo): copy or symlink it to
  `<project>/.claude/skills/eglot-java-test/`.

Script paths below are relative to wherever this `SKILL.md` ends up living
— resolve them against that directory, not the consuming project's root.

Three scripts, pick based on what you actually need:

| Script | Use when | Cost |
|---|---|---|
| `scripts/build-check.sh` | You just edited a `.java` file and want to know it still compiles | Cheap — incremental compile via JDTLS's own builder |
| `scripts/run-and-read.sh` | You need to actually exercise a test class/method | Heavier — spins up a JVM (or Maven) to run it |
| `scripts/debug-eval.sh` | You need live state at a specific point in a test — e.g. a page's real HTML to derive a locator, instead of asking the user to open devtools | Heaviest — starts a real debug session (browser included), pauses at a breakpoint, evaluates an expression, then tears down |

**Default to `build-check.sh` right after editing a file.** Only reach for
`run-and-read.sh` when you specifically need test *behavior*, not just
"does it parse and typecheck."

## Prerequisites

- The user's Emacs must have a running server (`(server-start)` in their
  init, or an `emacs --daemon`). If `emacsclient` can't reach it, both
  scripts fail fast (exit 2) — don't fall back to silently shelling out to
  `mvnw` instead; tell the user emacsclient isn't reachable.
- [`eglot-helpers-java`](https://github.com/koprotk/eglot-helpers-java) must
  be loaded in that Emacs — this skill drives its private `--run-test`
  function and its `build-workspace` LSP call directly.

Both scripts share the same buffer-discovery logic (`scripts/lib.sh`):
look for a `.java` buffer already open under `project-root` that JDTLS
manages; if none, open the target file and wait for `eglot-ensure` to
attach. **Cold start can take minutes** on a large Maven project — the
default timeouts (300s) reflect that; don't cut them short reflexively.

### If the Eglot connection dies or Emacs itself wedges

Every `emacsclient --eval` call goes through `lib.sh`'s `eeval`, which
enforces its own timeout (default 20s, override via `EMACSCLIENT_TIMEOUT`)
independent of whatever timeout you pass the script. This exists because
"no answer yet" and "still working" are not the same thing: if the target
Emacs's main thread gets wedged on a stuck synchronous call (a dying
JDTLS/eglot connection is the common cause), a naive polling loop reads
that identically to "not ready yet" and silently waits out its *entire*
nominal timeout before reporting anything — which is exactly what
motivated this. All three scripts now fail fast instead, with two new
exit codes that recur across them:

- **Emacs unresponsive** (main thread wedged, no reply within
  `EMACSCLIENT_TIMEOUT`s on even a trivial check) — reported the moment a
  poll times out, not at the end of the script's own budget.
- **Connection died** (Emacs itself is fine, but the Eglot/JDTLS or
  dape/debug connection's process is no longer live) — checked
  periodically during long waits (`run-and-read.sh`'s run-wait,
  `debug-eval.sh`'s breakpoint-hit wait).

Neither case is auto-recovered — killing our side of a hung `--eval`
does **not** abort the evaluation on the Emacs side (there's no cancel
signal for that), so a wedged Emacs can stay wedged for whatever you try
next too. Surface the error text to the user; the usual fix is
interactive, in that Emacs: `C-g`, `M-x eglot-reconnect`, or
`eglot-helpers-java-restart-server-clean`.

---

## `build-check.sh` — compile check

```bash
scripts/build-check.sh <project-root> <path/to/File.java> [full=0] [request-timeout=120] [cold-start-timeout=300]
```

Calls JDTLS's `java/buildWorkspace` LSP request directly (the same one
`M-x eglot-helpers-java-build-workspace` uses) — incremental by default,
pass `1` as the third argument to force a full rebuild. Prints:

```
Build status: SUCCEEDED|FAILED|CANCELLED|WITHDRAWN
Diagnostics for File.java:
<Flymake diagnostics for that file, one per line, or "(no diagnostics)">
```

The script force-enables `flymake-mode` in the buffer if it is not already
on — Eglot managing a buffer does not guarantee Flymake is active (depends
on the user's config), and without it there is nothing to read diagnostics
from. Diagnostics are scoped to the one file you passed in, since Flymake
is buffer-local; this will not surface errors *caused* in other files by
your edit.

Exit codes: `0` finished (even on `Build status: FAILED` — that is real
signal in the text, not a script failure), `1` bad args, `2` emacsclient
unreachable, `3` cold-start timeout, `4` no active Eglot server on the
buffer, `8` Emacs stopped responding before the build request returned —
see "If the Eglot connection dies or Emacs itself wedges" above.

## `run-and-read.sh` — run a test class or method

```bash
# run every test in a class
scripts/run-and-read.sh \
  <project-root> <path/to/File.java> <pkg.Class> class

# run one test method
scripts/run-and-read.sh \
  <project-root> <path/to/File.java> <pkg.Class#method> method
```

Optional 5th/6th args override the default 300s timeouts:
```bash
run-and-read.sh <project-root> <file> <fqn> <class|method> [run-timeout] [cold-start-timeout]
```

### Deriving the `fqn` argument

Read the target `.java` file yourself:
- `pkg` = the `package ...;` declaration
- `Class` = the public class name
- for a method run, append `#methodName`

Examples: `com.acme.billing.InvoiceServiceTest`,
`com.acme.billing.InvoiceServiceTest#calculatesTaxCorrectly`.

### What it does

1. Finds/opens the managed buffer (see Prerequisites above).
2. Triggers the run via `eglot-helpers-java--run-test`, the same
   non-interactive function the package's own interactive commands call.
   This resolves launch args via JDTLS's `vscode.java.test.junit.argument`
   LSP command, falling back to `mvnw -Dtest=... test` transparently if the
   test plugin is not loaded in that JDTLS instance — you do not need to
   know or care which path it took; the output tells you.
3. Finds the compilation buffer that run created (structurally, by mode +
   working directory — not by a hardcoded buffer name, since the exact
   name depends on the user's own `compilation-buffer-name-function`
   customization, and the buffer itself is `comint-mode` with
   `compilation-shell-minor-mode` layered on, not plain `compilation-mode`,
   because `--run-test` calls `compile` with COMINT enabled) and polls
   until it reaches `compile.el`'s own finish sentinel line
   (`Compilation finished`/`Compilation exited abnormally`/`Compilation
   segmentation fault`).
4. Prints the full buffer text to stdout.

### Reading the result

**Exit code is about orchestration, not test outcome.** Exit 0 means "the
run finished and here is the output" — that includes a finished run with
failing tests (JUnit/TestNG runners commonly exit non-zero on failure,
which makes `compile.el` say "exited abnormally", but the script still
exits 0 since it successfully retrieved the result). Read the printed text
itself to determine pass/fail — look for the test runner's own summary
(`Tests run: N, Failures: ...`, JUnit5 console launcher's table, or
individual `FAILED`/`PASSED` lines depending on which path (LSP vs Maven
fallback) was taken.

A real test run can take a while and may exercise shared infrastructure
(databases, staging environments, browser automation) — do not fire this
off speculatively just to "see what happens"; only run a specific test
when there is a concrete reason to (verifying a fix, reproducing a
failure the user described, etc).

Non-zero exits mean something went wrong *before* you got a result:

| Exit | Meaning |
|---|---|
| 1 | Bad arguments |
| 2 | `emacsclient` can't reach an Emacs server |
| 3 | Cold start: JDTLS never attached within the timeout |
| 4 | No compilation buffer appeared after triggering the run |
| 5 | Compilation buffer never reached a finished state within the timeout |
| 7 | Eglot's connection to JDTLS died mid-run, caught by a periodic health check (every 10s) instead of silently waiting out the full run-timeout |
| 8 | Emacs stopped responding (main thread wedged) mid-run |

In all of these, stderr has a specific one-line reason — surface it to the
user rather than guessing.

## `debug-eval.sh` — pause at a breakpoint and inspect live state

```bash
scripts/debug-eval.sh <project-root> <test-file> <fqmn> <bp-file> <bp-line> <expression> [hit-timeout=180] [cold-start-timeout=300]
```

For when you would otherwise have to ask the user to manually navigate to a
screen in the running app and report back an element locator. Instead:
starts a real dape/JDTLS debug session on `fqmn`, sets a breakpoint at
`bp-file:bp-line`, waits for it to be hit, evaluates a Java `expression` in
that paused frame's context, then resumes and tears the whole session down.

**Pick the breakpoint line yourself** by reading the test/Screen source —
put it right after the navigation call that reaches the screen you care
about, before any assertions. For the expression, `driver.getPageSource()`
(or whatever the project's WebDriver field/accessor is called — read the
test's base class to find it) gets you the actual rendered HTML, so you can
derive a locator directly from real markup instead of asking the user to
open devtools. `getCurrentUrl()`, or evaluating a specific `WebElement`
variable already in scope at that line, are also fair game — it is any
expression valid at that breakpoint, not just page source.

This is the heaviest of the three scripts: a real browser launches and a
JVM thread sits suspended until the expression resolves. **Do not fire this
off speculatively** — only when you have a concrete need for live state
that reading source cannot answer. After the evaluate result comes back,
the session is resumed and immediately torn down (`dape-continue` then
`dape-quit`) — this grabs one snapshot and cleans up eagerly, it does not
wait for or report the test's actual outcome. Use `run-and-read.sh` if you
need that.

This script does **not** implement the interactive Maven-surefire-debug
fallback that `eglot-helpers-java-debug-test-method` falls back to when the
JDTLS debug/test plugin is not loaded — if starting the session fails for
that reason, it exits cleanly with a pointer to try
`M-x eglot-helpers-java-reload-bundles` (or
`eglot-helpers-java-restart-server-clean`) interactively first, rather than
attempting to replicate that fallback headlessly.

**Starting the debug session already retries a bounded 3 attempts, ~8s
apart, before giving up (exit 4).** A timeout, or a JDTLS-side `Index 0
out of bounds for length 0` from `vscode.java.test.junit.argument`, on
the first attempt or two is expected right after a JDTLS restart or right
after a new test file was added — JDTLS is still re-indexing and briefly
resolves zero test items for anything. That's what the retry rides out.
**Do not wrap another retry loop around this script** if it still fails
— exit 4 after 3 spaced attempts means it's a real problem (wrong `fqmn`,
plugin genuinely not loaded), not a timing hiccup, and hammering the same
call faster doesn't fix indexing lag (seen in the wild: an external loop
retried the identical failing call 25+ times with no backoff and never
got anywhere — same anti-pattern as hand-rolling the compilation-finish
check `run-and-read.sh` already solves; use the script, don't reinvent
its polling).

Exit codes:

| Exit | Meaning |
|---|---|
| 1 | Bad arguments |
| 2 | `emacsclient` can't reach an Emacs server |
| 3 | Cold start: JDTLS never attached within the timeout |
| 4 | Starting the debug session failed (e.g. debug/test plugin not loaded) |
| 5 | Timed out waiting for the breakpoint to be hit |
| 6 | Timed out waiting for the evaluate result to appear |
| 7 | The dape/JDTLS debug connection died while waiting for the breakpoint (checked every poll, not just at timeout) |
| 8 | Emacs stopped responding (main thread wedged) mid-wait |
