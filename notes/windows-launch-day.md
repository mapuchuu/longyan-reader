# Windows 1.0.0 launch day

The steps from "certification passed" to "posted", in order. Written 2026-11-24 after the Store submission. Replaces sections 4 to 7 of windows-release-checklist.md, which assumed a signed beta first.

Where things are:
- Store: submission 1 (1.0.0.0, built from win/rc-1.0.0 at 15895ce) is in certification. Hold: "Don't publish until I select Publish now".
- Branch win/launch: main with win/rc-1.0.0 merged in, plus the site's Windows links (Store page, GitHub release `windows-v1.0.0`). Main moves only by fast-forward to this branch.
- The live site already says "Mac and Windows" (2a00b11). Its Windows buttons do nothing until win/launch reaches main.

Who does what: **you** = needs your hands or your OK. **me** = Claude does it.

## Before certification passes (optional, saves an hour on the day)

1. **you** OK the tag. **me** tag the Store build and push the tag:
   ```bash
   git tag windows-v1.0.0 15895ceef461d8bf1f3b8289f4c416d4365103a7
   git push origin refs/tags/windows-v1.0.0
   ```
   windows.yml builds both installers again at that commit (same build number as the Store package) and makes a **draft** release. Drafts aren't public. The tag is.
2. **me** put the notes in and check the draft: two installers, not latest.
   ```bash
   gh release edit windows-v1.0.0 --notes-file notes/windows-release-1.0.md
   gh release view windows-v1.0.0 --json isDraft,assets --jq '.isDraft, (.assets[] | "\(.name) \(.size)")'
   ```

## The day

3. Certification email says it passed.
4. **you** Partner Center, the submission: **Publish now**. It can take a few hours to show.
5. **me** check the Store page loads and shows 1.0.0: https://apps.microsoft.com/detail/9MSR9JKZKR50
6. **you** OK, **me** publish the GitHub release as a full release, never latest:
   ```bash
   gh release edit windows-v1.0.0 --draft=false --latest=false
   ```
   Then the Mac checks. If latest moved, set it back at once (`gh release edit v1.1 --latest`).
   ```bash
   gh api repos/mapuchuu/longyan-reader/releases/latest --jq .tag_name
   curl -sIL https://github.com/mapuchuu/longyan-reader/releases/latest/download/LongyanReader.zip | grep -i '^location' | head -1
   ```
7. **you** OK, **me** move main to win/launch (deploys longyan.app). If main moved since, merge it into win/launch first and wait for green.
   ```bash
   git push origin <win/launch sha>:refs/heads/main
   ```
   Then click on the live site: Windows > "Get it from the Microsoft Store", "Installer on GitHub", and the Mac download.
8. **me** the update feed. windows-release.yml only runs once it's on main (step 7).
   ```bash
   gh workflow run windows-release -f version=1.0.0
   ```
   Read the `appcast-windows` artifact: one item, both installers, signatures, build number = `git rev-list --count windows-v1.0.0`. Then:
   ```bash
   gh workflow run windows-release -f version=1.0.0 -f publish_feed=true
   ```
9. **me** stats: `gh workflow run stats.yml`, then check the badge counts .exe downloads.
10. **you** post (drafts in launch-posts.md, Windows section).

## After

- Watch issues for a week. Windows reports come in with the PC's details filled in.
- 1.0.1 is on win/1.0.1. A Store update is a new submission with a new `.msixupload`; the GitHub build updates through the feed.
