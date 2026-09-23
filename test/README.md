# Container smoke tests

`smoke.sh` is a container smoke-test harness: it builds the Docker image from
the repo root, runs it, and checks that expected tooling is present and that
the container stops promptly on `SIGTERM`. It's written as a reusable
template — the same pattern (build, run, exec-based tool checks, stop-time
check, trap-based cleanup) applies to any container-image-type project, not
just this one.

## Running

```
bash test/smoke.sh
```

Requires access to the Docker socket (i.e. `docker` must work from wherever
you run this — a plain host shell, or a container with the socket mounted).

The script builds the image, starts a detached container, execs into it to
check for `gh`, `node`, `git`, and `tmux`, times how long `docker stop` takes,
and prints `PASS`/`FAIL` for each check plus a final summary. It always
cleans up the container and image it created, even on failure, via a trap.

Throwaway `/root` homes are bind mounts, and `-v` paths are resolved by the
Docker daemon, not by the shell running this script. When the script runs in a
container with the host's socket mounted, the daemon creates a separate copy
of each home on the host, so a plain local `rm -rf` misses it. `new_home` and
`remove_home` handle both copies. Use them for any new bind-mounted directory.

Exits `0` if all checks pass, `1` otherwise.
