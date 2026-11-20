const SERVER_VERSION = "0.1.0"
const SUPPORTED_PROTOCOL_VERSIONS = ["2024-11-05", "2025-03-26", "2025-06-18", "2025-11-25"]
const DEFAULT_PROTOCOL_VERSION = "2025-06-18"

const JULIA_EVAL_DESCRIPTION = """
ALWAYS use this tool to run Julia code. NEVER run julia via command line.

Persistent REPL session with state preserved between calls.
Each env_path gets its own session, started lazily.
Do not type `Pkg.activate()` explicitly in your code; instead, specify the env_path argument to select the environment.

Args:
    code: Julia code to evaluate. Use display(...)/println(...) to see output.
    env_path: Julia project directory path. Omit for a temporary environment.
    timeout: Seconds (default: 60). Auto-disabled for Pkg operations.
    julia_cmd: Custom Julia command, should be used rarely, only when explicitly requested. Examples: "julia +1.11", "julia --check-bounds=yes", "/path/to/julia"."""

const JULIA_RESTART_DESCRIPTION = """
Restart a Julia session, clearing all state.

IMPORTANT: Restarting is slow and loses all session state. Very rarely needed.
Revise.jl is loaded automatically in every session, so code changes to loaded packages are picked up without restarting.
Only restart as a last resort when the session is truly broken, or code changes that Revise cannot fix.
Do NOT restart just because source files were edited between script or test runs — Revise picks up those changes automatically.

Args:
    env_path: Environment to restart. If omitted, restarts the temporary session
        (NOT every active session) — most callers should pass the same env_path
        they used in julia_eval."""

const JULIA_LIST_SESSIONS_DESCRIPTION = "List all active Julia sessions and their environments."

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
        "timeout" => nullable("number"), "julia_cmd" => nullable("string"); required = ["code"])),
    ToolSpec("julia_restart", JULIA_RESTART_DESCRIPTION, input_schema("env_path" => nullable("string"))),
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
    try
        session = get_or_create!(m, env_path; julia_cmd)
        output = execute(session, code, timeout)
        return isempty(output) ? "(no output)" : output
    catch e
        e isa InvalidParams && rethrow()
        drop_dead_session!(m, env_path)
        return "Error: " * error_message(e)
    end
end

python_list_repr(items::Vector{String}) = "[" * join(("'" * s * "'" for s in items), ", ") * "]"

function julia_restart(m::SessionManager, args::JSONObject)
    env_path = optional_string(args, "env_path")
    label = env_path === nothing ? "temporary" : env_path
    restart!(m, env_path) && return "Session restarted (env_path=$label). A fresh session will start on next julia_eval call."
    active = String[s.env_path for s in list_sessions(m)]
    msg = "No active session for env_path=$label — nothing to restart."
    isempty(active) && return msg
    return "No active session for env_path=$label — nothing to restart. Active sessions: " * python_list_repr(active)
end

function julia_list_sessions(m::SessionManager, ::JSONObject)
    sessions = list_sessions(m)
    isempty(sessions) && return "No active Julia sessions."
    lines = map(sessions) do s
        label = s.temp ? s.env_path * " (temp)" : s.env_path
        julia = s.julia_cmd === nothing ? "" : " julia_cmd=" * s.julia_cmd
        log = s.log_file === nothing ? "" : " log=" * s.log_file
        string("  ", label, ": ", s.alive ? "alive" : "dead", julia, log)
    end
    return "Active Julia sessions:\n" * join(lines, "\n")
end

function call_tool(m::SessionManager, name::String, args::JSONObject)::String
    name == "julia_eval" && return julia_eval(m, args)
    name == "julia_restart" && return julia_restart(m, args)
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
