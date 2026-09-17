# I Love Token Codex Setup - Phase 3 wrapper placeholder
#
# Do NOT publish this file as the public one-line installer yet.
# Phase 2 first verifies that the R2 mirror and the patched official installer
# work end-to-end on a clean Windows machine.
#
# When Phase 2 passes, this wrapper will:
#   1. run the mirrored official installer,
#   2. ask for the I Love Token API key locally,
#   3. back up and safely update ~/.codex/config.toml,
#   4. set the local credential,
#   5. test https://api.ilovetoken.online/v1/models,
#   6. print the final `codex` command.
#
# Kept intentionally inert for now to avoid publishing an untested credential/
# configuration migration path.

Write-Host "I Love Token Codex Setup wrapper is not published yet."
Write-Host "Phase 2: validate the mirrored official installer first."
exit 1
