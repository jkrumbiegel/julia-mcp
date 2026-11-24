const SERVER_VERSION = "0.1.0"
const SUPPORTED_PROTOCOL_VERSIONS = ["2024-11-05", "2025-03-26", "2025-06-18", "2025-11-25"]
const DEFAULT_PROTOCOL_VERSION = "2025-06-18"

const JULIA_EVAL_DESCRIPTION = """
Run Julia code in a persistent session. Prefer this over running `julia` from the shell: state and compiled code
are kept between calls, so later calls are fast.

Each environment gets its own session, started on first use. Select the environment with env_path instead of
calling `Pkg.activate`. Sessions unused for 72 hours are stopped, so state may be gone after a long pause.

Printed output is returned, followed by the value of the last expression as the REPL would show it. End the
code with `;` to suppress the value.

Revise is loaded when the session starts (if it is installed in the default environment) and runs before every
call, so edits to packages loaded with `using` or `import` take effect without stopping the session. Files you
`include` yourself are not tracked: include them again, or load them with `includet`. If Revise fails to load,
the first result of the session starts with a note saying so; edits are then not picked up and the session must
be stopped and started again after each change.

For package development, pass the package's test/ directory as env_path: the session then activates the package
with TestEnv, so the package and its test dependencies are both available. Pkg operations in such a session change
a temporary environment, not test/Project.toml.

Args:
    code: Julia code to evaluate.
    env_path: Julia project directory. Omit for a temporary environment.
    timeout: Seconds until the call is aborted, default 60. On timeout the session is killed and all its state is
        lost, so for long work (test suites, precompilation of large packages) pass a generous value, or 0 for no
        timeout. Calls containing `Pkg.` have no timeout unless one is passed.
    julia_cmd: Custom Julia command, only when explicitly requested. Examples: "julia +1.11",
        "julia --check-bounds=yes", "/path/to/julia".
    name: Short label for the session. Only needed to run several sessions on one env_path at the same time,
        typically to compare the same code under different Julia versions or builds (e.g. "julia +1.12.6" vs
        "julia +1.12.7", or a release vs a local Julia build at "/path/to/julia" when working on Julia or a
        stdlib), for benchmarks or differing outputs, or to keep a normal session next to one started with
        diagnostic flags (e.g. "julia --trace-compile=stderr", "julia --track-allocation=user").
        Pass it with env_path (and julia_cmd) once to
        create the session, then name alone on later calls. Named sessions are never replaced implicitly, while an
        unnamed call with a different julia_cmd replaces the unnamed session on that env_path.
        Sessions on different Julia minor versions must not share a Manifest.toml, or each rewrites it for its own
        version. Before starting the second version, copy the project's Manifest.toml to
        Manifest-v<major>.<minor>.toml (e.g. Manifest-v1.11.toml) next to it, which that version then uses instead,
        and run `import Pkg; Pkg.resolve()` first in the new session. That adapts stdlib and JLL entries to its Julia
        version while keeping package versions, so both sessions run the same packages. For a test/ session the
        manifest is the package's, so copy and resolve it in a session on the package directory."""

const JULIA_STOP_DESCRIPTION = """
Stop a Julia session, freeing its memory and losing all its state. The next julia_eval call for the same
environment starts a fresh session.

Use it to release resources of a session that is no longer needed, or to get a clean state. It is not needed
after editing source files: Revise picks up those changes (see julia_eval).

Args:
    env_path: Environment of the session. If omitted, stops the temporary session (not every session).
    julia_cmd: Same julia_cmd that was used to start the session, if any.
    name: Name of the session, instead of env_path and julia_cmd. The name is released, so a later
        julia_eval needs env_path again to recreate it."""

const JULIA_LIST_SESSIONS_DESCRIPTION = "List all active Julia sessions, their names, environments and Julia commands."

const JSONObject = JSON.Object{String, Any}
const RequestId = Union{Int64, String, Nothing}

struct TypeRef
    type::String
end

struct PropertySchema
    type::Union{String, JSON.Omit}
    anyOf::Union{Vector{TypeRef}, JSON.Omit}
    default::Union{JSON.Null, JSON.Omit}
end

plain(type::String) = PropertySchema(type, JSON.Omit(), JSON.Omit())
nullable(type::String) = PropertySchema(JSON.Omit(), [TypeRef(type), TypeRef("null")], JSON.Null())

struct InputSchema
    type::String
    required::Union{Vector{String}, JSON.Omit}
    properties::JSON.Object{String, PropertySchema}
end

input_schema(properties::Pair{String, PropertySchema}...; required = JSON.Omit()) =
    InputSchema("object", required, JSON.Object{String, PropertySchema}(collect(properties)))

struct ToolSpec
    name::String
    description::String
    inputSchema::InputSchema
end

tool_list() = [
    ToolSpec("julia_eval", JULIA_EVAL_DESCRIPTION, input_schema(
        "code" => plain("string"), "env_path" => nullable("string"),
        "timeout" => nullable("number"), "julia_cmd" => nullable("string"), "name" => nullable("string");
        required = ["code"])),
    ToolSpec("julia_stop", JULIA_STOP_DESCRIPTION, input_schema(
        "env_path" => nullable("string"), "julia_cmd" => nullable("string"), "name" => nullable("string"))),
    ToolSpec("julia_list_sessions", JULIA_LIST_SESSIONS_DESCRIPTION, input_schema()),
]

struct InvalidParams <: Exception
    msg::String
end

function optional_string(args::JSONObject, key::String)::Union{Nothing, String}
    v = get(args, key, nothing)
    v === nothing && return nothing
    v isa String || throw(InvalidParams("argument '$key' must be a string or null"))
    return v
end

function required_string(args::JSONObject, key::String)
    v = optional_string(args, key)
    v === nothing && throw(InvalidParams("missing required argument '$key'"))
    return v
end

function optional_number(args::JSONObject, key::String)::Union{Nothing, Float64}
    v = get(args, key, nothing)
    v === nothing && return nothing
    v isa Int64 && return Float64(v)
    v isa Float64 && return v
    v isa BigInt && return Float64(v)
    throw(InvalidParams("argument '$key' must be a number or null"))
end

function effective_timeout(code::String, timeout::Union{Nothing, Float64})::Union{Nothing, Float64}
    timeout === nothing && return occursin(PKG_PATTERN, code) ? nothing : DEFAULT_TIMEOUT
    return timeout > 0 ? timeout : nothing
end

function error_message(@nospecialize(e))::String
    e isa SessionError && return e.msg
    e isa Base.IOError && return e.msg
    e isa SystemError && return string(e.prefix, ": ", Libc.strerror(e.errnum))
    return "unexpected internal error"
end

function julia_eval(m::SessionManager, args::JSONObject)
    code = required_string(args, "code")
    env_path = optional_string(args, "env_path")
    timeout = effective_timeout(code, optional_number(args, "timeout"))
    julia_cmd = optional_string(args, "julia_cmd")
    name = optional_string(args, "name")
    try
        session = get_or_create!(m, env_path; julia_cmd, name)
        output = execute(session, code, timeout)
        return isempty(output) ? "(no output)" : output
    catch e
        e isa InvalidParams && rethrow()
        drop_dead_sessions!(m)
        return "Error: " * error_message(e)
    end
end

function julia_stop(m::SessionManager, args::JSONObject)
    env_path = optional_string(args, "env_path")
    julia_cmd = optional_string(args, "julia_cmd")
    name = optional_string(args, "name")
    stopped = try
        stop!(m, env_path; julia_cmd, name)
    catch e
        e isa SessionError || rethrow()
        return "Error: " * e.msg
    end
    label = name !== nothing ? name : env_path !== nothing ? env_path : "temporary"
    stopped && return "Session stopped ($label)."
    msg = "No active session for $label, nothing to stop."
    active = String[s.env_path for s in list_sessions(m)]
    return isempty(active) ? msg : msg * " Active sessions: " * python_list_repr(active)
end

function session_line(s::SessionInfo)
    name = s.name === nothing ? "" : "[" * s.name * "] "
    label = s.temp ? s.env_path * " (temp)" : s.env_path
    julia = s.julia_cmd === nothing ? "" : " julia_cmd=" * s.julia_cmd
    revise = s.revise_loaded ? "" : " (Revise not loaded)"
    log = s.log_file === nothing ? "" : " log=" * s.log_file
    cmd = s.cmd === nothing ? "" : "\n      cmd: " * s.cmd
    return string("  ", name, label, ": ", s.alive ? "alive" : "dead", revise, julia, log, cmd)
end

function julia_list_sessions(m::SessionManager, ::JSONObject)
    header = "Julia args applied to every session: " * (isempty(m.julia_args) ? "(none)" : shell_join(m.julia_args))
    sessions = list_sessions(m)
    isempty(sessions) && return "No active Julia sessions.\n" * header
    return "Active Julia sessions:\n" * join(map(session_line, sessions), "\n") * "\n" * header
end

function call_tool(m::SessionManager, name::String, args::JSONObject)::String
    name == "julia_eval" && return julia_eval(m, args)
    name == "julia_stop" && return julia_stop(m, args)
    name == "julia_list_sessions" && return julia_list_sessions(m, args)
    throw(InvalidParams("Unknown tool: " * name))
end

text_result(text::String, is_error::Bool) = (content = [(type = "text", text = text)], isError = is_error)

function tools_call(m::SessionManager, params::JSONObject)
    name = get(params, "name", nothing)
    name isa String || throw(InvalidParams("tools/call requires a string 'name'"))
    args = get(params, "arguments", nothing)
    args = args === nothing ? JSONObject() : args
    args isa JSONObject || throw(InvalidParams("'arguments' must be an object"))
    try
        return text_result(call_tool(m, name, args), false)
    catch e
        e isa InvalidParams || rethrow()
        return text_result(e.msg, true)
    end
end

function initialize_result(params::JSONObject)
    requested = get(params, "protocolVersion", nothing)
    version = requested isa String && requested in SUPPORTED_PROTOCOL_VERSIONS ? requested : DEFAULT_PROTOCOL_VERSION
    return (
        protocolVersion = version,
        capabilities = (tools = (listChanged = false,),),
        serverInfo = (name = "julia", version = SERVER_VERSION),
    )
end

struct Response{T}
    jsonrpc::String
    id::RequestId
    result::T
end

struct RPCError
    code::Int
    message::String
end

struct ErrorResponse
    jsonrpc::String
    id::RequestId
    error::RPCError
end

response(id::RequestId, result) = JSON.json(Response("2.0", id, result))

error_response(id::RequestId, code::Int, message::String) = JSON.json(ErrorResponse("2.0", id, RPCError(code, message)))

function dispatch(m::SessionManager, id::RequestId, method::String, params::JSONObject)::String
    method == "initialize" && return response(id, initialize_result(params))
    method == "ping" && return response(id, NamedTuple())
    method == "tools/list" && return response(id, (tools = tool_list(),))
    method == "tools/call" && return response(id, tools_call(m, params))
    return error_response(id, -32601, "Method not found: " * method)
end

function request_id(@nospecialize(id))::RequestId
    id isa Int64 && return id
    id isa String && return id
    return nothing
end

function handle_message(m::SessionManager, line::String)::Union{Nothing, String}
    msg = try
        JSON.parse(line)
    catch
        return error_response(nothing, -32700, "Parse error")
    end
    msg isa JSONObject || return error_response(nothing, -32600, "Invalid Request")

    is_notification = !haskey(msg, "id")
    id = request_id(get(msg, "id", nothing))
    method = get(msg, "method", nothing)
    if !(method isa String)
        is_notification && return nothing
        haskey(msg, "result") || haskey(msg, "error") || return error_response(id, -32600, "Invalid Request")
        return nothing
    end
    is_notification && return nothing

    params = get(msg, "params", nothing)
    params = params === nothing ? JSONObject() : params
    params isa JSONObject || return error_response(id, -32602, "'params' must be an object")
    try
        return dispatch(m, id, method, params)
    catch e
        e isa InvalidParams && return error_response(id, -32602, e.msg)
        return error_response(id, -32603, error_message(e))
    end
end

function respond(m::SessionManager, line::String, out::RawFD)
    reply = handle_message(m, line)
    reply === nothing && return
    try
        write_fd(out, reply * "\n")
    catch
    end
    return
end

function serve(m::SessionManager, in::FDReader, out::RawFD)
    while true
        line = readline_fd(in)
        line === nothing && break
        isempty(strip(line)) && continue
        @async respond(m, line, out)
    end
    return
end

function (@main)(args::Vector{String})::Cint
    julia_args = isempty(args) ? copy(DEFAULT_JULIA_ARGS) : args
    m = SessionManager(julia_args)
    write_fd(RawFD(2), "Julia MCP log directory: " * m.log_dir * "\n")
    try
        serve(m, FDReader(RawFD(0)), RawFD(1))
    finally
        shutdown!(m)
    end
    return 0
end
