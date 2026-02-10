using System.Xml.Linq;

namespace RoslynAnalyser.Commands;

public static class NuGetCommand
{
    public static NuGetResult Run(string csprojPath)
    {
        var result = new NuGetResult();
        if (!File.Exists(csprojPath)) return result;

        try
        {
            var doc = XDocument.Load(csprojPath);

            // Extract PackageReference elements
            var packageRefs = doc.Descendants()
                .Where(e => e.Name.LocalName == "PackageReference");

            foreach (var pkg in packageRefs)
            {
                var name = pkg.Attribute("Include")?.Value ?? "";
                var version = pkg.Attribute("Version")?.Value
                              ?? pkg.Element(XName.Get("Version", pkg.Name.NamespaceName))?.Value
                              ?? "";

                if (string.IsNullOrEmpty(name)) continue;

                result.Packages.Add(new PackageInfo { Name = name, Version = version });

                // Detect framework, mock, assertion, coverage by package name
                var lower = name.ToLowerInvariant();
                DetectTestEcosystem(lower, result);
            }

            // Default assertion library if none detected
            if (string.IsNullOrEmpty(result.AssertionLibrary) || result.AssertionLibrary == "builtin")
                result.AssertionLibrary = "builtin";
        }
        catch (Exception ex)
        {
            Console.Error.WriteLine($"NuGet parse error: {ex.Message}");
        }

        return result;
    }

    private static void DetectTestEcosystem(string packageNameLower, NuGetResult result)
    {
        // Test frameworks
        if (packageNameLower.Contains("xunit")) result.TestFramework = "xunit";
        else if (packageNameLower.Contains("nunit")) result.TestFramework = "nunit";
        else if (packageNameLower.Contains("mstest.testframework")) result.TestFramework = "mstest";

        // Mock libraries
        if (packageNameLower == "moq") result.MockLibrary = "moq";
        else if (packageNameLower == "nsubstitute") result.MockLibrary = "nsubstitute";
        else if (packageNameLower == "fakeiteasy") result.MockLibrary = "fakeiteasy";

        // Assertion libraries
        if (packageNameLower == "fluentassertions") result.AssertionLibrary = "fluentassertions";
        else if (packageNameLower == "shouldly") result.AssertionLibrary = "shouldly";

        // Coverage tools
        if (packageNameLower.Contains("coverlet")) result.CoverageTools.Add("coverlet");
        if (packageNameLower.Contains("stryker")) result.CoverageTools.Add("stryker");
    }
}
