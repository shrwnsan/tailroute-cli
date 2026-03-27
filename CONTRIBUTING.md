# Contributing to tailroute

Thanks for your interest in tailroute! We welcome bug reports, feature requests, and pull requests.

## Code of Conduct

Be respectful, inclusive, and constructive. We're all here to improve macOS + VPN + Tailscale interop.

## Getting Started

### Report a Bug

1. Check existing [GitHub Issues](https://github.com/shrwnsan/tailroute/issues) first
2. Include:
   - macOS version (`sw_vers`)
   - Tailscale version (`tailscale version`)
   - VPN app + version
   - Steps to reproduce
   - Logs: `tail -50 /var/log/tailroute.log`
   - Daemon status: `tailroute status`
3. Dry-run to see what would happen: `tailroute --dry-run`

### Request a Feature

1. Describe the problem it solves
2. Explain the desired behavior
3. Consider performance/maintenance impact
4. Check [CHANGELOG.md](CHANGELOG.md) for planned features

### Submit a Pull Request

1. **Fork** the repository
2. **Create a branch** — use descriptive name: `fix/dns-toggle-race` or `feat/ipv6-support`
3. **Make changes** — see guidelines below
4. **Test locally** — run `bash tests/run-tests.sh`
5. **Write a clear commit message**:
   ```
   feat: add IPv6 support to interface detection
   
   - Detects fe80::/10 addresses correctly
   - Adds 15 new unit tests for IPv6
   - Fixes #42
   ```
6. **Push to your fork** and open a PR
7. **Link related issues** — reference bug reports or features

## Development Guidelines

### Code Style

- **Language**: bash (POSIX-compatible, no bashisms where possible)
- **Shellcheck**: Must pass `shellcheck` linting
- **Indentation**: 2 spaces (no tabs)
- **Line length**: 120 characters max
- **Comments**: Explain *why*, not what. Code should be self-documenting.

### Security Requirements

All contributions must:

- [ ] Use **absolute paths** for external commands (no bare `grep`, `awk`, etc.)
- [ ] **Validate inputs** — interface names, IPs, CIDRs before use
- [ ] **No `eval`** — ever
- [ ] **No shell escaping tricks** — use arrays and quoting
- [ ] **Maintain `root:wheel` ownership** on privileged files
- [ ] **Log sanitized output** — no raw command output to logs
- [ ] **Pass security review** — run `bash -n` on all scripts

See [Security](docs/ref/SECURITY.md) for threat model.

### Testing Requirements

**Every change needs tests.**

1. Add unit tests to `tests/test-lib-*.sh` (or create new test file)
2. Run full suite: `bash tests/run-tests.sh`
3. Target: **100% pass rate** before PR
4. Use test helpers: `test_pass()`, `test_fail()`, `assert_ok()`, `assert_fail()`

Example:
```bash
test_magicdns_disable_when_vpn_active() {
    mock_tailscale_running=true
    mock_vpn_active=true
    
    assert_ok reconcile_dry_run  # Should succeed
    assert_contains "$(reconcile_dry_run)" "Would disable MagicDNS"
}
```

### Documentation Requirements

- [ ] Update README.md if user-facing behavior changes
- [ ] Update inline code comments for complex logic
- [ ] Add entry to [CHANGELOG.md](CHANGELOG.md) (Unreleased section)
- [ ] Link to related docs (ARCHITECTURE.md, etc.)

### Commit Guidelines

- **One feature per commit** (or one bug fix)
- **Atomic commits** — each commit should be independently testable
- **No merge commits** — rebase before pushing
- **Meaningful messages** — `git log` should tell the story

### Common Tasks

#### Run all tests
```bash
bash tests/run-tests.sh
```

#### Check syntax
```bash
bash -n bin/tailroute.sh
bash -n bin/lib-*.sh
```

#### Lint with shellcheck (if installed)
```bash
shellcheck bin/tailroute.sh bin/lib-*.sh
```

#### Test a specific library
```bash
bash tests/test-lib-dns.sh
```

#### View logs from daemon
```bash
tail -f /var/log/tailroute.log
```

#### Uninstall & reinstall locally
```bash
sudo tailroute uninstall
sudo ./install.sh
tailroute status
```

## PR Review Process

1. **Automated checks**
   - Tests must pass (124/124)
   - No shellcheck errors
   - Code review by maintainers

2. **Manual review**
   - Security implications
   - Performance impact
   - Documentation quality
   - Backwards compatibility

3. **Approval & merge**
   - At least one approval from maintainer
   - All conversations resolved
   - Squash & merge to `main`

## Release Process

Maintainers use this process:

1. Update [CHANGELOG.md](CHANGELOG.md) with new version
2. Update version in `bin/tailroute.sh` (currently v0.1.0)
3. Create git tag: `git tag -a v0.2.0 -m "Release v0.2.0"`
4. Push tag: `git push origin v0.2.0`
5. GitHub Actions automatically builds & publishes

## Maintainers

- [@shrwnsan](https://github.com/shrwnsan) — Original author

## Architecture & Design

### v0.1.0 (Bash)
Before making architectural changes, read [ARCHITECTURE.md](docs/ref/ARCHITECTURE.md) and the [Product Spec](docs/plans/prd-001-tailroute.md).

Key design decisions documented in:
- `docs/plans/prd-001-*.md` — Phase summaries & decisions
- `docs/ref/ARCHITECTURE.md` — Component overview
- `docs/ref/SECURITY.md` — Threat model

### v0.2.0 (Swift, Beta)
For the new Swift rewrite:
- Read [SWIFT-ARCHITECTURE.md](docs/ref/SWIFT-ARCHITECTURE.md) for module organization
- Read [BUILD.md](BUILD.md) for development setup
- Review [BUILD.md](BUILD.md) for release build details
- Check [tasks-001](docs/plans/tasks-001-tailroute.md) for known limitations and project status

## Questions?

- **FAQ**: See [FAQ.md](docs/ref/FAQ.md)
- **Security**: See [Security.md](docs/ref/SECURITY.md)
- **Technical**: See [ARCHITECTURE.md](docs/ref/ARCHITECTURE.md)
- **Issues**: Open a GitHub issue with `[question]` prefix

## License

By contributing, you agree your work will be licensed under [Apache 2.0](LICENSE).

---

**Thank you for improving tailroute!** 🚀
