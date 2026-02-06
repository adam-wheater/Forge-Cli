$Global:PromptTokens = 0
$Global:CompletionTokens = 0

$Global:MAX_TOTAL_TOKENS = 200000
$Global:MAX_ITERATION_TOKENS = 40000

$Global:PROMPT_COST_PER_1K = 0.002
$Global:COMPLETION_COST_PER_1K = 0.006
$Global:MAX_COST_GBP = 25.00

function Add-TokenUsage {
    param (
        [Parameter(Mandatory)][int]$Prompt,
        [Parameter(Mandatory)][int]$Completion
    )
    if ([int]$Prompt -lt 0 -or [int]$Completion -lt 0) {
        throw "Token values must be non-negative integers."
    }
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
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [ValidateRange(0, [int]::MaxValue)]
        [int]$IterationStartTokens
    )

    $totalTokens = Get-TotalTokens
    $usedTokens = $totalTokens - $IterationStartTokens

    if ($usedTokens -gt $Global:MAX_ITERATION_TOKENS) {
        throw "Iteration token budget exceeded: usedTokens=$usedTokens limitTokens=$($Global:MAX_ITERATION_TOKENS) iterationStartTokens=$IterationStartTokens totalTokens=$totalTokens"
    }

    if ($totalTokens -gt $Global:MAX_TOTAL_TOKENS) {
        throw "Total token budget exceeded: totalTokens=$totalTokens limitTokens=$($Global:MAX_TOTAL_TOKENS)"
    }

    $costGBP = Get-CurrentCostGBP
    if ($costGBP -gt $Global:MAX_COST_GBP) {
        throw "Cost budget exceeded: costGBP=$costGBP limitGBP=$($Global:MAX_COST_GBP) promptTokens=$($Global:PromptTokens) completionTokens=$($Global:CompletionTokens)"
    }
}
