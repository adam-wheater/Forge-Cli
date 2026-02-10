using Microsoft.CodeAnalysis;
using Microsoft.CodeAnalysis.CSharp;
using Microsoft.CodeAnalysis.CSharp.Syntax;

namespace RoslynAnalyser.Commands;

public static class SymbolsCommand
{
    public static SymbolResult Run(string filePath)
    {
        var result = new SymbolResult();
        if (!File.Exists(filePath)) return result;

        var code = File.ReadAllText(filePath);
        var tree = CSharpSyntaxTree.ParseText(code);
        var root = tree.GetCompilationUnitRoot();

        // Extract namespace (handles both block and file-scoped)
        var nsDecl = root.DescendantNodes().OfType<BaseNamespaceDeclarationSyntax>().FirstOrDefault();
        if (nsDecl != null)
            result.Namespace = nsDecl.Name.ToString();

        // Extract all class declarations
        foreach (var classDecl in root.DescendantNodes().OfType<ClassDeclarationSyntax>())
        {
            var classInfo = new ClassInfo
            {
                Name = classDecl.Identifier.Text,
                Line = classDecl.GetLocation().GetLineSpan().StartLinePosition.Line + 1,
                Visibility = GetVisibility(classDecl.Modifiers),
                Static = classDecl.Modifiers.Any(SyntaxKind.StaticKeyword),
                Abstract = classDecl.Modifiers.Any(SyntaxKind.AbstractKeyword),
            };

            // Parse base list
            if (classDecl.BaseList != null)
            {
                foreach (var baseType in classDecl.BaseList.Types)
                {
                    var typeName = baseType.Type.ToString();
                    // Heuristic: interfaces start with I + uppercase letter
                    if (typeName.Length > 1 && typeName[0] == 'I' && char.IsUpper(typeName[1]))
                        classInfo.Interfaces.Add(typeName);
                    else if (string.IsNullOrEmpty(classInfo.BaseClass))
                        classInfo.BaseClass = typeName;
                    else
                        classInfo.Interfaces.Add(typeName); // additional non-I types go to interfaces
                }
            }

            // Extract constructors
            foreach (var ctor in classDecl.Members.OfType<ConstructorDeclarationSyntax>())
            {
                classInfo.Constructors.Add(new ConstructorInfo
                {
                    Visibility = GetVisibility(ctor.Modifiers),
                    Parameters = ExtractParameters(ctor.ParameterList),
                    Line = ctor.GetLocation().GetLineSpan().StartLinePosition.Line + 1
                });
            }

            // Extract methods (exclude constructors — already handled)
            foreach (var method in classDecl.Members.OfType<MethodDeclarationSyntax>())
            {
                classInfo.Methods.Add(new MethodInfo
                {
                    Name = method.Identifier.Text,
                    ReturnType = method.ReturnType.ToString(),
                    Visibility = GetVisibility(method.Modifiers),
                    Static = method.Modifiers.Any(SyntaxKind.StaticKeyword),
                    Async = method.Modifiers.Any(SyntaxKind.AsyncKeyword),
                    Parameters = ExtractParameters(method.ParameterList),
                    Line = method.GetLocation().GetLineSpan().StartLinePosition.Line + 1
                });
            }

            // Extract properties
            foreach (var prop in classDecl.Members.OfType<PropertyDeclarationSyntax>())
            {
                classInfo.Properties.Add(new PropertyInfo
                {
                    Name = prop.Identifier.Text,
                    Type = prop.Type.ToString(),
                    Visibility = GetVisibility(prop.Modifiers),
                    Static = prop.Modifiers.Any(SyntaxKind.StaticKeyword),
                    Line = prop.GetLocation().GetLineSpan().StartLinePosition.Line + 1
                });
            }

            result.Classes.Add(classInfo);
        }

        return result;
    }

    internal static string GetVisibility(SyntaxTokenList modifiers)
    {
        if (modifiers.Any(SyntaxKind.PublicKeyword)) return "public";
        if (modifiers.Any(SyntaxKind.PrivateKeyword) && modifiers.Any(SyntaxKind.ProtectedKeyword)) return "private protected";
        if (modifiers.Any(SyntaxKind.ProtectedKeyword) && modifiers.Any(SyntaxKind.InternalKeyword)) return "protected internal";
        if (modifiers.Any(SyntaxKind.PrivateKeyword)) return "private";
        if (modifiers.Any(SyntaxKind.ProtectedKeyword)) return "protected";
        if (modifiers.Any(SyntaxKind.InternalKeyword)) return "internal";
        return "private"; // C# default
    }

    internal static List<ParamInfo> ExtractParameters(ParameterListSyntax? paramList)
    {
        var result = new List<ParamInfo>();
        if (paramList == null) return result;

        foreach (var param in paramList.Parameters)
        {
            var typeName = param.Type?.ToString() ?? "object";
            var isNullable = param.Type is NullableTypeSyntax ||
                             typeName.EndsWith("?") ||
                             typeName.StartsWith("Nullable<");

            result.Add(new ParamInfo
            {
                Type = typeName,
                Name = param.Identifier.Text,
                Nullable = isNullable
            });
        }

        return result;
    }
}
