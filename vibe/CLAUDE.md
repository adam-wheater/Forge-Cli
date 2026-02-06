# AUTONOMOUS MODE

- DO NOT ASK QUESTIONS
- DO NOT ASK FOR CONFIRMATION
- APPLY CHANGES DIRECTLY
- USE TOOLS IMMEDIATELY
- FOLLOW AI_MODE.txt STRICTLY

## Project: Forge CLI

AI-powered CLI for automated test generation and code fixes using Azure OpenAI agents.

### Architecture

- **run.ps1**: Main entry point - orchestrates the build/test/fix loop
- **agents/**: System prompts for builder, reviewer, and judge roles
- **lib/**: PowerShell modules for Azure OpenAI, token budgeting, file operations

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

TODO.md is the source of truth.
