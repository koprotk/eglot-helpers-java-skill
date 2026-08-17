---
name: eglot-java-test
description: Run a Java test class or method, or just check that a file compiles, in this project through JDTLS/Eglot (via emacsclient), and read the result. Use after editing a .java file to verify it compiles, when asked to run a test or a specific test method, to check if a fix passes, or to iterate on a Java test failure — as an alternative to shelling out to mvnw directly.
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

Two scripts, pick based on what you actually need:

| Script | Use when | Cost |
|---|---|---|
| `scripts/build-check.sh` | You just edited a `.java` file and want to know it still compiles | Cheap — incremental compile via JDTLS's own builder |
| `scripts/run-and-read.sh` | You need to actually exercise a test class/method | Heavier — spins up a JVM (or Maven) to run it |

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
buffer.

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

In all of these, stderr has a specific one-line reason — surface it to the
user rather than guessing.
