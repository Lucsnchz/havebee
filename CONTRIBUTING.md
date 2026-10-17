# Contributing to Havebee

Contributions can be bug reports, documentation, accessibility improvements,
translations or code. English and Spanish are welcome.

## Before starting

Search existing issues and pull requests. For a substantial feature or change
in behavior, open an issue describing the problem and proposed approach before
implementing it. Small fixes can go straight to a pull request.

Use synthetic examples. Remove credentials, private paths, conversations and
customer information from attachments. For security issues, follow
[SECURITY.md](SECURITY.md) instead of opening a public report.

## Local workflow

1. Fork the repository and create a branch from `main`.
2. Make a focused change. Keep unrelated formatting and refactoring separate.
3. Run the checks relevant to the change. For application changes, run
   `scripts/test.sh` and `scripts/build-app.sh` on macOS.
4. Add regression tests for behavior changes where they can catch the original
   problem. For UI changes, check light and dark appearance and narrow and wide
   windows. Include screenshots with synthetic data when useful.
5. Sign off your commits and open a pull request. Explain the user-visible
   problem, final behavior and checks performed, including anything untested.

The pinned dependency currently requires Swift 6.2 or later. See the
[README](README.md#build-and-run) for build requirements.

Keep pure decisions in `HiveCore` and UI coordination in `HiveKit`. Prefer
injected dependencies, temporary folders and fake agent processes in tests.
Do not make tests depend on a contributor's AI account, real conversation
history, project folders or standard user defaults.

## License and Developer Certificate of Origin

By intentionally submitting a contribution, you offer your original changes
under this project's `GPL-3.0-only` license. Existing third-party material must
retain its notices and have compatible licensing; identify its origin in the
pull request. Contributors retain copyright in their contributions. No
copyright assignment is required.

New contributions must comply with the [Developer Certificate of Origin 1.1](DCO).
Read it before signing. Add a sign-off to each commit using:

```bash
git commit -s
```

This adds a trailer using your configured Git name and email:

```text
Signed-off-by: Your Name <you@example.com>
```

Use your own identity and only certify contributions you have the right to
submit. A GitHub-provided no-reply email can protect your personal address.
Commit metadata and sign-offs become public. A sign-off is a DCO certification,
not a cryptographic signature or a transfer of ownership. The initial import
predates this policy; it is not necessary to rewrite historical commits.

AI-assisted contributions are welcome. You remain responsible for checking
their correctness, origin, licensing and tests. Mention material AI assistance
when it helps reviewers understand the change, and never submit private data
from another project.

## Review

The maintainer decides whether and when to merge. Passing CI is necessary but
does not guarantee acceptance. Review may request changes, a smaller scope or
a different approach. Be respectful, discuss the work and do not harass other
contributors. See [GOVERNANCE.md](GOVERNANCE.md).
