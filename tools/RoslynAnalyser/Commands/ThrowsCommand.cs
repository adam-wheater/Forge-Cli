using Microsoft.CodeAnalysis.CSharp;
using Microsoft.CodeAnalysis.CSharp.Syntax;

namespace RoslynAnalyser.Commands;

public static class ThrowsCommand
{
    public static List<ThrowInfo> Run(string filePath)
    {
        var results = new List<ThrowInfo>();
        if (!File.Exists(filePath)) return results;

        var code = File.ReadAllText(filePath);
        var lines = code.Split('\n');
        var tree = CSharpSyntaxTree.ParseText(code);
        var root = tree.GetCompilationUnitRoot();

        // Find all throw statements
        foreach (var throwStmt in root.DescendantNodes().OfType<ThrowStatementSyntax>())
        {
            var line = throwStmt.GetLocation().GetLineSpan().StartLinePosition.Line + 1;
            var rawLine = line <= lines.Length ? lines[line - 1].Trim() : "";

            if (throwStmt.Expression == null)
            {
                // Bare rethrow: throw;
                results.Add(new ThrowInfo
                {
                    ExceptionType = "(rethrow)",
                    Line = line,
                    IsRethrow = true,
                    RawLine = rawLine
                });
            }
            else if (throwStmt.Expression is ObjectCreationExpressionSyntax creation)
            {
                results.Add(new ThrowInfo
                {
                    ExceptionType = creation.Type.ToString(),
                    Message = ExtractMessage(creation.ArgumentList),
                    Line = line,
                    RawLine = rawLine
                });
            }
            else
            {
                // throw someVariable;
                results.Add(new ThrowInfo
                {
                    ExceptionType = throwStmt.Expression.ToString(),
                    Line = line,
                    RawLine = rawLine
                });
            }
        }

        // Find all throw expressions (C# 7+): x ?? throw new ...
        foreach (var throwExpr in root.DescendantNodes().OfType<ThrowExpressionSyntax>())
        {
            var line = throwExpr.GetLocation().GetLineSpan().StartLinePosition.Line + 1;
            var rawLine = line <= lines.Length ? lines[line - 1].Trim() : "";

            if (throwExpr.Expression is ObjectCreationExpressionSyntax creation)
            {
                results.Add(new ThrowInfo
                {
                    ExceptionType = creation.Type.ToString(),
                    Message = ExtractMessage(creation.ArgumentList),
                    Line = line,
                    RawLine = rawLine
                });
            }
            else
            {
                results.Add(new ThrowInfo
                {
                    ExceptionType = throwExpr.Expression.ToString(),
                    Line = line,
                    RawLine = rawLine
                });
            }
        }

        return results.OrderBy(t => t.Line).ToList();
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
