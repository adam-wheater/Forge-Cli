# Forge CLI

AI-powered CLI for automated test generation and code fixes using Azure OpenAI agents.

## CRITICAL: Off-limits folders

**NEVER read, modify, or create files in the `vibe/` folder.** The `vibe/` directory contains the development tooling that drives this project — it is NOT part of the Forge CLI codebase. Ignore it completely.

## Project scope

Only work on files in these directories:
- `lib/` — PowerShell modules (AzureAgent, Orchestrator, TokenBudget, RepoMemory, etc.)
- `agents/` — System prompts for builder, reviewer, and judge roles
- `scripts/` — Shell test and utility scripts
- `tests/` — Test files
- Root files: `run.ps1`, `TODO.md`, etc.

## Architecture

- **run.ps1**: Main entry point — orchestrates the build/test/fix loop
- **agents/**: System prompts for builder, reviewer, and judge roles
- **lib/**: PowerShell modules for Azure OpenAI, token budgeting, file operations

## Quality Rules

- Keep PowerShell scripts syntax-valid (`pwsh -c "& { . ./run.ps1 }"` should parse)
- Maintain token/cost budget enforcement in TokenBudget.ps1
- Preserve tool permission boundaries per agent role

## File Types

- `.ps1` — PowerShell scripts
- `.system.txt` — Agent system prompts

## TODO.md is the source of truth for work items.
