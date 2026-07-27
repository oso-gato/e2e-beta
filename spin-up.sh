#!/usr/bin/env bash
#
# e2e-beta — the interactive way in. A questionnaire, not a runner.
#
# This script asks for the four knobs run.sh documents, puts the answers in the
# environment, and hands the process over to run.sh. It contains no engine
# flags and no engine invocation of its own: no published port, no healthcheck,
# no restart policy, no container-start command anywhere in this file.
# Not because those are unimportant, but because run.sh already declares them.
# A second declaration here could drift out of step with the first, and the
# whole point of having one sanctioned run path is that it cannot.
#
# DEFAULTS LIVE IN run.sh AND DELIBERATELY NOT HERE. A blank answer does not
# mean "no answer" — it means "whatever run.sh says". It is implemented by
# leaving that knob UNSET in the environment handed over, so run.sh applies its
# own default. Note the consequence, which is intended: a blank answer clears a
# value inherited from the caller's environment rather than silently keeping
# it, so "blank" means run.sh's default every time and not merely usually.
# Printing the defaults into the prompts would be the easy alternative and the
# wrong one — it would make this file a second place the runtime is described.
#
# NON-INTERACTIVE INPUT: end-of-file counts as a blank answer, so
# `./spin-up.sh < /dev/null` is exactly "run.sh with all of its defaults".
#
# EXIT STATUS: whatever run.sh exits with — this process becomes run.sh. Zero
# therefore carries run.sh's meaning (the container is running AND healthy),
# not a weaker "the wizard finished".

set -euo pipefail

# Answers are relative to the repo, not to wherever the operator happens to be
# standing, so `exec ./run.sh` resolves the run.sh that ships beside this file.
cd "$(dirname "$0")" || exit 1

if [[ ! -x ./run.sh ]]; then
    printf 'spin-up.sh: ./run.sh is missing or not executable — nothing to delegate to\n' >&2
    exit 1
fi

# Ask for one knob. A non-blank answer is exported under $1; a blank answer or
# EOF unsets it, which is how "use run.sh's default" is expressed.
ask() {
    local var="$1" prompt="$2" answer=""

    if ! IFS= read -r -p "$prompt" answer; then
        printf '\n' >&2 # EOF leaves the cursor mid-prompt; close the line.
    fi

    if [[ -n "$answer" ]]; then
        export "${var}=${answer}"
    else
        unset "$var"
    fi
}

printf "e2e-beta — press Enter to take run.sh's default for any answer.\n\n" >&2

ask IMAGE     'IMAGE     (image to run)          : '
ask NAME      'NAME      (container name)        : '
ask PORT      'PORT      (port in the container) : '
ask HOST_PORT 'HOST_PORT (port on the host)      : '

printf '\nspin-up.sh: handing over to ./run.sh\n\n' >&2

exec ./run.sh
