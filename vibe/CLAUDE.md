# AUTONOMOUS MODE

- DO NOT ASK QUESTIONS
- DO NOT ASK FOR CONFIRMATION
- APPLY CHANGES DIRECTLY
- USE TOOLS IMMEDIATELY
- FOLLOW vibe/AI_MODE.txt STRICTLY

## IMPORTANT: Isolation Rules

This `vibe/` directory contains the development tooling (AI loop scripts, build state, TODO backlog).
The actual CLI tool code lives at the **repo root**: `lib/`, `agents/`, `run.ps1`, `memory/`, `tests/`.

### What you CAN modify
- CLI tool code: `lib/*.ps1`, `agents/*.system.txt`, `run.ps1`, `scripts/`, `tests/`
- Vibe backlog only: `vibe/TODO.md` (to mark items [x] or add new items)

### What you must NOT modify
- `vibe/ai-autonomous-loop-macos-copilot.sh` — the loop script itself
- `vibe/.ai-metrics/` — loop state files
- `vibe/AI_MODE.txt` — managed by the loop script
- `memory/` (repo root) — the CLI tool's own memory system

## Project: Forge CLI

AI-powered CLI for automated test generation and code fixes using Azure OpenAI agents.

### Architecture

- **run.ps1**: Main entry point - orchestrates the build/test/fix loop
- **agents/**: System prompts for builder, reviewer, and judge roles
- **lib/**: PowerShell modules for Azure OpenAI, token budgeting, file operations
- **tests/**: Pester test files
- **memory/**: CLI tool's runtime memory (repo-map, code-intel, heuristics, git-state, run-state)

### Quality Rules

- Keep PowerShell scripts syntax-valid (`pwsh -c "& { . ./run.ps1 }"` should parse)
- Maintain token/cost budget enforcement in TokenBudget.ps1
- Preserve tool permission boundaries per agent role
- Test changes with `pwsh -Command "Import-Module ./lib/*.ps1"`

### File Types

- `.ps1` - PowerShell scripts
- `.system.txt` - Agent system prompts

### Environment Variables Required

```
AZURE_OPENAI_ENDPOINT
AZURE_OPENAI_API_KEY
AZURE_OPENAI_API_VERSION
BUILDER_DEPLOYMENT
JUDGE_DEPLOYMENT
```

vibe/TODO.md is the source of truth for the backlog.
