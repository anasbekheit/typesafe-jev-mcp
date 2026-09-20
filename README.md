# typesafe-jev-mcp

An MCP server that gives agents **typed decisions instead of prose**. One tool, `evaluate`,
sends state plus typed questions to [TypeSafe](https://typesafe.ai)'s Jev model and returns
structured answers with probabilities, under a declared output schema.

Three answer types: `noul` (probability a condition holds), `choice` (one option from a map),
`score` (position on ordered levels).

## Install

```sh
curl -LsSf https://github.com/anasbekheit/typesafe-jev-mcp/releases/latest/download/typesafe-jev-mcp-installer.sh | sh
npx typesafe-jev-mcp            # any platform with Node
cargo install typesafe-jev-mcp  # from crates.io
```

Windows PowerShell:

```powershell
irm https://github.com/anasbekheit/typesafe-jev-mcp/releases/latest/download/typesafe-jev-mcp-installer.ps1 | iex
```

Prebuilt binaries for macOS (arm64, x64), Linux (arm64, x64) and Windows (x64) are on
[Releases](https://github.com/anasbekheit/typesafe-jev-mcp/releases), each with a SHA256.

## Configure

Get a key at <https://console.typesafe.ai/>, then pick one:

```sh
export TYPESAFE_API_KEY='...'                                        # simplest
export TYPESAFE_API_KEY_COMMAND='security find-generic-password -s jev-mcp -w'   # no secret on disk
```

`TYPESAFE_API_KEY_COMMAND` runs any command and reads the key from stdout — Keychain,
`op read`, `vault kv get`, `pass`. Use it to keep the key out of client config files.
It runs through `sh -c` on macOS and Linux, `cmd /C` on Windows, so use a Windows-native
command there, e.g. `powershell -Command "..."` against Credential Manager.

## Register

```sh
claude mcp add jev -s user -e 'TYPESAFE_API_KEY=${TYPESAFE_API_KEY}' -- $(which typesafe-jev-mcp)
codex mcp add jev --env "TYPESAFE_API_KEY_COMMAND=$TYPESAFE_API_KEY_COMMAND" -- $(which typesafe-jev-mcp)
agy mcp add -e "TYPESAFE_API_KEY_COMMAND=$TYPESAFE_API_KEY_COMMAND" jev $(which typesafe-jev-mcp)
```

Claude Code expands `${VAR}` at launch, so its config holds no secret. Codex, Antigravity and
opencode store `env` values literally — use `TYPESAFE_API_KEY_COMMAND` there.

opencode, in `opencode.json`:

```json
{ "mcp": { "jev": { "type": "local", "command": ["typesafe-jev-mcp"], "enabled": true,
  "environment": { "TYPESAFE_API_KEY_COMMAND": "security find-generic-password -s jev-mcp -w" } } } }
```

## Use

> Use evaluate to decide whether this ticket is urgent and who should own it:
> *Help! My payouts have been failing for 3 days.*

```json
{
  "state": "Help! My payouts have been failing for 3 days.",
  "questions": {
    "is_urgent": {"type": "noul", "instructions": "Does this convey urgency?"},
    "team": {"type": "choice", "instructions": "Which team should handle this?",
      "criteria": {"billing": "Payments, refunds", "technical": "Bugs, outages"}}
  }
}
```

```json
{"model": "jev-1.13.0",
 "answers": {"is_urgent": {"type": "noul", "noul": 0.95},
             "team": {"type": "choice", "choice": "billing", "confidence": 0.76,
                      "probabilities": {"billing": 0.84, "technical": 0.16}}},
 "usage": {"input_tokens": 420, "output_tokens": 71}}
```

## Limits

- `choice`: 1–255 options per question. `score`: 1–10 levels.
- State and questions share a 64k token ceiling; state alone is capped at 32k.
- Batch independent questions into one call — they run in parallel.
- `jev-latest` and `jev-preview` move between releases. Pin a versioned id such as
  `jev-1.13.0` once you have tuned a threshold.

Measured API behavior and design rationale: [DESIGN.md](DESIGN.md).

## License

MIT
