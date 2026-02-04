$Global:PromptTokens = 0
$Global:CompletionTokens = 0

$Global:MAX_TOTAL_TOKENS = 200000
$Global:MAX_ITERATION_TOKENS = 40000

$Global:PROMPT_COST_PER_1K = 0.002
$Global:COMPLETION_COST_PER_1K = 0.006
$Global:MAX_COST_GBP = 25.00

function Add-TokenUsage {
    param ($Prompt, $Completion)
    $Global:PromptTokens += [int]$Prompt
    $Global:CompletionTokens += [int]$Completion
}

function Get-TotalTokens {
    $Global:PromptTokens + $Global:CompletionTokens
}

function Get-CurrentCostGBP {
    ($Global:PromptTokens / 1000.0 * $Global:PROMPT_COST_PER_1K) +
    ($Global:CompletionTokens / 1000.0 * $Global:COMPLETION_COST_PER_1K)
}

function Enforce-Budgets {
    param ($IterationStartTokens)

    $used = (Get-TotalTokens) - $IterationStartTokens
    if ($used -gt $Global:MAX_ITERATION_TOKENS) { throw "Iteration token budget exceeded" }
    if ((Get-TotalTokens) -gt $Global:MAX_TOTAL_TOKENS) { throw "Total token budget exceeded" }
    if ((Get-CurrentCostGBP) -gt $Global:MAX_COST_GBP) { throw "Cost budget exceeded" }
}
