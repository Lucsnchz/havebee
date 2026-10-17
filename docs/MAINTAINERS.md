# Maintaining the official repository

The project is maintained by Luciano Sánchez. This guide describes the intended
GitHub setup and routine work; files in the repository do not apply GitHub
permissions automatically.

## Repository access

The canonical repository is [Lucsnchz/havebee](https://github.com/Lucsnchz/havebee).
Keep it under the maintainer's account. Community members
contribute through forks; they do not need collaborator access. Adding a
collaborator with write access changes who can push and merge, so review the
governance and branch rules before doing so.

Configure these controls in GitHub after the first push:

- Public repository, with Issues and pull requests enabled.
- `main` as the default branch, with force pushes and deletion blocked.
- Pull requests required, including for the maintainer's routine changes.
- Required status checks: **macOS tests and build** and **Secret scan**.
- Resolve review conversations before merging.
- Keep the maintainer as the only account with write or administrative access.
  With one maintainer, do not require a second person's approval for the
  maintainer's own pull requests. Outside contributions still need the
  maintainer's decision to merge.
- Protect release tags matching `v*` from updates and deletion.
- Enable private vulnerability reporting and secret scanning/push protection
  where available. Keep Actions tokens read-only and require approval before
  running workflows from outside contributors.

`CODEOWNERS` names the verified maintainer account, `@Lucsnchz`.
Code ownership requests reviews; branch rules and repository access
determine who can merge.

## Reviewing a contribution

Read the changes, not just the green checks. Confirm the DCO sign-offs, third-
party provenance, licensing and relevant tests. Review workflow changes before
allowing them to run. Never pass signing credentials or other private secrets
to forked pull requests, and do not run untrusted changes on a personal machine
or a self-hosted runner with access to private projects.

The checked-in workflow uses hosted runners, read-only permissions, pinned
action revisions and a checksummed secret-scanner download. CI deliberately
does not publish releases or receive Apple signing credentials.

## Publishing a release

1. Choose a tested commit on `main` and review its CI results.
2. Update the application version and user-facing release notes in a pull request.
3. Build from that commit with its checked-in `Package.resolved`.
4. Verify the app's license notices and test the packaged app. An official
   downloadable macOS build should have the appropriate signing/notarization;
   the development script uses ad-hoc signing only.
5. Create a version tag and GitHub release from that exact commit. Include the
   corresponding source and build instructions alongside any binary download,
   with clear access at no additional charge as required by the GPL.

Do not overwrite an existing release tag with different code. Publish a new
version for corrections. Keep account recovery and signing credentials outside
the repository, under the maintainer's control.

## Existing GitLab repository

The earlier private GitLab repository can remain a backup. GitHub is intended
to be the public contribution location; avoid creating two competing issue
trackers or release histories. Preserve the original remote until the GitHub
push and repository settings have been verified.
