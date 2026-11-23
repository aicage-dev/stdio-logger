# Generic, binary-safe STDIO traffic logger for Windows PowerShell 5.1 and PowerShell 7+.
# Usage: powershell.exe -NoProfile -File .\stdio-proxy.ps1 COMMAND [ARG ...]
param(
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]] $CommandLine
)

if (-not $CommandLine -or $CommandLine.Count -eq 0) {
    [Console]::Error.WriteLine('Usage: stdio-proxy.ps1 COMMAND [ARG ...]')
    exit 2
}

$ErrorActionPreference = 'Stop'
$logDir = Join-Path $PSScriptRoot 'logs'
New-Item -ItemType Directory -Force -Path $logDir | Out-Null
$runId = [guid]::NewGuid().ToString()
$argsLog = Join-Path $logDir "$runId.args.log"
$trafficLog = Join-Path $logDir "$runId.traffic.log"

$info = @(
    "Run ID: $runId"
    "Started: $([DateTimeOffset]::Now.ToString('o'))"
    "Working directory: $((Get-Location).ProviderPath)"
    "Argument count: $($CommandLine.Count)"
)
for ($i = 0; $i -lt $CommandLine.Count; $i++) {
    $info += "Argument $($i + 1): <$($CommandLine[$i])>"
}
[System.IO.File]::WriteAllLines($argsLog, [string[]]$info)

# PowerShell scriptblocks cannot safely run on arbitrary background threads.
# Use a small, in-memory C# helper for the two simultaneous byte-stream copies.
Add-Type -TypeDefinition @'
using System;
using System.Diagnostics;
using System.IO;
using System.Text;
using System.Threading;

public static class StdioTrafficProxy
{
    // Quote an argument according to Windows CommandLineToArgvW-style rules.
    // ProcessStartInfo.ArgumentList is not available on .NET Framework / PS 5.1.
    public static string Quote(string arg)
    {
        if (arg.Length > 0 && arg.IndexOfAny(new char[] {' ', '\t', '\n', '\v', '"'}) < 0)
            return arg;

        var result = new StringBuilder("\"");
        int slashes = 0;
        foreach (char c in arg)
        {
            if (c == '\\') { slashes++; continue; }
            if (c == '"')
            {
                result.Append('\\', slashes * 2 + 1);
                result.Append('"');
            }
            else
            {
                result.Append('\\', slashes);
                result.Append(c);
            }
            slashes = 0;
        }
        result.Append('\\', slashes * 2);
        result.Append('"');
        return result.ToString();
    }

    private static void Relay(Stream source, Stream destination, StreamWriter log,
                              object logLock, char direction)
    {
        byte[] buffer = new byte[8192];
        try
        {
            int count;
            while ((count = source.Read(buffer, 0, buffer.Length)) > 0)
            {
                // Forward the exact bytes; log separately. Never decode/re-encode traffic.
                destination.Write(buffer, 0, count);
                destination.Flush();

                // Human-readable, reversible representation of each chunk.
                var line = new StringBuilder(count * 2 + 64);
                line.Append(direction).Append(' ');
                for (int i = 0; i < count; i++)
                {
                    byte b = buffer[i];
                    switch (b)
                    {
                        case (byte)'\\': line.Append("\\\\"); break;
                        case (byte)'\n': line.Append("\\n"); break;
                        case (byte)'\r': line.Append("\\r"); break;
                        case (byte)'\t': line.Append("\\t"); break;
                        default:
                            if (b >= 32 && b <= 126) line.Append((char)b);
                            else line.Append("\\x").Append(b.ToString("x2"));
                            break;
                    }
                }
                lock (logLock)
                {
                    try
                    {
                        log.WriteLine(line.ToString());
                        log.Flush();
                    }
                    catch (ObjectDisposedException) { return; /* Child already exited. */ }
                }
            }
        }
        catch (IOException) { /* Peer closed its pipe. */ }
        catch (ObjectDisposedException) { /* Child exited while stdin was still open. */ }
        finally
        {
            try { destination.Flush(); } catch (IOException) { } catch (ObjectDisposedException) { }
            if (direction == '>')
            {
                try { destination.Close(); } catch (IOException) { } catch (ObjectDisposedException) { }
            }
        }
    }

    public static int Run(string executable, string[] args, string workingDirectory, string logPath)
    {
        var start = new ProcessStartInfo();
        start.FileName = executable;
        var joinedArgs = new StringBuilder();
        foreach (string arg in args)
        {
            if (joinedArgs.Length > 0) joinedArgs.Append(' ');
            joinedArgs.Append(Quote(arg));
        }
        start.Arguments = joinedArgs.ToString();
        start.WorkingDirectory = workingDirectory;
        start.UseShellExecute = false;
        start.RedirectStandardInput = true;
        start.RedirectStandardOutput = true;
        // Child's stderr is inherited, like the original socat invocation.
        start.RedirectStandardError = false;

        using (var log = new StreamWriter(new FileStream(logPath, FileMode.CreateNew,
                        FileAccess.Write, FileShare.Read), new UTF8Encoding(false)))
        using (var process = new Process())
        {
            process.StartInfo = start;
            process.Start();
            var stdin = Console.OpenStandardInput();
            var stdout = Console.OpenStandardOutput();
            object logLock = new object();
            var inputThread = new Thread(() =>
                Relay(stdin, process.StandardInput.BaseStream, log, logLock, '>'));
            inputThread.IsBackground = true;
            inputThread.Start();

            // The main thread drains stdout until EOF. Never wait for the input
            // thread: a terminal's stdin may remain open after the child exits.
            Relay(process.StandardOutput.BaseStream, stdout, log, logLock, '<');
            process.WaitForExit();
            return process.ExitCode;
        }
    }
}
'@

try {
    $programArgs = [string[]]@()
    if ($CommandLine.Count -gt 1) {
        $programArgs = [string[]]$CommandLine[1..($CommandLine.Count - 1)]
    }
    $exitCode = [StdioTrafficProxy]::Run($CommandLine[0], $programArgs,
                                         (Get-Location).ProviderPath, $trafficLog)
    exit $exitCode
}
catch {
    [Console]::Error.WriteLine("stdio-proxy: $($_.Exception.Message)")
    exit 1
}
