# Contributing to tailroute

Thanks for your interest! We welcome bug reports, feature requests, and pull requests.

## Report a Bug

1. Check existing [GitHub Issues](https://github.com/shrwnsan/tailroute-cli/issues)
2. Include:
   - macOS version (`sw_vers`)
   - Tailscale version (`tailscale version`)
   - VPN app + version
   - Steps to reproduce
   - Logs: `tail -50 /var/log/tailroute.log`
   - Daemon status: `tailroute status`

## Submit a Pull Request

1. Fork the repository
2. Create a branch: `fix/dns-toggle-race` or `feat/new-feature`
3. Make changes
4. Test locally: `bash tests/run-tests.sh`
5. Push and open a PR

## Development Guidelines

### Code Style

- **Language**: bash (POSIX-compatible)
- **Shellcheck**: Must pass `shellcheck` linting
- **Indentation**: 2 spaces
- **Security**: Use absolute paths, validate inputs, no `eval`

### Testing

Every change needs tests:

```bash
bash tests/run-tests.sh
```

Add unit tests to `tests/test-lib-*.sh`.

## Architecture

See [docs/architecture.md](docs/architecture.md) for technical overview.

## License

By contributing, you agree your work will be licensed under [Apache 2.0](LICENSE).
