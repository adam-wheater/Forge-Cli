using Microsoft.CodeAnalysis.CSharp;
using Microsoft.CodeAnalysis.CSharp.Syntax;

namespace RoslynAnalyser.Commands;

public static class InterfaceCommand
{
    private static readonly string[] ExcludeDirs = { "bin", "obj", "node_modules", ".git", ".vs" };

    public static InterfaceResult Run(string interfaceName, string repoRoot)
    {
        var csFiles = FindCSharpFiles(repoRoot);

        foreach (var file in csFiles)
        {
            try
            {
                var code = File.ReadAllText(file);
                // Quick text check before parsing
                if (!code.Contains(interfaceName)) continue;

                var tree = CSharpSyntaxTree.ParseText(code);
                var root = tree.GetCompilationUnitRoot();

                foreach (var iface in root.DescendantNodes().OfType<InterfaceDeclarationSyntax>())
                {
                    if (iface.Identifier.Text != interfaceName) continue;

                    var result = new InterfaceResult
                    {
                        Name = interfaceName,
                        Path = Path.GetRelativePath(repoRoot, file)
                    };

                    // Extract method signatures
                    foreach (var method in iface.Members.OfType<MethodDeclarationSyntax>())
                    {
                        result.Methods.Add(new InterfaceMethodInfo
                        {
                            Name = method.Identifier.Text,
                            ReturnType = method.ReturnType.ToString(),
                            Parameters = SymbolsCommand.ExtractParameters(method.ParameterList)
                        });
                    }

                    return result;
                }
            }
            catch
            {
                // Skip unparseable files
            }
        }

        return new InterfaceResult(); // Not found
    }

    private static IEnumerable<string> FindCSharpFiles(string root)
    {
        if (!Directory.Exists(root)) yield break;

        var stack = new Stack<string>();
        stack.Push(root);

        while (stack.Count > 0)
        {
            var dir = stack.Pop();
            var dirName = Path.GetFileName(dir);
            if (ExcludeDirs.Contains(dirName, StringComparer.OrdinalIgnoreCase)) continue;

            string[] files;
            try { files = Directory.GetFiles(dir, "*.cs"); }
            catch { continue; }

            foreach (var f in files) yield return f;

            string[] subdirs;
            try { subdirs = Directory.GetDirectories(dir); }
            catch { continue; }

            foreach (var sd in subdirs) stack.Push(sd);
        }
    }
}
