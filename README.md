<p align="center">
  <img src="branding.png" alt="Takumi Guard — a panda security guard scanning RubyGems packages" width="300" />
</p>

<h1 align="center">Takumi Guard for RubyGems</h1>

<p align="center">
  <strong>Stop malicious gems before they reach your CI.</strong><br />
  A GitHub Action that routes installs through a security proxy — no secrets, no config files, two lines of YAML.
</p>

<p align="center">
  <a href="https://github.com/flatt-security/setup-takumi-guard-rubygems/actions/workflows/test.yml"><img src="https://github.com/flatt-security/setup-takumi-guard-rubygems/actions/workflows/test.yml/badge.svg" alt="CI" /></a>
  <a href="LICENSE"><img src="https://img.shields.io/github/license/flatt-security/setup-takumi-guard-rubygems" alt="License" /></a>
</p>

---

> **Not using CI?** For local setup on your laptop, see the [email registration & token management appendix](#appendix-email-registration--token-management) below.

## Contents

- [What is Takumi Guard?](#what-is-takumi-guard)
- [Quickstart (3 steps)](#quickstart)
- [Setup modes](#setup-modes)
- [Migrating existing projects](#migrating-existing-projects)
- [Inputs](#inputs)
- [Outputs](#outputs)
- [Troubleshooting](#troubleshooting)
- [Security](#security)
- [Appendix: Email registration & token management](#appendix-email-registration--token-management)

---

## What is Takumi Guard?

Every `bundle install` in your CI is a trust decision. Takumi Guard sits between your workflow and RubyGems, **blocking known-malicious gems before they execute**.

- **How it works** -- Routes installs through a security proxy (`rubygems.flatt.tech`) that checks gems against a threat database in real time.
- **What you change** -- One step in your workflow YAML. No Gemfile edits, no secrets to manage.
- **What it supports** -- **Bundler** (via a mirror in Bundler's configuration). For direct `gem install` usage, see the [appendix](#appendix-email-registration--token-management).

---

## Quickstart

**Goal:** Add Takumi Guard to any GitHub Actions workflow. No account required.

**Step 1.** Add the action to your workflow file (e.g. `.github/workflows/ci.yml`):

```yaml
steps:
  - uses: actions/checkout@v4

  - uses: flatt-security/setup-takumi-guard-rubygems@v1   # <-- add this line

  - uses: ruby/setup-ruby@v1
    with:
      bundler-cache: true
  - run: bundle exec rspec
```

> **Ordering:** Put this action *before* any step that runs `bundle install`. That includes `ruby/setup-ruby` with `bundler-cache: true`, which runs `bundle install` itself. The action does not need Ruby or Bundler, so it can be the first step after checkout.

**Step 2.** Push the change. Every `bundle install` in this job now runs through the Takumi Guard proxy. Malicious gems are blocked automatically.

**Step 3.** *(Optional)* **Want audit logging and a dashboard?** Add a Bot ID for full visibility into gem activity:

```yaml
jobs:
  build:
    runs-on: ubuntu-latest
    permissions:
      id-token: write   # Required for authentication
      contents: read
    steps:
      - uses: actions/checkout@v4

      - uses: flatt-security/setup-takumi-guard-rubygems@v1
        with:
          bot-id: "YOUR_BOT_ID"

      - uses: ruby/setup-ruby@v1
        with:
          bundler-cache: true
```

> **Where do I get a Bot ID?** Create one at [Shisho Cloud byGMO](https://cloud.shisho.dev) -- or skip this entirely. Blocking works without it. The Bot ID is a public reference key, not a secret.

---

## Setup modes

| Mode | Blocks malware | Audit logging | Account needed | Best for |
|---|:---:|:---:|:---:|---|
| **[Blocking only](#blocking-only)** | Yes | No | No | OSS projects, quick evaluation |
| **[Full protection](#full-protection)** | Yes | Yes | Yes | Production workloads |
| **[Auth-only](#auth-only-advanced)** | You manage | Yes | Yes | Custom Bundler setups |

---

### Blocking only

> **No account needed.** Add one line and you are protected.

Blocks known-malicious gems. No signup, no authentication.

```yaml
- uses: flatt-security/setup-takumi-guard-rubygems@v1
```

Good for open-source projects or quick evaluation.

---

### Full protection

> **Recommended for production.** Blocks threats _and_ logs all gem activity to your dashboard.

```yaml
permissions:
  id-token: write

steps:
  - uses: flatt-security/setup-takumi-guard-rubygems@v1
    with:
      bot-id: "YOUR_BOT_ID"
```

**Key details:**
- Auth is handled via **GitHub's built-in OIDC** -- no PATs or secrets to rotate.
- If authentication fails (invalid `bot-id`, missing OIDC permission, STS unreachable, transient upstream error), the action exits with a clear error message and the build fails. There is no silent fallback to blocking-only mode.
- Get a Bot ID from [Shisho Cloud byGMO](https://cloud.shisho.dev).

---

### Auth-only (advanced)

> **For custom setups.** You manage the Bundler mirror yourself. The action only handles authentication.

```yaml
- uses: flatt-security/setup-takumi-guard-rubygems@v1
  with:
    bot-id: "YOUR_BOT_ID"
    set-mirror: false
```

**Key details:**
- Useful for projects that need full control over Bundler configuration (e.g. a vendored `.bundle/config` or a custom `source` block in the `Gemfile`).
- Requires that you configure the mirror yourself, e.g.:
  ```bash
  bundle config set --global mirror.https://rubygems.org https://rubygems.flatt.tech
  ```
- That command needs Bundler, so it runs after `ruby/setup-ruby`. With `bundler-cache: true`, the `bundle install` inside `ruby/setup-ruby` runs before your mirror is set and does not go through the proxy. Run `bundle install` in a later step instead of using `bundler-cache: true`.
- If authentication fails, **the action exits with an error** -- there is no fallback.

---

## Migrating existing projects

Unlike npm, RubyGems does not embed the registry URL into `Gemfile.lock`. Most projects can adopt Takumi Guard without any lockfile changes.

**For Bundler:** No migration needed. The action writes a mirror for `https://rubygems.org` to Bundler's user configuration (`~/.bundle/config`), and every `bundle install` automatically routes through the proxy. Your `Gemfile` continues to say `source 'https://rubygems.org'` -- Bundler silently uses the mirror.

**If you use `bundler-cache: true`:** A cache that `ruby/setup-ruby` saved before the mirror was set holds gems fetched directly from rubygems.org, and the cache key does not change when the mirror does, so that cache keeps being restored. Change `cache-version` once so that the next run installs through the proxy:

```yaml
- uses: ruby/setup-ruby@v1
  with:
    bundler-cache: true
    cache-version: 1
```

A run that restores the cache installs nothing, so it sends no request to the proxy. The gems in a cache saved after you changed `cache-version` went through the proxy when that cache was saved; they are not checked again when the cache is restored, even if one of them is found to be malicious later.

**For gems installed via `gem install`:** The action does *not* reroute `gem install` (only Bundler). If your workflow installs gems outside Bundler, add a `gem sources` step:

```yaml
- run: |
    gem sources --remove https://rubygems.org/ || true
    gem sources --add https://rubygems.flatt.tech/
```

**For private gem sources** (`source 'https://gems.mycompany.com' do ... end`): The Bundler mirror only rewrites `rubygems.org`. Private sources are unaffected and continue to resolve directly.

---

## Inputs

| Input | Required | Default | Description |
|---|---|---|---|
| `bot-id` | No | -- | Bot ID from Shisho Cloud byGMO. Omit for blocking-only mode. |
| `set-mirror` | No | `true` | Write `<registry-url>` as the mirror for `https://rubygems.org` to Bundler's user configuration (`~/.bundle/config`). Set to `false` if you manage the mirror yourself. |
| `registry-url` | No | `https://rubygems.flatt.tech` | Registry endpoint. |
| `sts-url` | No | `https://sts.cloud.shisho.dev` | STS endpoint for token exchange. |
| `expires-in` | No | `1800` | Token lifetime in seconds (max 86400). |
| `audience` | No | `https://sts.cloud.shisho.dev` (the STS URL) | Audience for the OIDC token request. Override when your Bot trust condition expects a different value. |

---

## Outputs

| Output | Description |
|---|---|
| `token` | The access token for the registry. Only set when authenticated. |
| `token-expires-at` | ISO 8601 timestamp of token expiration. Only set when authenticated. |

The `token` output lets a step hand the token to a tool that does not read the runner's `~/.bundle/config`, such as a Docker container that does not mount it. Pass it through `env:` and name the variable without its value, so the token does not appear on the command line:

```yaml
- uses: flatt-security/setup-takumi-guard-rubygems@v1
  id: guard
  with:
    bot-id: 'BT01...'

- name: Install in a container
  env:
    GUARD_TOKEN: ${{ steps.guard.outputs.token }}
  run: |
    docker run --rm -e GUARD_TOKEN \
      -v "$PWD:/src" -w /src ruby:3.3 \
      sh -c 'export BUNDLE_RUBYGEMS__FLATT__TECH="token:$GUARD_TOKEN" && bundle config set --global mirror.https://rubygems.org https://rubygems.flatt.tech/ && bundle install'
```

`BUNDLE_RUBYGEMS__FLATT__TECH` holds the credentials for `rubygems.flatt.tech`. If you set `registry-url`, use its host in both the variable name and the mirror. Bundler names the variable `BUNDLE_` followed by the host in upper case, with each `.` replaced by `__` and each `-` by `___`: `my-registry.example.com` becomes `BUNDLE_MY___REGISTRY__EXAMPLE__COM`.

The token is a credential for your bot. Do not pass it with `docker build --build-arg` or write it into an image, because build arguments and image layers keep it after the job ends; use a BuildKit secret (`docker build --secret`) instead.

---

## Troubleshooting

| Error | Cause | Fix |
|---|---|---|
| `OIDC not available` | Missing permission on the job | Add `permissions: { id-token: write }` to your job |
| `STS returned non-JSON (HTTP N)` | An error response from STS or an upstream layer was not valid JSON (e.g. an HTML error page from a transient outage) | Usually a transient infrastructure issue. The HTTP status and a body snippet are echoed to the log to help diagnose. |
| `STS returned HTTP N without an access_token` | STS rejected the auth request | The job log includes STS's own message inside this error. Common cases: `invalid ID token` -- trust condition mismatch, check the bot's trust settings in Shisho Cloud byGMO (if the trust condition sets an audience, it must equal the value the action sends -- by default the STS URL, overridable via the `audience` input); `invalid request` -- malformed bot-id, double-check the value from your console. |
| `GitHub OIDC token fetch failed` | Could not reach `token.actions.githubusercontent.com` or got a non-200 response | Usually transient; the action retries up to 3 times. Persistent failures point at a GitHub Actions issue. |
| Gems are still fetched from `rubygems.org` | Your repository's `.bundle/config` sets its own mirror for `https://rubygems.org`, which takes precedence over the user configuration the action writes. `bundle config get mirror.https://rubygems.org` shows which value is used. | Remove that setting from the repository, or use `set-mirror: false` and manage the mirror yourself |
| `Could not find gem X` after enabling | Gem is blocked, or `bundler-cache` served a stale resolution | Run `bundle install --redownload` once, or clear the action cache |

> **Still stuck?** Open an issue on this repository with your error output and workflow file (redact any IDs).

---

## Security

- **Short-lived tokens** -- 30 minutes by default, 24 hours max.
- **Auto-masked** -- Access tokens are automatically masked in workflow logs.
- **Global bundle config** -- The action writes to `~/.bundle/config` on the ephemeral runner, or to the file that `BUNDLE_USER_CONFIG` or `BUNDLE_USER_HOME` points to. Your repository's committed `.bundle/config` is not modified.
- **Basic auth over HTTPS** -- Bundler sends `Authorization: Basic <base64(token:ACCESS_TOKEN)>` to `rubygems.flatt.tech`. The token is never written to any file tracked by git.

---

## Appendix: Email registration & token management

> **Optional.** Register your email to receive breach notifications if a gem you installed is later flagged as malicious. This works for local development -- CI workflows should use [Full protection](#full-protection) instead.

### Register

```bash
curl -X POST https://rubygems.flatt.tech/api/v1/tokens \
  -H "Content-Type: application/json" \
  -d '{"email": "you@example.com"}'
```

Check your inbox and click the verification link. You will receive a token like `tg_anon_xxx...`.

**Language preference:** Add `"language": "ja"` to receive emails in Japanese. Defaults to English (`"en"`) if omitted.

```bash
curl -X POST https://rubygems.flatt.tech/api/v1/tokens \
  -H "Content-Type: application/json" \
  -d '{"email": "you@example.com", "language": "ja"}'
```

> **Reusing an existing token:** If you have already registered with Takumi Guard for npm or PyPI, the same `tg_anon_*` token works here -- it is a universal key across all ecosystems.

### Configure Bundler

Set a global mirror and attach your token:

```bash
bundle config set --global mirror.https://rubygems.org https://rubygems.flatt.tech
bundle config set --global rubygems.flatt.tech token:tg_anon_xxx...
```

After this, every `bundle install` routes through Takumi Guard with your identity attached. If a gem you downloaded is later found to be malicious, you will receive a breach notification email.

### Configure `gem` (optional)

For direct `gem install` usage (outside Bundler):

```bash
gem sources --remove https://rubygems.org/
gem sources --add https://token:tg_anon_xxx...@rubygems.flatt.tech/
```

> **Warning:** Removing `rubygems.org` from `gem sources` means every `gem install` routes exclusively through Takumi Guard. If you need the upstream fallback, use Bundler with `bundle config mirror` instead -- it forwards uncached requests transparently.

### Check token status

```bash
curl -H "Authorization: Bearer tg_anon_xxx..." \
  https://rubygems.flatt.tech/api/v1/tokens/status
```

### Rotate your key

```bash
curl -X POST -H "Authorization: Bearer tg_anon_xxx..." \
  https://rubygems.flatt.tech/api/v1/tokens/regenerate
```

Returns a new API key. The old one is invalidated immediately. Update your Bundler configuration with the new key.

### Revoke a token

```bash
curl -X DELETE -H "Authorization: Bearer tg_anon_xxx..." \
  https://rubygems.flatt.tech/api/v1/tokens
```

---

<p align="center">
  Built by <a href="https://flatt.tech">GMO Flatt Security Inc.</a><br />
  <a href="LICENSE">MIT License</a>
</p>
