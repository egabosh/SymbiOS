#!/bin/bash
# SymbiOS - shell-injection guard for external-system playbook parameters.
#
# External playbooks target minimal OpenWrt images without Python, so their
# tasks use `raw` shell strings. This validator rejects parameter values that
# could break out of a shell word, start a command substitution or inject extra
# UCI/config lines on the target. It is called both when parameters are saved
# (symbios-external-params.sh set) and immediately before a playbook run
# (symbios-run-remote-playbook.sh), so saved values and direct CLI runs cannot
# bypass it.
#
# Quotes, spaces and non-ASCII text are allowed: the UCI setters quote values
# with Ansible's `| quote` filter. Rejected are control characters (CR, LF,
# NUL), command substitutions ($( ... ), ${ ... }, backticks) and shell
# operators (;, |, &, backslash).

function f_usage {
  cat << EOF
Usage: $(basename "$0") [--json-stdin]

Read a JSON object on stdin and validate every string value for shell-unsafe
characters. The --json-stdin option is required.

Options:
  --json-stdin  read the JSON object from stdin (required)
  -h, --help    show this help and exit

Output:
  stdout   offending parameter paths, one per line (empty when all are safe)
  stderr   diagnostic message when the input is not an object
Exit codes:
  0  all values safe
  2  usage error or at least one unsafe value
EOF
}

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]
then
  f_usage
  exit 0
fi

if [[ $# -ne 1 || "${1:-}" != "--json-stdin" ]]
then
  f_usage >&2
  exit 2
fi

g_json=$(cat)
if ! printf '%s' "${g_json}" | jq -e 'type == "object"' > /dev/null 2>&1
then
  printf 'Expected a JSON object on stdin\n' >&2
  exit 2
fi

# Use explicit contains() checks rather than a regex character class: jq's
# Onigmo regex treats \u0000 as the literal characters u, 0, 0, 0, 0, which
# would flag every value containing "u" or "0" as unsafe.
g_unsafe=$(
  printf '%s' "${g_json}" | jq -r '
    def unsafe:
      contains("\r") or contains("\n") or contains("\u0000") or
      contains("`") or contains(";") or contains("|") or contains("&") or
      contains("\\") or contains("$(") or contains("${");
    [paths(scalars) as $p
     | {k: ($p | join(".")), v: getpath($p)}
     | select((.v | type) == "string")
     | select(.v | unsafe)
     | .k] | unique[]
  '
)

if [[ -n "${g_unsafe}" ]]
then
  printf '%s\n' "${g_unsafe}"
  exit 2
fi

exit 0
