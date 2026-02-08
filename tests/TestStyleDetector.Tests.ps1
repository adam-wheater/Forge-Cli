BeforeAll {
    . "$PSScriptRoot/../lib/TestStyleDetector.ps1"
}

Describe "Detect-TestStyle" {
    Context "xUnit framework detection" {
        It "Detects xUnit framework from [Fact] and [Theory] attributes" {
            $repoDir = Join-Path $TestDrive "xunit-repo"
            $testDir = Join-Path $repoDir "Tests"
            New-Item -ItemType Directory -Path $testDir -Force | Out-Null

            $csContent = @'
using Xunit;

public class UserServiceTests
{
    [Fact]
    public void CreateUser_ValidInput_ReturnsUser()
    {
        // Arrange
        var service = new UserService();
        // Act
        var result = service.Create("test");
        // Assert
        Assert.Equal("test", result.Name);
    }

    [Theory]
    [InlineData("a")]
    [InlineData("b")]
    public void CreateUser_VariousInputs_Succeeds(string name)
    {
        var service = new UserService();
        Assert.NotNull(service.Create(name));
    }

    [Fact]
    public void DeleteUser_ExistingUser_ReturnsTrue()
    {
        Assert.True(true);
    }
}
'@
            $csContent | Out-File (Join-Path $testDir "UserServiceTests.cs") -Encoding utf8

            $result = Detect-TestStyle -RepoRoot $repoDir

            $result.TestFramework | Should -Be "xunit"
            $result.SampleCount | Should -BeGreaterThan 0
            $result.TestFiles.Count | Should -Be 1
        }
    }

    Context "NUnit framework detection" {
        It "Detects NUnit framework from [Test] and [TestCase] attributes" {
            $repoDir = Join-Path $TestDrive "nunit-repo"
            $testDir = Join-Path $repoDir "Tests"
            New-Item -ItemType Directory -Path $testDir -Force | Out-Null

            $csContent = @'
using NUnit.Framework;

[TestFixture]
public class OrderServiceTests
{
    [SetUp]
    public void Setup()
    {
        // init
    }

    [Test]
    public void PlaceOrder_ValidOrder_Succeeds()
    {
        Assert.That(true, Is.EqualTo(true));
    }

    [TestCase(1)]
    [TestCase(2)]
    public void PlaceOrder_WithQuantity_Succeeds(int qty)
    {
        Assert.That(qty, Is.GreaterThan(0));
    }

    [Test]
    public void CancelOrder_ExistingOrder_ReturnsTrue()
    {
        Assert.That(true);
    }

    [TearDown]
    public void Cleanup()
    {
    }
}
'@
            $csContent | Out-File (Join-Path $testDir "OrderServiceTests.cs") -Encoding utf8

            $result = Detect-TestStyle -RepoRoot $repoDir

            $result.TestFramework | Should -Be "nunit"
        }
    }

    Context "MSTest framework detection" {
        It "Detects MSTest from [TestMethod] and [TestClass]" {
            $repoDir = Join-Path $TestDrive "mstest-repo"
            $testDir = Join-Path $repoDir "Tests"
            New-Item -ItemType Directory -Path $testDir -Force | Out-Null

            $csContent = @'
using Microsoft.VisualStudio.TestTools.UnitTesting;

[TestClass]
public class ProductServiceTests
{
    [TestInitialize]
    public void Init()
    {
    }

    [TestMethod]
    public void GetProduct_ValidId_ReturnsProduct()
    {
        Assert.AreEqual(1, 1);
    }

    [TestMethod]
    [DataRow(1)]
    [DataRow(2)]
    public void GetProduct_VariousIds_ReturnsProduct(int id)
    {
        Assert.IsTrue(id > 0);
    }

    [TestMethod]
    public void DeleteProduct_ExistingId_ReturnsTrue()
    {
        Assert.IsTrue(true);
    }
}
'@
            $csContent | Out-File (Join-Path $testDir "ProductServiceTests.cs") -Encoding utf8

            $result = Detect-TestStyle -RepoRoot $repoDir

            $result.TestFramework | Should -Be "mstest"
        }
    }

    Context "Mock library detection" {
        It "Detects Moq from Mock<T> and .Setup(" {
            $repoDir = Join-Path $TestDrive "moq-repo"
            $testDir = Join-Path $repoDir "Tests"
            New-Item -ItemType Directory -Path $testDir -Force | Out-Null

            $csContent = @'
using Xunit;
using Moq;

public class ServiceTests
{
    [Fact]
    public void DoWork_CallsRepo()
    {
        var mockRepo = new Mock<IRepository>();
        mockRepo.Setup(r => r.Get(It.IsAny<int>())).Returns(new Entity());
        var sut = new Service(mockRepo.Object);
        sut.DoWork();
        mockRepo.Verify(r => r.Get(It.IsAny<int>()), Times.Once);
    }
}
'@
            $csContent | Out-File (Join-Path $testDir "ServiceTests.cs") -Encoding utf8

            $result = Detect-TestStyle -RepoRoot $repoDir

            $result.MockLibrary | Should -Be "moq"
        }

        It "Detects NSubstitute from Substitute.For<" {
            $repoDir = Join-Path $TestDrive "nsub-repo"
            $testDir = Join-Path $repoDir "Tests"
            New-Item -ItemType Directory -Path $testDir -Force | Out-Null

            $csContent = @'
using NUnit.Framework;
using NSubstitute;

[TestFixture]
public class HandlerTests
{
    [Test]
    public void Handle_CallsService()
    {
        var service = Substitute.For<IService>();
        service.Get(1).Returns(new Result());
        var sut = new Handler(service);
        sut.Handle();
        service.Received().Get(1);
    }

    [Test]
    public void Handle_WithNull_Throws()
    {
        var service = Substitute.For<IService>();
        service.Get(0).Returns((Result)null);
        Assert.That(() => new Handler(service).Handle(), Throws.Exception);
    }
}
'@
            $csContent | Out-File (Join-Path $testDir "HandlerTests.cs") -Encoding utf8

            $result = Detect-TestStyle -RepoRoot $repoDir

            $result.MockLibrary | Should -Be "nsubstitute"
        }
    }

    Context "Assertion style detection" {
        It "Detects FluentAssertions from .Should()" {
            $repoDir = Join-Path $TestDrive "fluent-repo"
            $testDir = Join-Path $repoDir "Tests"
            New-Item -ItemType Directory -Path $testDir -Force | Out-Null

            $csContent = @'
using Xunit;
using FluentAssertions;

public class CalcTests
{
    [Fact]
    public void Add_TwoNumbers_ReturnsSum()
    {
        var calc = new Calculator();
        var result = calc.Add(2, 3);
        result.Should().Be(5);
    }

    [Fact]
    public void Add_Negatives_ReturnsCorrect()
    {
        var calc = new Calculator();
        calc.Add(-1, -1).Should().Be(-2);
    }

    [Fact]
    public void GetItems_ReturnsNonEmpty()
    {
        var calc = new Calculator();
        calc.GetItems().Should().HaveCount(3);
        calc.IsReady.Should().BeTrue();
    }
}
'@
            $csContent | Out-File (Join-Path $testDir "CalcTests.cs") -Encoding utf8

            $result = Detect-TestStyle -RepoRoot $repoDir

            $result.AssertionStyle | Should -Be "fluentassertions"
        }
    }

    Context "Naming convention detection" {
        It "Detects underscore naming convention (MethodName_Scenario_Expected)" {
            $repoDir = Join-Path $TestDrive "naming-repo"
            $testDir = Join-Path $repoDir "Tests"
            New-Item -ItemType Directory -Path $testDir -Force | Out-Null

            $csContent = @'
using Xunit;

public class NamingTests
{
    [Fact]
    public void CreateUser_ValidInput_ReturnsUser()
    {
        Assert.True(true);
    }

    [Fact]
    public void DeleteUser_InvalidId_ThrowsException()
    {
        Assert.True(true);
    }

    [Fact]
    public void UpdateUser_NullName_ThrowsArgumentException()
    {
        Assert.True(true);
    }

    [Fact]
    public void GetUser_ExistingId_ReturnsCorrectUser()
    {
        Assert.True(true);
    }
}
'@
            $csContent | Out-File (Join-Path $testDir "NamingTests.cs") -Encoding utf8

            $result = Detect-TestStyle -RepoRoot $repoDir

            $result.NamingConvention | Should -Be "MethodName_Scenario_Expected"
        }
    }

    Context "AAA comments detection" {
        It "Detects AAA comments percentage" {
            $repoDir = Join-Path $TestDrive "aaa-repo"
            $testDir = Join-Path $repoDir "Tests"
            New-Item -ItemType Directory -Path $testDir -Force | Out-Null

            # 3 out of 4 methods have AAA comments => 75%
            $csContent = @'
using Xunit;

public class AAATests
{
    [Fact]
    public void Method1_Works()
    {
        // Arrange
        var x = 1;
        // Act
        var y = x + 1;
        // Assert
        Assert.Equal(2, y);
    }

    [Fact]
    public void Method2_Works()
    {
        // Arrange
        var a = "hello";
        // Act
        var b = a.ToUpper();
        // Assert
        Assert.Equal("HELLO", b);
    }

    [Fact]
    public void Method3_Works()
    {
        // Arrange
        var list = new List<int>();
        // Act
        list.Add(1);
        // Assert
        Assert.Equal(1, list.Count);
    }

    [Fact]
    public void Method4_NoAAA()
    {
        var x = 1 + 1;
        Assert.Equal(2, x);
    }
}
'@
            $csContent | Out-File (Join-Path $testDir "AAATests.cs") -Encoding utf8

            $result = Detect-TestStyle -RepoRoot $repoDir

            $result.UsesAAAComments | Should -BeTrue
            $result.AAAPercentage | Should -Be 75
        }
    }

    Context "Empty repo handling" {
        It "Returns defaults for empty repo (no test files)" {
            $repoDir = Join-Path $TestDrive "empty-repo"
            New-Item -ItemType Directory -Path $repoDir -Force | Out-Null

            $result = Detect-TestStyle -RepoRoot $repoDir

            $result.TestFramework | Should -Be "unknown"
            $result.MockLibrary | Should -Be "none"
            $result.AssertionStyle | Should -Be "builtin"
            $result.NamingConvention | Should -Be "Descriptive"
            $result.TestOrganisation | Should -Be "FeatureGrouped"
            $result.UsesAAAComments | Should -BeFalse
            $result.AAAPercentage | Should -Be 0
            $result.SetupPattern | Should -Be "InlineSetup"
            $result.SampleCount | Should -Be 0
            $result.TestFiles | Should -HaveCount 0
        }
    }
}

Describe "Get-TestStylePrompt" {
    Context "xUnit + Moq + FluentAssertions style" {
        It "Generates correct prompt text for xUnit+Moq+FluentAssertions style" {
            $style = @{
                TestFramework    = "xunit"
                MockLibrary      = "moq"
                AssertionStyle   = "fluentassertions"
                NamingConvention = "MethodName_Scenario_Expected"
                TestOrganisation = "OneClassPerSUT"
                UsesAAAComments  = $true
                AAAPercentage    = 75
                SetupPattern     = "ConstructorSetup"
                SampleCount      = 42
                TestFiles        = @("path1.cs")
            }

            $prompt = Get-TestStylePrompt -Style $style

            $prompt | Should -Match "TEST_STYLE:"
            $prompt | Should -Match "xUnit"
            $prompt | Should -Match "\[Fact\]"
            $prompt | Should -Match "\[Theory\]"
            $prompt | Should -Match "Moq"
            $prompt | Should -Match "Mock<IService>"
            $prompt | Should -Match "FluentAssertions"
            $prompt | Should -Match "\.Should\(\)"
            $prompt | Should -Match "MethodName_Scenario_ExpectedResult"
            $prompt | Should -Match "// Arrange.*// Act.*// Assert"
            $prompt | Should -Match "constructor"
            $prompt | Should -Match "One test class per class under test"
        }
    }

    Context "NUnit + NSubstitute + Shouldly style" {
        It "Generates correct prompt for NUnit+NSubstitute+Shouldly style" {
            $style = @{
                TestFramework    = "nunit"
                MockLibrary      = "nsubstitute"
                AssertionStyle   = "shouldly"
                NamingConvention = "Should_Action_When_Condition"
                TestOrganisation = "FeatureGrouped"
                UsesAAAComments  = $false
                AAAPercentage    = 10
                SetupPattern     = "SetUpMethod"
                SampleCount      = 20
                TestFiles        = @("path1.cs", "path2.cs")
            }

            $prompt = Get-TestStylePrompt -Style $style

            $prompt | Should -Match "TEST_STYLE:"
            $prompt | Should -Match "NUnit"
            $prompt | Should -Match "\[Test\]"
            $prompt | Should -Match "\[TestCase\]"
            $prompt | Should -Match "NSubstitute"
            $prompt | Should -Match "Substitute\.For<IService>"
            $prompt | Should -Match "Shouldly"
            $prompt | Should -Match "\.ShouldBe\(\)"
            $prompt | Should -Match "Should_Action_When_Condition"
            $prompt | Should -Match "AAA comments are not used"
            $prompt | Should -Match "\[SetUp\]"
            $prompt | Should -Match "feature"
        }
    }
}
