# ARC — AI Requirements Checker

> Run your project requirements through AI agents in parallel and get a clear pass/fail report in seconds.

ARC takes a plain-text checklist of requirements, fans them out to a code agent CLI (Claude, OpenCode, or Antigravity), and watches each one investigate your codebase in a live TUI. When it finishes, you get a concise summary of what passes and what doesn't — with a short reason for every result.

## Why ARC?

- **Parallel by default** — every requirement is checked concurrently, so a 20-item checklist finishes in the time of one.
- **Live TUI** — watch each agent think, call tools, and stream output in real time. No more staring at a black box.
- **Pluggable agents** — works with Claude CLI, OpenCode, or Antigravity. Auto-detects what's installed.
- **Plain-text spec** — write requirements in a simple file, with optional grouping for context.
- **CI-friendly** — clean exit codes (`0` pass, `1` fail, `2` usage error) make it drop-in for any pipeline.

## Installation

The one-line installer works on Linux, macOS, and any Unix-like system. No dependencies required.

```bash
curl -fsSL https://raw.githubusercontent.com/geangontijo/arc/main/install.sh | bash
```

This installs `arc` to `~/.local/bin`. If that directory isn't on your `PATH`, add it:

```bash
echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.bashrc   # or ~/.zshrc
```

Other install options (run `./install.sh --help` for the full list):

```bash
./install.sh --system       # install to /usr/local/bin (requires sudo)
./install.sh --prefix /opt/bin   # custom location
./install.sh --uninstall    # remove the installed binary
```

## Getting Started

### 1. Write your requirements

Create a file called `requirements.txt` (or anything you like). One requirement per line, optional `"- "` bullets for grouping:

```text
The web checkout flow
- validates credit card numbers with the Luhn algorithm?
- displays a confirmation page after a successful payment?
- sends a receipt email within 30 seconds?

Repository level
- has a README with setup instructions?
- runs `npm test` cleanly?
- uses semantic versioning for releases?
```

Lines starting with `#` and blank lines are ignored. Parent lines (no `-` prefix) provide context for the bullets that follow — they get merged into each child requirement when sent to the agent.

### 2. Run ARC

```bash
arc requirements.txt
```

Or pipe requirements in directly:

```bash
echo "uses TypeScript strict mode?" | arc -
```

You'll see a live TUI like this:

```text
Requirements Check
============================================================
Project: /home/user/my-project
Agent: opencode (opencode)
Requirements: 5 (parallel)
============================================================
  ████████████████████████████░░░░░░░░░░ 3/5 completed

  The web checkout flow
    ⠋ #1 validates credit card numbers with the Luhn algorithm? running…
         ╎ [thinking] I need to find the payment validation logic…
         ╎ [tool] grep(pattern="luhn|Luhn",include="*.ts")
    ✓ #2 displays a confirmation page after a successful payment? (4s)
         reason: Confirmation page rendered by CheckoutSuccess.tsx after 200 from /api/pay
    ✗ #3 sends a receipt email within 30 seconds? (3s)
         reason: No email service configured; PaymentService only logs to console
    ○ #4 has a README with setup instructions?
    ○ #5 runs `npm test` cleanly?
```

### 3. Force a specific agent

ARC auto-detects an installed agent, but you can pin one:

```bash
arc requirements.txt --agent claude
arc requirements.txt --agent opencode
arc requirements.txt --agent agy
arc requirements.txt --agent antigravity
```

## Command-line reference

```text
arc <requirements-file | -> [--project-dir <path>] [--agent <name>]
```

| Flag | Description |
| --- | --- |
| `<file>` | Path to a requirements file. Use `-` to read from stdin. |
| `--project-dir <path>` | Directory the agent will analyze. Defaults to the git root of the current directory. |
| `--agent <name>` | Force a specific agent: `claude`, `opencode`, `agy`, or `antigravity`. |

Environment variables:

- `CLAUDE_CMD` — overrides the auto-detected agent binary.
- `OUTPUT_WINDOW` — number of streaming lines shown per running task in the TUI (default `10`).

## Exit codes

| Code | Meaning |
| --- | --- |
| `0` | All requirements passed. |
| `1` | One or more requirements failed. |
| `2` | Usage error (bad flags, missing input, etc.). |

## Supported agents

ARC works with any of these CLI tools installed and authenticated:

- [Claude CLI](https://docs.claude.com/claude-code) (`claude`)
- [OpenCode](https://opencode.ai) (`opencode`)
- [Antigravity](https://github.com/anomalyco/antigravity) (`agy` / `antigravity`)

ARC picks the first one it finds on `PATH`. If none is installed, install one and try again.

## License

MIT
