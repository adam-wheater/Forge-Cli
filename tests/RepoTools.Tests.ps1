BeforeAll {
    . "$PSScriptRoot/../lib/RepoTools.ps1"
}

# --- E40: Pester tests for Score-File relevance scoring ---
Describe 'Score-File' {
    BeforeEach {
        # Reset relevance tracker state so Get-RelevanceScore returns 0
        $Global:FileRelevance = @{}
    }

    Context 'Test files get high score' {
        It 'Scores a C# test file with Test in name' {
            $score = Score-File 'src/MyApp.Tests/UserServiceTests.cs'
            # Should match: Test (+50), .cs (+5) = 55 minimum
            $score | Should -BeGreaterOrEqual 55
        }

        It 'Scores a Pester test file (.Tests.ps1)' {
            $score = Score-File 'tests/Orchestrator.Tests.ps1'
            # Should match: Tests (+50), .ps1 (+5), .Tests.ps1 (+50) = 105 minimum
            $score | Should -BeGreaterOrEqual 100
        }

        It 'Scores a file with Tests in the path' {
            $score = Score-File 'tests/SomeTests/Helper.cs'
            # Should match: Tests (+50), .cs (+5) = 55
            $score | Should -BeGreaterOrEqual 55
        }
    }

    Context 'Service/Controller/Repository files get moderate score' {
        It 'Scores a Service file' {
            $score = Score-File 'src/Services/UserService.cs'
            # Should match: Service (+15), .cs (+5) = 20
            $score | Should -Be 20
        }

        It 'Scores a Controller file' {
            $score = Score-File 'src/Controllers/WeatherController.cs'
            # Should match: Controller (+15), .cs (+5) = 20
            $score | Should -Be 20
        }

        It 'Scores a Repository file' {
            $score = Score-File 'src/Data/UserRepository.cs'
            # Should match: Repository (+15), .cs (+5) = 20
            $score | Should -Be 20
        }

        It 'Scores a Manager file' {
            $score = Score-File 'src/Business/OrderManager.cs'
            # Should match: Manager (+15), .cs (+5) = 20
            $score | Should -Be 20
        }
    }

    Context 'Agent/Orchestrator/Module files get moderate score' {
        It 'Scores an Orchestrator module' {
            $score = Score-File 'lib/Orchestrator.ps1'
            # Should match: Orchestrator (+15), .ps1 (+5) = 20
            $score | Should -Be 20
        }

        It 'Scores an Agent module' {
            $score = Score-File 'lib/AzureAgent.ps1'
            # Should match: Agent (+15), .ps1 (+5) = 20
            $score | Should -Be 20
        }

        It 'Scores a Module file' {
            $score = Score-File 'lib/SomeModule.ps1'
            # Should match: Module (+15), .ps1 (+5) = 20
            $score | Should -Be 20
        }
    }

    Context 'System prompt files get a boost' {
        It 'Scores a .system.txt file' {
            $score = Score-File 'agents/builder.system.txt'
            # Should match: .system.txt (+10) = 10
            $score | Should -BeGreaterOrEqual 10
        }
    }

    Context 'Entry point files get a penalty' {
        It 'Scores a Program.cs file with penalty' {
            $score = Score-File 'src/Program.cs'
            # Should match: Program (-10), .cs (+5) = -5
            $score | Should -Be -5
        }

        It 'Scores a Startup.cs file with penalty' {
            $score = Score-File 'src/Startup.cs'
            # Should match: Startup (-10), .cs (+5) = -5
            $score | Should -Be -5
        }
    }

    Context 'Plain C# files get base score' {
        It 'Scores a plain .cs file' {
            $score = Score-File 'src/Models/User.cs'
            # Should match: .cs (+5) = 5
            $score | Should -Be 5
        }
    }

    Context 'Plain PowerShell files get base score' {
        It 'Scores a plain .ps1 file' {
            $score = Score-File 'scripts/helper.ps1'
            # Should match: .ps1 (+5) = 5
            $score | Should -Be 5
        }
    }

    Context 'Unknown file types get zero' {
        It 'Scores a random file with zero' {
            $score = Score-File 'readme.md'
            $score | Should -Be 0
        }
    }

    Context 'Relevance decay reduces score' {
        It 'Reduces score based on file access frequency' {
            $Global:FileRelevance['src/Services/UserService.cs'] = 3
            $score = Score-File 'src/Services/UserService.cs'
            # Should match: Service (+15), .cs (+5), relevance decay (-3) = 17
            $score | Should -Be 17
        }

        It 'Returns lower score for heavily accessed files' {
            $Global:FileRelevance['tests/MyTest.cs'] = 10
            $score = Score-File 'tests/MyTest.cs'
            # Should match: Test (+50), .cs (+5), relevance decay (-10) = 45
            $score | Should -Be 45
        }
    }

    Context 'Combined scoring' {
        It 'Combines test + service + .cs scores' {
            # A test file for a service
            $score = Score-File 'tests/ServiceTests.cs'
            # Should match: Test (+50), Service (+15), .cs (+5) = 70
            $score | Should -Be 70
        }

        It 'Combines test + agent + .ps1 + .Tests.ps1 scores' {
            $score = Score-File 'tests/AzureAgent.Tests.ps1'
            # Should match: Test (+50), Agent (+15), .ps1 (+5), .Tests.ps1 (+50) = 120
            $score | Should -Be 120
        }
    }
}

# --- E41: Pester tests for Search-Files deduplication and sorting ---
Describe 'Search-Files' {
    BeforeEach {
        $Global:FileRelevance = @{}
    }

    Context 'Single pattern search' {
        It 'Returns files matching pattern sorted by score descending' {
            Mock -CommandName git -MockWith {
                'src/Services/UserService.cs'
                'src/Models/User.cs'
                'tests/UserServiceTests.cs'
            }
            Mock -CommandName Get-RelevanceScore -MockWith { 0 }

            $result = Search-Files 'User'
            $result | Should -Not -BeNullOrEmpty
            # Test file should be first (highest score)
            $result[0] | Should -Be 'tests/UserServiceTests.cs'
        }

        It 'Returns array of file paths' {
            Mock -CommandName git -MockWith { 'file1.ps1'; 'file2.ps1' }
            Mock -CommandName Get-RelevanceScore -MockWith { 0 }
            $result = Search-Files 'ps1'
            $result | Should -Contain 'file1.ps1'
            $result | Should -Contain 'file2.ps1'
        }
    }

    Context 'Multi-pattern search (array)' {
        It 'Returns deduplicated results across multiple patterns' {
            Mock -CommandName git -MockWith {
                'src/Services/UserService.cs'
                'src/Services/OrderService.cs'
                'tests/UserServiceTests.cs'
            }
            Mock -CommandName Get-RelevanceScore -MockWith { 0 }

            $result = Search-Files @('User', 'Service')
            # Results should be unique (no duplicates)
            $uniqueResult = $result | Select-Object -Unique
            $uniqueResult.Count | Should -Be $result.Count
        }

        It 'Combines results from multiple patterns' {
            Mock -CommandName git -MockWith {
                'file1.cs'
                'file2.ps1'
                'file3.cs'
            }
            Mock -CommandName Get-RelevanceScore -MockWith { 0 }

            $result = Search-Files @('file1', 'file2')
            $result | Should -Contain 'file1.cs'
            $result | Should -Contain 'file2.ps1'
        }
    }

    Context 'Score ordering' {
        It 'Returns results sorted by score descending' {
            Mock -CommandName git -MockWith {
                'src/Program.cs'
                'src/Services/TestService.cs'
                'tests/TestServiceTests.cs'
            }
            Mock -CommandName Get-RelevanceScore -MockWith { 0 }

            $result = Search-Files 'Test'
            # TestServiceTests.cs should be first (Test +50, Service +15, .cs +5 = 70)
            # TestService.cs next (Test +50, Service +15, .cs +5 = 70)
            # Program.cs should be last (Program -10, .cs +5 = -5)
            $result[-1] | Should -Be 'src/Program.cs'
        }
    }

    Context 'Max results limit' {
        It 'Returns at most 25 results' {
            # Generate 30 files
            $files = 1..30 | ForEach-Object { "file$_.cs" }
            Mock -CommandName git -MockWith { $files }
            Mock -CommandName Get-RelevanceScore -MockWith { 0 }

            $result = Search-Files 'file'
            $result.Count | Should -BeLessOrEqual 25
        }
    }

    Context 'No matches' {
        It 'Returns empty when no files match' {
            Mock -CommandName git -MockWith {
                'src/Services/UserService.cs'
                'src/Models/Order.cs'
            }
            Mock -CommandName Get-RelevanceScore -MockWith { 0 }

            $result = Search-Files 'NonExistentPattern'
            $result | Should -BeNullOrEmpty
        }
    }
}

# Existing Open-File tests
Describe 'Open-File' {
    Context 'With existing file' {
        It 'Returns file content' {
            Mock -CommandName Test-Path -MockWith { $true }
            Mock -CommandName Get-Content -MockWith { 'line1'; 'line2' }
            Mock -CommandName Mark-Relevant -MockWith { }
            $result = Open-File 'file.ps1' 10
            $result | Should -Be "line1`nline2"
        }
    }
    Context 'With missing file' {
        It 'Returns FILE_NOT_FOUND' {
            Mock -CommandName Test-Path -MockWith { $false }
            $result = Open-File 'nofile.ps1'
            $result | Should -Be 'FILE_NOT_FOUND'
        }
    }
}
