# TODO

## C stream: Bug fixes
- [x] **C106 — Add error handling for missing or failed git log/blame calls in RepoMemory.ps1** — lib/RepoMemory.ps1 L162, L393, L405
- [x] **C107 — Add error handling for Write-MemoryFile failures in RepoMemory.ps1** — lib/RepoMemory.ps1 L170, L380
- [x] **C108 — Add error handling for file not found in Get-BlameForFile in RepoMemory.ps1** — lib/RepoMemory.ps1 L395, L405
- [x] **C92 — Add logging to all empty catch blocks in RepoMemory.ps1** — lib/RepoMemory.ps1 L166, L374, L407
- [x] **C93 — Add error handling for missing file in RepoMemory.ps1** — lib/RepoMemory.ps1 L166
- [x] **C94 — Add logging to empty catch block in RepoMemory.ps1** — lib/RepoMemory.ps1 L374
- [x] **C95 — Add logging to empty catch block in RepoMemory.ps1** — lib/RepoMemory.ps1 L407
- [x] **C101 — Add warning log to all catch blocks in RepoMemory.ps1** — lib/RepoMemory.ps1 L166, L374, L407, L411
- [x] **C59 — Ensure all error budget checks in TokenBudget.ps1 throw with clear messages** — lib/TokenBudget.ps1 L30
- [x] **C60 — Add forbidden tool error handling in Orchestrator.ps1** — lib/Orchestrator.ps1 L34
- [x] **C79 — Replace hardcoded 'api-key' header with secure Authorization Bearer token in AzureAgent.ps1** — lib/AzureAgent.ps1 L24
- [x] **C80 — Add null check for API response before accessing .choices[0] in AzureAgent.ps1** — lib/AzureAgent.ps1 L35
- [x] **C81 — Add error handling for Invoke-RestMethod failure in AzureAgent.ps1** — lib/AzureAgent.ps1 L27
- [x] **C82 — Fix infinite loop: change 'continue' to 'break' on budget/tool limits in Orchestrator.ps1** — lib/Orchestrator.ps1 L39
- [x] **C83 — Add JSON parsing validation in Orchestrator.ps1 before accessing parsed fields** — lib/Orchestrator.ps1 L35
- [x] **C84 — Add git clone error handling in run.ps1** — run.ps1 L14
- [x] **C85 — Add git checkout error handling in run.ps1** — run.ps1 L16
- [x] **C86 — Add git apply error handling in run.ps1** — run.ps1 L49
- [x] **C87 — Add git commit error handling in run.ps1** — run.ps1 L65
- [x] **C88 — Add path sanitization to prevent directory traversal in DebugLogger.ps1** — lib/DebugLogger.ps1 L17
- [x] **C89 — Add catch block logging for all try/catch in RepoMemory.ps1** — lib/RepoMemory.ps1 L100
- [x] **C103 — Add error handling for git log and blame calls in RepoMemory.ps1** — lib/RepoMemory.ps1 L162, L393, L405
- [x] **C104 — Add error handling for Write-MemoryFile in RepoMemory.ps1** — lib/RepoMemory.ps1 L170, L380
- [x] **C105 — Add error handling for file not found in Get-BlameForFile in RepoMemory.ps1** — lib/RepoMemory.ps1 L395, L405

## D stream: New features
- [x] **D10 — Add retry mechanism with exponential backoff for Azure OpenAI API calls** — lib/AzureAgent.ps1
- [x] **D11 — Add configurable timeout for agent execution in Orchestrator.ps1** — lib/Orchestrator.ps1 (MAX_AGENT_ITERATIONS=20)
- [x] **D12 — Add [Parameter(Mandatory)] validation attributes to all lib/ functions** — lib/*.ps1
- [x] **D13 — Add startup validation for required environment variables (AZURE_OPENAI_ENDPOINT, API_KEY, API_VERSION)** — run.ps1
- [x] **D14 — Add structured error response type for agent failures** — lib/Orchestrator.ps1

## C stream: Bug fixes (new)
- [x] **C109 — Wire up reviewer agent in the main loop** — run.ps1 L94
- [x] **C110 — Add git reset between loop iterations** — run.ps1 L49
- [x] **C111 — Validate judge output is a valid unified diff before applying** — run.ps1 L102
- [x] **C112 — Move Enforce-Budgets to run every iteration, not just on failure** — run.ps1 L107, L117, L138, L179, L187
- [x] **C113 — Default RepoName from RepoUrl when not provided** — run.ps1 L11
- [x] **C114 — Clean up ai.patch file between iterations** — run.ps1 L55

## D stream: New features (new)
- [x] **D15 — Support PowerShell project build/test in run.ps1** — run.ps1 L125
- [x] **D16 — Use Get-SuggestedFix to inform builder hypotheses** — run.ps1 L64
- [x] **D17 — Add PowerShell file scoring in Score-File** — lib/RepoTools.ps1 L9

## E stream: Test coverage
- [x] **E27 — Add/verify Pester tests for TokenBudget.ps1 error budget enforcement** — lib/TokenBudget.ps1 L30
- [x] **E28 — Add/verify Pester tests for forbidden tool error in Orchestrator.ps1** — lib/Orchestrator.ps1 L34
- [x] **E30 — Add Pester tests for AzureAgent.ps1 error handling (HTTP failures, null responses)** — lib/AzureAgent.ps1
- [x] **E31 — Add Pester tests for Orchestrator.ps1 JSON parsing robustness** — lib/Orchestrator.ps1
- [x] **E32 — Add Pester tests for infinite loop prevention in Orchestrator.ps1** — lib/Orchestrator.ps1
- [x] **E33 — Add Pester tests for parameter validation across all lib modules** — lib/*.ps1

---

# V2 ROADMAP — Make Forge the best AI CLI tool

## F stream: Redis-backed memory & persistence

> Replace ephemeral JSON files with Azure Redis Cache for cross-run, cross-machine, cross-project persistent memory.

- [x] **F01 — Create lib/RedisCache.ps1 module** — Wrapper for Azure Redis (StackExchange.Redis or REST API). Connect via `REDIS_CONNECTION_STRING` env var. Functions: `Set-CacheValue`, `Get-CacheValue`, `Remove-CacheValue`, `Search-CacheKeys` with TTL support.
- [x] **F02 — Migrate RepoMemory storage backend to Redis** — Replace `Read-MemoryFile`/`Write-MemoryFile` (JSON on disk) with Redis hash sets keyed by `forge:{repoName}:{memoryType}`. Keep local JSON as fallback when Redis unavailable.
- [x] **F03 — Cross-project knowledge sharing via Redis** — Store successful fix patterns in `forge:global:fixPatterns` so fixes discovered in one repo benefit all repos. Score by success rate and recency.
- [x] **F04 — Session management in Redis** — Store run sessions as `forge:session:{id}` with TTL. Enable resume from crash: `run.ps1 -ResumeSession <id>`. Track iteration state, patches tried, agent context.
- [x] **F05 — Repo fingerprinting and similarity** — Hash repo structure (frameworks, test runners, file patterns) and store in Redis. When Forge encounters a new repo, look up similar repos and pre-load relevant fix patterns and heuristics.
- [x] **F06 — Agent conversation memory in Redis** — Store multi-turn agent conversations per session in Redis lists. Enable agents to reference prior conversation turns across iterations (not just the current one).
- [x] **F07 — Configurable memory backend** — `forge.config.json` with `memoryBackend: "redis" | "local"` so users can choose. Default to local, upgrade to Redis when connection string provided.

## G stream: Semantic search & RAG pipeline

> Replace regex file search with embedding-based semantic search using Azure AI Search or Redis Vector Search. Optimised for C#/.NET codebases.

- [x] **G01 — Create lib/Embeddings.ps1 module** — Call Azure OpenAI Embeddings API (`text-embedding-3-small`). Functions: `Get-Embedding -Text $text`, `Get-FileEmbedding -Path $file` (chunk by class/method). Store vectors in Redis with `forge:{repo}:embeddings:{filePath}:{chunkId}`.
- [x] **G02 — C#-aware code chunking** — Parse `.cs` files into semantic chunks: class declarations, method bodies, constructor+DI setup, using blocks, attribute blocks. Each chunk gets its own embedding + metadata (file, namespace, class, method, startLine, endLine, visibility). Use Roslyn via `dotnet-script` or a small C# helper for accurate parsing.
- [x] **G03 — Semantic search tool for agents** — New tool `semantic_search` in Orchestrator.ps1: agent provides natural language query ("find the service that handles user authentication"), returns top-K chunks by cosine similarity with file path, line range, and snippet. Add to builder's tool permissions.
- [x] **G04 — Hybrid search: regex + semantic** — `Search-Files` returns union of regex matches (existing) and semantic matches (new). Rank by combined score: `0.4 * regexScore + 0.6 * semanticScore`. Dedup by file path.
- [x] **G05 — Context-aware RAG for agent prompts** — Before each builder iteration, auto-retrieve top-10 most relevant code chunks based on the test failure message + stack trace. Inject as `RELEVANT_CODE:` context section. Include the interface definition, implementation, and existing tests for each matched class.
- [x] **G06 — Incremental embedding updates** — On `git diff`, re-embed only changed files. Store last-embedded commit SHA per file in Redis. Skip files unchanged since last embedding.
- [x] **G07 — Test-to-implementation semantic mapping** — Embed both test classes and implementation classes. Build semantic similarity matrix: `UserServiceTests` → `UserService.cs` + `IUserService.cs` (by embedding proximity, not just naming convention). Also map by DI: if test mocks `IUserRepository`, link to `UserRepository.cs`. Store in `code-intel.json`.
- [x] **G08 — Solution-aware indexing** — Parse `.sln` and `.csproj` files to understand project references, NuGet dependencies, and target frameworks. Only embed projects relevant to test projects (follow `<ProjectReference>` chains). Skip third-party generated code.

## H stream: Agent intelligence & tools

> Give agents more powerful tools, richer prompts, and feedback loops. C#/.NET-first design.

- [x] **H01 — Add `write_file` tool for builder** — Let builder write/create files directly instead of only returning patches. Required for new test file creation. Permission: builder only. Validate path is within repo. On first pass, restrict to `*Tests*` directories and `*.cs` files only.
- [x] **H02 — Add `run_tests` tool for builder** — Let builder trigger `dotnet test` mid-iteration and see results. Returns pass/fail + structured failure output (test name, message, stack trace). Limit: 2 invocations per agent run. Enables test-driven iteration within a single agent session.
- [x] **H03 — Add `read_test_output` tool** — Parse `dotnet test` TRX output into structured JSON: `{ passed: [...], failed: [{ name, message, stackTrace, file, line }] }`. Replaces flat text TEST_FAILURES section with parseable data agents can reason about precisely.
- [x] **H04 — Add `get_coverage` tool for builder** — Run `dotnet test --collect:"XPlat Code Coverage"` with Coverlet, parse Cobertura XML output. Return uncovered lines per class/method. Builder can see exactly which branches lack tests. Show: `UserService.CreateAsync: 45% covered, lines 23-31 uncovered (null check branch)`.
- [x] **H05 — Add `explain_error` tool** — Takes a C# stack trace or build error, returns structured explanation: root cause hypothesis, likely file, likely fix category (NullReferenceException → missing mock setup, InvalidOperationException → wrong service registration, CS0246 → missing using/reference).
- [x] **H06 — Add JSON tool schema to tools.system.txt** — Document exact JSON format for every tool with examples. Include: `search_files`, `open_file`, `show_diff`, `semantic_search`, `write_file`, `run_tests`, `get_coverage`, `get_symbols`, `get_interface`. Document error responses (`FILE_NOT_FOUND`, `BUILD_FAILED`, etc.) and all context section formats.
- [x] **H07 — Add few-shot examples to builder prompt** — Show 2-3 complete C# examples: (1) search for test → open test + implementation → fix Moq setup → patch. (2) search for untested service → open service + interface → create new xUnit test class with DI mocks → write_file. (3) interpret stack trace → find null ref source → add guard + test.
- [x] **H08 — Implement judge→builder feedback loop** — If judge rejects all patches, return structured feedback: `{"verdict":"reject","reason":"patches don't address NullReferenceException in UserService.cs line 42","hint":"check Moq setup for IUserRepository.GetAsync"}`. Builders get one retry with this feedback injected as `JUDGE_FEEDBACK:` context.
- [x] **H09 — Implement reviewer refinement loop** — If reviewer identifies issues but patch is salvageable, return `{"verdict":"refine","issues":["missing Verify() call for repository mock","FluentAssertions Should().Be() used but project uses Assert.Equal()"]}` to builder for a targeted fix pass (max 1 refinement).
- [x] **H10 — Budget-aware agents** — Inject remaining token budget into agent context: `BUDGET_REMAINING: 120,000 tokens (60%)`. Agents can self-regulate: skip expensive searches when budget is low, prefer smaller patches.
- [x] **H11 — Add `list_tests` tool** — Run `dotnet test --list-tests` and return all test method names grouped by class and project. Helps builder understand existing test coverage before generating new tests.
- [x] **H12 — Add `get_symbols` tool** — Use Roslyn or regex to extract class/method/property signatures from a `.cs` file with line numbers and visibility modifiers. Faster than `open_file` for understanding file structure without reading full content. Returns: `public class UserService : IUserService { +CreateAsync(User):Task<User> L23, +DeleteAsync(int):Task L45, -ValidateEmail(string):bool L67 }`.
- [x] **H13 — Add `get_interface` tool** — Given a class name, find and return its interface definition(s). Critical for C# mock generation — builder needs to know `IUserRepository` signatures to write `Mock<IUserRepository>().Setup(...)` correctly.
- [x] **H14 — Add `get_nuget_info` tool** — Return installed NuGet packages and versions for the test project. Builder needs to know: which test framework (xUnit vs NUnit vs MSTest), which mock library (Moq vs NSubstitute vs FakeItEasy), which assertion library (FluentAssertions vs Shouldly vs built-in). Determines generated code style.
- [x] **H15 — Add `get_di_registrations` tool** — Parse `Startup.cs` / `Program.cs` for DI registrations (`services.AddScoped<IFoo, Foo>()`). Return interface→implementation mappings. Critical for understanding what to mock vs what to use concrete implementations for.

## I stream: Best-in-class test generation

> Make Forge generate best-in-class C#/.NET unit tests by deeply understanding the code under test.

- [x] **I01 — Coverage-gap-driven test generation** — Run `dotnet test --collect:"XPlat Code Coverage"` first. Parse Cobertura XML to identify uncovered branches/lines per method. Generate builder hypotheses targeting specific uncovered paths (e.g., "test the null-input branch of UserService.CreateAsync") rather than generic "fix failing tests".
- [x] **I02 — Roslyn-powered code analysis** — Create a small C# helper tool (`tools/RoslynAnalyser/`) that uses Microsoft.CodeAnalysis to extract: method signatures with full parameter types, return types, async markers, attribute decorators, throw statements, branching complexity (cyclomatic), nullable annotations. Output JSON consumed by PowerShell. This replaces the regex-based CallGraph.ps1 and ImportGraph.ps1 with accurate AST data.
- [x] **I03 — Stryker.NET mutation testing** — Run `dotnet-stryker` after tests pass to verify test quality. Parse mutation report JSON. If mutations survive (e.g., "removing null check on line 42 didn't break any test"), generate targeted test hypotheses that kill those mutants. Store surviving mutants in Redis for cross-run tracking.
- [x] **I04 — C# test pattern library in Redis** — Store successful test patterns as `forge:patterns:csharp:{category}`. Categories: `moq-setup`, `async-test`, `exception-test`, `theory-inlinedata`, `fixture-setup`, `httpClient-mock`, `dbContext-mock`, `mediator-test`, `controller-test`, `middleware-test`. Builder retrieves matching patterns based on the class/method under test.
- [x] **I05 — Dependency-graph-aware test ordering** — Use Roslyn-extracted call graph + `<ProjectReference>` graph to determine test priority. Test leaf services first (repositories, validators), then composed services (application services), then controllers. Reduces cascading failures where one broken mock breaks 20 tests.
- [x] **I06 — Auto mock scaffolding** — For each class under test, analyse constructor via Roslyn: extract all `I*` interface parameters. Look up interface definitions. Generate complete mock setup: `var mockRepo = new Mock<IUserRepository>(); mockRepo.Setup(x => x.GetByIdAsync(It.IsAny<int>())).ReturnsAsync(new User {...});`. Inject as `MOCK_SCAFFOLD:` context section — builder just needs to fill in assertion logic.
- [x] **I07 — Test style detection and enforcement** — Scan existing test files to detect: test framework (xUnit `[Fact]`/`[Theory]` vs NUnit `[Test]`/`[TestCase]` vs MSTest `[TestMethod]`), mock library (Moq `Mock<T>` vs NSubstitute `Substitute.For<T>` vs FakeItEasy `A.Fake<T>`), assertion style (FluentAssertions `.Should()` vs Shouldly `.ShouldBe()` vs built-in `Assert.Equal`), naming convention (`Method_Scenario_Expected` vs `ShouldDoX_WhenY`), test class organisation (one class per SUT vs feature-grouped). Enforce detected style in builder prompt.
- [x] **I08 — Arrange-Act-Assert structure enforcement** — Validate generated tests follow AAA pattern. Builder prompt explicitly requires: `// Arrange` (setup mocks + inputs), `// Act` (call method under test), `// Assert` (verify outputs + mock interactions). Reviewer rejects tests missing clear AAA structure.
- [x] **I09 — Edge case generation from method signatures** — Given a method `Task<User> CreateAsync(string email, string name)`, auto-generate edge case hypotheses: null email, empty email, whitespace email, email > max length, null name, duplicate email (if uniqueness constraint detected), concurrent calls. Feed as `EDGE_CASES:` context to builder.
- [x] **I10 — Integration test generation for controllers/endpoints** — Detect `[ApiController]` classes. Generate `WebApplicationFactory<Program>` based integration tests with `HttpClient`. Mock only external dependencies (databases, third-party APIs), use real DI pipeline. Test HTTP status codes, response shapes, validation errors, auth requirements.
- [x] **I11 — Test data builder pattern** — Detect entity/model classes. Generate `UserBuilder` fluent test data builders: `new UserBuilder().WithEmail("test@example.com").WithRole(Role.Admin).Build()`. Store generated builders as reusable fixtures. Reduces test setup boilerplate and makes tests more readable.

## J stream: Architecture & performance

> Scale the system, parallelize work, add configuration, improve reliability.

- [x] **J01 — External config file: forge.config.json** — Move all hardcoded constants to config: `maxLoops`, `maxAgentIterations`, `maxSearches`, `maxOpens`, `maxTokens`, `maxCostGBP`, `memoryBackend`, `embeddingModel`, `builderDeployment`, `judgeDeployment`, `reviewerDeployment`. Load with defaults + env var overrides.
- [x] **J02 — Parallel builder execution** — Run builder hypotheses in parallel using PowerShell `Start-Job` or `ForEach-Object -Parallel`. Currently sequential. 3-4x speedup on multi-hypothesis iterations.
- [x] **J03 — Streaming API responses** — Switch from batch REST to SSE streaming for Azure OpenAI. Show real-time agent thinking in console. Reduces perceived latency. Enables early abort if agent goes off-track.
- [x] **J04 — Multi-model strategy** — Use fast/cheap model (GPT-4o-mini) for search and file analysis. Use powerful model (GPT-4o, o1) for patch generation and judging. Configure per-role in forge.config.json: `{ "builder": { "searchModel": "gpt-4o-mini", "patchModel": "gpt-4o" } }`.
- [x] **J05 — Incremental patching** — Instead of resetting tree every iteration, allow patches to accumulate if they fix some tests. Track which tests each patch fixed. Only reset if a patch breaks previously-passing tests.
- [x] **J06 — Azure AI Foundry agent integration** — Use Azure AI Foundry's managed agent service instead of raw REST calls. Leverage built-in tool calling (function calling with JSON schema), conversation management, and file handling. Create builder/reviewer/judge as persistent agent resources with code interpreter enabled.
- [x] **J07 — Plugin architecture** — Let users add custom tools via `plugins/` directory. Each plugin exports: name, description, permissions, handler function. Loaded at startup, registered in Orchestrator tool permissions. Ship default plugins: `roslyn-analyser`, `stryker-runner`, `coverage-parser`.
- [x] **J08 — Git worktree isolation** — Use `git worktree` to create isolated working directories per builder hypothesis. Eliminates need for git reset between iterations. Enables true parallel patching.
- [x] **J09 — Azure DevOps / GitHub Actions CI integration** — Add `run.ps1 -CIMode` that outputs structured JSON results suitable for CI pipelines. Post test coverage diffs and generated test summaries as PR comments via Azure DevOps REST API or GitHub API. Fail pipeline if coverage drops.
- [x] **J10 — .NET solution-aware project graph** — Parse `.sln` → `.csproj` references → NuGet packages to build full dependency tree. Use this to: (a) determine build order, (b) identify which test projects cover which implementation projects, (c) skip rebuilding unchanged projects with `dotnet build --no-incremental` only on changed assemblies.
- [x] **J11 — Azure OpenAI function calling migration** — Replace JSON-in-text tool protocol with native Azure OpenAI function calling (`tools` parameter in API request with JSON schemas). Eliminates JSON parse errors in Orchestrator.ps1, gives model structured tool definitions, enables parallel tool calls in a single response.

## K stream: Observability & developer experience

> Make Forge transparent, measurable, and delightful to use.

- [x] **K01 — Rich CLI output with progress indicators** — Replace plain Write-Host with structured output: iteration progress bar, token usage gauge, cost ticker, agent status (searching/analyzing/patching). Use ANSI colors.
- [x] **K02 — Run metrics dashboard** — After each run, generate `metrics.json`: total time, iterations used, tokens consumed, cost, patches tried, tests fixed, success rate. Optional HTML report.
- [x] **K03 — Agent decision trace** — Log every agent decision as structured events: `{ timestamp, agent, action, tool, input, output, tokens }`. Enable replay/audit of why a particular patch was chosen.
- [x] **K04 — Cost estimation before run** — Analyze repo size, test count, and failure count. Estimate token usage and cost before starting. Ask for confirmation if estimated cost > threshold.
- [x] **K05 — Interactive mode** — `run.ps1 -Interactive`: pause after judge selection, show diff to user, ask "apply this patch? (y/n/edit)". Enables human-in-the-loop for high-stakes repos.
- [x] **K06 — Dry-run mode** — `run.ps1 -DryRun`: run full pipeline but don't apply patches or commit. Show what would have been done. Useful for evaluating Forge on a new repo.
- [x] **K07 — Success rate tracking across runs** — Store per-repo success metrics in Redis: `forge:{repo}:metrics:{date}`. Track: iterations to success, common failure patterns, cost per fix. Show trends.

## E stream: Test coverage (new)

> Expand Pester test coverage for new and existing modules.

- [x] **E40 — Add Pester tests for Score-File relevance scoring** — Test all scoring branches: test files, services, agents, entry points, relevance decay. lib/RepoTools.ps1
- [x] **E41 — Add Pester tests for Search-Files deduplication and sorting** — Test multi-pattern search, score ordering, max results limit. lib/RepoTools.ps1
- [x] **E42 — Add integration test for full run.ps1 loop** — Mock Azure API, run complete iteration cycle against a sample C# solution, verify: memory updates, budget enforcement, git operations, patch validation.
- [x] **E43 — Add Pester tests for RedisCache.ps1** — Test connection, get/set/delete, TTL expiry, fallback to local when Redis unavailable. lib/RedisCache.ps1
- [x] **E44 — Add Pester tests for Embeddings.ps1** — Test C# code chunking (class/method splitting), embedding API calls, vector storage/retrieval, incremental update logic. lib/Embeddings.ps1
- [x] **E45 — Add Pester tests for new agent tools** — Test write_file path validation (reject non-test paths), run_tests invocation limits, get_coverage Cobertura XML parsing, get_symbols Roslyn output parsing. lib/Orchestrator.ps1
- [x] **E46 — Add Pester tests for test style detection** — Test xUnit/NUnit/MSTest detection, Moq/NSubstitute/FakeItEasy detection, assertion style detection, naming convention extraction. lib/TestStyleDetector.ps1
- [x] **E47 — Add sample C# solution for integration tests** — Create `tests/fixtures/SampleApi/` with a minimal ASP.NET Core Web API (controller, service, repository interface, entity, one existing test). Use as the target repo for integration tests (E42).
