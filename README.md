# eglot-helpers-java-skill

An agent skill for Claude Code and GitHub Copilot CLI that drives
[`eglot-helpers-java`](https://github.com/koprotk/eglot-helpers-java) via
`emacsclient` — lets an agent check that a Java file still compiles, or run
a test class/method, through the user's already-running Emacs + Eglot +
JDTLS instead of cold-starting Maven from the shell.

See [`SKILL.md`](./SKILL.md) for usage and installation. The same skill
directory works with both agents; install it in the appropriate skills
location for your setup.

## Layout

```
SKILL.md              trigger description + usage, read by both agents
scripts/lib.sh         shared emacsclient/buffer-discovery helpers
scripts/organize-imports.sh let JDTLS add/remove/sort a file's imports
scripts/build-check.sh "does it compile" check via eglot-helpers-java-mvn-build-project-skiptests
scripts/run-and-read.sh run a test class/method and read the result
```

## License

GPL-3.0-or-later, matching `eglot-helpers-java`.
