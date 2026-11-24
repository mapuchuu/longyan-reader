# Microsoft Store build

Windows ships two ways:

- **GitHub**: the Inno Setup installer, unsigned, with WinSparkle updates. For people who know how to get past SmartScreen. Unchanged.
- **Microsoft Store**: an MSIX package. The Store signs it, so no certificate is needed, and the Store installs updates.

## What CI makes

`windows.yml`'s `msix` job runs `windows-msix.yml` after the two app jobs:

1. For x64 and arm64, it builds the Store flavour of the app (`dotnet publish -p:Store=true`) over that arch's app folder and packs it with `windows/store/pack.ps1` (MakeAppx and MakePri from the runner's Windows SDK).
2. On that arch's runner it signs a copy with a throwaway certificate made in the job, installs it, opens it from Start and checks it (`windows/store/test.ps1`, `UiCheck --packaged`), then uninstalls it.
3. It bundles both into `LongyanReader_<version>_x64_arm64.msixbundle` and `.msixupload`, unsigned. That's the `LongyanReader-store` artifact. The `.msixupload` is the file to upload to Partner Center.

The version is `<Version>` in `LongyanReader.csproj` with `.0` added (0.1.0 becomes 0.1.0.0). Each Store upload needs a higher version than the last.

## How the Store build differs

- **No WinSparkle.** `Store.Build` turns updates off, and `WinSparkle.dll` isn't in the package. No "Check for updates" in the menu or Settings. Store policy: the Store updates Store apps.
- **Open at login** is the package's startup task (`windows.startupTask` in the manifest), not the `HKCU\...\Run` value. Same switch, same words: "Opens Longyan Reader when you log in to Windows." It shows in Settings > Apps > Startup and Task Manager as before. If the reader turns it off there, the app can't turn it back on; only they can, from those places.
- **Where data goes.** The app still writes to `%LOCALAPPDATA%\LongyanReader` (settings, history, the model, logs). Windows redirects that into `%LOCALAPPDATA%\Packages\<package family>\LocalCache\Local\LongyanReader`. The same goes for `HKCU\Software`, though the Store build writes nothing there (only WinSparkle did). "Open history folder" in History and the log path in Report a problem point at the real folder.
- **Uninstall deletes all data**, as the GitHub uninstaller does: Windows removes the package's folder, its registry and its startup task. CI checks that nothing is left.
- If someone has both builds, the Store copy can see files the GitHub copy already wrote (a downloaded model, for example), but it never changes or deletes them.

The GitHub build is the same as before. `Store.Packaged` is checked at run time and is never true for it, and the startup task code is only compiled with `-p:Store=true`.

## The package

- `windows/store/identity.txt`: the identity from Partner Center (Store ID 9MSR9JKZKR50): `Mapuchu.LongyanReader`, publisher `CN=C4844210-E46B-4ED7-BD3A-C88143816909`, display name `Mapuchu`. CI checks the installed package's family name is `Mapuchu.LongyanReader_qxst12vwamc5m`, as Partner Center lists it.
- `windows/store/AppxManifest.xml`: Windows 10 1809 (10.0.17763) and later, as the installer. One capability, `runFullTrust`: a normal desktop app. It needs it to read selected text in other apps (UI Automation), watch the shortcut and the mouse, sit in the notification area and download the model. Nothing else is declared.
- `windows/store/assets.ps1`: the tile and icon images. Taskbar and Start icons are the frames of `LongyanReader.ico`; tiles and the Store logo are the mark from `Resources/longyan-mark.png` on white. No new art.

## What CI checks on the runner

On both x64 and arm64:

- The package installs, and the bundle picks the x64 package on an x64 runner.
- The app opens from Start with its package identity, from `WindowsApps`.
- The welcome window shows, with Open at login on.
- WinSparkle isn't in the package or loaded, and the log has no update lines.
- The log and the model download (stopped after its first pieces) go to the package's folder, and nothing goes to the real `%LOCALAPPDATA%\LongyanReader` or `HKCU\Software\LongyanReader`.
- Done in the welcome window turns the startup task on. The next start reads it back. The Settings switch turns it off and on again. The Run key is never touched.
- Uninstall leaves no package folder, registry key or startup task.

Not checked: a real login (CI can't log out and back in), the Store's own install and update, the full model download inside the package (the first-run job covers the download itself), Windows 10.

## What you do in Partner Center

1. Done: an individual developer account.
2. Done: the name **Longyan Reader** reserved as an MSIX app.
3. Done: its identity is in `windows/store/identity.txt`. Take `LongyanReader_<version>_x64_arm64.msixupload` from the `LongyanReader-store` artifact of a green run.
4. **Pricing and availability**: free, the markets you want.
5. **Properties**: category (Education, or Books and reference). Privacy policy URL: `https://longyan.app/privacy.html`. That page only covers the Mac today, so add Windows first (the data folder, the model download, no update check in the Store build).
6. **Age ratings**: fill in the questionnaire. No user content, no chat, no purchases.
7. **Packages**: upload the `.msixupload`. Partner Center reads the identity and version from it; it must match step 3.
8. **Store listing** (English): the description, a short description, and at least one screenshot (1366x768 or larger; a card over a Chinese web page shows it best). Search terms: Chinese, pinyin, dictionary, reader.
9. **Submission options**: the restricted capability `runFullTrust` needs a reason. Suggested: "A desktop app that reads the text selected in other apps (UI Automation), listens for its keyboard shortcut and shows a notification area icon." Notes for certification: "Select Chinese text in any app and press Ctrl+Alt+L. The reading model (2.7 GB) is optional; cards work without it."
10. **Submit**. Certification usually takes a few days. Store updates later: raise `<Version>`, upload the new `.msixupload`, submit.
