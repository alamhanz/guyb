# Windows half of tab-status.sh (called from it under Git Bash; works on PS 5.1 and 7). Never prints, always exits 0.
# Usage: tab-status.ps1 running|done|waiting|end. Acts only when GUYB_TAB_NAME is set.
# A hook runs on its own hidden console, so writing CONOUT$ directly does not reach the terminal. Spike result (Windows Terminal,
# real Claude Code hook): direct CONOUT$ no, /dev/tty from Git Bash no, FreeConsole + AttachConsole(<claude pid>) then CONOUT$ yes.
# Windows Terminal honours the OSC 0 title only when the tab was not opened with --suppressApplicationTitle.
# Icons: running U+23F3, done U+2705, waiting U+2753 (code points; source stays ASCII). GUYB_TAB_ASCII=1: * + ?
# GUYB_DRYRUN=1 prints "tab: conout <title>" instead of writing.
param([string]$State)
try {
    $name = $env:GUYB_TAB_NAME
    if (-not $name) { exit 0 }
    $name = -join ($name.ToCharArray() | Where-Object { [int]$_ -gt 31 -and [int]$_ -ne 127 -and ([int]$_ -lt 128 -or [int]$_ -gt 159) })
    if (-not $name) { exit 0 }
    $ascii = ($env:GUYB_TAB_ASCII -eq '1') -or ($env:TERM -eq 'linux') -or ($env:TERM -eq 'dumb')
    switch ($State) {
        'running' { $g = if ($ascii) { '*' } else { [string][char]0x23F3 } }
        'done'    { $g = if ($ascii) { '+' } else { [string][char]0x2705 } }
        'waiting' { $g = if ($ascii) { '?' } else { [string][char]0x2753 } }
        'end'     { $g = '' }
        default   { exit 0 }
    }
    $title = if ($g) { "$g $name" } else { $name }
    if ($env:GUYB_DRYRUN) { "tab: conout $title"; exit 0 }

    Add-Type -Namespace Guyb -Name Con -MemberDefinition @"
[DllImport("kernel32.dll", SetLastError=true)] static extern bool FreeConsole();
[DllImport("kernel32.dll", SetLastError=true)] static extern bool AttachConsole(uint pid);
[DllImport("kernel32.dll")] static extern uint GetConsoleProcessList(uint[] list, uint count);
[DllImport("kernel32.dll", SetLastError=true, CharSet=CharSet.Unicode)] static extern Microsoft.Win32.SafeHandles.SafeFileHandle CreateFile(string name, uint access, uint share, IntPtr sa, uint disp, uint flags, IntPtr tmpl);
[DllImport("kernel32.dll")] static extern IntPtr CreateToolhelp32Snapshot(uint flags, uint pid);
[DllImport("kernel32.dll")] static extern bool Process32First(IntPtr snap, ref PE e);
[DllImport("kernel32.dll")] static extern bool Process32Next(IntPtr snap, ref PE e);
[DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr h);
[StructLayout(LayoutKind.Sequential, CharSet=CharSet.Ansi)] struct PE { public uint size, usage, pid; public IntPtr heap; public uint module, threads, parent; public int pri; public uint flags; [MarshalAs(UnmanagedType.ByValTStr, SizeConst=260)] public string exe; }
static System.Collections.Generic.Dictionary<uint, uint> Parents() {
    var d = new System.Collections.Generic.Dictionary<uint, uint>();
    IntPtr s = CreateToolhelp32Snapshot(2, 0);
    PE e = new PE(); e.size = (uint)Marshal.SizeOf(typeof(PE));
    if (Process32First(s, ref e)) { do { d[e.pid] = e.parent; } while (Process32Next(s, ref e)); }
    CloseHandle(s);
    return d;
}
// Attach to the console of the nearest ancestor that is not on our own (hidden) console, then write bytes to CONOUT$.
public static bool Write(byte[] bytes) {
    uint[] own = new uint[64];
    uint n = GetConsoleProcessList(own, 64);
    var parents = Parents();
    uint cur = (uint)System.Diagnostics.Process.GetCurrentProcess().Id;
    for (int i = 0; i < 10; i++) {
        if (!parents.TryGetValue(cur, out cur) || cur == 0) return false;
        if (Array.IndexOf(own, cur, 0, (int)Math.Min(n, 64)) >= 0) continue;
        FreeConsole();
        if (!AttachConsole(cur)) continue;
        using (var h = CreateFile("CONOUT$", 0x40000000, 3, IntPtr.Zero, 3, 0, IntPtr.Zero)) {
            if (h.IsInvalid) return false;
            using (var fs = new System.IO.FileStream(h, System.IO.FileAccess.Write)) { fs.Write(bytes, 0, bytes.Length); fs.Flush(); }
        }
        return true;
    }
    return false;
}
"@
    $bytes = [Text.Encoding]::UTF8.GetBytes([string][char]27 + ']0;' + $title + [string][char]7)
    [void][Guyb.Con]::Write($bytes)
}
catch { }
exit 0
