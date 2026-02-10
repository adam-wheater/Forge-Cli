using Microsoft.CodeAnalysis.CSharp;
using Microsoft.CodeAnalysis.CSharp.Syntax;

namespace RoslynAnalyser.Commands;

public static class ComplexityCommand
{
    public static List<ClassComplexityResult> Run(string filePath)
    {
        var results = new List<ClassComplexityResult>();
        if (!File.Exists(filePath)) return results;

        var code = File.ReadAllText(filePath);
        var tree = CSharpSyntaxTree.ParseText(code);
        var root = tree.GetCompilationUnitRoot();

        // Get method analysis for the file
        var methodAnalysis = MethodsCommand.Run(filePath);

        foreach (var classDecl in root.DescendantNodes().OfType<ClassDeclarationSyntax>())
        {
            var className = classDecl.Identifier.Text;

            // Count inheritance depth (non-interface base types)
            int inheritanceDepth = 0;
            if (classDecl.BaseList != null)
            {
                foreach (var baseType in classDecl.BaseList.Types)
                {
                    var name = baseType.Type.ToString();
                    // Skip interfaces (start with I + uppercase)
                    if (!(name.Length > 1 && name[0] == 'I' && char.IsUpper(name[1])))
                        inheritanceDepth++;
                }
            }

            // Count constructor dependencies (parameters of the largest constructor)
            int dependencyCount = 0;
            var constructors = classDecl.Members.OfType<ConstructorDeclarationSyntax>().ToList();
            if (constructors.Count > 0)
            {
                dependencyCount = constructors.Max(c => c.ParameterList.Parameters.Count);
            }

            // Get methods belonging to this class by line range
            var classStart = classDecl.GetLocation().GetLineSpan().StartLinePosition.Line + 1;
            var classEnd = classDecl.GetLocation().GetLineSpan().EndLinePosition.Line + 1;

            var classMethods = methodAnalysis
                .Where(m => m.Line >= classStart && m.EndLine <= classEnd)
                .ToList();

            int totalComplexity = classMethods.Sum(m => m.Complexity);
            double avgComplexity = classMethods.Count > 0 ? (double)totalComplexity / classMethods.Count : 0;

            results.Add(new ClassComplexityResult
            {
                ClassName = className,
                InheritanceDepth = inheritanceDepth,
                DependencyCount = dependencyCount,
                MethodCount = classMethods.Count,
                TotalComplexity = totalComplexity,
                AvgComplexity = Math.Round(avgComplexity, 2),
                Methods = classMethods.Select(m => new MethodComplexityInfo
                {
                    Name = m.Name,
                    Complexity = m.Complexity
                }).ToList()
            });
        }

        return results;
    }
}
