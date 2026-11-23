# Windows release checklist

Every step from a green shared-core to a public Windows release, in order. Written 2026-11-23 on branch win/launch-docs, from shared-core at baed711 (windows.yml green, run 45198517061).

Marks:
- **[done]**: already true.
- **[auto]**: a workflow does it when the step before it happens.
- **[me]**: Claude can do it from here (code, CI, `gh` reads, drafts).
- **[you]**: needs your hands, your money, your accounts, or your OK to publish.
- **[both]**: I prepare it, you do the step that needs you.

Nothing here has been run. No tag, release, secret or deploy has been made.

## Where things stand

- **shared-core is green** on windows.yml (jobs app, ui, sse42), core.yml and gallery.yml. [done]
- **Three release branches aren't merged yet**, and all three edit windows.yml:
  - win/installer (Inno Setup, per-user installer, tag `windows-v*` makes a draft release). Its last run (45201078155) failed at "Install, upgrade, uninstall".
  - win/updates (WinSparkle, `appcast-windows.xml` on the `windows-feed` pre-release, the `windows-release` workflow).
  - win/arm64 (native ARM64 build on the windows-11-arm runner).
- **The app's version is 0.1.0** (`<Version>` in windows/LongyanReader/LongyanReader.csproj). The installer and the tag read it.
- **No update key and no certificate yet.** `gh secret list` shows no secrets on the repo.
- **Speed is unknown on real PCs.** The model runs on the CPU. On GitHub's 4-core runner a word card takes 15 to 17 s (AVX2) and about 20 s on the ARM runner. A real 8-core laptop will be faster, but nobody has measured one. Vulkan is started on win/speed.
- **Not tested on Windows 10.** CI runs windows-latest (Windows Server 2025) and windows-11-arm. The installer allows Windows 10 (`MinVersion=10.0`).
- **The stats workflow didn't count .exe files.** Fixed on this branch (step 2.7).

## 0. Decisions [you]

- [ ] **Certificate.** Which kind and from whom. Since June 2023 new OV and EV code-signing keys must live on a hardware token or a cloud signing service, so a plain .pfx in a GitHub secret (what `windows/installer/sign.ps1` expects now) may not be possible. Options:
  - Azure Trusted Signing (Microsoft's service, monthly fee, signs from CI, identity check required; check whether individuals in your country can use it now).
  - An OV certificate with cloud signing (SSL.com eSigner, DigiCert KeyLocker, Certum SimplySign) so CI can sign.
  - EV no longer skips SmartScreen's reputation check, so it buys little here.
  Validation can take days to weeks: start it first.
- [ ] **Publisher name.** An individual certificate shows your legal name as the publisher in SmartScreen and in file properties. Decide whether that's acceptable or whether to sign as an organisation.
- [ ] **Beta version numbers.** Proposed: betas are 0.9.0, 0.9.1, and so on; the release is 1.0.0. The installer and release job only handle plain x.y.z (a tag like `windows-v1.0.0-beta.1` fails the job's file-name check).
- [ ] **Beta signed or not.** The plan says signed before the *public* release. A beta can go out unsigned (testers follow variant B of the guide) or wait for the certificate.
- [ ] **How private the beta is.** A GitHub pre-release is public in the Releases list; it's only unannounced. For a closed beta: give testers the CI artifact (needs a GitHub login) or add them as collaborators and keep the release a draft. Pre-release is simplest.
- [ ] **Windows 10.** Find a Windows 10 tester before claiming it, or say Windows 11 only.
- [ ] **Minimum memory.** README draft says 8 GB. Confirm on an 8 GB PC in the beta.
- [ ] **Where Windows releases are built from.** Tags on shared-core work (windows.yml runs on the tag). README, site and stats.yml changes need main. Decide whether shared-core merges into main first (it changes the Mac's core; the Mac keeps Apple's splitter, per the plan).
- [ ] **GPU before 1.0?** CPU-only speed may be too slow on older laptops. Decide whether Vulkan (win/speed) is in 1.0 or later.

## 1. Merge the release branches into shared-core

- [ ] [me] Fix win/installer's failing "Install, upgrade, uninstall" step (run 45201078155), or wait for whoever is on that branch.
- [ ] [me] Merge win/installer, win/updates and win/arm64 into shared-core. Resolve windows.yml by hand: keep every job (app, ui, sse42, installer, updates, app-arm64, ui-arm64, ui-x64-on-arm64, release).
- [ ] [me] Add the ARM64 installer: a second call to windows-installer.yml with `arm64-artifact: LongyanReader-windows-arm64` and `runner: windows-11-arm` (test.ps1 installs it, so it needs an ARM runner).
- [ ] [me] The `release` job (from win/installer) must attach both installers, `needs: [installer, installer-arm64]`. Today it downloads only the x64 one.
- [ ] [me] The app job must build with the build number on tags: `-p:BuildNumber=$(git rev-list --count HEAD)` with `fetch-depth: 0` (win/updates has this for x64; add it to app-arm64 too). WinSparkle compares this number.
- [ ] [auto] windows.yml, core.yml and gallery.yml run on the push. All green, including installer and updates.

## 2. Release plumbing to check and fix

- [ ] [me] **Build number in windows-release.yml.** It takes the build from the release's `targetCommitish`. A release made by `gh release create <existing tag>` without `--target` reports the default branch there (`main`), so the feed would get main's commit count, not the tag's. Fix: in the "The release and its installers" step use
  ```bash
  build=$(git rev-list --count "refs/tags/$TAG")
  ```
  (checkout already uses `fetch-depth: 0`, which brings tags). Check on the first draft with `gh release view windows-v0.9.0 --json targetCommitish`.
- [ ] [both] **windows-release.yml must be on main.** GitHub only lets you run a `workflow_dispatch` workflow that exists on the default branch. `gh workflow run windows-release` runs main's copy with main's `scripts/windows-release-feed.sh` and `scripts/windows-feed.py`, so those three files have to reach main before the beta (or main gets all of shared-core, step 0). Run it with `--ref shared-core` only once it's on main too.
- [ ] [me] **Release notes in the draft.** The release job writes a one-line body. Replace it before running windows-release, which puts the body in the feed: `gh release edit windows-v0.9.0 --notes-file notes/windows-release-beta.md`.
- [x] [done] **Own tag** (on win/installer and win/updates, merged in step 1). Windows tags are `windows-v<version>`; the Mac's are `v<version>`. release.sh refuses an existing `v` tag only, so they don't collide.
- [x] [done] **Never marked latest** (same branches). The release job creates drafts with `--latest=false`, and windows-release.yml refuses to publish the feed if the Windows release is latest. The Mac's `releases/latest/download/LongyanReader.zip` (site, README, Homebrew) and `releases/latest/download/appcast.xml` (Sparkle) depend on this.
- [ ] [you] **Publishing by hand:** use `gh release edit <tag> --draft=false --latest=false`. In the web page, untick "Set as the latest release" before publishing; it's ticked by default for a full release.
- [x] [done] **No Mac file names.** Windows releases carry `LongyanReader-Setup-*.exe` and `appcast-windows.xml`, never `LongyanReader.zip` or `appcast.xml`.
- [x] [done] **Stats count .exe.** `.github/workflows/stats.yml` on this branch now counts `LongyanReader-Setup-*.exe` in every published release (betas too, since they're pre-releases), plus Mac zips as before. Drafts, appcasts and site-media videos stay out. Checked against the live API: the total is unchanged today (47). Scheduled workflows run from main, so this needs to reach main; the counts come from GitHub's totals, so merging any time before launch loses nothing.
- [ ] [me] After merging, run it once: `gh workflow run stats.yml`, then `curl -s https://raw.githubusercontent.com/mapuchuu/longyan-reader/stats/downloads.json`.

## 3. Keys and secrets [you]

- [ ] [you] **Update key, before the first build anyone installs.** On the Mac with the signing folder, from a checkout that has win/updates merged:
  ```bash
  scripts/windows-update-key.sh
  ```
  It writes the private key to `~/Library/Application Support/LongyanReader-signing/windows-update-key.txt`, sets the `WINDOWS_UPDATE_KEY` secret and writes `windows/update-key.txt`. Commit that file [me]. A build without it has no updates, so beta testers on such a build would have to reinstall by hand.
- [ ] [you] **Back up the signing folder off this Mac**, now with the Windows key in it. Losing it means installed copies can never update. (The same backup is still open for the Mac keys.)
- [ ] [you] **Buy the certificate** (decision in step 0) and finish identity checks.
- [ ] [both] **Signing secrets.** For a .pfx: `gh secret set WINDOWS_CERT_PFX < cert.b64` and `gh secret set WINDOWS_CERT_PASSWORD`. For a cloud service I change the signtool line in `windows/installer/sign.ps1` and the secrets it needs (for example the Azure tenant, client and account names), and you set them.
- [ ] [auto] Then every installer build signs the app's .exe and .dll files, the setup and the uninstaller. Check the "Build the installer" step's log says `Valid` for `Get-AuthenticodeSignature`.

## 4. Beta

- [ ] [me] Set `<Version>0.9.0</Version>` in LongyanReader.csproj, commit, push to shared-core. Wait for green.
- [ ] [you] Tag the green commit and push the tag (this starts the release job):
  ```bash
  git tag windows-v0.9.0 <sha>
  git push origin refs/tags/windows-v0.9.0
  ```
- [ ] [auto] windows.yml builds both apps, both installers, tests install, upgrade and uninstall, and makes a **draft** release `windows-v0.9.0` with both `.exe` files.
- [ ] [me] Check the draft: two installers, sizes, signature status (or the expected "not signed"), not latest.
- [ ] [you] Put the notes in: `gh release edit windows-v0.9.0 --notes-file notes/windows-release-beta.md` (fill in its brackets first).
- [ ] [you] Write the feed, without publishing it: `gh workflow run windows-release -f version=0.9.0`. [me] Read the `appcast-windows` artifact: one item, both enclosures, signatures, build number = `git rev-list --count windows-v0.9.0`.
- [ ] [you] Publish as a pre-release: `gh release edit windows-v0.9.0 --draft=false --prerelease --latest=false`.
- [ ] [me] Check the Mac is untouched:
  ```bash
  gh api repos/mapuchuu/longyan-reader/releases/latest --jq .tag_name     # v1.1
  curl -sIL https://github.com/mapuchuu/longyan-reader/releases/latest/download/LongyanReader.zip | grep -i '^location' | head -1   # .../v1.1/...
  curl -sL https://github.com/mapuchuu/longyan-reader/releases/latest/download/appcast.xml | grep -c shortVersionString   # the Mac feed, no Windows items
  ```
- [ ] [you] Publish the feed: `gh workflow run windows-release -f version=0.9.0 -f publish_feed=true`. It checks the live copy.
- [ ] [you] **Pick beta testers**, 5 to 10. Cover: x64 Windows 11; Windows 10; a Snapdragon (ARM64) laptop; an 8 GB PC; an older CPU without AVX2 if possible; an AltGr keyboard layout (Polish, German); two monitors at different scaling; readers who use Edge, Chrome, Word, a PDF reader and WeChat.
- [ ] [you] Send each tester the release link and `notes/windows-beta-guide.md` (as a gist or pasted). Ask for their PC model in the first report.
- [ ] [both] **Prove updates once.** Ship 0.9.1 the same way (even with one small fix) and confirm a tester's 0.9.0 offers it, installs it and keeps history and settings. On the Mac, the update path was the biggest untested risk at launch; don't repeat that.
- [ ] [me] Triage reports as they come: label them `windows`, link fixes, keep a short list of what's open.
- [ ] [both] **Exit criteria**, agreed before starting: no crash without a fix, the selection works in the main apps testers use, speed acceptable on the slowest supported PC, an update installed by at least two testers, memory fine on 8 GB.

## 5. Release 1.0

- [ ] [me] `<Version>1.0.0</Version>`, the final notes in `notes/windows-release-1.0.md` (fill in "Since the beta"), push, green.
- [ ] [auto] The installer job signs (the certificate secrets exist by now). If it says not signed, stop.
- [ ] [you] Tag and push `windows-v1.0.0`, as in step 4.
- [ ] [auto] Draft release with both installers.
- [ ] [you] `gh release edit windows-v1.0.0 --notes-file notes/windows-release-1.0.md`
- [ ] [you] `gh workflow run windows-release -f version=1.0.0`, then [me] read the feed artifact.
- [ ] [you] Publish as a full release, not latest: `gh release edit windows-v1.0.0 --draft=false --latest=false`.
- [ ] [me] The same three Mac checks as in step 4. If latest moved, set it back at once: `gh release edit v1.1 --latest`.
- [ ] [you] `gh workflow run windows-release -f version=1.0.0 -f publish_feed=true`. Beta copies now get 1.0.
- [ ] [me] Download both installers from the release page on a clean runner or VM, check the signature and the publisher name.
- [ ] [auto] Within the hour, stats.yml includes the .exe downloads in the badge.

## 6. README and website

- [ ] [me] README (draft on this branch): pick variant A (signed) in the Windows install step, delete variant B, fill in the bracketed values (installed size, speed, publisher), set the version in the two download links.
- [ ] [me] Website: fold `notes/site-windows-download.html` into `site/index.html` and `site/style.css`, set `WIN_VERSION`, and make the other changes listed at its top: title and meta text, the hero's button, "works everywhere on your Mac", the phone label, privacy.html, the `?v=` cache key.
- [ ] [me] Check the page locally on a Mac, on Windows (Edge, Chrome, Firefox), on an ARM64 Windows PC and on a phone.
- [ ] [you] Merge to main. **A push to main that touches `site/` deploys longyan.app** (pages.yml), so merge only after 1.0 is published and its links work.
- [ ] [me] After the deploy: click both Windows links on the live site, and the Mac one.
- [ ] [me] Each later Windows release changes `WIN_VERSION` and the README links (the URL has the tag in it, since Windows releases are never "latest"). Add it to the release steps in DEVELOPMENT.md.

## 7. Announcement [you]

- [ ] [you] Where and when: the same places as the Mac launch, after the site shows Windows. I can draft the posts from the 1.0 notes when you say where they go.
- [ ] [you] Post them.

## 8. After launch

- [ ] [both] Watch issues for a week; Windows reports come in with the Windows version, CPU, memory and model state filled in.
- [ ] [me] Check the badge and the per-asset counts: `gh release view windows-v1.0.0 --json assets --jq '.assets[] | "\(.name) \(.downloadCount)"'`.
- [ ] [me] Record what was learned here and in notes/windows-plan.md.
