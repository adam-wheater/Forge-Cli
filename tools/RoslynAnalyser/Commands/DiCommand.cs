using Microsoft.CodeAnalysis.CSharp;
using Microsoft.CodeAnalysis.CSharp.Syntax;

namespace RoslynAnalyser.Commands;

public static class DiCommand
{
    private static readonly string[] DiFileNames = { "Startup.cs", "Program.cs" };
    private static readonly string[] DiMethods = { "AddScoped", "AddTransient", "AddSingleton" };

    public static DiResult Run(string repoRoot)
    {
        var result = new DiResult();

        // Find Startup.cs and Program.cs files
        var diFiles = FindDiFiles(repoRoot);

        foreach (var file in diFiles)
        {
            try
            {
                var code = File.ReadAllText(file);
                var tree = CSharpSyntaxTree.ParseText(code);
                var root = tree.GetCompilationUnitRoot();

                // Find all invocation expressions
                foreach (var invocation in root.DescendantNodes().OfType<InvocationExpressionSyntax>())
                {
                    if (invocation.Expression is not MemberAccessExpressionSyntax memberAccess) continue;

                    var methodName = memberAccess.Name.Identifier.Text;

                    // Check for AddScoped/AddTransient/AddSingleton
                    if (!DiMethods.Contains(methodName)) continue;

                    // Check for generic type arguments: AddScoped<IService, Impl>()
                    if (memberAccess.Name is GenericNameSyntax generic && generic.TypeArgumentList.Arguments.Count == 2)
                    {
                        result.Registrations.Add(new DiRegistration
                        {
                            Interface = generic.TypeArgumentList.Arguments[0].ToString(),
                            Implementation = generic.TypeArgumentList.Arguments[1].ToString(),
                            Lifetime = methodName.Replace("Add", ""),
                            Line = invocation.GetLocation().GetLineSpan().StartLinePosition.Line + 1
                        });
                        continue;
                    }

                    // Check for typeof pattern: AddScoped(typeof(IService), typeof(Impl))
                    var args = invocation.ArgumentList.Arguments;
                    if (args.Count == 2 &&
                        args[0].Expression is TypeOfExpressionSyntax typeofA &&
                        args[1].Expression is TypeOfExpressionSyntax typeofB)
                    {
                        result.Registrations.Add(new DiRegistration
                        {
                            Interface = typeofA.Type.ToString(),
                            Implementation = typeofB.Type.ToString(),
                            Lifetime = methodName.Replace("Add", ""),
                            Line = invocation.GetLocation().GetLineSpan().StartLinePosition.Line + 1
                        });
                        continue;
                    }

                    // Check for AddDbContext<T> and AddHttpClient<T, TImpl>
                    if (methodName == "AddDbContext" || methodName == "AddHttpClient")
                    {
                        if (memberAccess.Name is GenericNameSyntax gen)
                        {
                            var typeArgs = gen.TypeArgumentList.Arguments;
                            if (typeArgs.Count >= 1)
                            {
                                result.Registrations.Add(new DiRegistration
                                {
                                    Interface = typeArgs.Count > 1 ? typeArgs[0].ToString() : typeArgs[0].ToString(),
                                    Implementation = typeArgs.Count > 1 ? typeArgs[1].ToString() : typeArgs[0].ToString(),
                                    Lifetime = methodName == "AddDbContext" ? "Scoped" : "Transient",
                                    Line = invocation.GetLocation().GetLineSpan().StartLinePosition.Line + 1
                                });
                            }
                        }
                    }
                }
            }
            catch
            {
                // Skip unparseable files
            }
        }

        return result;
    }

    private static IEnumerable<string> FindDiFiles(string root)
    {
        if (!Directory.Exists(root)) yield break;

        foreach (var file in Directory.EnumerateFiles(root, "*.cs", SearchOption.AllDirectories))
        {
            var dir = Path.GetDirectoryName(file) ?? "";
            if (dir.Contains("bin") || dir.Contains("obj") || dir.Contains("node_modules")) continue;

            var fileName = Path.GetFileName(file);
            if (DiFileNames.Contains(fileName, StringComparer.OrdinalIgnoreCase))
                yield return file;

            // Also check for files with "ServiceCollection" extension methods
            if (fileName.Contains("Extension", StringComparison.OrdinalIgnoreCase) ||
                fileName.Contains("Registration", StringComparison.OrdinalIgnoreCase) ||
                fileName.Contains("DependencyInjection", StringComparison.OrdinalIgnoreCase))
                yield return file;
        }
    }
}
