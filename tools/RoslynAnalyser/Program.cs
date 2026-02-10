using System.Text.Json;
using System.Text.Json.Serialization;
using RoslynAnalyser.Commands;

namespace RoslynAnalyser;

public static class Program
{
    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        WriteIndented = false,
        DefaultIgnoreCondition = JsonIgnoreCondition.Never,
        PropertyNamingPolicy = null // PascalCase to match PowerShell hashtable keys
    };

    public static int Main(string[] args)
    {
        if (args.Length < 2)
        {
            Console.Error.WriteLine("Usage: RoslynAnalyser <command> <args...>");
            Console.Error.WriteLine("Commands: symbols, interface, nuget, di, methods, complexity, throws");
            return 1;
        }

        try
        {
            var command = args[0].ToLowerInvariant();
            object result = command switch
            {
                "symbols" => SymbolsCommand.Run(args[1]),
                "interface" => InterfaceCommand.Run(args[1], args.Length > 2 ? args[2] : "."),
                "nuget" => NuGetCommand.Run(args[1]),
                "di" => DiCommand.Run(args[1]),
                "methods" => MethodsCommand.Run(args[1]),
                "complexity" => ComplexityCommand.Run(args[1]),
                "throws" => ThrowsCommand.Run(args[1]),
                _ => throw new ArgumentException($"Unknown command: {command}")
            };

            Console.WriteLine(JsonSerializer.Serialize(result, result.GetType(), JsonOptions));
            return 0;
        }
        catch (Exception ex)
        {
            Console.Error.WriteLine($"Error: {ex.Message}");
            return 1;
        }
    }
}
