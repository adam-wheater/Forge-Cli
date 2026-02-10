using System.Text.Json.Serialization;

namespace RoslynAnalyser;

// ── Get-CSharpSymbols return structure ──

public class SymbolResult
{
    public string Namespace { get; set; } = "";
    public List<ClassInfo> Classes { get; set; } = new();
}

public class ClassInfo
{
    public string Name { get; set; } = "";
    public string Visibility { get; set; } = "internal";
    public bool Static { get; set; }
    public bool Abstract { get; set; }
    public string BaseClass { get; set; } = "";
    public List<string> Interfaces { get; set; } = new();
    public int Line { get; set; }
    public List<MethodInfo> Methods { get; set; } = new();
    public List<PropertyInfo> Properties { get; set; } = new();
    public List<ConstructorInfo> Constructors { get; set; } = new();
}

public class MethodInfo
{
    public string Name { get; set; } = "";
    public string ReturnType { get; set; } = "";
    public string Visibility { get; set; } = "";
    public bool Static { get; set; }
    public bool Async { get; set; }
    public List<ParamInfo> Parameters { get; set; } = new();
    public int Line { get; set; }
}

public class PropertyInfo
{
    public string Name { get; set; } = "";
    public string Type { get; set; } = "";
    public string Visibility { get; set; } = "";
    public bool Static { get; set; }
    public int Line { get; set; }
}

public class ConstructorInfo
{
    public string Visibility { get; set; } = "";
    public List<ParamInfo> Parameters { get; set; } = new();
    public int Line { get; set; }
}

public class ParamInfo
{
    public string Type { get; set; } = "";
    public string Name { get; set; } = "";
    public bool Nullable { get; set; }
}

// ── Get-CSharpInterface return structure ──

public class InterfaceResult
{
    public string Name { get; set; } = "";
    public string Path { get; set; } = "";
    public List<InterfaceMethodInfo> Methods { get; set; } = new();
}

public class InterfaceMethodInfo
{
    public string Name { get; set; } = "";
    public string ReturnType { get; set; } = "";
    public List<ParamInfo> Parameters { get; set; } = new();
}

// ── Get-NuGetPackages return structure ──

public class NuGetResult
{
    public List<PackageInfo> Packages { get; set; } = new();
    public string TestFramework { get; set; } = "";
    public string MockLibrary { get; set; } = "";
    public string AssertionLibrary { get; set; } = "builtin";
    public List<string> CoverageTools { get; set; } = new();
}

public class PackageInfo
{
    public string Name { get; set; } = "";
    public string Version { get; set; } = "";
}

// ── Get-DIRegistrations return structure ──

public class DiResult
{
    public List<DiRegistration> Registrations { get; set; } = new();
}

public class DiRegistration
{
    public string Interface { get; set; } = "";
    public string Implementation { get; set; } = "";
    public string Lifetime { get; set; } = "";
    public int Line { get; set; }
}

// ── Get-MethodAnalysis return structure ──

public class MethodAnalysisResult
{
    public string Name { get; set; } = "";
    public string ReturnType { get; set; } = "";
    public string Visibility { get; set; } = "";
    public bool Static { get; set; }
    public bool Async { get; set; }
    public bool Virtual { get; set; }
    public bool Override { get; set; }
    public List<string> Attributes { get; set; } = new();
    public List<ParamInfo> Parameters { get; set; } = new();
    public List<ThrowInfo> ThrowStatements { get; set; } = new();
    public int Complexity { get; set; } = 1;
    public bool NullableReturn { get; set; }
    public int Line { get; set; }
    public int EndLine { get; set; }
}

// ── Get-ClassComplexity return structure ──

public class ClassComplexityResult
{
    public string ClassName { get; set; } = "";
    public int InheritanceDepth { get; set; }
    public int DependencyCount { get; set; }
    public int MethodCount { get; set; }
    public int TotalComplexity { get; set; }
    public double AvgComplexity { get; set; }
    public List<MethodComplexityInfo> Methods { get; set; } = new();
}

public class MethodComplexityInfo
{
    public string Name { get; set; } = "";
    public int Complexity { get; set; }
}

// ── Get-ThrowStatements return structure ──

public class ThrowInfo
{
    public string ExceptionType { get; set; } = "";
    public string Message { get; set; } = "";
    public int Line { get; set; }
    public bool IsRethrow { get; set; }
    public string RawLine { get; set; } = "";
}
