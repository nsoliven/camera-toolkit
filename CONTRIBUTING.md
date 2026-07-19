# Contributing

Thanks for helping improve Camera Toolkit.

## Development setup

1. Use macOS 14 or newer with Xcode 16 or newer.
2. Fork and clone the repository.
3. Run `swift test --jobs 1` before making changes.
4. Keep changes focused and add tests for behavioral fixes.

## Pull requests

- Explain the user-visible problem and the chosen behavior.
- Include tests for transfer, path-safety, event, catalog, or preview changes.
- Never include real usernames, home-directory paths, mounted-volume names, server addresses, photo metadata, API keys, or database files.
- Preserve the read-only camera-source boundary and no-overwrite copy behavior.
- Run `scripts/audit-public-repo.sh` before opening the pull request.

For security-sensitive reports, follow [SECURITY.md](SECURITY.md) instead of opening a public issue.
