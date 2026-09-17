#!/usr/bin/env python3
"""
Mirror the latest stable OpenAI Codex Windows standalone packages to Cloudflare R2.

Security properties:
- Uses GitHub's /releases/latest endpoint (stable release, not prerelease).
- Verifies every downloaded asset against the SHA-256 digest returned by GitHub.
- Mirrors the official package archives byte-for-byte; binaries are never modified.
- Only the official PowerShell installer text is patched, replacing its release
  base URL with the I Love Token R2 mirror. The patch must occur exactly once,
  otherwise the job fails closed.
"""

from __future__ import annotations

import hashlib
import json
import os
import shutil
import sys
import tempfile
import urllib.request
from pathlib import Path

import boto3
from botocore.config import Config

GITHUB_LATEST = "https://api.github.com/repos/openai/codex/releases/latest"

WINDOWS_ASSETS = [
    "codex-package-x86_64-pc-windows-msvc.tar.gz",
    "codex-package-aarch64-pc-windows-msvc.tar.gz",
    "codex-package_SHA256SUMS",
    "install.ps1",
]

OFFICIAL_RELEASE_BASE = "https://releases.openai.com/codex"


def required_env(name: str) -> str:
    value = os.environ.get(name, "").strip()
    if not value:
        raise RuntimeError(f"Required environment variable is missing: {name}")
    return value


ACCOUNT_ID = required_env("R2_ACCOUNT_ID")
ACCESS_KEY_ID = required_env("R2_ACCESS_KEY_ID")
SECRET_ACCESS_KEY = required_env("R2_SECRET_ACCESS_KEY")
BUCKET = os.environ.get("R2_BUCKET", "ilovetoken-downloads").strip()
PUBLIC_BASE = os.environ.get(
    "PUBLIC_BASE", "https://download.ilovetoken.online"
).rstrip("/")
GITHUB_TOKEN = os.environ.get("GITHUB_TOKEN", "").strip()

R2_ENDPOINT = f"https://{ACCOUNT_ID}.r2.cloudflarestorage.com"

s3 = boto3.client(
    "s3",
    endpoint_url=R2_ENDPOINT,
    aws_access_key_id=ACCESS_KEY_ID,
    aws_secret_access_key=SECRET_ACCESS_KEY,
    region_name="auto",
    config=Config(signature_version="s3v4"),
)


def github_request(url: str) -> urllib.request.Request:
    headers = {
        "Accept": "application/vnd.github+json",
        "User-Agent": "ilovetoken-codex-mirror/1.0",
        "X-GitHub-Api-Version": "2022-11-28",
    }
    if GITHUB_TOKEN:
        headers["Authorization"] = f"Bearer {GITHUB_TOKEN}"
    return urllib.request.Request(url, headers=headers)


def fetch_json(url: str) -> dict:
    with urllib.request.urlopen(github_request(url), timeout=30) as response:
        return json.load(response)


def download(url: str, destination: Path) -> None:
    req = github_request(url)
    with urllib.request.urlopen(req, timeout=300) as response, destination.open("wb") as out:
        shutil.copyfileobj(response, out, length=1024 * 1024)


def sha256_file(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def digest_from_asset(asset: dict) -> str:
    raw = str(asset.get("digest") or "")
    prefix = "sha256:"
    if not raw.lower().startswith(prefix):
        raise RuntimeError(
            f"GitHub did not provide a SHA-256 digest for {asset.get('name')}: {raw!r}"
        )
    digest = raw[len(prefix):].lower()
    if len(digest) != 64 or any(c not in "0123456789abcdef" for c in digest):
        raise RuntimeError(f"Invalid SHA-256 digest for {asset.get('name')}: {raw!r}")
    return digest


def verify(path: Path, expected: str, label: str) -> None:
    actual = sha256_file(path)
    if actual != expected:
        raise RuntimeError(
            f"SHA-256 mismatch for {label}: expected {expected}, got {actual}"
        )
    print(f"[OK] SHA-256 verified: {label} ({actual[:12]}…)")


def object_exists(key: str) -> bool:
    try:
        s3.head_object(Bucket=BUCKET, Key=key)
        return True
    except Exception:
        return False


def upload_file(
    local_path: Path,
    key: str,
    *,
    content_type: str,
    cache_control: str,
) -> None:
    print(f"[UPLOAD] {key}")
    s3.upload_file(
        str(local_path),
        BUCKET,
        key,
        ExtraArgs={
            "ContentType": content_type,
            "CacheControl": cache_control,
        },
    )


def put_bytes(
    data: bytes,
    key: str,
    *,
    content_type: str,
    cache_control: str,
) -> None:
    print(f"[UPLOAD] {key}")
    s3.put_object(
        Bucket=BUCKET,
        Key=key,
        Body=data,
        ContentType=content_type,
        CacheControl=cache_control,
    )


def version_from_tag(tag: str) -> str:
    if not tag.startswith("rust-v"):
        raise RuntimeError(f"Unexpected Codex stable release tag: {tag!r}")
    version = tag[len("rust-v"):]
    pieces = version.split(".")
    if len(pieces) != 3 or not all(p.isdigit() for p in pieces):
        raise RuntimeError(f"Refusing unexpected non-stable version: {version!r}")
    return version


def main() -> None:
    print("[INFO] Fetching latest stable Codex release metadata from GitHub…")
    release = fetch_json(GITHUB_LATEST)

    if release.get("draft") or release.get("prerelease"):
        raise RuntimeError("GitHub /releases/latest unexpectedly returned a draft/prerelease.")

    tag = str(release.get("tag_name") or "")
    version = version_from_tag(tag)
    print(f"[INFO] Latest stable Codex: {version} ({tag})")

    by_name = {asset["name"]: asset for asset in release.get("assets", [])}
    missing = [name for name in WINDOWS_ASSETS if name not in by_name]
    if missing:
        raise RuntimeError(f"Stable release is missing required assets: {missing}")

    immutable_keys = [
        f"codex/releases/{version}/{name}"
        for name in WINDOWS_ASSETS
        if name != "install.ps1"
    ]
    metadata_key = f"codex/releases/{version}/release.json"
    patched_installer_key = "installer/codex-install.ps1"

    if (
        all(object_exists(key) for key in immutable_keys)
        and object_exists(metadata_key)
        and object_exists("codex/channels/latest")
        and object_exists(patched_installer_key)
    ):
        # Still inspect the public latest metadata. If it already names this version,
        # the mirror is complete and we can avoid ~260 MB of redundant downloads.
        try:
            with urllib.request.urlopen(
                f"{PUBLIC_BASE}/codex/channels/latest", timeout=15
            ) as response:
                mirrored = json.load(response)
            if mirrored.get("tag_name") == tag:
                print("[INFO] Mirror already has this stable release. Nothing to do.")
                return
        except Exception as exc:
            print(f"[WARN] Could not read public channel metadata ({exc}); re-validating mirror.")

    with tempfile.TemporaryDirectory(prefix="codex-mirror-") as tmp:
        tmpdir = Path(tmp)

        downloaded = {}
        for name in WINDOWS_ASSETS:
            asset = by_name[name]
            target = tmpdir / name
            print(f"[DOWNLOAD] {name}")
            download(asset["browser_download_url"], target)
            expected = digest_from_asset(asset)
            verify(target, expected, name)
            downloaded[name] = target

        # Mirror the official binary package archives byte-for-byte.
        for name in WINDOWS_ASSETS:
            if name == "install.ps1":
                continue
            content_type = (
                "text/plain; charset=utf-8"
                if name == "codex-package_SHA256SUMS"
                else "application/gzip"
            )
            upload_file(
                downloaded[name],
                f"codex/releases/{version}/{name}",
                content_type=content_type,
                cache_control="public, max-age=31536000, immutable",
            )

        # Create minimal release metadata compatible with OpenAI's installer.
        mirrored_assets = []
        for name in WINDOWS_ASSETS:
            if name == "install.ps1":
                continue
            asset = by_name[name]
            mirrored_assets.append(
                {
                    "name": name,
                    "digest": asset["digest"],
                    "browser_download_url": (
                        f"{PUBLIC_BASE}/codex/releases/{version}/{name}"
                    ),
                    "size": asset.get("size"),
                }
            )

        release_metadata = {
            "tag_name": tag,
            "name": release.get("name") or version,
            "draft": False,
            "prerelease": False,
            "published_at": release.get("published_at"),
            "assets": mirrored_assets,
        }
        metadata_bytes = (
            json.dumps(release_metadata, ensure_ascii=False, indent=2) + "\n"
        ).encode("utf-8")

        put_bytes(
            metadata_bytes,
            metadata_key,
            content_type="application/json; charset=utf-8",
            cache_control="public, max-age=31536000, immutable",
        )
        put_bytes(
            metadata_bytes,
            "codex/channels/latest",
            content_type="application/json; charset=utf-8",
            cache_control="no-cache, max-age=60",
        )

        # Patch only OpenAI's release base URL. If upstream changes the installer,
        # fail closed instead of publishing a potentially broken installer.
        official_installer = downloaded["install.ps1"].read_text(
            encoding="utf-8-sig"
        )
        mirror_base = f"{PUBLIC_BASE}/codex"
        replacement_count = official_installer.count(OFFICIAL_RELEASE_BASE)
        if replacement_count != 1:
            raise RuntimeError(
                "Refusing to patch official installer: expected exactly one "
                f"{OFFICIAL_RELEASE_BASE!r}, found {replacement_count}."
            )

        patched = official_installer.replace(OFFICIAL_RELEASE_BASE, mirror_base)
        header = (
            "# I Love Token Codex mirror installer\n"
            "# Derived automatically from the official OpenAI Codex release installer.\n"
            "# Only the release base URL is changed; Codex package binaries are unmodified.\n"
            f"# Mirrored stable version at publication time: {version}\n\n"
        )
        put_bytes(
            (header + patched).encode("utf-8"),
            patched_installer_key,
            content_type="text/plain; charset=utf-8",
            cache_control="no-cache, max-age=300",
        )

    print("")
    print("[DONE] Codex stable mirror is synchronized.")
    print(f"[INFO] Channel: {PUBLIC_BASE}/codex/channels/latest")
    print(f"[INFO] Installer: {PUBLIC_BASE}/installer/codex-install.ps1")


if __name__ == "__main__":
    try:
        main()
    except Exception as exc:
        print(f"[ERROR] {exc}", file=sys.stderr)
        raise
