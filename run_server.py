import sys

# `--lint-draft`: `improve` asks the core to compile the code
# in a draft before its reviewer is allowed to say "keep". It is a CLI and not
# an endpoint because IDE agents call `improve` whether or not the Delegator
# window is open.
from delegator_core.draft_check import maybe_run_as_linter  # noqa: E402

if maybe_run_as_linter(sys.argv):
    sys.exit(0)

# And for `--route`: the mode router decides improve/delegate/boost/keep for an
# incoming request. It runs on the critical path of every `assist` call, so it
# must not pay for importing FastAPI, and it must work with the GUI closed.
from delegator_core.router import maybe_run_as_router  # noqa: E402

if maybe_run_as_router(sys.argv):
    sys.exit(0)

from delegator_core.main import run  # noqa: E402  (deliberately after the guard)


if __name__ == "__main__":
    run()
