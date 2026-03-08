function Detect-TestStyle {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RepoRoot
    )

    if (-not (Test-Path $RepoRoot -PathType Container)) {
        Write-Warning "Detect-TestStyle: RepoRoot '$RepoRoot' does not exist or is not a directory."
        return @{
            TestFramework    = "unknown"
            MockLibrary      = "none"
            AssertionStyle   = "builtin"
            NamingConvention = "Descriptive"
            TestOrganisation = "FeatureGrouped"
            UsesAAAComments  = $false
            AAAPercentage    = 0
            SetupPattern     = "InlineSetup"
            SampleCount      = 0
            TestFiles        = [System.Collections.Generic.List[string]]::new()
        }
    }

    # Scan all *Tests*.cs and *Test*.cs files in the repo
    $testFiles = Get-ChildItem $RepoRoot -Recurse -Filter "*.cs" -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match 'Test' -and $_.FullName -notmatch '[\\/](obj|bin|\.git)[\\/]' }

    if (-not $testFiles -or $testFiles.Count -eq 0) {
        return @{
            TestFramework    = "unknown"
            MockLibrary      = "none"
            AssertionStyle   = "builtin"
            NamingConvention = "Descriptive"
            TestOrganisation = "FeatureGrouped"
            UsesAAAComments  = $false
            AAAPercentage    = 0
            SetupPattern     = "InlineSetup"
            SampleCount      = 0
            TestFiles        = [System.Collections.Generic.List[string]]::new()
        }
    }

    $testFilePaths = [System.Collections.Generic.List[string]]::new()
    foreach ($f in $testFiles) { $testFilePaths.Add($f.FullName) }

    # Read all test file contents
    $allContents = [System.Collections.Generic.List[hashtable]]::new()
    foreach ($f in $testFiles) {
        $content = Get-Content $f.FullName -Raw -ErrorAction SilentlyContinue
        if ($content) {
            $allContents.Add(@{ Path = $f.FullName; Content = $content; Name = $f.Name; BaseName = $f.BaseName })
        }
    }

    if ($allContents.Count -eq 0) {
        return @{
            TestFramework    = "unknown"
            MockLibrary      = "none"
            AssertionStyle   = "builtin"
            NamingConvention = "Descriptive"
            TestOrganisation = "FeatureGrouped"
            UsesAAAComments  = $false
            AAAPercentage    = 0
            SetupPattern     = "InlineSetup"
            SampleCount      = 0
            TestFiles        = $testFilePaths
        }
    }

    $allText = ($allContents | ForEach-Object { $_.Content }) -join "`n"

    # -------------------------------------------------------
    # 1. Test Framework Detection
    # -------------------------------------------------------
    $frameworkCounts = @{
        xunit  = 0
        nunit  = 0
        mstest = 0
    }
    $frameworkCounts.xunit  = ([regex]::Matches($allText, '\[Fact\]|\[Theory\]|\[InlineData\b')).Count
    $frameworkCounts.nunit  = ([regex]::Matches($allText, '\[Test\]|\[TestCase\b|\[TestFixture\]|\[SetUp\]|\[TearDown\]')).Count
    $frameworkCounts.mstest = ([regex]::Matches($allText, '\[TestMethod\]|\[TestClass\]|\[DataRow\b|\[TestInitialize\]')).Count

    $testFramework = "unknown"
    $maxFramework = ($frameworkCounts.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First 1)
    if ($maxFramework.Value -gt 0) {
        $testFramework = $maxFramework.Name
    }

    # -------------------------------------------------------
    # 2. Mock Library Detection
    # -------------------------------------------------------
    $mockCounts = @{
        moq          = 0
        nsubstitute  = 0
        fakeiteasy   = 0
    }
    $mockCounts.moq         = ([regex]::Matches($allText, 'new\s+Mock<|Mock<|\.Setup\(|\.Verify\(|It\.IsAny<|\.Object\b')).Count
    $mockCounts.nsubstitute = ([regex]::Matches($allText, 'Substitute\.For<|\.Returns\(|\.Received\(')).Count
    $mockCounts.fakeiteasy  = ([regex]::Matches($allText, 'A\.Fake<|A\.CallTo\(')).Count

    $mockLibrary = "none"
    $maxMock = ($mockCounts.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First 1)
    if ($maxMock.Value -gt 0) {
        $mockLibrary = $maxMock.Name
    }

    # -------------------------------------------------------
    # 3. Assertion Style Detection
    # -------------------------------------------------------
    $assertCounts = @{
        fluentassertions = 0
        shouldly         = 0
        builtin          = 0
    }
    $assertCounts.fluentassertions = ([regex]::Matches($allText, '\.Should\(\)|\.BeEquivalentTo\(|\.BeTrue\(|\.HaveCount\(')).Count
    $assertCounts.shouldly         = ([regex]::Matches($allText, '\.ShouldBe\(|\.ShouldNotBeNull\(|\.ShouldThrow\(')).Count
    # Built-in assertions (xUnit, NUnit, MSTest)
    $assertCounts.builtin          = ([regex]::Matches($allText, 'Assert\.Equal\(|Assert\.True\(|Assert\.Throws<|Assert\.That\(|Is\.EqualTo\(|Assert\.AreEqual\(|Assert\.IsTrue\(')).Count

    $assertionStyle = "builtin"
    $maxAssert = ($assertCounts.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First 1)
    if ($maxAssert.Value -gt 0) {
        $assertionStyle = $maxAssert.Name
    }

    # -------------------------------------------------------
    # 4. Naming Convention Detection
    # -------------------------------------------------------
    # Extract test method names (methods decorated with [Fact], [Test], [TestMethod], or [Theory])
    $methodNamePattern = '(?:\[(?:Fact|Test|TestMethod|Theory)\]\s*(?:\[.*?\]\s*)*)(?:public\s+(?:async\s+)?(?:void|Task)\s+)(\w+)\s*\('
    $methodMatches = [regex]::Matches($allText, $methodNamePattern, [System.Text.RegularExpressions.RegexOptions]::Singleline)

    $namingCounts = @{
        "MethodName_Scenario_Expected"      = 0
        "Should_Action_When_Condition"       = 0
        "GivenWhenThen"                      = 0
        "Descriptive"                        = 0
    }

    $sampleCount = $methodMatches.Count

    foreach ($mm in $methodMatches) {
        $methodName = $mm.Groups[1].Value
        if ($methodName -match 'Given_\w+_When_\w+_Then_\w+') {
            $namingCounts["GivenWhenThen"]++
        } elseif ($methodName -match 'Should\w+_When\w+' -or $methodName -match '^Should_\w+') {
            $namingCounts["Should_Action_When_Condition"]++
        } elseif ($methodName -match '^\w+_\w+_\w+') {
            $namingCounts["MethodName_Scenario_Expected"]++
        } else {
            $namingCounts["Descriptive"]++
        }
    }

    $namingConvention = "Descriptive"
    $maxNaming = ($namingCounts.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First 1)
    if ($maxNaming.Value -gt 0) {
        $namingConvention = $maxNaming.Name
    }

    # -------------------------------------------------------
    # 5. Test Organisation Detection
    # -------------------------------------------------------
    # Get all non-test C# class files
    $implFiles = Get-ChildItem $RepoRoot -Recurse -Filter "*.cs" -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -notmatch 'Test' -and $_.FullName -notmatch '[\\/](obj|bin|\.git)[\\/]' }
    $implClassNames = [System.Collections.Generic.List[string]]::new()
    if ($implFiles) {
        foreach ($f in $implFiles) { $implClassNames.Add($f.BaseName) }
    }

    $mappedCount = 0
    $totalTestClasses = 0
    foreach ($tc in $allContents) {
        # Extract class names from test files
        $classMatches = [regex]::Matches($tc.Content, 'class\s+(\w+)')
        foreach ($cm in $classMatches) {
            $totalTestClasses++
            $testClassName = $cm.Groups[1].Value
            # Strip common suffixes to find the SUT name
            $sutName = $testClassName -replace '(Tests|Test|Spec|Specs)$', ''
            if ($sutName -and $implClassNames -contains $sutName) {
                $mappedCount++
            }
        }
    }

    $testOrganisation = "FeatureGrouped"
    if ($totalTestClasses -gt 0 -and $mappedCount -gt ($totalTestClasses / 2)) {
        $testOrganisation = "OneClassPerSUT"
    }

    # -------------------------------------------------------
    # 6. AAA Comments Detection
    # -------------------------------------------------------
    $methodBodies = [regex]::Matches($allText, '(?:\[(?:Fact|Test|TestMethod|Theory)\][\s\S]*?)(?:public\s+(?:async\s+)?(?:void|Task)\s+\w+\s*\([^)]*\)\s*\{)([\s\S]*?\n\s*\})', [System.Text.RegularExpressions.RegexOptions]::None)

    $aaaCount = 0
    $totalMethodsForAAA = 0

    # Simpler approach: split by test methods and check for AAA comments
    # Count methods that have at least 2 of the 3 AAA comment markers
    $arrangePattern = '//\s*Arrange'
    $actPattern = '//\s*Act'
    $assertPattern = '//\s*Assert'

    # Count total arrange/act/assert comment blocks
    $arrangeMatches = ([regex]::Matches($allText, $arrangePattern)).Count
    $actMatches = ([regex]::Matches($allText, $actPattern)).Count
    $assertMatches = ([regex]::Matches($allText, $assertPattern)).Count

    # A complete AAA block = min of all three counts (rough estimate per method)
    $aaaBlocks = [Math]::Min($arrangeMatches, [Math]::Min($actMatches, $assertMatches))
    $totalMethodsForAAA = $sampleCount

    $aaaPercentage = 0
    $usesAAAComments = $false
    if ($totalMethodsForAAA -gt 0) {
        $aaaPercentage = [Math]::Round(($aaaBlocks / $totalMethodsForAAA) * 100)
        if ($aaaPercentage -gt 100) { $aaaPercentage = 100 }
        $usesAAAComments = $aaaPercentage -ge 25
    }

    # -------------------------------------------------------
    # 7. Test Class Setup Pattern Detection
    # -------------------------------------------------------
    $setupCounts = @{
        ConstructorSetup = 0
        SetUpMethod      = 0
        InlineSetup      = 0
    }

    foreach ($tc in $allContents) {
        $c = $tc.Content
        # Check for [SetUp] or [TestInitialize] methods
        if ($c -match '\[SetUp\]' -or $c -match '\[TestInitialize\]') {
            $setupCounts.SetUpMethod++
        }
        # Check for constructor that contains mock setup (xUnit pattern)
        # Look for constructors that contain "new Mock<" or "Substitute.For<"
        elseif ($c -match 'public\s+\w+Tests?\s*\(' -and ($c -match 'new\s+Mock<' -or $c -match 'Substitute\.For<' -or $c -match 'A\.Fake<')) {
            $setupCounts.ConstructorSetup++
        }
        else {
            $setupCounts.InlineSetup++
        }
    }

    $setupPattern = "InlineSetup"
    $maxSetup = ($setupCounts.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First 1)
    if ($maxSetup.Value -gt 0) {
        $setupPattern = $maxSetup.Name
    }

    # -------------------------------------------------------
    # Return results
    # -------------------------------------------------------
    return @{
        TestFramework    = $testFramework
        MockLibrary      = $mockLibrary
        AssertionStyle   = $assertionStyle
        NamingConvention = $namingConvention
        TestOrganisation = $testOrganisation
        UsesAAAComments  = $usesAAAComments
        AAAPercentage    = $aaaPercentage
        SetupPattern     = $setupPattern
        SampleCount      = $sampleCount
        TestFiles        = $testFilePaths
    }
}

function Get-TestStylePrompt {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Style
    )

    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add("TEST_STYLE:")

    # Framework instruction
    switch ($Style.TestFramework) {
        "xunit" {
            $lines.Add("This project uses xUnit with [Fact] and [Theory] attributes.")
        }
        "nunit" {
            $lines.Add("This project uses NUnit with [Test] and [TestCase] attributes.")
        }
        "mstest" {
            $lines.Add("This project uses MSTest with [TestMethod] and [TestClass] attributes.")
        }
        default {
            $lines.Add("No test framework detected. Use xUnit with [Fact] and [Theory] attributes by default.")
        }
    }

    # Mock library instruction
    switch ($Style.MockLibrary) {
        "moq" {
            $lines.Add("Mocking: Use Moq (new Mock<IService>(), .Setup(), .Verify(), It.IsAny<T>()).")
        }
        "nsubstitute" {
            $lines.Add("Mocking: Use NSubstitute (Substitute.For<IService>(), .Returns(), .Received()).")
        }
        "fakeiteasy" {
            $lines.Add("Mocking: Use FakeItEasy (A.Fake<IService>(), A.CallTo()).")
        }
        default {
            $lines.Add("Mocking: No mocking library detected. Use Moq if mocking is needed.")
        }
    }

    # Assertion style instruction
    switch ($Style.AssertionStyle) {
        "fluentassertions" {
            $lines.Add("Assertions: Use FluentAssertions (.Should().Be(), .Should().NotBeNull()).")
        }
        "shouldly" {
            $lines.Add("Assertions: Use Shouldly (.ShouldBe(), .ShouldNotBeNull()).")
        }
        default {
            $lines.Add("Assertions: Use built-in framework assertions (Assert.Equal(), Assert.True(), etc.).")
        }
    }

    # Naming convention instruction
    switch ($Style.NamingConvention) {
        "MethodName_Scenario_Expected" {
            $lines.Add("Naming: Use MethodName_Scenario_ExpectedResult pattern (e.g., CreateUser_ValidInput_ReturnsUser).")
        }
        "Should_Action_When_Condition" {
            $lines.Add("Naming: Use Should_Action_When_Condition pattern (e.g., ShouldCreateUser_WhenInputIsValid).")
        }
        "GivenWhenThen" {
            $lines.Add("Naming: Use Given_When_Then pattern (e.g., Given_ValidInput_When_CreateUser_Then_ReturnsUser).")
        }
        default {
            $lines.Add("Naming: Use descriptive method names in plain English (e.g., CreatesUserWithValidInput).")
        }
    }

    # AAA pattern instruction
    if ($Style.UsesAAAComments) {
        $lines.Add("Structure: Follow Arrange-Act-Assert pattern with // Arrange, // Act, // Assert comments.")
    } else {
        $lines.Add("Structure: Follow Arrange-Act-Assert pattern (AAA comments are not used in this project).")
    }

    # Setup pattern instruction
    switch ($Style.SetupPattern) {
        "ConstructorSetup" {
            $lines.Add("Setup: Create mocks in the test class constructor (xUnit pattern - no [SetUp] method).")
        }
        "SetUpMethod" {
            $lines.Add("Setup: Use [SetUp] or [TestInitialize] method for shared mock configuration.")
        }
        default {
            $lines.Add("Setup: Each test method sets up its own mocks and dependencies inline.")
        }
    }

    # Organisation instruction
    switch ($Style.TestOrganisation) {
        "OneClassPerSUT" {
            $lines.Add("Organisation: One test class per class under test (e.g., UserServiceTests for UserService).")
        }
        default {
            $lines.Add("Organisation: Tests are grouped by feature rather than one-to-one with implementation classes.")
        }
    }

    return ($lines -join "`n")
}
