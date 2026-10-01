# CI/CD

Two workflows, one build script. Anything CI runs, you can run identically
on your own machine - there is no hidden pipeline logic.

## The build script

`build/Build.ps1` is the only entry point.

```powershell
.\build\Build.ps1 -Task Lint            # PSScriptAnalyzer
.\build\Build.ps1 -Task Lint -Strict    # warnings fail too (what CI does)
.\build\Build.ps1 -Task Test            # Pester 5 + coverage
.\build\Build.ps1 -Task Package         # zip + SHA256 into artifacts/
.\build\Build.ps1                       # all three
```

One-time local setup:

```powershell
Install-Module Pester -MinimumVersion 5.5.0 -Force -SkipPublisherCheck -Scope CurrentUser
Install-Module PSScriptAnalyzer -MinimumVersion 1.22.0 -Force -Scope CurrentUser
```

## Workflow: CI

Runs on every push to `main`/`master`, every pull request, and on demand.
Runner is `windows-latest` with `shell: powershell`, which is Windows
PowerShell 5.1 - the same engine the app targets, so CI cannot pass on a
runtime the users do not have.

| Step | Gate |
|---|---|
| Lint | `-Strict`: any Error **or** Warning fails the build |
| Test | any failing Pester test fails the build |
| Upload test results | `testResults.xml` + `coverage.xml`, uploaded even on failure |
| Summarise | test totals written to the job summary |
| Package | zip + SHA256, uploaded as a build artifact |

PowerShell modules are cached by an explicit version key, so a green run today
stays green tomorrow instead of silently picking up a new analyzer release.

## Workflow: Release

Triggered by a SemVer tag, or manually with a version input.

```powershell
git tag v1.0.1
git push origin v1.0.1
```

It re-runs lint and tests before packaging - a tag is never a shortcut past the
gates - then publishes a GitHub Release with the zip, the `.sha256`, and
auto-generated notes. A tag containing a hyphen (`v1.1.0-beta1`) is marked as a
prerelease automatically.

The version comes from `GITHUB_REF_NAME`, falling back to the `VERSION` file,
falling back to `0.0.0-dev`.

## What is tested, and what is not

**Tested (36 test cases across 10 groups):** the 2-minute threshold and
its boundaries, one-alarm-per-episode, re-arming after movement, lock-screen
suppression including the no-ambush-after-unlock rule, pause semantics, the
sleep/suspend delta guard, config merging from JSON, jitter rejection, and the
persisted day-record shape.

**Not tested, and honestly cannot be cheaply:**

- The WinForms UI. There is no headless display on a GitHub runner, so the
  window, tray icon, and balloon toast are only covered by a parse check.
- The Win32 lock probe. `OpenInputDesktop` cannot be exercised on a CI runner
  that is never locked. The *decision* built on top of it is fully tested;
  the *signal* itself is not.
- Actual audio output.

So CI proves the logic is right. It does not prove the app launches. Run it
once by hand after a release.

## Recommended repository settings

- Protect `main`: require the **Lint, test, package** check before merge.
- Require a linear history; the release workflow assumes tags point at
  commits that already passed CI.

## Not included, deliberately

- **Code signing.** An unsigned `.ps1` needs `-ExecutionPolicy Bypass`. Signing
  needs a certificate you would have to buy and a secret to store; say the word
  and I will wire `Set-AuthenticodeSignature` into the release job.
- **Dependabot.** Worth adding for the actions themselves if this repo lives
  longer than a few months.
