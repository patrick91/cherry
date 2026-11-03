# Releasing Cherry

Cherry ships from GitHub Actions. Every push to `main` whose tests pass
becomes a pre-release; a stable release is a pre-release promoted with a
tag. Both are Developer ID signed and notarized, published as GitHub
releases, and listed in one Sparkle appcast,
`https://updates.cherry.patrick.wtf/appcast.xml`, which the app checks every hour.
`Packaging/release.conf` holds the release identity, the team, the feed,
the Sparkle public key, the bucket and the appcast's retention; every release
script reads it (`CHERRY_RELEASE_CONF` points them at another file).

## Channels and versions

- A version is `YYYY.MM.DD.N`: the UTC day of the build, and N counting that
  day's releases (one more than the largest N of that day's `vYYYY.MM.DD.N-pre`
  and `vYYYY.MM.DD.N` tags, drafts included). It is the app's
  `CFBundleShortVersionString`.
- A pre-release is tagged `vV-pre`; the stable release of the same version is
  tagged `vV`, on the same commit.
- The build is `<YYYYMMDDHHMMSS>.<rev7>`: the UTC build time and the first 7
  hex digits of the commit. It is the app's `CFBundleVersion`, the item's
  `sparkle:version` and the build `cherry` and `cherry-host` report
  (`cherry --version`, `cherry status`). Sparkle orders updates by it, and so
  does cherry-host's daemon handover (Host/README.md, Updates). The stamp
  never goes backwards: it is the later of now and one second after the
  previous pre-release's build.
- A stable release is always the same bytes as an earlier pre-release: the
  promotion republishes that pre-release's notarized zip and disk image and
  keeps their Sparkle signature.
- Pre-release items in the appcast carry `<sparkle:channel>prerelease</sparkle:channel>`;
  stable items carry no channel. A Mac with **Settings › Updates › Get
  pre-release builds** on sees both and takes the newest; every other Mac
  sees stable items only.

## What a push to main does

`.github/workflows/prerelease.yml` runs on every push to `main` (it has no
path filter). `app.yml` and `host.yml` skip pushes to `main` themselves;
`prerelease.yml` calls them (`workflow_call`), so each push runs the full
test suite once. Alongside them, job `appcast-config` (environment `appcast`)
reports whether the R2 credentials are set: `none`, `all` or `partial`.

When all three pass, job `build` runs on macos-26 in environment `release`,
in concurrency group `cherry-prerelease`:

1. It checks out the commit with its full history and tags, without keeping
   a token in the checkout.
2. `Scripts/release-preflight` decides whether to release at all (below).
3. `Scripts/release-plan` decides what to release. It skips a commit that is
   not newer than the newest published pre-release ("older than vV-pre"). A
   commit that is already released builds nothing and hands its tag on to
   the appcast job, so a run whose appcast write failed is healed by running
   it again. When `main` was rewritten, the tip is released anyway with a
   warning. It deletes stale pre-release drafts (never tags: a stray
   `vV-pre` tag only makes the next N skip it), picks the build id, the
   version and the tag, and writes the release notes: the commit subjects
   since the previous pre-release, merges left out (bytes that are not UTF-8
   become U+FFFD, and control characters XML cannot hold are dropped).
4. With no secret in the environment yet (but on the runner the secret steps
   use later: the accepted risk under [Secrets and
   variables](#secrets-and-variables)), it selects Xcode, installs the host
   toolchain and runs `Scripts/package-release build`: universal app and
   helpers, `--force-resolved-versions`, cargo `--locked`, Sparkle embedded,
   signed ad hoc, the notices checked, and dSYMs kept.
5. It imports the Developer ID identity into a temporary keychain and runs
   `Scripts/package-release sign`: everything is signed again inside out
   with Developer ID, the hardened runtime, a timestamp and
   `Packaging/Cherry.entitlements`, every component is checked, and a copy
   re-signed the same way, with another bundle id and support folder, is
   launched with a private `HOME` and private sockets (`Scripts/test-packaged-app`).
6. `Scripts/package-release finish` notarizes and staples the app, makes the
   Sparkle zip `Cherry-V.zip`, makes the disk image `Cherry-V.dmg` and signs,
   notarizes and staples it, and writes `SHA256SUMS` and `release.json`.
7. `Scripts/cherry-release appcast item` checks that the zip's own
   `CFBundleVersion` is the build id, signs the zip with Sparkle's
   `sign_update`, verifies the signature against the zip's own
   `SUPublicEDKey`, checks that the item parses back as a release item, and
   writes `appcast-item.xml`.
8. The dSYMs are kept as the workflow artifact `cherry-V-dsyms` for 90 days.
9. `Scripts/publish-github-release --prerelease` creates a draft release on
   the commit, uploads the four assets (`Cherry-V.zip`, `Cherry-V.dmg`,
   `SHA256SUMS`, `appcast-item.xml`) to that draft by its id, checks each
   asset's size and SHA-256 digest and that there are exactly four, and then
   publishes it as a pre-release that is never "latest". Publishing creates
   the tag, which must point at the commit. A failed or cancelled run deletes
   its draft. The keychain and the notary key are always removed.

Job `appcast` then runs on Ubuntu in environment `appcast`, in concurrency
group `cherry-appcast`. It checks out `main` for its scripts, whichever
commit was released, and runs `Scripts/publish-appcast add-release vV-pre`
(see [The appcast](#the-appcast)). Macs on the pre-release channel see the
new item at their next hourly check.

What decides whether a push releases:

| Configuration | Result |
|---|---|
| `RELEASES_PAUSED` is `true` (a repository variable) | Green with a notice; nothing is published. A dry run still works. |
| No release secret at all | Green with a warning ("nothing was published because the release environments have no secrets"); the run's summary lists the secrets and points to `Scripts/release-setup`. |
| Some secrets set, others missing | Red, naming what is missing. A dry run needs only the `release` environment's secrets: it publishes nothing, so it goes on without the `appcast` ones, with a notice. |
| `SPARKLE_PUBLIC_ED_KEY` empty in `release.conf` | Green with a warning: commit the public key. |
| `SPARKLE_ED_PRIVATE_KEY` does not match `SPARKLE_PUBLIC_ED_KEY` | Red. The key is checked again against the zip's own `SUPublicEDKey` when the item is signed. |
| `RELEASE_SKIP_SMOKE_TEST` is `true` | Releases with a warning, without launching the signed copy. Only for runners that cannot run it. |

- **`[skip ci]`** in the message of a push's last commit skips every workflow
  for that push, so it is neither tested nor released. The next push's
  pre-release includes its commits.
- **Dry run:** Actions › Pre-release › Run workflow on `main` with `dry_run`
  tests, builds, signs and notarizes `main`'s tip, keeps the zip, the disk
  image, `SHA256SUMS`, `release.json`, `appcast-item.xml` and the notary logs
  as the workflow artifact `cherry-V-dry-run` for 7 days, and publishes
  nothing: no release, no tag, no appcast item. It needs the secrets, and it
  works while releases are paused.
- **One build at a time.** Job `build` waits its turn in `cherry-prerelease`
  (`queue: max`), so a push made while another builds is released after it
  and every tested commit newer than the last pre-release is released, in
  turn. GitHub keeps at most 100 runs waiting in a group and drops the newest
  beyond that. Waiting runs are not guaranteed to start in order; an older
  commit that starts after a newer one was released is skipped, and its
  changes are already in that release. Never add `cancel-in-progress` (GitHub
  refuses it with `queue: max`).

## Promoting to stable

```bash
Scripts/promote                 # the newest published pre-release
Scripts/promote 2026.10.11.2    # that one
```

`Scripts/promote [VERSION] [--yes]` needs `gh` (signed in) and `git`. It
fetches `vV-pre`, shows its commit and release title and asks before it
creates the annotated tag `vV` ("Cherry V") on that commit and pushes that
one tag (GitHub runs no workflow when more than three tags are pushed at
once, so never push it with others). It then prints the command that
follows the promotion's run. If origin has `vV` on that commit already, it
says so and suggests `gh workflow run promote.yml -f version=V`; if `vV` is
on another commit, here or on origin, it stops.

The tag runs `.github/workflows/promote.yml`. Job `release` runs on Ubuntu
with no environment and no secrets, only the workflow token with
`contents: write`, in concurrency group `cherry-promote`, and runs `main`'s
`Scripts/promote-release` (a tag push runs the tagged commit's copy of the
workflow, so it stays thin and takes its scripts from `main`). It checks the
tag against the pre-release's commit, refuses a build the appcast lists as
pulled, deletes stale stable drafts of this tag, downloads the pre-release's
assets and checks them against its `SHA256SUMS`, and publishes the stable
release `vV` ("Cherry V") with the same zip and disk image, a copy of the
disk image named `Cherry.dmg`, a new `SHA256SUMS` and the stable
`appcast-item.xml` (no channel, links and enclosure rewritten to `vV`, the
same signature and length). Its notes are the pre-release's, after
"Promoted from vV-pre". Job `appcast` (environment `appcast`, group
`cherry-appcast`) then adds the stable item, which replaces the pre-release
item of that version.

- **Dispatch:** Actions › Promote › Run workflow with `version` (empty
  promotes the newest pre-release) does the same and creates the tag itself
  when it does not exist.
- **Running it again** for a version that is already stable publishes
  nothing (`already_stable=true`) and merges the same item again, which
  changes nothing.
- **Latest:** the stable release becomes GitHub's "latest" unless a newer
  stable release exists, so promoting an older pre-release never takes
  "latest" from a newer one. Sparkle offers the newest build anyway.
- **`Cherry.dmg`** exists on stable releases only. The README's download link,
  `https://github.com/patrick91/cherry/releases/latest/download/Cherry.dmg`,
  resolves to the latest stable release's copy.
- **Paused:** while `RELEASES_PAUSED` is `true`, job `release` refuses before
  it reads anything (the run is red) and nothing is published. A tag pushed
  meanwhile stays; once releases are unpaused, run Actions › Promote with its
  version.

What `promote-release` refuses, and the fix:

| Message | Fix |
|---|---|
| `Releases are paused (RELEASES_PAUSED is true), so … is not promoted. …` | Unpause (`gh variable set RELEASES_PAUSED --body false`), then run Actions › Promote with the version. |
| `` `X` is not vYYYY.MM.DD.N `` | Delete the tag and promote a version of that form. |
| `` There is no pre-release `vV-pre`, so `vV` promotes nothing. … `` | `git push origin :refs/tags/vV`, then promote an existing pre-release with `Scripts/promote`. |
| `` `vV` is on <sha> but `vV-pre` is on <sha>: delete it and run Scripts/promote V. `` | Delete the tag (`git push origin :refs/tags/vV`, and `git tag -d vV` locally) and run `Scripts/promote V`. |
| `V was pulled from the appcast; restore it first (Actions › Appcast › restore).` | Restore it, or promote another pre-release. |

A pre-release that is still a draft cannot be promoted either; wait for its
run to finish.

## The appcast

`https://updates.cherry.patrick.wtf/appcast.xml` is one RSS file for both channels.
It holds one item per version: a stable item replaces the pre-release item of
its version, and a pre-release item never replaces a stable one. Items are
newest first, by build. It keeps the newest 20 pre-release items and the
newest 10 stable items, counted separately (`APPCAST_KEEP_PRERELEASES`,
`APPCAST_KEEP_STABLE`); older GitHub releases stay where they are.

A build taken out of the feed is listed in its channel as
`<cherry:pulled version="V">BUILD</cherry:pulled>` (namespace
`https://updates.cherry.patrick.wtf/xmlns/appcast`). Sparkle ignores the element;
Cherry reads it to drop a pulled build it has downloaded, and no merge adds
a pulled build back (see [Pulling a bad release](#pulling-a-bad-release)).

The file is the object `appcast.xml` in the R2 bucket `cherry-updates`,
served on the custom domain `updates.cherry.patrick.wtf` (the bucket's `r2.dev` URL
stays off). Only workflow jobs write it, all through `Scripts/publish-appcast`
in environment `appcast` and concurrency group `cherry-appcast`, with
`main`'s scripts: the appcast jobs of `prerelease.yml` and `promote.yml`, and
`appcast.yml`. A write:

1. downloads the release's `appcast-item.xml` (`add-release`) and checks that
   its enclosure URL answers 200 with the item's length;
2. reads the authoritative copy through R2's S3 API (never through the
   domain), or starts an empty feed when there is none;
3. merges the item (or removes or restores a build) and checks the result
   (`Scripts/cherry-release appcast check`);
4. writes it only if nobody wrote in between (`If-Match` the ETag it read,
   `If-None-Match: *` for the first write), with `Content-Type:
   application/xml; charset=utf-8` and `Cache-Control: public, max-age=300`,
   and starts again from the read on a conflict, up to 5 times;
5. reads the object back, and warns if the public URL does not show the
   change yet.

Merges give the same bytes in any order (only which items past the
retention limits were dropped can differ), and a write that changes nothing
is skipped. Do not add a Cloudflare Cache Rule for `.xml`: the domain does not
cache the feed (`cf-cache-status: DYNAMIC`), so a change reaches Macs within
the five minutes `Cache-Control` allows, and a pulled build stops being
offered as soon.

With the R2 credentials in the environment (`CLOUDFLARE_ACCOUNT_ID`,
`AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`), `Scripts/publish-appcast show`
prints the authoritative feed. `curl -s https://updates.cherry.patrick.wtf/appcast.xml`
shows what Macs get, and `Scripts/cherry-release appcast check FEED` checks a
saved copy.

## One-time setup

In this order:

1. Run `Scripts/release-setup`. It needs `gh` signed in with admin rights on
   the repository and the Xcode command line tools. It pauses releases first
   (`RELEASES_PAUSED=true`), so pushes stay green while the rest is set up;
   then it creates the environments `release` (branch `main`) and `appcast`
   (branch `main` and tags `v*`), and sets each group of secrets from what
   you give it, never echoing a secret or writing one to disk. A run without
   `--only` goes through every part: leave the `.p12` path, the notary key's
   path or the Cloudflare account ID empty and it skips that part for now,
   then names the skipped parts above its list of what is left to do by
   hand. Run one part with
   `--only pause|environments|sparkle|developer-id|notary|cloudflare` as each
   manual step below is done; run alone, a part needs its file or account
   ID. Running it again is safe: deployment policies that exist and a
   Sparkle key already in place are kept, and the secrets of the parts it
   runs are asked for and set again.
2. The manual steps:
   - Create the **Developer ID Application** certificate of team
     `Z7Q27G3R62`. Only the Account Holder can. Export it with its private
     key as a `.p12` and give it to `release-setup --only developer-id --p12
     PATH`.
   - Create an App Store Connect **Team** API key with the **Developer**
     role, download `AuthKey_<ID>.p8` and note the issuer id:
     `release-setup --only notary --notary-key AuthKey_<ID>.p8` checks it
     with a read-only `notarytool history`.
   - The Sparkle key: `release-setup --only sparkle` generates it in your
     login keychain (account `dev.patrick.cherry`) unless it is there, writes
     its public key into `Packaging/release.conf` and sets the private key as
     a secret. It generates a key only while `release.conf` has none: when
     `release.conf` holds a public key and this Mac's keychain has no key
     (another Mac, or before restoring the backup), it stops and asks you to
     import the backed-up key with Sparkle's `generate_keys --account
     dev.patrick.cherry -f FILE`. Back the private key up in your password
     manager: losing it means the next key change must ship as a Developer
     ID–signed disk image ([Rotating keys](#rotating-keys)).
   - In Cloudflare, create the R2 bucket `cherry-updates`, connect the custom
     domain `updates.cherry.patrick.wtf` (the zone `patrick.wtf` must be in the same
     account, with no DNS record for that name yet) and keep the bucket's
     `r2.dev` URL disabled. Create an R2 **Account** API token with **Object
     Read & Write** on `cherry-updates` only, and give its keys and the
     account id to `release-setup --only cloudflare`.
   - Check that bot protection on `patrick.wtf` does not challenge Sparkle:
     `curl -A 'Cherry Sparkle/2' -I https://updates.cherry.patrick.wtf/appcast.xml`
     must not answer with a challenge (a 404 before the first release is
     fine). It must not fail its TLS handshake either: `updates.cherry` is a
     second-level name, which the zone's Universal SSL certificate
     (`patrick.wtf`, `*.patrick.wtf`) does not cover. If the custom domain
     gets no certificate of its own, turn on Total TLS (Advanced Certificate
     Manager) or move the feed to a first-level name, changing
     `SPARKLE_FEED_URL` in `Packaging/release.conf` before the first
     release (a release's app has the feed URL in its Info.plist).
   - Check both environments in Settings › Environments: their deployment
     branches and tags as above, no reviewers and no wait timer.
   - Optionally, add a tag ruleset (below).
3. Commit `Packaging/release.conf` with its `SPARKLE_PUBLIC_ED_KEY`. This push
   stays green because releases are paused.
4. Actions › Pre-release › Run workflow on `main` with `dry_run`.
5. Download the artifact `cherry-V-dry-run`, unpack the zip with `ditto -x -k`,
   and check that `spctl -a -vvv -t exec Cherry.app` says `source=Notarized
   Developer ID`, and that `xcrun stapler validate` accepts `Cherry.app` and
   `Cherry-V.dmg`.
6. `gh variable set RELEASES_PAUSED --body false`.
7. Push to `main`, or run Pre-release without `dry_run`.
8. Install that pre-release from its disk image and check it: the feed's
   headers (`curl -sI https://updates.cherry.patrick.wtf/appcast.xml`: the content
   type, `cache-control: public, max-age=300`, `cf-cache-status: DYNAMIC`),
   then, with the next pre-release, a real update (below). Promote it, so
   the README's download link works.

Decide Cherry's own LICENSE before the first public release. The repository
has none yet; the app ships the third-party notices in
`Contents/Resources/Licenses/`, and `Scripts/app-notices --check` warns about
the `TODO:` lines left in `Packaging/notices/GhosttyKit.txt`.

To check a real update, use a separate administrator account, or a standard
account that installs Cherry into `~/Applications` (a standard user cannot
write `/Applications`, so Sparkle would only offer "Update Available").
Install pre-release #1, turn on **Get pre-release builds**, run
`defaults delete dev.patrick.cherry SULastCheckTime` and open Cherry again;
once #2 is out and the sidebar shows **Restart to Update**, start a long
command in a persistent tab and click it. The windows come back with the same
program running, and `cherry status` shows the daemon at #2's build. Also
check a quit without clicking (⌘Q with #2 downloaded; Cherry opens as #2),
**Discard** in Settings › Updates (Discard Downloaded Update), and
`Scripts/install-local-app` while an update is downloaded (the local build
survives the quit).

### Secrets and variables

| Environment | Deployment branches and tags | Secrets |
|---|---|---|
| `release` | branch `main` | `DEVELOPER_ID_P12_BASE64`, `DEVELOPER_ID_P12_PASSWORD`: the "Developer ID Application: Farbun LIMITED (Z7Q27G3R62)" `.p12` with its private key, base64, and its export password. `NOTARY_KEY_P8`, `NOTARY_KEY_ID`, `NOTARY_ISSUER_ID`: the App Store Connect Team API key (PEM), its key id and its issuer id. `SPARKLE_ED_PRIVATE_KEY`: the Sparkle key, the base64 32-byte seed. |
| `appcast` | branch `main`, tags `v*` | `CLOUDFLARE_ACCOUNT_ID`, `R2_ACCESS_KEY_ID`, `R2_SECRET_ACCESS_KEY`: the R2 token with Object Read & Write on `cherry-updates` only. |

Each secret reaches only the steps that use it; the build step sees none.
Promotion's `release` job has no environment and no secret. Repository
variables: `RELEASES_PAUSED` (`true`: pushes to `main` publish no pre-release
and promotions are refused; a dry run and Actions › Appcast's `remove` and
`restore` still run, so a bad build can be pulled while paused) and
`RELEASE_SKIP_SMOKE_TEST` (`true` skips launching the signed copy; only when
the runners cannot run it, and then run `Scripts/package-release sign` with
the certificate locally after each change to `Package.swift` or signing).

**Accepted risk: one job.** The build step holds no secret, but a step is not
a job. The third-party code it runs (cargo build scripts and proc-macros,
SwiftPM packages, the Zig build of the Ghostty VT library, the toolchains it
restores from the Actions cache) shares the runner with the later steps that
hold the Developer ID (in an unlocked temporary keychain), the notary key and
the Sparkle key. A step boundary separates environment variables, not files
or processes: that code could leave a process running, or change a file a
later step runs, such as `sign_update` under `.build/artifacts` or the
checkout's scripts. The smoke test likewise launches the app's own code while
the keychain is unlocked. A leaked certificate or notary key can be revoked
and replaced; a leaked Sparkle key cannot be replaced without a hand-made
release ([Rotating keys](#rotating-keys)). The pipeline keeps one job because
`Scripts/release-plan` picks the version's N and the build id that is
compiled into the helpers, and only one serialized job (`cherry-prerelease`)
keeps another push's release from coming between that choice and the
publish. Splitting it would need: a job with no environment that plans and
builds, and passes on `Cherry.app` (as a tar, so symlinks and signatures
survive), the notes and the plan's outputs as an artifact; a job in
environment `release` that checks out afresh, downloads that artifact, takes
`sign_update` from a fresh Sparkle download whose SHA-256 is pinned in
`release.conf`, and builds nothing; and a serialization across both jobs, for
example the signing job checking again, in its own turn in
`cherry-prerelease`, that its version is still newer than the newest
pre-release before it publishes.

Optional hardening: a tag ruleset on `refs/tags/v*` that excludes
`refs/tags/v*-pre` and restricts creating such tags to admins. It also blocks
the tags Actions › Promote creates through the API unless the GitHub Actions
app is a bypass actor; check that before enabling it.

## Pulling a bad release

Sparkle never downgrades, so ship a fix forward at once, and meanwhile:

- Actions › Appcast › Run workflow with `remove` and the version
  (`YYYY.MM.DD.N`) or build (`<stamp>.<rev>`) takes every item of it out of
  the feed and lists it as pulled. No Mac downloads it after that, no merge
  adds it back, and it cannot be promoted.
- Macs that already downloaded it drop it within about 2 hours (Cherry checks
  the feed every 2 hours while an update waits), or at once with **Settings ›
  Updates › Discard** (Discard Downloaded Update); otherwise they install it
  at their next quit.
- Macs that already installed it stay on it until the fix ships.
- A build that cannot launch cannot update itself: its users install the disk
  image of a fixed release.
- Optionally delete the GitHub release. Deleting a stable release makes the
  previous stable release "latest" again, and the download link with it.
- Never edit a published release's assets: the feed's signature and length,
  and the promotion's checksums, name those bytes.

`restore` with the same version or build takes it off the pulled list. It
does not add the item back: run that release's appcast job again (or promote
it) to do that.

## Rotating keys

- **Developer ID:** for a renewed or second certificate of the same team,
  replace `DEVELOPER_ID_P12_BASE64` and `DEVELOPER_ID_P12_PASSWORD`
  (`Scripts/release-setup --only developer-id`). The app's designated
  requirement names the team, not the certificate, so privacy permissions
  and Sparkle's check of the new app's signature carry over.
- **Notary key, R2 token:** replace their secrets (`--only notary`,
  `--only cloudflare`).
- **Sparkle EdDSA key:** the apps verify an update's EdDSA signature before
  they extract it (`SUVerifyUpdateBeforeExtraction`), with the key of the
  installed build. A new key can therefore ship only in a release whose
  archive is a Developer ID–signed, notarized **disk image**, through a
  one-off appcast item that points at that disk image and is signed with the
  old key; the pipeline makes zip items only, so that release is made by hand
  while releases are paused. The order: generate a new key, set
  `SPARKLE_PUBLIC_ED_KEY` (and `SPARKLE_KEYCHAIN_ACCOUNT`) in
  `Packaging/release.conf`, publish that release, then replace
  `SPARKLE_ED_PRIVATE_KEY` and resume releases. Never change the certificate
  and the key in the same release.

## Local builds and updates

`Scripts/install-local-app` builds the release identity, `dev.patrick.cherry`,
so a local build in `~/Applications` is the copy Sparkle updates: once
`SPARKLE_PUBLIC_ED_KEY` is committed, a newer release (by build time)
replaces it when Cherry quits, or at **Restart to Update**. To keep a local
build, turn off **Check for updates automatically** in Settings › Updates.
Installing again discards an update Cherry had downloaded (the installer
removes Sparkle's installer jobs before it replaces the app), and the app
does the same at quit or at **Restart to Update** when its bundle was
replaced by hand, so a downloaded older build never overwrites a newer one.
Until it is reopened, that copy checks for nothing more and Settings ›
Updates says another build was installed.

To check packaging without Apple's services, build a release-shaped bundle
with a throwaway Sparkle key, so neither the keychain nor the committed key
is used:

```bash
S=$(mktemp -d /private/tmp/cherry-release-check.XXXXXX)
seed=$(head -c 32 /dev/urandom | base64)
pub=$(printf '%s' "$seed" | xcrun swift Scripts/sparkle-key.swift derive)
sed "s|^SPARKLE_PUBLIC_ED_KEY=.*|SPARKLE_PUBLIC_ED_KEY=$pub|" Packaging/release.conf > "$S/release.conf"
CHERRY_RELEASE_CONF="$S/release.conf" Scripts/package-release all --version 2026.10.11.1 \
  --build 20261011000000.abcdef0 --out "$S/rel" --identity - --no-notarize
SPARKLE_ED_PRIVATE_KEY="$seed" CHERRY_RELEASE_CONF="$S/release.conf" Scripts/cherry-release appcast item \
  --manifest "$S/rel/release.json" --channel prerelease --tag v2026.10.11.1-pre --repo patrick91/cherry \
  --notes /dev/null --output "$S/item.xml"
Scripts/cherry-release appcast empty --output "$S/empty.xml"
Scripts/cherry-release appcast merge "$S/empty.xml" "$S/item.xml" --output "$S/feed.xml"
Scripts/cherry-release appcast check "$S/feed.xml"
```

Remove `$S` when done.

Never launch a `dev.patrick.cherry` bundle built for a check: it would share
your preferences domain (cfprefsd ignores `CFFIXED_USER_HOME`), the update
feed and `~/Library/Application Support/Cherry`. `package-release`'s smoke
test launches only `Scripts/test-packaged-app`'s copy, which has another
bundle id and support folder, no update keys, and a private `HOME` and
sockets. With a Developer ID in your keychain, `CHERRY_RELEASE_CONF="$S/release.conf"
Scripts/package-release sign --out "$S/rel" --identity <it>` also runs the
hardened-runtime launch check locally. To launch a build of your own, give it another identity (see the
README's Local Install).

## Moving from a local build

For a Mac that runs a local build from before releases
(`dev.patrick.cherry.local` in `~/Applications/Cherry.app`):

1. **Install the new build.** Pull, then run `Scripts/install-local-app`. It
   replaces `~/Applications/Cherry.app` in place with `dev.patrick.cherry`,
   signed with your Developer ID if that certificate is in the keychain, else
   Apple Development. It updates itself only once `SPARKLE_PUBLIC_ED_KEY` is
   committed.
2. **Quit the running old Cherry, then open the new one.** The changed bundle
   makes this quit an update quit: sessions are kept and nothing is asked
   about them (busy programs in native tabs are still confirmed).
   Settings are imported once. Tabs, sessions, notes, devices, the instance
   lock and the MCP server name carry over, because the Application Support
   folder (`Cherry`) and the scheme (`cherry`) are the same; `~/.local/bin`
   symlinks and MCP configurations that point into
   `~/Applications/Cherry.app` keep working.
3. **The daemon.** The new `cherry-host` was installed at the daemon's own
   path, so the new app's first `cherry control` hands the daemon over and
   the sessions carry on; `cherry status` shows the build. If it still shows
   the old build, run `cherry restart` or Settings › Sessions › Restart
   Host…. That happens when another copy or a `dev-…` build started
   the daemon, within an hour of a handover the old build won, or when an
   update's swap raced a daemon from before the host noticed swapped bundles.
4. **Permissions.** macOS asks once more for notifications, local network (at
   the first SSH connection to a Mac on your network), folders, Automation,
   camera and microphone, and Full Disk Access if you had granted it. Remove
   the old "Cherry" entries in System Settings if you like.
5. **Turn on** Settings › Updates › **Get pre-release builds**.
6. **The old preferences domain stays.** `defaults delete
   dev.patrick.cherry.local` is optional; run it once you are happy.
7. **If you install a release disk image into `/Applications` instead,**
   remove `~/Applications/Cherry.app`, link `~/.local/bin/cherry` and
   `~/.local/bin/cherry-host` to the copies in
   `/Applications/Cherry.app/Contents/MacOS/` again, run the MCP install
   commands again (each agent's page in Settings › Agents & MCP shows them),
   and run `cherry restart`.
   Never keep both copies.

## Troubleshooting

- Logs: `log stream --predicate 'subsystem == "org.sparkle-project.Sparkle"'`
  for Sparkle, and `log stream --predicate 'subsystem == "dev.patrick.cherry"
  AND category == "Updates"'` for Cherry's updater (whether it started, and
  why not).
- Sparkle's caches, including a downloaded update:
  `~/Library/Caches/dev.patrick.cherry/org.sparkle-project.Sparkle`.
- Sparkle's internal launchd jobs: `dev.patrick.cherry-sparkle-updater` and
  `dev.patrick.cherry-sparkle-progress`. Cherry removes them to discard a
  downloaded update. The names are Sparkle's own
  (`InstallerLauncher/SUInstallerLauncher.m`): re-check them, and the delegate
  methods `SparkleBridge.requiredSelectors` names, on every Sparkle upgrade.
  Sparkle is pinned exactly in `Package.swift`.
- A downloaded update stops further checks until it installs: a Mac left
  running stays one build behind until its next quit or **Restart to
  Update**.
- Turning pre-release builds off never downgrades: the Mac stays on its
  pre-release until a newer stable release ships.
- `cherry status` shows the daemon's build after an update; see
  [Moving from a local build](#moving-from-a-local-build) when it still shows
  the old one.

## Linux, later

Linux builds of `cherry` and `cherry-host` would be separate release assets
with a manifest of their own. Sparkle ignores other assets; never put them in
`appcast.xml`.
