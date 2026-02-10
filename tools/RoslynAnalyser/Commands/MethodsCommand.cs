using Microsoft.CodeAnalysis;
using Microsoft.CodeAnalysis.CSharp;
using Microsoft.CodeAnalysis.CSharp.Syntax;

namespace RoslynAnalyser.Commands;

public static class MethodsCommand
{
    public static List<MethodAnalysisResult> Run(string filePath)
    {
        var results = new List<MethodAnalysisResult>();
        if (!File.Exists(filePath)) return results;

        var code = File.ReadAllText(filePath);
        var lines = code.Split('\n');
        var tree = CSharpSyntaxTree.ParseText(code);
        var root = tree.GetCompilationUnitRoot();

        foreach (var method in root.DescendantNodes().OfType<MethodDeclarationSyntax>())
        {
            var span = method.GetLocation().GetLineSpan();
            var startLine = span.StartLinePosition.Line + 1;
            var endLine = span.EndLinePosition.Line + 1;

            var result = new MethodAnalysisResult
            {
                Name = method.Identifier.Text,
                ReturnType = method.ReturnType.ToString(),
                Visibility = SymbolsCommand.GetVisibility(method.Modifiers),
                Static = method.Modifiers.Any(SyntaxKind.StaticKeyword),
                Async = method.Modifiers.Any(SyntaxKind.AsyncKeyword),
                Virtual = method.Modifiers.Any(SyntaxKind.VirtualKeyword),
                Override = method.Modifiers.Any(SyntaxKind.OverrideKeyword),
                Parameters = SymbolsCommand.ExtractParameters(method.ParameterList),
                Line = startLine,
                EndLine = endLine,
                NullableReturn = method.ReturnType is NullableTypeSyntax ||
                                 method.ReturnType.ToString().EndsWith("?")
            };

            // Extract attributes
            foreach (var attrList in method.AttributeLists)
            {
                foreach (var attr in attrList.Attributes)
                {
                    result.Attributes.Add(attr.Name.ToString());
                }
            }

            // Find throw statements within this method
            foreach (var throwStmt in method.DescendantNodes().OfType<ThrowStatementSyntax>())
            {
                var throwLine = throwStmt.GetLocation().GetLineSpan().StartLinePosition.Line + 1;
                var rawLine = throwLine <= lines.Length ? lines[throwLine - 1].Trim() : "";

                if (throwStmt.Expression == null)
                {
                    result.ThrowStatements.Add(new ThrowInfo
                    {
                        ExceptionType = "(rethrow)",
                        Line = throwLine,
                        IsRethrow = true,
                        RawLine = rawLine
                    });
                }
                else if (throwStmt.Expression is ObjectCreationExpressionSyntax creation)
                {
                    result.ThrowStatements.Add(new ThrowInfo
                    {
                        ExceptionType = creation.Type.ToString(),
                        Message = ExtractMessage(creation.ArgumentList),
                        Line = throwLine,
                        RawLine = rawLine
                    });
                }
                else
                {
                    result.ThrowStatements.Add(new ThrowInfo
                    {
                        ExceptionType = throwStmt.Expression.ToString(),
                        Line = throwLine,
                        RawLine = rawLine
                    });
                }
            }

            // Also find throw expressions (C# 7+)
            foreach (var throwExpr in method.DescendantNodes().OfType<ThrowExpressionSyntax>())
            {
                var throwLine = throwExpr.GetLocation().GetLineSpan().StartLinePosition.Line + 1;
                var rawLine = throwLine <= lines.Length ? lines[throwLine - 1].Trim() : "";

                if (throwExpr.Expression is ObjectCreationExpressionSyntax creation)
                {
                    result.ThrowStatements.Add(new ThrowInfo
                    {
                        ExceptionType = creation.Type.ToString(),
                        Message = ExtractMessage(creation.ArgumentList),
                        Line = throwLine,
                        RawLine = rawLine
                    });
                }
            }

            // Calculate cyclomatic complexity
            result.Complexity = CalculateComplexity(method);

            results.Add(result);
        }

        return results;
    }

    internal static int CalculateComplexity(SyntaxNode node)
    {
        int complexity = 1; // Base complexity

        foreach (var descendant in node.DescendantNodes())
        {
            switch (descendant)
            {
                case IfStatementSyntax: complexity++; break;
                case ElseClauseSyntax e when e.Statement is IfStatementSyntax: break; // counted as if
                case CaseSwitchLabelSyntax: complexity++; break;
                case CasePatternSwitchLabelSyntax: complexity++; break;
                case ConditionalExpressionSyntax: complexity++; break; // ternary ?:
                case CatchClauseSyntax: complexity++; break;
                case BinaryExpressionSyntax bin:
                    if (bin.IsKind(SyntaxKind.LogicalAndExpression) ||
                        bin.IsKind(SyntaxKind.LogicalOrExpression))
                        complexity++;
                    if (bin.IsKind(SyntaxKind.CoalesceExpression)) // ??
                        complexity++;
                    break;
                case ConditionalAccessExpressionSyntax: complexity++; break; // ?.
                case ForStatementSyntax: complexity++; break;
                case ForEachStatementSyntax: complexity++; break;
                case WhileStatementSyntax: complexity++; break;
                case DoStatementSyntax: complexity++; break;
            }
        }

        return complexity;
    }

    private static string ExtractMessage(ArgumentListSyntax? argList)
    {
        if (argList == null || argList.Arguments.Count == 0) return "";

        var firstArg = argList.Arguments[0].Expression;
        if (firstArg is LiteralExpressionSyntax literal && literal.IsKind(SyntaxKind.StringLiteralExpression))
            return literal.Token.ValueText;

        if (firstArg is InterpolatedStringExpressionSyntax interp)
            return interp.ToString();

        return firstArg.ToString();
    }
}
