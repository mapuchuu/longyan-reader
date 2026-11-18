# Launch checklist: the app

Covers the Mac app itself: features, install, and updates. The website is done separately.

Who does each item:
- **[me]**: I can do it from here. That means builds, scripts, the CLI, code reading, and driving apps.
- **[you]**: it needs your hands. Examples are system privacy prompts, a second Mac or user account, and publishing a release.
- **[both]**: I prepare it and you do the step that needs you.

## Where things stand (checked 2026-11-18)

- **v0.1 is live.** It is build 97, from 2026-11-17. The site's link has been downloaded 8 times and the versioned zip once.
- **main is ahead of the release.** It has 126 commits, and 3 of the ones since the release change the app (dd17c71, 5fb205c, 4385189). Launch needs a new release.
- **No update has ever been installed.** There is only one release, so the Sparkle path has never run. The README says "updates install without it [Open Anyway]", and that is unverified. **This is the biggest risk.**
- **The v0.1 notes are wrong.** They say "click the eye in the menu bar", but the eye appears next to the selection.
- **Signing:** the self-signed certificate is valid until 2046. The certificate (.p12) and the Sparkle private key exist only on this Mac.
- **Version:** `version=0.1` is hard-coded in `scripts/build-app.sh`. The build number is the commit count.
- **Fragment translations:** partly fixed (outside words kept out while decoding). Leaks on held-out fragments fell from 30% to 25%, and real-T went from 48 to 49 of 52. About one fragment in four still leaks.

## 0. Decisions first [you]

- [ ] **Launch version number.** Choose 1.0, or 0.2 to keep a "still early" signal. I recommend 1.0 if this is the public launch.
- [ ] **Throwaway update test.** Can I publish a test release so we can update 0.1 for real? Two options:
  - a release that you pull right after;
  - a staging feed: a build that points at a different appcast URL, so real users never see it. **I recommend this one.**
- [ ] **Test machines.** Which can we use: a second Mac, a fresh macOS user account on this one, or a macOS VM (a large download that needs your OK)? We need at least one machine that has never run the app, and ideally both macOS 15 and macOS 26.
- [x] **Fragment translation leaks.** Partial fix merged. Going further probably means changing how the card shows a fragment's translation, not more model work.
- [ ] **Lowest machine we promise.** Is an 8 GB M1 supported? If yes, it must be tested on 8 GB.

## 1. The release build

- [ ] [me] Build from a fresh clone, not this working copy, to prove nothing depends on local files. That covers cedict, the model path, and the env vars.
- [ ] [me] `--check-data` passes, and the dictionary compiles with no differences.
- [ ] [me] Read the Info.plist in the built app:
  - bundle ID, version and build
  - `LSMinimumSystemVersion` 15.0
  - `LSUIElement`
  - `SUFeedURL` and `SUPublicEDKey`
  - copyright line
- [ ] [me] The binary and frameworks are arm64 only, and the appcast says `hardwareRequirements arm64`.
- [ ] [me] There is no `DEV_TOOLS` code in the release binary: no debug notification, probe, or simulation hooks.
- [ ] [me] Check which dev-only CLI paths can be reached in a shipped binary. Examples are `NotesBuilder`, which calls the Anthropic API, and `--simulate`. They are probably harmless, but nothing in the shipped app may go online in ways the README doesn't mention. Gate them, or record why they're fine.
- [ ] [me] Signatures:
  - `codesign --verify --deep --strict` passes.
  - The designated requirement names the certificate.
  - Sparkle's helpers are signed inside out.
  - Hardened runtime is on where Sparkle needs it.
- [ ] [me] Licences are in `Contents/Resources/Licenses`: CC-CEDICT, MIT, llama.cpp and Sparkle. The About window or a menu item shows them.
- [ ] [me] Check the zip's size and that it unzips to a single `Longyan Reader.app` with its symlinks intact (ditto).
- [ ] [me] `release.sh` refuses a dirty tree, and the build number is higher than 97.

## 2. First install, as a stranger would do it

Run on a machine or account that has never had the app.

- [ ] [both] Download from longyan.app in Safari and in Chrome. Check:
  - the file name
  - that it unzips by itself in Safari
  - that it carries the quarantine flag
- [ ] [you] Opening it shows the Gatekeeper dialog. The steps match the README and the site's install animation, word for word:
  - macOS 15 (Done, then Privacy & Security, then Open Anyway, then a password)
  - macOS 26, whose dialog wording may differ
- [ ] [both] Opening it straight from Downloads, without moving it to Applications:
  - Is there a clear prompt to move it (`outsideApplications`)?
  - Does translocation break the Accessibility grant or updates?
- [ ] [both] Wrong machines:
  - What does an Intel Mac see?
  - What does macOS 14 see?
  - The site and README must say so clearly. The download button could say "Apple silicon, macOS 15+".
- [ ] [you] Onboarding, step 1 (Accessibility):
  - The prompt adds the app to the list.
  - The switch is noticed within about 1 s, with no relaunch needed.
  - Closing the window halfway leaves a way back from the menu.
- [ ] [both] Onboarding, step 2 (reading model):
  - Download progress and speed are shown.
  - hf-mirror.com falls back to huggingface.co. Test both, including behind your proxy.
  - Quitting mid-download and relaunching resumes it.
  - Each failure gives a clear message and no stuck state: no network, a checksum mismatch, a full disk (needs 3 GB free), and Cancel.
- [ ] [me] Skipping the model leaves the app usable:
  - dictionary order, and no translations
  - the menu still offers Download Reading Model
  - Apple's model fills in on macOS 26
- [ ] [me] If `qwen3.5:4b` is already in Ollama, the download isn't offered and the Ollama copy is used.
- [ ] [me] Time from first launch to the first useful card, with the download included. It should feel short.

## 3. Features

For each one: it works, it's fast enough, and its failure looks deliberate.

- [ ] **Trigger**
  - [me] The eye appears after a drag or double-click and goes away on click, key, scroll, or after 6 s.
  - [me] ⌃⌥L works on a selection and on the word under the pointer.
  - [me] ⌃⌥L doesn't clash with common apps. If it does, can it be changed?
- [ ] **Reading text.** [me] Test each of these: Safari, Chrome, Firefox, Arc, Preview (PDF), Books, Kindle, Notes, Pages, Word, Mail, Messages, WeChat, VS Code/Electron, Terminal, and a scanned PDF with no text layer.
  - For each, the result is one of: works, falls back to ⌘C, or fails clearly.
  - The ⌘C fallback restores the previous clipboard, including images and rich text.
- [ ] **Word card** [me]: the sense chosen for this sentence, pinyin with tone colors, notes, other senses, and changing the pick.
- [ ] **Phrase card** [me]: it opens instantly, the translation streams in, and word meanings follow. Check:
  - a long selection (the 2,048-token context)
  - mixed Chinese and English
  - traditional characters
  - numbers and punctuation only
  - a non-Chinese selection, which should produce no card or a polite one
- [ ] **Model quality** [me]: run `scripts/evals.sh` against `eval-baseline.tsv`, with no regressions since v0.1.
- [ ] **Listen** [me]: with the default system voice, and on a Mac that has no Chinese voice installed.
- [ ] **History** [me]:
  - entries record the meaning the word had
  - Export to Anki and to a spreadsheet, then open both files in Anki and Numbers
  - Clear, and turning history off
  - a history file with thousands of entries
- [ ] **Card handling** [me]: the zoom grip, double-click to reset, dragging, a dragged card staying open on scroll, Escape, and keyboard focus.
- [ ] **Appearance** [me]: Light, Dark and System, switched live; Classic and Liquid Glass (macOS 26 only, hidden on 15).
- [ ] **Windows and screens** [me]: several displays, full-screen apps, Spaces, and a card near a screen edge. The card should never be cut off.
- [ ] **Menu**: every item works, with the right wording and shortcuts.
  - [you] Open at Login, including its approval in System Settings.
  - [me] Report a Problem opens a filled-in GitHub issue with no private data in it.
  - [me] About shows the version and build.
  - [me] Check for Updates, the Accessibility status line, and Quit.
- [ ] **Permissions changing** [you]:
  - Accessibility turned off while the app runs leads to a clear message and a way back.
  - Turning it back on works without a relaunch.

## 4. Robustness and performance

- [ ] [me] Run the usage simulation (`Simulation.swift`) for a long session: no crashes, flat memory, the model unloaded after 5 idle minutes.
- [ ] [me] Through sleep and wake, and with the network changing (proxy on and off), the next lookup still works.
- [ ] [me] Failures stay contained: a corrupt or truncated model file, a corrupt history file, missing resources, and low disk. Each should end in a clear message, not a crash or hang.
- [ ] [me] Check the speed numbers DEVELOPMENT.md promises: about 0.15 s for a word and 1 to 2 s for a sentence. Measure cold start as well (first lookup after launch, with the model loading).
- [ ] [you] Test on the lowest Mac we support, ideally an 8 GB M1. That covers memory pressure from the mapped model and the slowest speeds.
- [ ] [me] Look at energy use while idle: no busy timers or polling, and Activity Monitor's energy figure near zero.
- [ ] [me] Look at crash and log output. What does a user send us when something breaks? Is it written down?

## 5. Updates and versioning

- [ ] [me] **Version scheme, written down.**
  - Marketing version (`CFBundleShortVersionString`) is set by hand for each release, not hard-coded. The script could take it as an argument, read a VERSION file, or use the git tag.
  - The build number is the commit count, so it only grows. Note the risk: a rebase or squash of main could lower it.
- [ ] [me] Check the appcast: `sparkle:version`, the short version, the minimum OS, arm64, the EdDSA signature, the length, and markdown release notes that read well in Sparkle's window.
- [ ] [both] **End-to-end update test (the big one).** Start with 0.1 installed and set up: Accessibility granted, the model downloaded, history recorded, Open at Login on. Then publish the next build to a staging feed and check each of these:
  - the second-launch "check automatically?" prompt
  - Check for Updates finds it
  - the update installs and relaunches the app
  - **Accessibility is still granted**, because the same certificate means the same designated requirement
  - **Gatekeeper does not ask again**
  - the model, history, settings and login item all survive
  - the gentle scheduled reminder appears when no one is in the middle of reading
- [ ] [me] Negative tests:
  - An update with a bad EdDSA signature is refused.
  - An update signed with a different certificate is refused, or we know what happens.
  - "Skip this version" works.
- [ ] [me] Settings migrations: an old defaults key or a new history format is upgraded, not lost (see the `cardSizeVersion` pattern).
- [ ] [me] **Bad-release plan, written in DEVELOPMENT.md.** The feed is "latest release" and Sparkle won't downgrade, so a bad release is fixed forward: a new build number out quickly. Record the steps and how long they take.
- [ ] [you] **Back up the keys** somewhere other than this Mac, such as a password manager or an encrypted USB drive. The files are `longyan-codesign.p12` with its password, and `sparkle-private-key.txt`. If they're lost, existing users can never be updated, and they would have to re-grant Accessibility.
- [ ] [me] `release.sh` prints the publish command. Add a check step after publishing: fetch the live appcast and the site's zip, and confirm the version and signature.

## 6. Privacy, data, and uninstalling

- [ ] [me] **Network audit.** Watch the app's connections (nettop or lsof) through a whole session. The only ones allowed are the model download and Sparkle checks, and Sparkle only after you say yes. That makes the README's privacy claim checked, not just stated.
- [ ] [me] List everything the app writes:
  - `~/Library/Application Support/LongyanReader/` (2.7 GB model)
  - `~/Library/Logs/LongyanReader/` (history)
  - defaults
  - Sparkle's caches
  - the login item
  - the Accessibility entry
- [ ] [me] Add uninstall steps to the README: delete the app, the model folder and the history, and remove the Accessibility entry. Possibly add a "Remove reading model" menu item to free 2.7 GB.
- [ ] [me] Is history stored under Logs the right place? Users may clear Logs and lose their history without knowing.

## 7. Words people see

- [ ] [me] Read every string in the app (menus, onboarding, errors, alerts, the update window) against notes/style.md: short, plain, no AI tics, no em dashes.
- [ ] [me] README, site and app all match on requirements, install steps, shortcuts, disk space and privacy claims.
- [ ] [me] Release notes for the launch version, plus a corrected sentence about the eye.
- [ ] [me] Check the GitHub repo:
  - description, topics and website link
  - licence shown
  - issue templates (bug report: version, macOS, what app, and the text if it's shareable)
  - nothing private committed (real-eval.tsv stays ignored)
- [ ] [me] Leftover follow-up: the 走 example in App.swift:201, CLI.swift:493/752 and Simulation.swift.

## 8. Launch day

- [ ] [you] Publish the release (`gh release create ...`), not as a draft or prerelease, so `releases/latest` moves.
- [ ] [me] Fetch the live appcast, then download the zip from longyan.app and check its signature and version.
- [ ] [both] On the test machine with 0.1, Check for Updates gets the new version.
- [ ] [both] On a clean machine, do the full install from the site once more.
- [ ] [me] For the first few days, watch GitHub issues and the download counts.

## Suggested order

1. Make the decisions in section 0.
2. **Release pipeline:** do sections 1 and 5.
   - Make the version settable.
   - Set up the staging feed.
   - Run the end-to-end update test from 0.1.
   This comes first because if updates are broken, every user who installs now is stuck.
3. Back up the keys.
4. Features, robustness and performance (sections 3 and 4). I can do most of this unattended. You only need to step in for permission switches and the 8 GB Mac.
5. Clean-machine install (section 2), with your hands.
6. Privacy audit, words, docs (sections 6 and 7).
7. Cut the launch build, then run section 8.
