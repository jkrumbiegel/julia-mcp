# julia-mcp

An MCP server for persistent Julia sessions, written in Julia and compiled with `juliac --trim=safe` into a standalone executable. It provides three tools over stdio: `julia_eval`, `julia_stop` and `julia_list_sessions`. Each environment gets its own `julia` child process, so state and compiled code are kept between calls.

It started as a Julia port of the Python server [aplavin/julia-mcp](https://github.com/aplavin/julia-mcp).

Only macOS and Linux are supported, because the process and pipe handling uses POSIX file descriptors.

## Build

Requires Julia 1.13 (via juliaup) and a C compiler.

```sh
./build.sh                    # uses `julia +1.13`; override with JULIA=/path/to/julia
```

This writes a relocatable bundle to `dist/`. The executable is `dist/bin/julia-mcp` and needs `dist/lib` next to it. A rebuild replaces `dist/` only once the new bundle is complete, so running servers are not affected.

## Register with Claude Code

Link the executable into a directory on your `PATH` and register it:

```sh
ln -sf "$PWD/dist/bin/julia-mcp" ~/.local/bin/julia-mcp
claude mcp add --scope user julia -- ~/.local/bin/julia-mcp
```

To update, pull and run `./build.sh` again; new Claude sessions pick up the new binary.

Julia flags passed after the executable replace the default `--threads=auto`.

## Test

```sh
julia +1.13 --project=test -e 'import Pkg; Pkg.instantiate(); include("test/runtests.jl")'
```

## Differences from the Python server

- `julia_restart` is replaced by `julia_stop`, which frees a session's resources; the next `julia_eval` starts a fresh one.
- The value of the last expression is shown like in the REPL, unless the code ends with `;`.
- If Revise fails to load, the first result of the session says so, and `julia_list_sessions` marks the session.
- Sessions can be given a `name`, so several sessions can share one `env_path` (for example the same project under two Julia versions), and later calls can address a session by name alone.
- Sessions idle for 72 hours are shut down.
- Sessions are killed and temporary directories removed when the client closes stdin, including sessions that are still busy.
- Each session gets a small `/bin/sh` watcher that SIGKILLs it once the server process is gone, so sessions do not outlive a server that was terminated by a signal.
- Unexpected internal errors are reported without exception details, because generic `showerror` is not trim-safe.

## Trim notes

These parts of Base fail `--trim=safe` verification on Julia 1.13.3, and are worked around here:

- `run(pipeline(cmd; stdin, stdout, stderr); wait = false)`: stdio setup goes through `Vector{Union{RawFD, FileRedirect, IOServer, IO}}`. Processes are spawned with a direct `jl_spawn` call on raw pipe fds instead (`src/fdio.jl`).
- Reading from any libuv stream (`stdin`, `PipeEndpoint`): `Base.uv_readcb` calls `readcb_specialized` on an abstract `LibuvStream`. Reads use `FileWatching.FDWatcher` plus `read(2)` instead.
- `Timer(callback, timeout)` and `@sync` are not inferable. Timeouts use a plain `Timer` waited on in a separate task.
- `Libc.strftime` and `lpad` hit unresolved calls; `string(x; pad = 2)` works.
- JSON.jl is trim-safe as long as parsed `Any` values are narrowed with `isa` before use and everything written has a concrete type. Responses are therefore structs or NamedTuples, never `Dict{String, Any}` or tuples of mixed types.
- On SIGTERM the trimmed runtime exits without running `atexit` hooks, hence the watcher process above.
