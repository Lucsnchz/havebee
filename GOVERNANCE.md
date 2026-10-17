# Project governance

Havebee is a maintainer-led open-source project created by **Luciano Sánchez**.
Luciano ([@Lucsnchz](https://github.com/Lucsnchz)) is the initial sole maintainer
and repository administrator. The canonical repository is
[Lucsnchz/havebee](https://github.com/Lucsnchz/havebee).

## Decisions and access

The maintainer has final responsibility for the official project's scope,
roadmap, design, dependencies, accepted contributions and release schedule.
Community feedback informs these decisions; voting is not required to merge or
decline a proposal. Nobody is required to accept or maintain a contribution.

Contributors use forks and pull requests. Contributing does not automatically
grant write, merge, administrative or release access. Maintainer appointments
and access changes must be explicitly approved by Luciano and documented here.

The intended repository policy is:

- Protect `main` from force pushes and deletion.
- Use pull requests and require the CI checks before merging.
- Require maintainer review of outside contributions.
- Keep administration and official release publishing with the maintainer.
- Keep signing credentials out of the repository and untrusted pull-request jobs.

Repository settings enforce permissions; this document and `CODEOWNERS` alone
do not enforce them. A sole maintainer cannot approve their own pull request, so
the initial setup must allow maintainer-authored changes without requiring a
second maintainer. Outside contributors have no direct write or merge access.

## Releases and forks

Official releases are published by the maintainer from the canonical GitHub
repository. A source tag identifies the code used for a release. Binary
distribution must include the applicable license notices and a way to obtain
its corresponding source. A CI build is a development artifact, not a signed
or notarized official release.

The source license allows independent forks. Fork maintainers make their own
decisions and must comply with the license and applicable trademark rights.
They do not gain control of this repository, the project's accounts or its
official releases. See [TRADEMARKS.md](TRADEMARKS.md).

## Ownership and continuity

Contributors retain copyright in their contributions. The DCO does not transfer
that copyright. Any future relicensing must respect all relevant rights;
maintainer status alone does not allow changing another contributor's license.
Existing GPL grants remain effective under their terms.

If project leadership changes, the maintainer will document the new roles,
repository ownership and release responsibilities publicly. Until that occurs,
there is no implied succession or automatic transfer of administrative access.
