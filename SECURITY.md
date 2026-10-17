# Security policy

## Report a vulnerability privately

Use [Security → Report a vulnerability](https://github.com/Lucsnchz/havebee/security/advisories/new)
to send a private vulnerability report to the maintainer. If that button is
unavailable, open an issue that only requests a private contact channel; do not
include the vulnerability or sensitive details in the public issue.

Include the affected commit or release, macOS and tool versions, a minimal
reproduction using synthetic data, the expected and actual behavior and the
potential impact. Suggested fixes are welcome. Do not attach real access
tokens, private keys, customer data or conversation archives.

The maintainer will assess the report and coordinate a fix and disclosure.
This volunteer project does not promise a response deadline, paid support or
a bug bounty. Please allow time to investigate before publishing exploit details.

## Supported versions

During early development, fixes target `main` and the latest published release,
if one exists. Older builds do not have a separate maintenance commitment.
Please reproduce on the latest code when practical.

## Security boundaries

This app launches local shells and AI CLIs with your account's permissions.
It is not a sandbox for untrusted repositories, commands, agents or MCP servers.
Review project setup and teardown commands and worktree file-copy selections
before running them. Environment files and conversation histories may contain
sensitive data even when the app stores them locally.

Agent services have their own authentication, data handling and terms. Report
issues in third-party tools to their owners, while letting this project know
if its integration contributes to the problem.
