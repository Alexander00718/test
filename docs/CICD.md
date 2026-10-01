# CI/CD

Three workflows, one build script. Anything CI runs, you can run identically
on your own machine - there is no pipeline-only logic.

## The build script

`build/Build.ps1` is the only entry point.

```powershell
.\build\Build.ps1 -Task Lint            # PSScriptAnalyzer
.\build\Build.ps1 -Task Lint -Strict    # warnings fail too (what CI does)
.\build\Build.ps1 -Task Test            # Pester + coverage
.\build\Build.ps1 -Task Package         # zip + SHA256 into artifacts/
.\build\Build.ps1                       # all three
```

Dependencies: `.\build\Install-DevDependencies.ps1`. CI calls the same script
through the local composite action `.github/actions/setup-ps-deps`, so there is
exactly one dependency code path.

## Workflow: CI

Runs on every pull request, every push to `main`, and on demand.

| Job | Gate |
|---|---|
| **Lint** | `-Strict`: any Error **or** Warning fails |
| **Test** | any failing Pester test fails; results and coverage uploaded even on failure |
| **Build** | `needs: [lint, test]` - packages zip + SHA256 only if both passed |

Lint and Test run concurrently so a failure is obvious from the job name
without opening logs. Modules are cached under an explicit version key, so a
green run today stays green tomorrow instead of silently absorbing a new
analyzer release.

### Type checking

PowerShell has no static type checker, so there is no type-check job. The
closest equivalent is `tests/Syntax.Tests.ps1`, which parses every shipped
`.ps1`, `.psm1` and `.psd1` through the PowerShell AST parser and fails on any
syntax error. It runs inside the Test job.

## Workflow: CD

**This project has no deployment infrastructure, and the workflow does not
pretend otherwise.**

It is a Windows desktop application: no server, no container, no registry, no
domain. Its only real distribution channel is a tagged GitHub Release, handled
by `release.yml`.

`cd.yml` triggers via `workflow_run` after CI completes on `main`, so it can
never run ahead of the gates. It then branches:

- **No `DEPLOY_TARGET` variable set** (today): a job writes to the run summary
  explaining exactly what is missing. It does not fail the run.
- **`DEPLOY_TARGET` set**: the deploy job activates, rebuilds the package from
  source, and hits a placeholder step that **exits 1 on purpose** - failing
  loudly beats reporting a deployment that never happened.

### To enable CD, provide

1. A repository **variable** `DEPLOY_TARGET` naming a GitHub Environment.
2. A GitHub **Environment** of that name, with reviewers/protection as needed.
3. Any credentials that target needs, as **Environment Secrets** - never
   literals in the workflow.
4. The real deploy command, replacing the placeholder step.

Decide first what deployment means here: an MSI, a winget manifest, a signed
executable, an internal file share, or an intranet download page. That choice
determines items 3 and 4. Nothing above has been invented on your behalf.

## Workflow: Release

Triggered by a SemVer tag, or manually with a version input.

```powershell
git tag v1.0.1
git push origin v1.0.1
```

It re-runs lint and tests before packaging - a tag is never a shortcut past
the gates - then publishes a GitHub Release with the zip, the `.sha256`, and
generated notes. A tag containing a hyphen (`v1.1.0-beta1`) is marked
prerelease automatically.

Version resolution: `GITHUB_REF_NAME`, falling back to the `VERSION` file,
falling back to `0.0.0-dev`.

## Security posture

- `permissions: contents: read` on CI and CD. Only `release.yml` requests
  `contents: write`, and only to create the Release.
- No workflow references any secret. The repository needs none; the Release
  job uses the automatic `GITHUB_TOKEN`.
- Third-party actions are constrained to major version tags
  (`actions/checkout@v4`, `softprops/action-gh-release@v2`). Pinning to full
  commit SHAs is stricter and recommended for a public repository; replace
  each `@vN` with `@<40-char-sha>` to adopt it.
- `.gitignore` blocks `.env`, `*.pfx`, `*.snk`, `*.p12` and `secrets.json`.
  The repository contains none today - these are guards, not fixes.
- `concurrency` on Release uses `cancel-in-progress: false`, so a publish is
  never interrupted halfway.

## What is tested, and what is not

**Tested (44 test cases across 10 groups, 100% coverage of the core module):**
the 2-minute threshold and its boundaries, one-alarm-per-episode, re-arming
after movement, lock-screen suppression including the no-ambush-after-unlock
rule, pause semantics, the sleep/suspend delta guard, config merging from real
`ConvertFrom-Json` shapes, jitter rejection, and the persisted day-record shape.

**Not tested, and honestly cannot be cheaply:**

- The WinForms UI. There is no headless display on a GitHub runner, so the
  window, tray icon and balloon toast get a parse check and nothing more.
- The Win32 lock probe. `OpenInputDesktop` cannot be exercised on a runner
  that is never locked. The *decision* built on the signal is fully tested;
  the *signal* is not.
- Actual audio output.

So CI proves the logic is right. It does not prove the app launches. Run it
once by hand after a release.

## Recommended repository settings

- Protect `main`: require the **Lint**, **Test** and **Build** checks to pass.
- Require a linear history; `release.yml` assumes tags point at commits that
  already passed CI.

## Not included, deliberately

- **Code signing.** An unsigned `.ps1` needs `-ExecutionPolicy Bypass`.
  Signing needs a certificate you would have to buy and a secret to store.
- **Dependabot.** Worth adding for the action versions if this repository
  outlives a few months.
- **Docker.** There is nothing to containerise; the app is a Windows desktop
  program driven by Win32 APIs.
