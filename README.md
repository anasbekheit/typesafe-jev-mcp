# typesafe-jev-mcp

[![crates.io](https://img.shields.io/crates/v/typesafe-jev-mcp.svg)](https://crates.io/crates/typesafe-jev-mcp)
[![npm](https://img.shields.io/npm/v/typesafe-jev-mcp.svg)](https://www.npmjs.com/package/typesafe-jev-mcp)
[![ci](https://github.com/anasbekheit/typesafe-jev-mcp/actions/workflows/ci.yml/badge.svg)](https://github.com/anasbekheit/typesafe-jev-mcp/actions/workflows/ci.yml)
[![license](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

MCP server for [TypeSafe](https://typesafe.ai) Jev. One tool, `evaluate`: state + typed questions in, `noul` / `choice` / `score` with probabilities out. Not affiliated with TypeSafe.

## Install

macOS / Linux:

```sh
curl -fsSL https://raw.githubusercontent.com/anasbekheit/typesafe-jev-mcp/main/scripts/install.sh | sh
```

Windows:

```powershell
powershell -ExecutionPolicy Bypass -c "irm https://raw.githubusercontent.com/anasbekheit/typesafe-jev-mcp/main/scripts/install.ps1 | iex"
```

Needs Claude Code, Codex, OpenCode, Antigravity, or Cursor. Opens [console.typesafe.ai](https://console.typesafe.ai/) or prints the URL; paste a key. No TTY: `TYPESAFE_API_KEY='…'` and re-run. Restart the agent.

Binary only: [releases](https://github.com/anasbekheit/typesafe-jev-mcp/releases), `npx typesafe-jev-mcp`, `cargo install typesafe-jev-mcp`.

## evaluate

Live docs: [docs.typesafe.ai/llms.txt](https://docs.typesafe.ai/llms.txt). Pin a versioned model (`jev-1.13.0`) after you tune a threshold.

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
                      "probabilities": {"billing": 0.84, "technical": 0.16}}}}
```

## License

MIT
