BeforeAll {
    . "$PSScriptRoot/../lib/Embeddings.ps1"
}

Describe 'Get-Embedding' {
    BeforeEach {
        $env:AZURE_OPENAI_ENDPOINT = 'https://example.openai.azure.com'
        $env:AZURE_OPENAI_API_KEY = 'dummy-key'
        $env:AZURE_OPENAI_API_VERSION = '2023-05-15'
    }

    Context 'Calls correct Azure endpoint with correct headers' {
        It 'Sends POST to Azure OpenAI embeddings endpoint' {
            Mock -CommandName Invoke-RestMethod -MockWith {
                @{ data = @(@{ embedding = @(0.1, 0.2, 0.3) }) }
            }

            $result = Get-Embedding -Text 'hello world'
            $result | Should -Not -BeNullOrEmpty
            $result.Count | Should -Be 3

            Should -Invoke Invoke-RestMethod -Times 1 -ParameterFilter {
                $Method -eq 'POST' -and
                $Uri -like '*openai/deployments/text-embedding-3-small/embeddings*' -and
                $Uri -like '*api-version=2023-05-15*' -and
                $Headers['Authorization'] -eq 'Bearer dummy-key' -and
                $Headers['Content-Type'] -eq 'application/json'
            }
        }
    }

    Context 'Returns null on API failure' {
        It 'Does not throw on API error' {
            Mock -CommandName Invoke-RestMethod -MockWith { throw 'API error' }

            $result = Get-Embedding -Text 'fail test'
            $result | Should -BeNullOrEmpty
        }
    }
}

Describe 'Get-CosineSimilarity' {
    Context 'Identical vectors' {
        It 'Returns 1.0' {
            $v = [float[]]@(1.0, 0.0, 0.0)
            $result = Get-CosineSimilarity -VectorA $v -VectorB $v
            [Math]::Round($result, 4) | Should -Be 1.0
        }
    }

    Context 'Orthogonal vectors' {
        It 'Returns 0.0' {
            $a = [float[]]@(1.0, 0.0, 0.0)
            $b = [float[]]@(0.0, 1.0, 0.0)
            $result = Get-CosineSimilarity -VectorA $a -VectorB $b
            [Math]::Round($result, 4) | Should -Be 0.0
        }
    }

    Context 'Opposite vectors' {
        It 'Returns -1.0' {
            $a = [float[]]@(1.0, 0.0, 0.0)
            $b = [float[]]@(-1.0, 0.0, 0.0)
            $result = Get-CosineSimilarity -VectorA $a -VectorB $b
            [Math]::Round($result, 4) | Should -Be -1.0
        }
    }
}

Describe 'Split-CSharpFile' {
    BeforeAll {
        $testDir = Join-Path $TestDrive 'cs-tests'
        New-Item -ItemType Directory -Path $testDir -Force | Out-Null
    }

    Context 'Splits simple class into using, class, method chunks' {
        It 'Returns using, class, and method chunks' {
            $csContent = @'
using System;
using System.Collections.Generic;

namespace MyApp
{
    public class MyService
    {
        public void DoWork()
        {
            Console.WriteLine("work");
        }
    }
}
'@
            $filePath = Join-Path $testDir 'Simple.cs'
            Set-Content -Path $filePath -Value $csContent

            $chunks = Split-CSharpFile -Path $filePath
            $chunks | Should -Not -BeNullOrEmpty

            $types = $chunks | ForEach-Object { $_.Type }
            $types | Should -Contain 'using'
            $types | Should -Contain 'class'
            $types | Should -Contain 'method'
        }
    }

    Context 'Extracts constructor as separate chunk' {
        It 'Returns a constructor chunk' {
            $csContent = @'
using System;

namespace MyApp
{
    public class MyService
    {
        private readonly string _name;

        public MyService(string name)
        {
            _name = name;
        }

        public void Run()
        {
            Console.WriteLine(_name);
        }
    }
}
'@
            $filePath = Join-Path $testDir 'WithCtor.cs'
            Set-Content -Path $filePath -Value $csContent

            $chunks = Split-CSharpFile -Path $filePath
            $ctorChunks = $chunks | Where-Object { $_.Type -eq 'constructor' }
            $ctorChunks | Should -Not -BeNullOrEmpty
            $ctorChunks.Count | Should -Be 1
        }
    }

    Context 'Handles multiple methods correctly' {
        It 'Returns separate chunks for each method' {
            $csContent = @'
namespace MyApp
{
    public class Calculator
    {
        public int Add(int a, int b)
        {
            return a + b;
        }

        public int Subtract(int a, int b)
        {
            return a - b;
        }

        public int Multiply(int a, int b)
        {
            return a * b;
        }
    }
}
'@
            $filePath = Join-Path $testDir 'MultiMethod.cs'
            Set-Content -Path $filePath -Value $csContent

            $chunks = Split-CSharpFile -Path $filePath
            $methodChunks = $chunks | Where-Object { $_.Type -eq 'method' }
            $methodChunks.Count | Should -Be 3
        }
    }

    Context 'Returns empty array for non-existent file' {
        It 'Returns empty array' {
            $result = Split-CSharpFile -Path '/nonexistent/file.cs'
            $result | Should -BeNullOrEmpty
        }
    }
}

Describe 'Search-Embeddings' {
    BeforeEach {
        $env:AZURE_OPENAI_ENDPOINT = 'https://example.openai.azure.com'
        $env:AZURE_OPENAI_API_KEY = 'dummy-key'
        $env:AZURE_OPENAI_API_VERSION = '2023-05-15'
    }

    Context 'Returns chunks sorted by similarity descending' {
        It 'Sorts results by similarity' {
            # Mock Get-Embedding to return a known vector for the query
            Mock -CommandName Invoke-RestMethod -MockWith {
                @{ data = @(@{ embedding = @(1.0, 0.0, 0.0) }) }
            }

            $chunks = @(
                @{ Id = "a"; Text = "chunk a"; Embedding = [float[]]@(0.0, 1.0, 0.0); File = "a.cs"; StartLine = 1; EndLine = 5; Type = "method" },
                @{ Id = "b"; Text = "chunk b"; Embedding = [float[]]@(1.0, 0.0, 0.0); File = "b.cs"; StartLine = 1; EndLine = 5; Type = "method" },
                @{ Id = "c"; Text = "chunk c"; Embedding = [float[]]@(0.5, 0.5, 0.0); File = "c.cs"; StartLine = 1; EndLine = 5; Type = "method" }
            )

            $results = Search-Embeddings -Query 'test' -Chunks $chunks -TopK 10
            $results.Count | Should -Be 3
            # Most similar should be first (exact match with query vector)
            $results[0].File | Should -Be 'b.cs'
        }
    }

    Context 'Respects TopK limit' {
        It 'Returns only TopK results' {
            Mock -CommandName Invoke-RestMethod -MockWith {
                @{ data = @(@{ embedding = @(1.0, 0.0, 0.0) }) }
            }

            $chunks = @(
                @{ Id = "a"; Text = "a"; Embedding = [float[]]@(1.0, 0.0, 0.0); File = "a.cs"; StartLine = 1; EndLine = 2; Type = "method" },
                @{ Id = "b"; Text = "b"; Embedding = [float[]]@(0.9, 0.1, 0.0); File = "b.cs"; StartLine = 1; EndLine = 2; Type = "method" },
                @{ Id = "c"; Text = "c"; Embedding = [float[]]@(0.8, 0.2, 0.0); File = "c.cs"; StartLine = 1; EndLine = 2; Type = "method" }
            )

            $results = Search-Embeddings -Query 'test' -Chunks $chunks -TopK 2
            $results.Count | Should -Be 2
        }
    }
}

Describe 'Build-EmbeddingIndex' {
    BeforeAll {
        $testDir = Join-Path $TestDrive 'build-index'
        New-Item -ItemType Directory -Path $testDir -Force | Out-Null
    }

    BeforeEach {
        $Global:EmbeddingCache = @{}
        $env:AZURE_OPENAI_ENDPOINT = 'https://example.openai.azure.com'
        $env:AZURE_OPENAI_API_KEY = 'dummy-key'
        $env:AZURE_OPENAI_API_VERSION = '2023-05-15'
    }

    Context 'Skips files over 50KB' {
        It 'Does not index oversized files' {
            Mock -CommandName git -MockWith { 'small.cs'; 'large.cs' }
            Mock -CommandName Start-Sleep -MockWith { }
            Mock -CommandName Invoke-RestMethod -MockWith {
                @{ data = @(@{ embedding = @(0.1, 0.2, 0.3) }) }
            }

            # Create a small file
            $smallFile = Join-Path $testDir 'small.cs'
            $smallContent = @'
namespace Test
{
    public class Small
    {
        public void Work()
        {
            return;
        }
    }
}
'@
            Set-Content -Path $smallFile -Value $smallContent

            # Create a large file (> 50KB)
            $largeFile = Join-Path $testDir 'large.cs'
            $largeContent = "namespace Test {`n" + ("// " + ("x" * 100) + "`n") * 600 + "}"
            Set-Content -Path $largeFile -Value $largeContent

            $count = Build-EmbeddingIndex -RepoRoot $testDir
            # Only chunks from the small file should be indexed
            # The large file should be skipped entirely
            $largeChunks = $Global:EmbeddingCache.Keys | Where-Object { $_ -like "*large*" }
            $largeChunks | Should -BeNullOrEmpty
        }
    }
}

Describe 'Load-EmbeddingIndex' {
    BeforeEach {
        $Global:EmbeddingCache = @{}
    }

    Context 'Restores cache from JSON file' {
        It 'Loads chunks from cache file' {
            $cacheFile = Join-Path $TestDrive 'cache.json'
            $cacheData = @{
                "file.cs:method:DoWork" = @{
                    Id        = "file.cs:method:DoWork"
                    Text      = "public void DoWork() { }"
                    File      = "file.cs"
                    StartLine = 5
                    EndLine   = 7
                    Type      = "method"
                    Embedding = @(0.1, 0.2, 0.3)
                }
                "file.cs:class:MyClass" = @{
                    Id        = "file.cs:class:MyClass"
                    Text      = "public class MyClass"
                    File      = "file.cs"
                    StartLine = 3
                    EndLine   = 3
                    Type      = "class"
                    Embedding = @(0.4, 0.5, 0.6)
                }
            }
            $cacheData | ConvertTo-Json -Depth 10 | Set-Content -Path $cacheFile -Encoding utf8

            $count = Load-EmbeddingIndex -CachePath $cacheFile
            $count | Should -Be 2
            $Global:EmbeddingCache.Count | Should -Be 2
            $Global:EmbeddingCache["file.cs:method:DoWork"].Type | Should -Be "method"
            $Global:EmbeddingCache["file.cs:class:MyClass"].Type | Should -Be "class"
            $Global:EmbeddingCache["file.cs:method:DoWork"].Embedding | Should -Not -BeNullOrEmpty
        }
    }

    Context 'Missing cache file' {
        It 'Returns 0 and warns' {
            $result = Load-EmbeddingIndex -CachePath '/nonexistent/cache.json'
            $result | Should -Be 0
        }
    }
}
