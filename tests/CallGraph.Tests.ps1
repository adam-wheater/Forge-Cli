BeforeAll {
    . "$PSScriptRoot/../lib/CallGraph.ps1"
}

Describe 'Get-ConstructorDependencies' {
    Context 'Basic Functionality' {
        It 'Returns empty result for non-existent file' {
            $result = Get-ConstructorDependencies -Path (Join-Path $TestDrive 'nonexistent.cs')
            $result | Should -BeNullOrEmpty
        }

        It 'Returns dependencies for a simple constructor' {
            $content = @'
public class MyService
{
    public MyService(ILogger logger, IRepository repo)
    {
    }
}
'@
            $file = Join-Path $TestDrive 'MyService.cs'
            $content | Out-File $file -Encoding utf8
            $result = Get-ConstructorDependencies -Path $file
            $result | Should -Contain 'ILogger'
            $result | Should -Contain 'IRepository'
            $result.Count | Should -Be 2
        }

        It 'Handles multiple constructors and aggregates dependencies' {
            $content = @'
public class Multi
{
    public Multi(ILogger log) {}
    public Multi(IDatabase db, ILogger log) {}
}
'@
            $file = Join-Path $TestDrive 'Multi.cs'
            $content | Out-File $file -Encoding utf8
            $result = Get-ConstructorDependencies -Path $file
            $result | Should -Contain 'ILogger'
            $result | Should -Contain 'IDatabase'
            $result.Count | Should -Be 2
        }

        It 'Handles formatting variations (spaces/newlines)' {
            $content = @'
public class Format
{
    public Format(
        ILogger   log ,
        IDatabase
           db
    ) {}
}
'@
            $file = Join-Path $TestDrive 'Format.cs'
            $content | Out-File $file -Encoding utf8
            $result = Get-ConstructorDependencies -Path $file
            $result | Should -Contain 'ILogger'
            $result | Should -Contain 'IDatabase'
        }
    }

    Context 'Edge Cases' {
        It 'Returns unique dependencies' {
            $content = @'
public class Unique
{
    public Unique(ILogger log1, ILogger log2) {}
}
'@
            $file = Join-Path $TestDrive 'Unique.cs'
            $content | Out-File $file -Encoding utf8
            $result = Get-ConstructorDependencies -Path $file
            $result | Should -Contain 'ILogger'
            $result.Count | Should -Be 1
        }

        It 'Handles constructor with no parameters' {
            $content = @'
public class Empty
{
    public Empty() {}
}
'@
            $file = Join-Path $TestDrive 'Empty.cs'
            $content | Out-File $file -Encoding utf8
            $result = Get-ConstructorDependencies -Path $file
            $result | Should -HaveCount 0
        }

        It 'Handles attributes on parameters (naive approach check)' {
            # The current implementation splits by space, so [Attribute] might become the type.
            $content = @'
public class Attr
{
    public Attr([FromServices] ILogger log) {}
}
'@
            $file = Join-Path $TestDrive 'Attr.cs'
            $content | Out-File $file -Encoding utf8
            $result = Get-ConstructorDependencies -Path $file

            # Based on implementation, this returns the attribute as the type
            $result | Should -Contain '[FromServices]'
        }

        It 'Handles simple generics' {
            $content = @'
public class Generic
{
    public Generic(List<string> list) {}
}
'@
            $file = Join-Path $TestDrive 'Generic.cs'
            $content | Out-File $file -Encoding utf8
            $result = Get-ConstructorDependencies -Path $file

            $result | Should -Contain 'List<string>'
        }

        It 'Handles complex generics with commas (limitation check)' {
            $content = @'
public class ComplexGeneric
{
    public ComplexGeneric(Dictionary<int, string> dict) {}
}
'@
            $file = Join-Path $TestDrive 'ComplexGeneric.cs'
            $content | Out-File $file -Encoding utf8
            $result = Get-ConstructorDependencies -Path $file

            # Current implementation splits by comma, breaking the generic type
            $result | Should -Contain 'Dictionary<int'
            $result | Should -Contain 'string>'
        }
    }
}
