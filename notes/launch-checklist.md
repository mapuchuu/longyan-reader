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

- [x] **Launch version number.** 1.0. Choose 1.0, or 0.2 to keep a "still early" signal. I recommend 1.0 if this is the public launch.
- [x] **Throwaway update test.** Can I publish a test release so we can update 0.1 for real? Two options:
  - a release that you pull right after;
  - a staging feed: a build that points at a different appcast URL, so real users never see it. **I recommend this one.**
- [ ] **Test machines.** Which can we use: a second Mac, a fresh macOS user account on this one, or a macOS VM (a large download that needs your OK)? We need at least one machine that has never run the app, and ideally both macOS 15 and macOS 26.
- [x] **Fragment translation leaks.** Partial fix merged. Going further probably means changing how the card shows a fragment's translation, not more model work.
- [ ] **Lowest machine we promise.** Is an 8 GB M1 supported? If yes, it must be tested on 8 GB.

## 1. The release build

- [x] [me] Build from a fresh clone, not this working copy, to prove nothing depends on local files. That covers cedict, the model path, and the env vars.
- [x] [me] `--check-data` passes, and the dictionary compiles with no differences.
- [x] [me] Read the Info.plist in the built app:
  - bundle ID, version and build
  - `LSMinimumSystemVersion` 15.0
  - `LSUIElement`
  - `SUFeedURL` and `SUPublicEDKey`
  - copyright line
- [x] [me] The binary and frameworks are arm64 only, and the appcast says `hardwareRequirements arm64`.
- [x] [me] There is no `DEV_TOOLS` code in the release binary: no debug notification, probe, or simulation hooks. Checked 2026-11-18: none in the binary. The developer command-line tools (`--eval`, `--notes-*`) are there but only run from Terminal; the notes tools need a key in the keychain.
- [x] [me] Check which dev-only CLI paths can be reached in a shipped binary. Examples are `NotesBuilder`, which calls the Anthropic API, and `--simulate`. They are probably harmless, but nothing in the shipped app may go online in ways the README doesn't mention. Gate them, or record why they're fine.
- [x] [me] Signatures:
  - `codesign --verify --deep --strict` passes.
  - The designated requirement names the certificate.
  - Sparkle's helpers are signed inside out.
  - Hardened runtime is on where Sparkle needs it.
- [x] [me] Licences are in `Contents/Resources/Licenses`: CC-CEDICT, MIT, llama.cpp and Sparkle. The About window or a menu item shows them.
- [x] [me] Check the zip's size and that it unzips to a single `Longyan Reader.app` with its symlinks intact (ditto). Checked 2026-11-18: 12 MB; plain `unzip` gives one app, symlinks intact, no `._` files, signature valid.
- [x] [me] `release.sh` refuses a dirty tree, and the build number is higher than 97.

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
- [x] [me] If `qwen3.5:4b` is already in Ollama, the download isn't offered and the Ollama copy is used. Checked in code 2026-11-18: `EmbeddedModel.modelPath` takes Ollama's blob of the same file when the app has none.
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
- [x] **Model quality** [me]: run `scripts/evals.sh` against `eval-baseline.tsv`, with no regressions since v0.1. Done 2026-11-18: no regressions, and real-T is 49/52. The stored phrase target of 83 is stale (main scores 82 without the fix too); refresh it with `--update` on the release build.
- [ ] **Listen** [me]: with the default system voice, and on a Mac that has no Chinese voice installed.
- [ ] **History** [me]:
  - entries record the meaning the word had
  - Export to Anki and to a spreadsheet, then open both files in Anki and Numbers
  - Clear, and turning history off
  - a history file with thousands of entries (done 2026-11-18 with 5,000 made-up lines and a cut-off one: the window opens at once, CSV and Anki export in 1.4 s, formulas stay text; the When column cuts the time off at the default width)
- [ ] **Card handling** [me]: the zoom grip, double-click to reset, dragging, a dragged card staying open on scroll, Escape, and keyboard focus.
- [ ] **Appearance** [me]: Light, Dark and System, switched live; Classic and Liquid Glass (macOS 26 only, hidden on 15).
- [ ] **Windows and screens** [me]: several displays, full-screen apps, Spaces, and a card near a screen edge. The card should never be cut off.
- [ ] **Menu**: every item works, with the right wording and shortcuts.
  - [you] Open at Login, including its approval in System Settings.
  - [me] Report a Problem opens a filled-in GitHub issue with no private data in it. Done 2026-11-18: GitHub fills the body in; only versions, chip, memory and model.
  - [me] About shows the version and build.
  - [me] Check for Updates, the Accessibility status line, and Quit.
- [ ] **Permissions changing** [you]:
  - Accessibility turned off while the app runs leads to a clear message and a way back.
  - Turning it back on works without a relaunch.

## 4. Robustness and performance

Also fixed 2026-11-18:
- With no Accessibility, there's no eye chip, and ⌃⌥L opens the permission window.
- Phrase-card errors are plain text.
- CSV export has a BOM for Excel.
- History loads off the main thread.

Code sweep 2026-11-18 (five audits: crashes, text, UI, release, docs). Fixed:
- A selection edge inside a character (CRLF, emoji sequence) could index past the passage. Ranges are now clamped.
- A lookup queued at quit could load the model again during teardown.
- Digits were trimmed off selections, so dates lost the year and 100元 became 元.
- Traditional text was tokenized as simplified (我們 split) and found no notes.
- 〇 and CJK Extensions C onward weren't counted as Chinese.
- ⌘C fallback: runs on main, restores the clipboard after a late copy, and never puts back a password manager's copy.
- No main menu, so ⌘V/⌘C/⌘A/⌘W didn't work in History.
- Esc anywhere in the app closed the card.
- Onboarding registered the login item before the reader chose.
- Downloading after picking Apple's model left Apple's model selected.
- The eye could sit off-screen or under the menu bar.
- The menu went stale; it's now rebuilt on open.
- VoiceOver labels on the card buttons and the eye.
- AX calls could block main for ~6 s; the global timeout is now 0.5 s.
- Cancelled requests no longer read their prompt; a failed context waits a minute before retrying.
- Translocated (run from Downloads): menu says to move it, Open at Login and Check for Updates are off.
- Release zip had ._ AppleDouble files; release.sh now checks branch, push state and existing tag.
- Privacy page and README: history keeps the app name, Clear moves to Trash, the Ollama check, the miss note. Miss traces no longer carry a PDF file name or the character.

Still open:
- The usage simulation. It posts real clicks, so run it when no system dialog is on screen.
- Names get glosses (王小明 = king/young/clear). Post-launch.
- Tone sandhi (一, 不) isn't shown. A display decision.
- Kangxi radicals and compatibility ideographs from PDFs aren't normalised.
- "Windows coming soon" on the site: confirm or remove.

- [x] [me] Run the usage simulation (`Simulation.swift`) for a long session: no crashes, flat memory, the model unloaded after 5 idle minutes. Done 2026-11-18: six runs back to back, 126/126 each, footprint 600 to 770 MB with no growth; idle, the model let go at 5 minutes (3.3 GB resident to 431 MB).
- [ ] [me] Through sleep and wake, and with the network changing (proxy on and off), the next lookup still works.
- [x] [me] Failures stay contained: a corrupt or truncated model file, a corrupt history file, missing resources, and low disk. Each should end in a clear message, not a crash or hang. Fixed after an audit and real tests:
  - the download progress froze on a retry
  - an error page could spoil a resume
  - a damaged download was trashed rather than removed
  - the history write crashed on a full disk
  - a model that wouldn't load was treated as ready and couldn't be downloaded again
  - quitting mid-lookup could free the model during a decode
- [x] [me] Check the speed numbers DEVELOPMENT.md promises: about 0.15 s for a word and 1 to 2 s for a sentence. Measure cold start as well (first lookup after launch, with the model loading). Done 2026-11-18 on an M5 Pro: card open 72 ms after the click, translation at 147 ms, words by 0.9 s; a fresh process with the model load 0.6 s for a word and 1.2 s for a phrase. Not measured: cold from disk after a restart, and an 8 GB M1.
- [ ] [you] Test on the lowest Mac we support, ideally an 8 GB M1. That covers memory pressure from the mapped model and the slowest speeds.
- [x] [me] Look at energy use while idle: no busy timers or polling, and Activity Monitor's energy figure near zero. Measured: 0% CPU, about 0.2 wakeups/s, 12 MB.
- [x] [me] Look at crash and log output. What does a user send us when something breaks? Is it written down? Done 2026-11-18: release builds keep no log but the history. README now has "Something broke?" (Report a Problem, which app, the crash report from Console). Report a Problem now sends the build number and asks which app; the issue template matches.
- [x] [me] Second audit, 2026-11-18 (five reviews: saved data, thread safety, fuzzing, data, website). Fixed:
  - history: a bad byte hid all of it, a failed open replaced it, a cut-off line ate the next, the move could duplicate it; quick lookups replaced by a newer card weren't logged; one copy of the app at a time; CSV formula injection and UTC dates; Anki quotes
  - quitting during the first model load; an onboarding leak; the ⌘C fallback running twice or restoring over a later copy; Accessibility ranges that could trap; a looping parent chain; the download flipping back to "Downloading"
  - phrase cards dropped every word after an emoji or invisible character; malformed short meanings (咱们, 大厦, the Heavenly Stems); "also pr.", "also written" and "same as" listed as meanings
  - traditional text now gets the hand-set meaning order and the cues; a dead cue, a duplicate note, a note against its gloss, an example without its word
  - site: the card works from the keyboard, Firefox's keyboard path, reduced-motion install steps, lang tags, privacy wording
  - Left: traditional text still splits a little differently (4 of 110 sentences); site contrast on phones and video size are design calls.

## 5. Updates and versioning

- [x] [me] **Version scheme, written down.**
  - Marketing version (`CFBundleShortVersionString`) is set by hand for each release, not hard-coded. The script could take it as an argument, read a VERSION file, or use the git tag.
  - The build number is the commit count, so it only grows. Note the risk: a rebase or squash of main could lower it.
- [x] [me] Check the appcast: `sparkle:version`, the short version, the minimum OS, arm64, the EdDSA signature, the length, and markdown release notes that read well in Sparkle's window.
- [~] [both] **End-to-end update test (the big one).** Done 2026-11-18 from the real 0.1 to a 1.0 build on a local feed: installed on quit, no quarantine, same signing requirement, settings kept. Still to see with your eyes: "Accessibility: allowed" in the menu after updating, and the update window itself. Start with 0.1 installed and set up: Accessibility granted, the model downloaded, history recorded, Open at Login on. Then publish the next build to a staging feed and check each of these:
  - the second-launch "check automatically?" prompt
  - Check for Updates finds it
  - the update installs and relaunches the app
  - **Accessibility is still granted**, because the same certificate means the same designated requirement
  - **Gatekeeper does not ask again**
  - the model, history, settings and login item all survive
  - the gentle scheduled reminder appears when no one is in the middle of reading
- [x] [me] Negative tests: (forged EdDSA refused; an ad-hoc update with a good EdDSA signature WAS installed, so release signing now refuses ad-hoc and release.sh checks the certificate)
  - An update with a bad EdDSA signature is refused.
  - An update signed with a different certificate is refused, or we know what happens.
  - "Skip this version" works.
- [x] [me] Settings migrations: an old defaults key or a new history format is upgraded, not lost (see the `cardSizeVersion` pattern). Done 2026-11-18: no key changed since 0.1; made-up 0.1 records all read; the history move is idempotent. Fixed: History now orders by date, so a downgrade and re-upgrade can't keep an older lookup over a newer one. Note for later: the `cardSizeVersion` cleanup deletes every `card.` key (pin and zoom too); copy it with care.
- [x] [me] **Bad-release plan, written in DEVELOPMENT.md.** The feed is "latest release" and Sparkle won't downgrade, so a bad release is fixed forward: a new build number out quickly. Record the steps and how long they take.
- [ ] [you] **Back up the keys** somewhere other than this Mac, such as a password manager or an encrypted USB drive. The files are `longyan-codesign.p12` with its password, and `sparkle-private-key.txt`. If they're lost, existing users can never be updated, and they would have to re-grant Accessibility.
- [x] [me] `release.sh` prints the publish command. Add a check step after publishing: fetch the live appcast and the site's zip, and confirm the version and signature. Done: `scripts/check-release.sh`, tested on the 0.1 release and on a tampered zip.

## 6. Privacy, data, and uninstalling

- [x] [me] **Network audit.** Watch the app's connections (nettop or lsof) through a whole session. The only ones allowed are the model download and Sparkle checks, and Sparkle only after you say yes. That makes the README's privacy claim checked, not just stated. Done 2026-11-18. In code, the app only reaches the model hosts, GitHub (for Sparkle, with no profile sent) and a local Ollama. Watched for 60 s after launch: no sockets.
- [x] [me] List everything the app writes: Also writes to Caches and HTTPStorages; the README lists them.
  - `~/Library/Application Support/LongyanReader/` (2.7 GB model)
  - `~/Library/Application Support/LongyanReader/History/` (history; in Logs before 1.0)
  - defaults
  - Sparkle's caches
  - the login item
  - the Accessibility entry
- [x] [me] Add uninstall steps to the README: delete the app, the model folder and the history, and remove the Accessibility entry. Possibly add a "Remove reading model" menu item to free 2.7 GB. The README now has the full list. Removing the model from the menu is not done.
- [x] [me] Is history stored under Logs the right place? Users may clear Logs and lose their history without knowing. No: from 1.0 it's in `~/Library/Application Support/LongyanReader/History/`, moved there at launch. README, privacy page and About updated.

## 7. Words people see

- [x] [me] Read every string in the app (menus, onboarding, errors, alerts, the update window) against notes/style.md: short, plain, no AI tics, no em dashes. About 150 strings reviewed. The model now has one name (reading model). Fixed: menu Title Case, plural "1 lookup", the jargon in card status lines, and plain download errors.
- [x] [me] README, site and app all match on requirements, install steps, shortcuts, disk space and privacy claims. The README is fixed: 4 GB free, Intel/macOS 14, the second Open Anyway, the history default, Apple Intelligence, the privacy lines. The site's menu mock is updated. The dictionary claim stays (your call). The site's install animation now shows the password and the second Open Anyway. The hero says "Apple silicon, macOS 15 or later". There is a privacy page at /privacy.html.
- [x] [me] Release notes for the launch version, plus a corrected sentence about the eye. Done 2026-11-18: `notes/release-1.0.md`; 0.1 put the eye in the menu bar, it's next to the selection.
- [x] [me] Check the GitHub repo: done 2026-11-18. Updated the description, website and topics, and added an issue template. Still to do: set the social preview image (only possible from the web settings).
  - description, topics and website link
  - licence shown
  - issue templates (bug report: version, macOS, what app, and the text if it's shareable)
  - nothing private committed (real-eval.tsv stays ignored)
- [x] [me] Leftover follow-up: the 走 example in App.swift:201, CLI.swift:493/752 and Simulation.swift. Replaced in the debug demo and the simulation. It stays in the CLI eval cases, which are test data no user sees.

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
