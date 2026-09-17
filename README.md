# I Love Token — Codex distribution

This repository mirrors **official OpenAI Codex stable Windows packages** to
Cloudflare R2 for a more reliable download path.

## Security model

- Stable release metadata comes from `openai/codex` GitHub Releases.
- Package files are downloaded from the official release.
- Every downloaded asset is verified against GitHub's SHA-256 digest.
- Codex package binaries are uploaded to R2 **byte-for-byte and unmodified**.
- The official `install.ps1` is patched automatically in one place only:
  `https://releases.openai.com/codex` becomes
  `https://download.ilovetoken.online/codex`.
- If that exact one-line patch is no longer possible, the workflow fails closed.
- No API keys or I Love Token user credentials are stored in this repository.

## Repository setup

Recommended repository name:

`ilovetoken-distribution`

A public repository is recommended so users can audit the installer logic.

### 1. Create a bucket-scoped R2 API token

In Cloudflare:

`R2 Object Storage -> Manage R2 API Tokens -> Create API Token`

Use **Object Read & Write** access and scope it only to:

`ilovetoken-downloads`

Do not paste these credentials into chat or commit them to Git.

### 2. Add GitHub Actions secrets

In GitHub:

`Settings -> Secrets and variables -> Actions -> New repository secret`

Create exactly:

- `R2_ACCOUNT_ID`
- `R2_ACCESS_KEY_ID`
- `R2_SECRET_ACCESS_KEY`

The bucket and public domain are intentionally non-secret and are set in the
workflow:

- bucket: `ilovetoken-downloads`
- public base: `https://download.ilovetoken.online`

### 3. Run the workflow manually

Open:

`Actions -> Sync Codex stable release to R2 -> Run workflow`

The job also runs once per day.

## Expected R2 objects after the first successful run

```text
codex/
├── channels/
│   └── latest
└── releases/
    └── <stable-version>/
        ├── release.json
        ├── codex-package-x86_64-pc-windows-msvc.tar.gz
        ├── codex-package-aarch64-pc-windows-msvc.tar.gz
        └── codex-package_SHA256SUMS

installer/
└── codex-install.ps1
```

## Phase 2 validation

After the workflow succeeds, do these public checks:

```powershell
irm https://download.ilovetoken.online/codex/channels/latest
```

You should see JSON containing a stable tag such as `rust-v0.xxx.x`.

Then, on a clean/test Windows machine:

```powershell
powershell -ExecutionPolicy ByPass -c "irm https://download.ilovetoken.online/installer/codex-install.ps1 | iex"
```

After installation:

```powershell
codex --version
```

Only after this mirror installation path is confirmed should
`installer/windows.ps1` become the public I Love Token one-line setup wrapper.

## Why Windows first?

It gives us one small, testable path before we add macOS and Linux. Once Windows
works, the same sync job can mirror the official Apple/Linux package assets and
the official `install.sh`.
