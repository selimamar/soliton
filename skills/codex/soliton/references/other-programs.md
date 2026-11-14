# Any other program: `scripts/monitor_solver.py`

For a program that isn't Python, or that you shouldn't edit (a compiled
solver in C++, Fortran or Julia, a community code, an MPI launch, a shell
pipeline), don't touch it. Launch it through the wrapper, which runs it
unchanged, passes its output through, reads the numbers it writes, and
reports a simulation:

```bash
python3 scripts/monitor_solver.py --name NAME --project PROJECT --t-end T_END \
    --setup "grid=256^3" --setup "input=run.cfg" \
    --table 'GLOB,t=COL,name=COL,...' \
    --h5 'FILE,dataset=NAME,t=COL,name=COL,...' \
    --stdout 'REGEX with (?P<t>...) and (?P<name>...) groups' \
    --error 'REGEX for fatal lines' \
    -- THE ORIGINAL LAUNCH COMMAND (e.g. srun ./solver run.cfg)
```

`python3 scripts/monitor_solver.py --help` has every option, how specs are parsed
and how rows from several sources are merged: read it. The program's exit
code is kept (the wrapper exits with it), so job states, dependencies and
any script logic after the launch behave as before. The wrapper sees stdout
and stderr. It runs once, outside the MPI launcher: put it in front of
`srun`/`mpirun`, not inside.

## Find out what the program writes

Don't guess file names or column numbers. Look at an earlier run's output
directory, or run a very short version (a few steps, a coarse grid), and
find the files that grow while it runs, one row per output time:

- **Text tables** (`.dat`, `.txt`, `.csv` with spaces, `.tsv`, or a code's
  own extension): read the comment lines at the top (`#`): they often
  number the columns ("# 1:iteration 2:level ... 9:time 10:value"). The
  time is often *not* column 1, and many codes write one small file per
  quantity (a minimum, a maximum, a norm): use one `--table` each. Columns
  in the spec are **1-based**, as such headers number them.
- **HDF5 files** (`.h5`): list them with `h5ls -r FILE`, or in Python
  `h5py.File(FILE).visit(print)` and the dataset's `.dtype.names` and
  `.attrs`. A table is a 2D dataset (one row per time) whose columns are
  named in an attribute (often `Legend`) or a compound dataset with named
  fields. Use the names in the spec: `t=time,error=error_l2`.
- **Output lines**: progress lines such as `it=120 t=3.42 dt=1e-3` or
  `Time = 3.42`; match them with `--stdout` and named groups.
- **Restarts** write into new numbered directories (`out-0000/`,
  `out-0001/`, ...) or append to the same files: use a glob that matches all
  of them (`out-*/name.dat`, for tables and HDF5 alike). A "current"
  directory symlinked to one of them is fine (files are read once), and rows
  at or before the last logged time are skipped.
- Files that only appear later (after an event, or at the first output) are
  waited for; a spec for them can be there from the start. Files that stop
  growing (a quantity only defined for part of the run) don't hold the
  others back.
- **Compare how each file prints the time.** If one prints it with fewer
  digits (e.g. `0.964` where another has `0.963692...`), pass
  `--time-tolerance` (half its last digit: `0.0005` for 3 decimals), so
  values from both land in one record, which `--derive` across files needs.

## Choose what to watch

Keep it to a handful of values that show progress and health:

- **the simulated time** (always). Give `--t-end` when the run has a final
  time: read it from the input or parameter file, at job time if the file is
  generated (`--t-end "$(awk ... input.par)"`). A run that ends on an event
  instead (a condition, not a time) has no `--t-end`: no progress bar, the
  values still show;
- **error, residual or constraint norms**: name them so the name contains
  "error" or "residual" (e.g. `constraint_error`), which the app draws on a
  log scale. They grow when a run goes wrong;
- **conserved quantities** (mass, energy, momentum, charge): every value's
  card says how far it moved since the start;
- **extremes of key fields** (a minimum that collapses, a maximum that
  blows up) and the time step or CFL number (`cfl`, with `--cfl-limit`):
  early warnings;
- one or two quantities of physical interest, computed with `--derive`
  when the program writes only the parts (e.g. a distance from two
  positions: `'separation=hypot(x1-x2, y1-y2)'`).

`--monitor` (drawn on the run's card) must be one of the names you log.
If the program writes none of the useful values, adding output-only lines
to its input (more diagnostics, no change to the numerics) can help, but
ask the user first: it's their input file.

## Things to check

- **What do its exit codes mean?** Look at how earlier runs ended (the
  job's log, `sacct`). Some programs print an error and still exit 0: add
  `--error` with a pattern for their fatal lines (e.g. `'^ERROR|FATAL'`,
  as they actually appear). Some exit with a special code when they stop on
  purpose to continue in a new job (after writing a checkpoint near the
  wall-time limit): pass it as `--continue-code`, so the run doesn't show
  as crashed.
- **Does the run continue across several jobs** (restarts from
  checkpoints, chained jobs)? Give `--id` a fixed id from the first job on
  (e.g. the simulation's name; letters, digits, `.`, `_`, `-`, so turn `/`
  into `-`) and the same `SOLITON_DIR` in every job: the jobs appear as one
  run, continuing where the last one stopped, live again even if a job
  ended it as finished.
- **Is the job script generated by a tool** (a workflow manager or a
  templating system that writes and submits it)? Wrap the program's launch
  line in the template or run script the tool fills in, not the tool
  itself; keep the tool's own options and anything after the launch line.
  Prefer overriding a template in the user's own configuration to editing
  the tool's files. Mind the template language: find out which characters
  it substitutes (e.g. `@NAME@` in some tools, `{{ }}` and `{% %}` in
  Jinja) and escape them, or keep them out of your regular expressions, as
  that language requires. Characters it leaves alone, such as a shell's
  `$( )` in most templates, need nothing.
- **Is the wrapper the job script itself?** If it runs inside a tool's run
  script, after `time`, or code after it must still run, don't `exec` it.
  Slurm's early warning (`--signal=B:TERM@60`) then can't reach it; that's
  fine: the server marks the run "Stopped by its Slurm time limit" a minute
  after the limit.
- **Does the job's Python have h5py** (for `--h5`)? Check with
  `python3 -c 'import h5py'` in the same environment. On a cluster, look
  for a module (`ml spider h5py`) or use a Python environment that has it.
  Always prepend to `PYTHONPATH`: some codes' own launchers set it, and
  replacing it drops the logger or their packages.
- **How much does it write?** Each read logs at most `--max-rows` rows (200,
  evenly spread), output lines included; the default `--interval` is 15 s.
