# Skills: coding agents that add Soliton monitoring by themselves

Install one of these and your coding agent adds Soliton monitoring whenever
it writes, edits or submits a computation (a training script, a simulation,
a solver run, a job script for Sherlock, Modal or anywhere else), so you
can follow it in the app. Neither is active until you install it.

| Folder | For | Follows |
|---|---|---|
| [claude-code/soliton](claude-code/soliton/SKILL.md) | Claude Code | [Claude Code skills](https://docs.claude.com/en/docs/claude-code/skills): one `SKILL.md` |
| [codex/soliton](codex/soliton/SKILL.md) | OpenAI Codex (CLI, IDE extension, app) | [Codex skills](https://developers.openai.com/codex/skills): a short `SKILL.md`, details in `references/`, app metadata in `agents/openai.yaml` |

Both say the same thing and carry the same wrapper,
`scripts/monitor_solver.py`, which reports programs that aren't Python
(compiled solvers, MPI jobs) without changing them.

## Installing

From this repository, on the computer where you run the agent. A symbolic
link keeps the skill up to date when you `git pull`; copy the folder
instead (`cp -R`) for a version that doesn't change.

**Claude Code** (every project of yours):

```bash
mkdir -p ~/.claude/skills && ln -s "$PWD/skills/claude-code/soliton" ~/.claude/skills/soliton
```

**Codex** (every project of yours):

```bash
mkdir -p ~/.agents/skills && ln -s "$PWD/skills/codex/soliton" ~/.agents/skills/soliton
```

(`~/.agents/skills` is where current Codex versions look. If yours keeps
its skills in `~/.codex/skills`, as older versions did, link it there.)

For one project only, put the link (or a copy) in that project instead:
`.claude/skills/soliton` for Claude Code, `.agents/skills/soliton` for
Codex. Codex can also install it with its built-in installer: ask
`$skill-installer` to install `skills/codex/soliton` from this repository.

Restart the agent if the skill doesn't show up (Claude Code: in its list of
skills; Codex: `/skills`). Codex uses it by itself when a task matches; to
call it explicitly, type `$soliton`.

Then give the agent what it needs at run time, never in code: the server's
address and token in `SOLITON_SERVER` and `SOLITON_TOKEN` (in your shell,
or on Sherlock in `~/.soliton_env`, which `soliton setup` writes: the agent
runs it in your terminal and you paste the token at its hidden prompt).
For agents and job scripts, the job
token (the app's Settings → Advanced security) is the safer choice: it can
add runs but not read or delete them, and the skills know to expect that.
See [docs/getting-started.md](../docs/getting-started.md).

## Changing them

Keep the two in step: a change to one skill's instructions belongs in the
other too (the Codex skill splits them into `SKILL.md` and `references/`).
The wrapper lives in both `scripts/` folders; edit the Claude Code copy and
copy it over:

```bash
cp skills/claude-code/soliton/scripts/monitor_solver.py skills/codex/soliton/scripts/
```

A test (`logger/tests/test_monitor_solver.py`) fails if the copies differ.
