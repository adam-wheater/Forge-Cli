BeforeAll {
    . "$PSScriptRoot/../lib/CSharpAnalyser.ps1"
}

Describe 'Get-CSharpSymbols' {
    Context 'Extracts class name, methods, properties, constructor params, namespace' {
        BeforeAll {
            $csContent = @'
using System;

namespace MyApp.Services
{
    public class UserService : BaseService, IUserService
    {
        private readonly ILogger _logger;

        public UserService(ILogger logger, IDbContext context)
        {
            _logger = logger;
        }

        public string Name { get; set; }
        public int Age { get; set; }

        public string GetUserName(int userId)
        {
            return "test";
        }

        private void LogAction(string action, bool verbose)
        {
        }
    }
}
'@
            $testFile = Join-Path $TestDrive 'UserService.cs'
            $csContent | Out-File $testFile -Encoding utf8

            $script:symbols = Get-CSharpSymbols -Path $testFile
        }

        It 'Extracts namespace' {
            $script:symbols.Namespace | Should -Be 'MyApp.Services'
        }

        It 'Extracts class name' {
            $script:symbols.Classes.Count | Should -Be 1
            $script:symbols.Classes[0].Name | Should -Be 'UserService'
        }

        It 'Extracts class visibility' {
            $script:symbols.Classes[0].Visibility | Should -Be 'public'
        }

        It 'Extracts base class' {
            $script:symbols.Classes[0].BaseClass | Should -Be 'BaseService'
        }

        It 'Extracts interfaces' {
            $script:symbols.Classes[0].Interfaces | Should -Contain 'IUserService'
        }

        It 'Extracts constructor parameters' {
            $script:symbols.Classes[0].Constructors.Count | Should -Be 1
            $ctor = $script:symbols.Classes[0].Constructors[0]
            $ctor.Parameters.Count | Should -Be 2
            $ctor.Parameters[0].Type | Should -Be 'ILogger'
            $ctor.Parameters[0].Name | Should -Be 'logger'
            $ctor.Parameters[1].Type | Should -Be 'IDbContext'
            $ctor.Parameters[1].Name | Should -Be 'context'
        }

        It 'Extracts methods' {
            $methods = $script:symbols.Classes[0].Methods
            $methods.Count | Should -BeGreaterOrEqual 2
            $getUserName = $methods | Where-Object { $_.Name -eq 'GetUserName' }
            $getUserName | Should -Not -BeNullOrEmpty
            $getUserName.ReturnType | Should -Be 'string'
            $getUserName.Visibility | Should -Be 'public'
            $getUserName.Parameters.Count | Should -Be 1
            $getUserName.Parameters[0].Type | Should -Be 'int'
        }

        It 'Extracts properties' {
            $props = $script:symbols.Classes[0].Properties
            $namesProp = $props | Where-Object { $_.Name -eq 'Name' }
            $namesProp | Should -Not -BeNullOrEmpty
            $namesProp.Type | Should -Be 'string'
            $ageProp = $props | Where-Object { $_.Name -eq 'Age' }
            $ageProp | Should -Not -BeNullOrEmpty
            $ageProp.Type | Should -Be 'int'
        }

        It 'Records line numbers' {
            $script:symbols.Classes[0].Line | Should -BeGreaterThan 0
            $script:symbols.Classes[0].Constructors[0].Line | Should -BeGreaterThan 0
        }
    }

    Context 'Handles async methods, generic return types, nullable params' {
        BeforeAll {
            $csContent = @'
namespace MyApp.Handlers
{
    public class OrderHandler
    {
        public async Task<List<Order>> GetOrdersAsync(string? customerId, int count)
        {
            return new List<Order>();
        }

        public static Task<bool> ValidateAsync(string input)
        {
            return Task.FromResult(true);
        }
    }
}
'@
            $testFile = Join-Path $TestDrive 'OrderHandler.cs'
            $csContent | Out-File $testFile -Encoding utf8

            $script:asyncSymbols = Get-CSharpSymbols -Path $testFile
        }

        It 'Detects async methods' {
            $methods = $script:asyncSymbols.Classes[0].Methods
            $getOrders = $methods | Where-Object { $_.Name -eq 'GetOrdersAsync' }
            $getOrders | Should -Not -BeNullOrEmpty
            $getOrders.Async | Should -BeTrue
        }

        It 'Captures generic return types' {
            $methods = $script:asyncSymbols.Classes[0].Methods
            $getOrders = $methods | Where-Object { $_.Name -eq 'GetOrdersAsync' }
            $getOrders.ReturnType | Should -Match 'Task'
        }

        It 'Captures nullable parameter types' {
            $methods = $script:asyncSymbols.Classes[0].Methods
            $getOrders = $methods | Where-Object { $_.Name -eq 'GetOrdersAsync' }
            $getOrders.Parameters[0].Type | Should -Match 'string\?'
        }

        It 'Detects static methods' {
            $methods = $script:asyncSymbols.Classes[0].Methods
            $validate = $methods | Where-Object { $_.Name -eq 'ValidateAsync' }
            $validate | Should -Not -BeNullOrEmpty
            $validate.Static | Should -BeTrue
        }
    }

    Context 'Returns empty structure for empty/non-existent file' {
        It 'Returns empty for non-existent file' {
            $result = Get-CSharpSymbols -Path (Join-Path $TestDrive 'nonexistent.cs')
            $result.Namespace | Should -Be ''
            $result.Classes | Should -HaveCount 0
        }

        It 'Returns empty for empty file' {
            $emptyFile = Join-Path $TestDrive 'empty.cs'
            '' | Out-File $emptyFile -Encoding utf8

            $result = Get-CSharpSymbols -Path $emptyFile
            $result.Namespace | Should -Be ''
            $result.Classes | Should -HaveCount 0
        }
    }
}

Describe 'Get-CSharpInterface' {
    Context 'Finds interface in repo and extracts method signatures' {
        BeforeAll {
            # Set up a fake repo structure
            $script:repoDir = Join-Path $TestDrive 'fakerepo'
            $srcDir = Join-Path $script:repoDir 'src' 'Services'
            New-Item -ItemType Directory -Path $srcDir -Force | Out-Null

            # Initialize a git repo so git ls-files works
            git -C $script:repoDir init 2>$null | Out-Null
            git -C $script:repoDir config user.email "test@test.com" 2>$null | Out-Null
            git -C $script:repoDir config user.name "Test" 2>$null | Out-Null

            $interfaceContent = @'
namespace MyApp.Services
{
    public interface IUserService
    {
        Task<User> GetByIdAsync(int id);
        void DeleteUser(string userId);
        List<User> Search(string query, int limit);
    }
}
'@
            $interfaceFile = Join-Path $srcDir 'IUserService.cs'
            $interfaceContent | Out-File $interfaceFile -Encoding utf8

            git -C $script:repoDir add -A 2>$null | Out-Null
            git -C $script:repoDir commit -m "init" 2>$null | Out-Null

            $script:ifResult = Get-CSharpInterface -InterfaceName 'IUserService' -RepoRoot $script:repoDir
        }

        It 'Returns the interface name' {
            $script:ifResult.Name | Should -Be 'IUserService'
        }

        It 'Returns the file path' {
            $script:ifResult.Path | Should -Match 'IUserService\.cs'
        }

        It 'Extracts method signatures' {
            $script:ifResult.Methods.Count | Should -Be 3
        }

        It 'Parses method return types' {
            $getById = $script:ifResult.Methods | Where-Object { $_.Name -eq 'GetByIdAsync' }
            $getById | Should -Not -BeNullOrEmpty
            $getById.ReturnType | Should -Match 'Task'
        }

        It 'Parses method parameters' {
            $search = $script:ifResult.Methods | Where-Object { $_.Name -eq 'Search' }
            $search | Should -Not -BeNullOrEmpty
            $search.Parameters.Count | Should -Be 2
            $search.Parameters[0].Type | Should -Be 'string'
            $search.Parameters[0].Name | Should -Be 'query'
        }
    }

    Context 'Returns null when interface not found' {
        It 'Returns null for missing interface' {
            $repoDir = Join-Path $TestDrive 'emptyrepo'
            New-Item -ItemType Directory -Path $repoDir -Force | Out-Null

            $result = Get-CSharpInterface -InterfaceName 'INonExistent' -RepoRoot $repoDir
            $result | Should -BeNullOrEmpty
        }

        It 'Returns null for non-existent repo root' {
            $result = Get-CSharpInterface -InterfaceName 'IFoo' -RepoRoot (Join-Path $TestDrive 'nope')
            $result | Should -BeNullOrEmpty
        }
    }
}

Describe 'Get-NuGetPackages' {
    Context 'Detects xUnit + Moq + FluentAssertions from csproj XML' {
        BeforeAll {
            $csprojContent = @'
<Project Sdk="Microsoft.NET.Sdk">
  <PropertyGroup>
    <TargetFramework>net8.0</TargetFramework>
  </PropertyGroup>
  <ItemGroup>
    <PackageReference Include="xunit" Version="2.6.1" />
    <PackageReference Include="xunit.runner.visualstudio" Version="2.5.3" />
    <PackageReference Include="Moq" Version="4.20.69" />
    <PackageReference Include="FluentAssertions" Version="6.12.0" />
    <PackageReference Include="coverlet.collector" Version="6.0.0" />
    <PackageReference Include="Microsoft.EntityFrameworkCore" Version="8.0.0" />
  </ItemGroup>
</Project>
'@
            $csprojFile = Join-Path $TestDrive 'MyApp.Tests.csproj'
            $csprojContent | Out-File $csprojFile -Encoding utf8

            $script:pkgResult = Get-NuGetPackages -ProjectPath $csprojFile
        }

        It 'Extracts all packages' {
            $script:pkgResult.Packages.Count | Should -Be 6
        }

        It 'Includes package names' {
            $names = @($script:pkgResult.Packages | ForEach-Object { $_.Name })
            $names | Should -Contain 'xunit'
            $names | Should -Contain 'Moq'
            $names | Should -Contain 'FluentAssertions'
        }

        It 'Includes package versions' {
            $xunit = $script:pkgResult.Packages | Where-Object { $_.Name -eq 'xunit' }
            $xunit.Version | Should -Be '2.6.1'
        }

        It 'Detects xUnit test framework' {
            $script:pkgResult.TestFramework | Should -Be 'xunit'
        }

        It 'Detects Moq mock library' {
            $script:pkgResult.MockLibrary | Should -Be 'moq'
        }

        It 'Detects FluentAssertions' {
            $script:pkgResult.AssertionLibrary | Should -Be 'fluentassertions'
        }

        It 'Detects coverlet coverage tool' {
            $script:pkgResult.CoverageTools | Should -Contain 'coverlet'
        }
    }

    Context 'Detects NUnit + NSubstitute correctly' {
        BeforeAll {
            $csprojContent = @'
<Project Sdk="Microsoft.NET.Sdk">
  <ItemGroup>
    <PackageReference Include="NUnit" Version="3.14.0" />
    <PackageReference Include="NUnit3TestAdapter" Version="4.5.0" />
    <PackageReference Include="NSubstitute" Version="5.1.0" />
    <PackageReference Include="Shouldly" Version="4.2.1" />
  </ItemGroup>
</Project>
'@
            $csprojFile = Join-Path $TestDrive 'NUnit.Tests.csproj'
            $csprojContent | Out-File $csprojFile -Encoding utf8

            $script:nunitResult = Get-NuGetPackages -ProjectPath $csprojFile
        }

        It 'Detects NUnit test framework' {
            $script:nunitResult.TestFramework | Should -Be 'nunit'
        }

        It 'Detects NSubstitute mock library' {
            $script:nunitResult.MockLibrary | Should -Be 'nsubstitute'
        }

        It 'Detects Shouldly assertion library' {
            $script:nunitResult.AssertionLibrary | Should -Be 'shouldly'
        }
    }

    Context 'Handles missing/empty csproj gracefully' {
        It 'Returns empty result for non-existent file' {
            $result = Get-NuGetPackages -ProjectPath (Join-Path $TestDrive 'nope.csproj')
            $result.Packages | Should -HaveCount 0
            $result.TestFramework | Should -Be ''
            $result.MockLibrary | Should -Be ''
            $result.AssertionLibrary | Should -Be 'builtin'
        }

        It 'Returns empty result for empty csproj' {
            $emptyFile = Join-Path $TestDrive 'empty.csproj'
            '' | Out-File $emptyFile -Encoding utf8

            $result = Get-NuGetPackages -ProjectPath $emptyFile
            $result.Packages | Should -HaveCount 0
            $result.TestFramework | Should -Be ''
        }
    }
}

Describe 'Get-DIRegistrations' {
    Context 'Extracts AddScoped/AddTransient/AddSingleton registrations' {
        BeforeAll {
            $script:diRepo = Join-Path $TestDrive 'direpo'
            New-Item -ItemType Directory -Path $script:diRepo -Force | Out-Null

            $startupContent = @'
using Microsoft.Extensions.DependencyInjection;

namespace MyApp
{
    public class Startup
    {
        public void ConfigureServices(IServiceCollection services)
        {
            services.AddScoped<IUserService, UserService>();
            services.AddTransient<IEmailSender, SmtpEmailSender>();
            services.AddSingleton<ICacheService, RedisCacheService>();
            services.AddScoped(typeof(IRepository<>), typeof(GenericRepository<>));
            services.AddDbContext<AppDbContext>(options => options.UseSqlServer());
            services.AddHttpClient<IApiClient, ApiClient>();
        }
    }
}
'@
            $startupFile = Join-Path $script:diRepo 'Startup.cs'
            $startupContent | Out-File $startupFile -Encoding utf8

            $script:diResult = Get-DIRegistrations -RepoRoot $script:diRepo
        }

        It 'Extracts AddScoped registration' {
            $scoped = $script:diResult.Registrations | Where-Object { $_.Interface -eq 'IUserService' }
            $scoped | Should -Not -BeNullOrEmpty
            $scoped.Implementation | Should -Be 'UserService'
            $scoped.Lifetime | Should -Be 'Scoped'
        }

        It 'Extracts AddTransient registration' {
            $transient = $script:diResult.Registrations | Where-Object { $_.Interface -eq 'IEmailSender' }
            $transient | Should -Not -BeNullOrEmpty
            $transient.Implementation | Should -Be 'SmtpEmailSender'
            $transient.Lifetime | Should -Be 'Transient'
        }

        It 'Extracts AddSingleton registration' {
            $singleton = $script:diResult.Registrations | Where-Object { $_.Interface -eq 'ICacheService' }
            $singleton | Should -Not -BeNullOrEmpty
            $singleton.Implementation | Should -Be 'RedisCacheService'
            $singleton.Lifetime | Should -Be 'Singleton'
        }

        It 'Extracts typeof() registration' {
            $generic = $script:diResult.Registrations | Where-Object { $_.Interface -match 'IRepository' }
            $generic | Should -Not -BeNullOrEmpty
            $generic.Implementation | Should -Match 'GenericRepository'
            $generic.Lifetime | Should -Be 'Scoped'
        }

        It 'Extracts AddDbContext registration' {
            $db = $script:diResult.Registrations | Where-Object { $_.Interface -eq 'AppDbContext' }
            $db | Should -Not -BeNullOrEmpty
            $db.Lifetime | Should -Be 'Scoped'
        }

        It 'Extracts AddHttpClient registration' {
            $http = $script:diResult.Registrations | Where-Object { $_.Interface -eq 'IApiClient' }
            $http | Should -Not -BeNullOrEmpty
            $http.Implementation | Should -Be 'ApiClient'
            $http.Lifetime | Should -Be 'Transient'
        }

        It 'Records line numbers' {
            $script:diResult.Registrations | ForEach-Object {
                $_.Line | Should -BeGreaterThan 0
            }
        }
    }

    Context 'Handles minimal API (builder.Services) pattern' {
        BeforeAll {
            $script:minimalRepo = Join-Path $TestDrive 'minimalrepo'
            New-Item -ItemType Directory -Path $script:minimalRepo -Force | Out-Null

            $programContent = @'
var builder = WebApplication.CreateBuilder(args);

builder.Services.AddScoped<IOrderService, OrderService>();
builder.Services.AddTransient<INotifier, EmailNotifier>();
builder.Services.AddSingleton<IConfig, AppConfig>();

var app = builder.Build();
app.Run();
'@
            $programFile = Join-Path $script:minimalRepo 'Program.cs'
            $programContent | Out-File $programFile -Encoding utf8

            $script:minimalResult = Get-DIRegistrations -RepoRoot $script:minimalRepo
        }

        It 'Extracts builder.Services.AddScoped' {
            $scoped = $script:minimalResult.Registrations | Where-Object { $_.Interface -eq 'IOrderService' }
            $scoped | Should -Not -BeNullOrEmpty
            $scoped.Implementation | Should -Be 'OrderService'
            $scoped.Lifetime | Should -Be 'Scoped'
        }

        It 'Extracts builder.Services.AddTransient' {
            $transient = $script:minimalResult.Registrations | Where-Object { $_.Interface -eq 'INotifier' }
            $transient | Should -Not -BeNullOrEmpty
            $transient.Implementation | Should -Be 'EmailNotifier'
            $transient.Lifetime | Should -Be 'Transient'
        }

        It 'Extracts builder.Services.AddSingleton' {
            $singleton = $script:minimalResult.Registrations | Where-Object { $_.Interface -eq 'IConfig' }
            $singleton | Should -Not -BeNullOrEmpty
            $singleton.Implementation | Should -Be 'AppConfig'
            $singleton.Lifetime | Should -Be 'Singleton'
        }
    }

    Context 'Returns empty when no Startup.cs or Program.cs found' {
        It 'Returns empty registrations for empty directory' {
            $emptyDir = Join-Path $TestDrive 'emptydidir'
            New-Item -ItemType Directory -Path $emptyDir -Force | Out-Null

            $result = Get-DIRegistrations -RepoRoot $emptyDir
            $result.Registrations | Should -HaveCount 0
        }

        It 'Returns empty for non-existent directory' {
            $result = Get-DIRegistrations -RepoRoot (Join-Path $TestDrive 'nope')
            $result.Registrations | Should -HaveCount 0
        }
    }
}
