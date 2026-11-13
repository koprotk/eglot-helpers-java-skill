---
name: eglot-java-test
description: Run a Java test class or method, check that a file compiles, in this project through JDTLS/Eglot (via emacsclient). Use after editing a .java file to verify it compiles, when asked to run a test or a specific test method, to check if a fix passes, to iterate on a Java test failure, or when you would otherwise have to ask the user to manually navigate to a screen and report back a locator/selector (add a page-source print to the test and run it) — as an alternative to shelling out to mvnw directly. Filter script output with the OUTPUT_GREP/OUTPUT_TAIL env vars instead of piping through Bash grep/sed/head/tail. Never add, remove or sort Java import lines by hand: write bare class names and run scripts/organize-imports.sh so JDTLS manages imports.
---

# eglot-java-test

> **Rules (read first):**
> 1. **Trim output with `OUTPUT_GREP` / `OUTPUT_TAIL`** on the script call,
>    not Bash `grep`/`sed`/`head`/`tail` afterwards. (General source
>    search/read/edit guidance lives in the `emacsclient` skill of
>    `emacs-skills`.)
> 2. **No polling.** Scripts block until the run finishes. Never wrap them in
>    `until grep ...; do sleep; done` on an output file.
> 3. **Never hand-edit imports.** Don't add, remove or reorder `import`
>    lines yourself — write bare class names in the code, then run
>    `organize-imports.sh` once and let JDTLS add/remove/sort them.
> 4. **Compile check = `build-check.sh`**, tests = `run-and-read.sh`.
>
> Details: "Trimming output" and "`organize-imports.sh`" below.

Drives the user's already-running Emacs +
[`eglot-helpers-java`](https://github.com/koprotk/eglot-helpers-java) +
JDTLS via `emacsclient`, instead of cold-starting Maven from the shell.
Faster, and gives the same signal the user sees interactively.

## Installing for Claude Code or GitHub Copilot CLI

This repo is the skill directory. Keep `SKILL.md` and `scripts/` together
when installing; script paths below are relative to this directory, not the
consuming project's root.

- **Claude Code, personal:** symlink or clone it to
  `~/.claude/skills/eglot-java-test/`.
- **Copilot CLI, personal:** symlink or clone it to
  `~/.copilot/skills/eglot-java-test/`.
- **Project-scoped:** place or symlink the skill directory at
  `<project>/.claude/skills/eglot-java-test/` for Claude Code, or
  `<project>/.github/skills/eglot-java-test/` for Copilot CLI. Copilot CLI
  also discovers skills in `.claude/skills`, so that location can be shared
  when both agents use the same project.

If Copilot CLI is already running after installation, run `/skills reload`;
use `/skills info eglot-java-test` to confirm discovery. Invoke it explicitly
with `/eglot-java-test`, or let Copilot select it from the task.

Three scripts, pick based on what you actually need:

| Script | Use when | Cost |
|---|---|---|
| `scripts/organize-imports.sh` | You added/removed a class usage and imports need to match | Cheap — one JDTLS `source.organizeImports` code action; saves the file |
| `scripts/build-check.sh` | You just edited a `.java` file and want to know it still compiles | Runs `eglot-helpers-java-mvn-build-project-skiptests` (`mvnw clean package -DskipTests -U`); no JDTLS needed |
| `scripts/run-and-read.sh` | You need to actually exercise a test class/method | Heavier — spins up a JVM (or Maven) to run it |

**Edit code → `organize-imports.sh` → `build-check.sh`.** Run
`organize-imports.sh` after edits that add or drop class references, before
`build-check.sh`.

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
  function and its `mvn-build-project-skiptests` command directly.

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
motivated this. Both scripts now fail fast instead, with two new
exit codes that recur across them:

- **Emacs unresponsive** (main thread wedged, no reply within
  `EMACSCLIENT_TIMEOUT`s on even a trivial check) — reported the moment a
  poll times out, not at the end of the script's own budget.
- **Connection died** (Emacs itself is fine, but the Eglot/JDTLS
  connection's process is no longer live) — checked periodically during
  long waits (`run-and-read.sh`'s run-wait).

Neither case is auto-recovered — killing our side of a hung `--eval`
does **not** abort the evaluation on the Emacs side (there's no cancel
signal for that), so a wedged Emacs can stay wedged for whatever you try
next too. Surface the error text to the user; the usual fix is
interactive, in that Emacs: `C-g`, `M-x eglot-reconnect`, or
`eglot-helpers-java-restart-server-clean`.

---

## Trimming output (`OUTPUT_GREP` / `OUTPUT_TAIL`)

Both scripts print the whole compilation/comint buffer by default. To trim it
**inside Emacs** instead of piping through `sed`/`grep`/`tail` afterwards, set
env vars on the call (applied to a temp copy; the real buffer is untouched):

- `OUTPUT_GREP='<emacs-regexp>'` — keep only matching lines (`keep-lines`,
  case-sensitive). Emacs regexp syntax: alternation is `\|`, not `|`.
  Example: `OUTPUT_GREP='FAILED\|ERROR\|Tests run:'`.
- `OUTPUT_TAIL=<n>` — keep only the last n lines (applied after
  `OUTPUT_GREP`).

```bash
OUTPUT_GREP='FAILED\|ERROR' OUTPUT_TAIL=40 scripts/run-and-read.sh ...
```

Prefer these over shell post-processing. Start with the filtered view; fall
back to the full buffer only if the filter hides what you need.

**Do not poll the script's output file.** The scripts already block until the
Maven/comint run finishes and print only afterwards, so a wrapper like
`until grep -q "Comint finished" out; do sleep 5; done; grep ... out | tail`
is redundant. Run the script once (in the foreground, or in the background
and wait for its completion notification), with the filter on the call:

```bash
OUTPUT_GREP='BUILD SUCCESS\|BUILD FAILURE\|Tests run:\|Test result was\|PAGE_SOURCE_START' \
OUTPUT_TAIL=40 \
scripts/run-and-read.sh <project-root> <File.java> <pkg.Class> class
```

## `organize-imports.sh` — let JDTLS manage imports

```bash
scripts/organize-imports.sh <project-root> <path/to/File.java> [cold-start-timeout=300]
```

Runs Eglot's `eglot-code-action-organize-imports` (JDTLS's
`source.organizeImports` action) on the file: removes unused imports, adds
missing ones, sorts them per the project's import order, and saves the file.
Prints `Imports: CHANGED|UNCHANGED` and the resulting `import` block.

**Workflow instead of editing imports yourself:**
1. Write the code using bare class names (`List`, `WebElement`, ...). Do not
   hand-write the matching `import` lines, and do not delete or reorder
   existing ones when you remove usages.
2. Run `organize-imports.sh` once.
3. Run `build-check.sh`. If it reports a "cannot be resolved" error for a
   name that was **ambiguous** (same simple name in several packages, e.g.
   `List`), add just that one import by hand — JDTLS cannot pick between
   candidates without asking.

**Import order and grouping come from the user's Emacs config, not this
skill.** JDTLS sorts using `java.completion.importOrder` (and the formatter's
`blank_lines_between_import_groups`). A project's order must be set as a
*dir-local* `eglot-workspace-configuration` (e.g. via
`dir-locals-set-class-variables` in `config.el`): Eglot answers JDTLS's
`workspace/configuration` requests from a temporary buffer that sees only the
global value and dir-locals, so a `setq-local` in a mode hook never reaches
JDTLS. If the script rewrites imports into an unexpected order or adds blank
lines between groups, that config is the place to look — don't reorder by hand.

If the file's Emacs buffer has unsaved edits the script refuses to touch it
(exit 6) rather than overwrite them. Edits made on disk (e.g. via the Edit
tool) are picked up by reverting the buffer first.

Exit codes: `0` finished, `1` bad args, `2` emacsclient unreachable, `3`
cold-start timeout, `6` buffer has unsaved edits, `7` buffer not managed by
Eglot or the code action failed, `8` Emacs stopped responding.

## `build-check.sh` — compile check

```bash
scripts/build-check.sh <project-root> <path/to/File.java> [build-timeout=900]
```

Runs only `eglot-helpers-java-mvn-build-project-skiptests` (`mvnw clean
package -DskipTests -U`) with the target file's buffer as context, waits for
the Maven compilation buffer to finish, and prints its full output. No JDTLS
attach, no `java/buildWorkspace`, no Flymake diagnostics — read pass/fail
from the Maven output.

Caveat: `mvnw clean` deletes `target/classes` outside Eclipse's resource API
and can corrupt the JDTLS workspace cache (`ObjectNotFoundException` at next
startup) for any buffer in the same project that has a live JDTLS session.

Exit codes: `0` finished (even if the Maven build failed — that is real
signal in the text, not a script failure), `1` bad args, `2` emacsclient
unreachable, `4` no compilation buffer appeared within 10s of triggering the
build, `5` build-timeout exceeded, `8` Emacs stopped responding.

## `run-and-read.sh` — run a test class or method

```bash
# run every test in a class
scripts/run-and-read.sh \
  <project-root> <path/to/File.java> <pkg.Class> class

# run one test method
scripts/run-and-read.sh \
  <project-root> <path/to/File.java> <pkg.Class#method> method
```

Optional 5th/6th args override the defaults (run-timeout 900s,
cold-start-timeout 300s — run-timeout was bumped from 300s, then 700s,
after real class-level runs were seen taking up to ~8 min):
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
2. Opens the target test class in a new Emacs window (reused if already
   visible) so the user sees what is about to run. Non-fatal if it fails.
3. Triggers the run via `eglot-helpers-java--run-test`, the same
   non-interactive function the package's own interactive commands call.
   This resolves launch args via JDTLS's `vscode.java.test.junit.argument`
   LSP command, falling back to `mvnw -Dtest=... test` transparently if the
   test plugin is not loaded in that JDTLS instance — you do not need to
   know or care which path it took; the output tells you.
4. Finds the compilation buffer that run created (structurally, by mode +
   working directory — not by a hardcoded buffer name, since the exact
   name depends on the user's own `compilation-buffer-name-function`
   customization, and the buffer itself is `comint-mode` with
   `compilation-shell-minor-mode` layered on, not plain `compilation-mode`,
   because `--run-test` calls `compile` with COMINT enabled) and polls
   until it reaches `compile.el`'s own finish sentinel line
   (`Compilation finished`/`Compilation exited abnormally`/`Compilation
   segmentation fault`).
5. Prints the full buffer text to stdout.

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

## Reading live page HTML (to derive a locator) — no debugger

Do **not** pause at a breakpoint to inspect state; a debug session is
fragile and unnecessary. To get a page's real HTML, instead:

1. Edit the test: right after the navigation call that reaches the screen
   you care about (before assertions), add a line that dumps the page
   source, e.g. `System.out.println(getPage().getPageSource());` — read the
   test's base class to find the project's actual WebDriver accessor
   (`getPage`, `driver`, ...). `getCurrentUrl()` or a specific `WebElement`
   works the same way.
2. Run it with `run-and-read.sh` (method run, usually).
3. The script prints the full compilation (comint) buffer, so the dumped
   DOM is in that output. Rescue it from there and derive the locator from
   the real markup.
4. Remove the temporary print line once the locator is done.

Don't ask the user to open devtools and report back — this gets the same
info with one test run.
