# eglot-helpers-java-skill

A Claude Code skill that drives
[`eglot-helpers-java`](https://github.com/koprotk/eglot-helpers-java) via
`emacsclient` — lets an agent check that a Java file still compiles, or run
a test class/method, through the user's already-running Emacs + Eglot +
JDTLS instead of cold-starting Maven from the shell.

See [`SKILL.md`](./SKILL.md) for what it does and how to install it
(personal `~/.claude/skills/eglot-java-test/` or project-scoped
`.claude/skills/eglot-java-test/`).

## Layout

```
SKILL.md              trigger description + usage, read by Claude Code
scripts/lib.sh         shared emacsclient/buffer-discovery helpers
scripts/build-check.sh cheap "does it compile" check via java/buildWorkspace
scripts/run-and-read.sh run a test class/method and read the result
```

## License

GPL-3.0-or-later, matching `eglot-helpers-java`.
