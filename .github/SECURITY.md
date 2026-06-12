# Security Policy

## Supported versions

force-close is a single Bash script. Only the latest release line receives
security fixes — please upgrade to the newest tag before reporting.

| Version | Supported |
| ------- | --------- |
| 5.0.x (latest) | ✅ |
| < 5.0.0 | ❌ |

## Reporting a vulnerability

**Please report security issues privately, not in a public issue.**

Use GitHub's private vulnerability reporting:
[**Report a vulnerability**](https://github.com/softganz88/force-close/security/advisories/new)
(also reachable from the repository's **Security** tab → *Report a vulnerability*).

Include what you'd put in a bug report, plus the security angle: the affected
version, how to reproduce, and the impact. As this is a small solo-maintained
project, expect an initial response within a couple of weeks; there is no
guaranteed SLA.

## Threat model — what counts as a vulnerability here

force-close runs **locally, as the invoking user**, and force-terminates
processes on the same machine. It is not a network service and holds no
secrets. Bugs that matter for security are ones where the tool can be **steered
into signaling the wrong process** or **into running attacker-controlled input
as code**. For example:

- A crafted window title, process name (`comm`), `/proc` field, or CLI pattern
  that causes the tool to select, escalate against, or signal a process the
  user did not intend — or that breaks out of its escaping into shell/regex
  execution. (Window titles and `comm` are treated as untrusted input and
  sanitized before printing; the kill pattern is ERE-escaped before `pgrep`.)
- A regression that lets the kill chain signal beyond the target's process
  subtree — e.g. reaching the session's process group and taking down the
  desktop session. This class of bug is exactly what the subtree-only design
  exists to prevent (see the v5.0.3 changelog).
- A failure of the self-tree or session-leader guards that lets the tool signal
  its own controlling terminal or a session leader.

**Out of scope:** the tool requires the privileges of the user running it and
will signal processes that user is already allowed to signal — that a user can
kill their own processes (or use `sudo` to kill others) is the intended
function, not a vulnerability. Issues that require an attacker to already have
the user's shell or root are also out of scope.
