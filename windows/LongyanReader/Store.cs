using System;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;

namespace Longyan;

/// The Microsoft Store build (notes/windows-store.md). Built with -p:Store=true (windows-msix.yml),
/// which defines STORE: no WinSparkle (the Store updates the app) and Open at login through the
/// package's startup task (LoginItem.cs). Packaged is a check at run time: the app has a package
/// identity, which only an installed MSIX gives. The GitHub build is never packaged, so none of
/// this changes it.
///
/// In a package, Windows keeps what the app writes under %LOCALAPPDATA% and HKCU\Software in the
/// package's own folder and registry hive, and deletes both when the app is uninstalled. The app
/// still reads and writes the usual paths; other programs (Explorer) only see the real place,
/// which RealPath gives.
static class Store
{
#if STORE
    public static readonly bool Build = true;
#else
    public static readonly bool Build = false;
#endif

    public static string? PackageFullName { get; } = Name(GetCurrentPackageFullName);
    public static string? PackageFamilyName { get; } = Name(GetCurrentPackageFamilyName);
    public static bool Packaged => PackageFamilyName != null;

    static readonly string localAppData = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);

    /// Where a file the app wrote under %LOCALAPPDATA% really is, for Explorer: in a package,
    /// %LOCALAPPDATA%\Packages\<family>\LocalCache\Local\... when the package wrote it there.
    public static string RealPath(string path)
    {
        if (PackageFamilyName is not string family || !path.StartsWith(localAppData + "\\", StringComparison.OrdinalIgnoreCase)) return path;
        var real = Path.Combine(localAppData, "Packages", family, "LocalCache", "Local", path[(localAppData.Length + 1)..]);
        return File.Exists(real) || Directory.Exists(real) ? real : path;
    }

    /// %LOCALAPPDATA%\LongyanReader as the reader would type it into Explorer.
    public static string DataFolderForPeople => PackageFamilyName is string family
        ? @"%LOCALAPPDATA%\Packages\" + family + @"\LocalCache\Local\LongyanReader"
        : @"%LOCALAPPDATA%\LongyanReader";

    delegate int PackageName(ref int length, StringBuilder? name);

    static string? Name(PackageName get)
    {
        try
        {
            int length = 0;
            // APPMODEL_ERROR_NO_PACKAGE (15700) when the process has no package identity.
            if (get(ref length, null) != 122) return null;   // ERROR_INSUFFICIENT_BUFFER
            var name = new StringBuilder(length);
            return get(ref length, name) == 0 ? name.ToString() : null;
        }
        catch (EntryPointNotFoundException) { return null; }
    }

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)] static extern int GetCurrentPackageFullName(ref int length, StringBuilder? name);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)] static extern int GetCurrentPackageFamilyName(ref int length, StringBuilder? name);
}
