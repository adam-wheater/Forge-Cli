BeforeAll {
    # Import functions under test
    . "$PSScriptRoot/../lib/TokenBudget.ps1"

    # Ensure deterministic budgets for tests
    $Global:MAX_TOTAL_TOKENS = 200
    $Global:MAX_ITERATION_TOKENS = 50
    $Global:PROMPT_COST_PER_1K = 0.0
    $Global:COMPLETION_COST_PER_1K = 0.0
    $Global:MAX_COST_GBP = 100.0

    $Global:PromptTokens = 0
    $Global:CompletionTokens = 0
}

Describe 'Enforce-Budgets' {
    BeforeEach {
        $Global:PromptTokens = 0
        $Global:CompletionTokens = 0
    }

    Context 'When within budgets' {
        It 'Does not throw' {
            Add-TokenUsage -Prompt 10 -Completion 10
            { Enforce-Budgets -IterationStartTokens 0 } | Should -Not -Throw
        }
    }

    Context 'When iteration token budget exceeded' {
        It 'Throws with a clear message containing used and limit tokens' {
            Add-TokenUsage -Prompt 60 -Completion 0
            { Enforce-Budgets -IterationStartTokens 0 } | Should -Throw -ExpectedMessage '*Iteration token budget exceeded*usedTokens=*limitTokens=*'
        }
    }

    Context 'When total token budget exceeded' {
        It 'Throws with a clear message containing total and limit tokens' {
            # Avoid triggering iteration budget first
            $Global:MAX_ITERATION_TOKENS = 1000

            Add-TokenUsage -Prompt 201 -Completion 0
            { Enforce-Budgets -IterationStartTokens 0 } | Should -Throw -ExpectedMessage '*Total token budget exceeded*totalTokens=*limitTokens=*'
        }
    }

    Context 'When cost budget exceeded' {
        It 'Throws with a clear message containing cost and component tokens' {
            $Global:PROMPT_COST_PER_1K = 1.0
            $Global:COMPLETION_COST_PER_1K = 1.0
            $Global:MAX_COST_GBP = 0.01

            # Cost per 1K = 1, with 20 prompt tokens => 0.02 GBP > 0.01 GBP
            Add-TokenUsage -Prompt 20 -Completion 0
            { Enforce-Budgets -IterationStartTokens 20 } | Should -Throw -ExpectedMessage '*Cost budget exceeded*costGBP=*limitGBP=*promptTokens=*completionTokens=*'
        }
    }

    Context 'When IterationStartTokens is invalid' {
        It 'Rejects negative values' {
            { Enforce-Budgets -IterationStartTokens -1 } | Should -Throw
        }
    }
}

AfterAll {
    $Global:PromptTokens = 0
    $Global:CompletionTokens = 0
}

Describe 'Get-TotalTokens' {
    It 'Returns correct sum' {
        $Global:PromptTokens = 5
        $Global:CompletionTokens = 7
        Get-TotalTokens | Should -Be 12
    }
}

Describe 'Get-CurrentCostGBP' {
    It 'Returns correct cost' {
        $Global:PromptTokens = 1000
        $Global:CompletionTokens = 2000
        $Global:PROMPT_COST_PER_1K = 2
        $Global:COMPLETION_COST_PER_1K = 3
        Get-CurrentCostGBP | Should -Be 8
    }
}

Describe 'Add-TokenUsage' {
    It 'Rejects negative values' {
        { Add-TokenUsage -Prompt -1 -Completion 0 } | Should -Throw
        { Add-TokenUsage -Prompt 0 -Completion -1 } | Should -Throw
    }
    It 'Rejects non-integer strings' {
        { Add-TokenUsage -Prompt 'abc' -Completion 0 } | Should -Throw
    }
}
