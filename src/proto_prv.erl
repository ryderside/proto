-module('proto_prv').

-export([init/1, do/1, format_error/1]).

-define(PROVIDER, 'proto').
-define(DEPS, [app_discovery]).

%% ===================================================================
%% Public API
%% ===================================================================
-spec init(rebar_state:t()) -> {ok, rebar_state:t()}.
init(State) ->
    Provider = providers:create([
            {name, ?PROVIDER},            % The 'user friendly' name of the task
            {module, ?MODULE},            % The module implementation of the task
            {bare, true},                 % The task can be run by the user, always true
            {deps, ?DEPS},                % The list of dependencies
            {example, "rebar3 proto"}, % How to use the plugin
            {opts, []},                   % list of options understood by the plugin
            {short_desc, "protobuffs tool"},
            {desc, "protobuffs tool"}
    ]),
    {ok, rebar_state:add_provider(State, Provider)}.


-spec do(rebar_state:t()) -> {ok, rebar_state:t()} | {error, string()}.
do(State) ->
    make([{imports_dir, ["./protocol/"]}, {output_include_dir, "./src/proto/"}, {output_src_dir, "./src/proto/"}]),
    {ok, State}.

-spec format_error(any()) ->  iolist().
format_error(Reason) ->
    io_lib:format("~p", [Reason]).


make(Options) ->
    ImportsDirs = proplists:get_value(imports_dir, Options, []),
    OutputDir = proplists:get_value(output_src_dir, Options, []),
    DstFileName = proplists:get_value(routing_filename, Options, "protobuff_routing.erl"),
    generate_protobuffs(ImportsDirs, Options),
    generate_protobuffs_routing(ImportsDirs, OutputDir, DstFileName),
    ok.


generate_protobuffs([], _Options) -> ok;
generate_protobuffs([ImportsDir|T], Options) ->
    lists:foreach(
        fun(File) ->
            protobuffs_compile:generate_source(ImportsDir ++ File, Options)
        end, filelib:wildcard("*.proto", ImportsDir)),
    generate_protobuffs(T, Options).

generate_protobuffs_routing(ImportsDirs, OutputDir, DstFileName) ->
    L = get_proto_files(ImportsDirs),
    L2 = lists:filtermap(fun(FilePath) ->
        try
            get_file_ctx(FilePath)
        catch
            Err:Reason ->
                io:format("Error:~p~n", {FilePath, Err, Reason, erlang:get_stacktrace()})
        end
                         end, L),
    L3 = lists:merge(L2),
    L4 = lists:map(fun dict:from_list/1, L3),
    L5 = lists:map(fun(FileName) -> dict:from_list([{pb_file, filename:basename(FileName, ".proto")}]) end,L),
    %% 重复ID检查
    PbIdList = [dict:fetch(pb_id, X) || X <- L4],
    UniqPbIdList = sets:to_list(sets:from_list(PbIdList)),
    case PbIdList -- UniqPbIdList of
        [] -> ok;
        Diff -> throw({duplicate_pb_id_found, Diff})
    end,
    %% 生成文件
    Module = list_to_atom(filename:basename(DstFileName, ".erl")),
    Ctx = [
        {module, Module},
        {include, L5},
        {encodes, L4},
        {decodes, L4}
    ],
    Src = mustache:render(mustache_content(), Ctx),
    error_logger:info_msg("Writing pt file to ~p~n", [OutputDir ++ DstFileName]),
    file:write_file(OutputDir ++ DstFileName, Src).

get_proto_files(Paths) ->
    get_proto_files(Paths, []).
get_proto_files([], AccIn) -> AccIn;
get_proto_files([Dir|T], AccIn) ->
    FileList = filelib:wildcard("*.proto", Dir),
    get_proto_files(T, [Dir++File||File<-FileList] ++ AccIn).

get_file_ctx(FileName) ->
    {ok, Bin} = file:read_file(FileName),
    Name = filename:basename(FileName, ".proto"),
    Src = binary_to_list(Bin),
    PbMod = list_to_atom(Name ++ "_pb"),
    HandleMod = list_to_atom(lists:flatten(io_lib:format("handle_~s", [Name]))),
    case re:run(Src, "//\s*0x(?<pb_id>[0-9,a-z,A-Z]+).*\r\nmessage (?<pb_name>\\S+) *{", [{capture, all_names}, global]) of
        {match, L} ->
            Ret = lists:map(fun([PbIdAt, PbNameAt]) ->
                PbId = erlang:list_to_integer(substr(Src, PbIdAt), 16),
                PbName = erlang:list_to_atom(substr(Src, PbNameAt)),
                [
                    {pb_id, lists:flatten(io_lib:format("16#~4.16.0B", [PbId]))},
                    {pb_name, PbName},
                    {handle_mod, HandleMod},
                    {pb_mod, PbMod}
                ]
                            end, L),
            {true, Ret};
        nomatch ->
            false
    end.

substr(Src, {Offset, Len}) ->
    string:sub_string(Src, Offset + 1, Offset + Len).


mustache_content() ->
    "-module({{module}}).\n\n" ++
    "{{#include}}\n" ++
    "-include(\"{{pb_file}}_pb.hrl\").\n" ++
    "{{/include}}\n" ++
    "{{!ignore}}\n" ++
    "-export([encode/1, decode/2]).\n\n" ++
    "{{#encodes}}" ++
    "encode(#{{pb_name}}{} = Msg) ->\n\t" ++
    "IoData = {{pb_mod}}:encode_{{pb_name}}(Msg),\n\t" ++
    "[<<{{pb_id}}:32>>, IoData];\n" ++
    "{{/encodes}}\n" ++
    "encode(Msg) ->\n\t" ++
    "erlang:error({invalid_proto_msg, Msg}).\n\n" ++
    "{{#decodes}}\n" ++
    "decode({{pb_id}}, Bin) -> { {{handle_mod}}, {{pb_mod}}:decode_{{pb_name}}(Bin)};\n" ++
    "{{/decodes}}\n" ++
    "decode(Id, _) ->\n\t" ++
    "erlang:error({invalid_proto_id, Id}).\n".