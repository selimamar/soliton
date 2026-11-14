"""`python -m soliton ...`: the `soliton` command, for when the logger is on
PYTHONPATH rather than installed (e.g. on a cluster)."""

from .cli import main

main()
