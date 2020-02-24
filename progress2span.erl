-module(progress2span).

%% -compile(export_all).
-export([main/1]).

-record(options, {
                  %% Output debug info?
                  info = info :: 'quiet' | 'info' | 'debug',

                  %% Name of local NSO node
                  localEndpoint = <<"NSO">>,

                  %% Whether to make each usid a unique trace
                  traceid = random_usid ::
                    'usid'                % Use usid directly
                  | 'random_usid'         % Use usid + random
                  | 'random'              % Use a random number for whole file
                  | {supplied, string()}, % Use supplied number for whole file

                  %% Only include entries between these two timestamps (nyi)
                  from = 0 :: non_neg_integer(),
                  to = infinity :: non_neg_integer() | 'infinity',

                  %% Include a span that represents the transaction log
                  lock_span = false :: boolean()
                 }).

-define(info(F, A), case get(info) of
                        quiet -> ok;
                        _ -> io:format(standard_error, F, A)
                    end).
-define(debug(F, A),
        case get(info) of
            debug -> io:format(standard_error, F, A);
            _ -> ok
        end).

main(Args0) ->
    check_version(),
    {Args, Options} = get_opt(Args0, #options{}),
    %% io:format("Options: ~999p\nArgs: ~p\n", [Options, Args]),
    {I, O} = file_args(Args),
    process(I, O, Options),
    erlang:halt(0).

check_version() ->
    {ok, StdLibVsnStr} = application:get_key(stdlib, vsn),
    case [list_to_integer(S) || S <- string:split(StdLibVsnStr, ["."], all)] of
        [3, Mi | _] when (Mi >= 8) ->
            ok;
        [Ma, _Mi | _] when (Ma > 3) ->
            ok;
        _ ->
            io:format(standard_error,
                      "Error: Need Erlang/OTP 21 or newer to run\n", []),
            erlang:halt(1)
    end.

get_opt(Args, Options) ->
    get_opt(Args, [], Options).

get_opt(["-" ++ _ = Arg | Args], Remain, Options) ->
    case Arg of
        "-l" ->
            get_opt(Args, Remain, Options#options{lock_span = true});
        "-d" ->
            put(info, debug),
            get_opt(Args, Remain, Options#options{info = debug});
        "-q" ->
            put(info, quiet),
            get_opt(Args, Remain, Options#options{info = quiet});
        "-h" when Args /= [] ->
            Nodename = unicode:characters_to_binary(hd(Args)),
            get_opt(tl(Args), Remain,
                    Options#options{localEndpoint = Nodename});
        "-t" ++ What ->
            TraceId =
                case What of
                    [] when Args /= [] ->
                        {supplied, arg_hexstr(hd(Args))};
                    "u" ->
                        usid;
                    "r" ->
                        random;
                    "ru" ->
                        random_usid
                end,
            Args1 = case What of [] -> tl(Args); _ -> Args end,
            get_opt(Args1, Remain, Options#options{traceid = TraceId});
        _ ->
            io:format(standard_error, "Unknown argument: ~p\n", [Arg]),
            erlang:halt(1)
    end;
get_opt([Arg|Args], Remain, Options) ->
    get_opt(Args, [Arg|Remain], Options);
get_opt([], Remaining, Options) ->
    {lists:reverse(Remaining), Options}.

arg_hexstr(Str) ->
    try
        case
            ((length(Str) == 16) orelse (length(Str) == 32))
            andalso string:take(Str, "0123456789abcdef")
        of
            {Str, ""} ->
                list_to_binary(Str);
            _ ->
                case string:to_integer(Str) of
                    {I, _} when is_integer(I) ->
                        hex16(I)
                end
        end
    catch _:_ ->
            io:format(standard_error, "Invalid trace id: ~s\n", [Str]),
            erlang:halt(1)
    end.


file_args(Args) ->
    case Args of
        [] ->
            %% Is there really no other way?
            {ok, F} = ropen("/dev/stdin"),
            {F, standard_output};
        [FName] ->
            {ok, F} = ropen(FName),
            {F, standard_output};
        [InFile, OutFile] ->
            {ok, F1} = ropen(InFile),
            {ok, F2} = wopen(OutFile),
            {F1, F2};
        _ ->
            io:format(standard_error, "Unknown args: ~p\n", [Args]),
            erlang:halt(1)
    end.

ropen(FileName) ->
    file:open(FileName, [read,raw,binary,read_ahead]).

wopen(FileName) ->
    file:open(FileName, [write]).

process(I, O, Options) ->
    process_flag(trap_exit, true),
    try
        Collector =
            spawn_link(fun () ->
                               put(info, Options#options.info),
                               start_collector(O, Options)
                       end),
        Fn =
            fun (eof) ->
                    Collector ! eof;
                (Line) ->
                    case read_progress_csv(Line) of
                        empty ->
                            ok;
                        PMap ->
                            Collector ! {progress, PMap}
                    end
            end,
        loop(I, Fn, file:read_line(I)),
        receive
            {'EXIT', Collector, _} ->
                ok
        end
    after
        file:close(I),
        file:close(O)
    end.

loop(_I, Fn, eof) ->
    Fn(eof),
    ok;
loop(I, Fn, {ok, Line}) ->
    Fn(Line),
    loop(I, Fn, file:read_line(I)).


-include_lib("kernel/include/file.hrl").

follow(FileName, Fn) ->
    case ropen(FileName) of
        {ok, Fd} ->
            {ok, Info} = file:read_file_info(FileName),
            follow(Fd, Info, FileName, Fn);
        _X ->
            timer:sleep(250),
            follow(FileName, Fn)
    end.

follow(Fd, Info, FileName, Fn) ->
    case file:read_line(Fd) of
        {ok, Line} ->
            Fn(Line),
            follow(Fd, Info, FileName, Fn);
        eof ->
            {ok, Pos} = file:position(Fd, cur),
            case file:read_file_info(FileName) of
                {ok, NI} when
                      NI#file_info.size == Pos andalso
                      NI#file_info.minor_device == Info#file_info.minor_device
                      andalso
                      NI#file_info.major_device == Info#file_info.major_device
                      andalso
                      NI#file_info.inode == Info#file_info.inode
                      ->
                    timer:sleep(250),
                    follow(Fd, Info, FileName, Fn);
                _X ->
                    file:close(Fd),
                    follow(FileName, Fn)
            end
    end.

%% What is a Trace? It should probably be all the activities that are
%% initiated by an interaction with a northbound api. For example a
%% transaction initiated over RESTCONF, and all its resulting
%% transactions (e.g. if there is a nano service involved).
%%
%% But for the purpose of this script it makes more sense to define a
%% trace as all the progress entries in one single file (that way we
%% get all the spans generated in a single trace)
%%
-record(state, {
                options = #options{} :: #options{},
                outfd,
                span_printed = false,
                traceid = rand:uniform(16#ffffffffffffffff),
                vspans = #{},             % "virtual" spans
                cspans = #{},             % spans currently working on
                astacks = #{},            % annotation stack
                pstacks = #{}             % parent stack
               }).

start_collector(O, Options) ->
    io:put_chars(O, "["),
    collector_loop(#state{outfd = O, options = Options}).

stop_collector(#state{outfd = O} = State0) ->
    State =
        maps:fold(fun (_, VSpan, S0) -> print_span(VSpan, S0) end,
                  State0, State0#state.vspans),
    print_nl(O, false),
    io:put_chars(O, "]\n"),
    case maps:size(State#state.cspans) of
        0 -> ok;
        N -> ?info("~p unmatched start events left\n", [N]),
             debug_print_state(State)
    end,
    exit(normal).

collector_loop(State) ->
    receive
        {progress, TraceMap} ->
            collector_loop(handle_trace(TraceMap, State));
        eof ->
            stop_collector(State)
    end.

%% Algorithm for building the hierarchy:
%% * First time a usid/tid is seen that id is the top
%% * Subsequent messages on that usid/tid sets parentId to first
%% * XXX should any start msg form a new hierachy?
%%
%% Store a start message, key is:
%% <usid,tid,t(message),phase,device,service> A stop message is one
%% with duration, match it to its start message and output the
%% span. Add the stop message as an annotation (so the result is
%% saved)

handle_trace(Trace, S0) ->
    S1 = save_vspans(Trace, S0),
    case classify(Trace, S1) of
        {start, Key} ->
            Id = span_id(Trace),
            ParentId = parent_id(Trace, Id, S1),
            Span = make_span(Trace, Id, ParentId, S1),
            maybe_push_pstack(Id, Span, push_span(Key, Span, S1));
        {stop, Key} ->
            case pop_span(Key, S1) of
                undefined ->
                    ?info("unmatched stop event: ~p\n", [trace_msg(Trace)]),
                    S1;
                {Span, S2} ->
                    S3 = maybe_pop_pstack(Span, S2),
                    S4 = print_span(add_stop(Trace, Span), S3),
                    special_span_stop(Trace, S4)
            end;
        {annotation, Key} ->
            S2 = add_annotation_to_current(Key, Trace, S1),
            special_span_annotation(Trace, S2);
        {ignore, _} ->
            S1
    end.

special_span_stop(Trace, State) ->
    case trace_msg(Trace) of
        <<"grabbing transaction lock ok">> when
              (State#state.options)#options.lock_span ->
            Key = {musid(Trace), mtid(Trace)},
            ParentId = maps:get(id, maps:get(Key, State#state.vspans)),
            LTrace = maps:put(name, <<"transaction lock">>,
                              maps:without([name,message], Trace)),
            Id = span_id(LTrace),
            Span = make_span(LTrace, Id, ParentId, State),
            CSpans = maps:put(key(LTrace), Span, State#state.cspans),
            State#state{cspans = CSpans};
        _ ->
            State
    end.

special_span_annotation(Trace, State) ->
    case trace_msg(Trace) of
        <<"releasing transaction lock">> when
              (State#state.options)#options.lock_span ->
            LTrace = maps:put(name, <<"transaction lock">>, Trace),
            case maps:take(key(LTrace), State#state.cspans) of
                {Span, NewCSpans} ->
                    State1 = State#state{cspans = NewCSpans},
                    Duration = trace_ts(LTrace) - trace_ts(Span),
                    print_span(maps:put(duration, Duration, Span), State1);
                error ->
                    ?info("unmatched transaction lock event: ~999p\n",
                          [LTrace]),
                    debug_print_state(State),
                    State
            end;
        _ ->
            State
    end.

debug_print_state(#state{options = #options{info = debug}} = State) ->
    ?debug("STATE:\n  ~p\n", [State]);
debug_print_state(_) ->
    ok.

save_vspans(Trace, #state{vspans = V} = State) ->
    U = musid(Trace), T = mtid(Trace),
    case maps:find(U, V) of
        {ok, USpan} ->
            case maps:is_key({U,T}, V) of
                true ->
                    State;
                false ->
                    NewVSpan = V#{{U,T} => vt_span(Trace, USpan, State)},
                    State#state{vspans = NewVSpan}
            end;
        error ->
            USpan = vu_span(Trace, State),
            NewVSpan = V#{U => USpan, {U,T} => vt_span(Trace, USpan, State)},
            State#state{vspans = NewVSpan}
    end.

vu_span(Trace, State) ->
    TS = trace_ts(Trace),
    Name = <<"user-session">>,
    Id = span_id(musid(Trace),0,TS,Name,undefined),
    Span0 =
        #{
          traceId => trace_id(Trace, State),
          id => Id,
          parentId => Id,
          name => Name,
          kind => <<"SERVER">>,
          timestamp => TS,
          tags => maps:with([usid,context,package], Trace),
          localEndpoint => #{ serviceName => local_endpoint(State) }
         },
    update(context, Trace, remoteEndpoint, serviceName, Span0).

vt_span(Trace, USpan, State) ->
    TS = trace_ts(Trace),
    Name = <<"transaction">>,
    Id = span_id(musid(Trace),mtid(Trace),TS,Name,undefined),
    Span0 =
        #{
          traceId => trace_id(Trace, State),
          id => Id,
          parentId => maps:get(id, USpan),
          name => Name,
          kind => <<"SERVER">>,
          timestamp => TS,
          tags => maps:with([usid,tid,context,package], Trace),
          localEndpoint => #{ serviceName => local_endpoint(State) }
         },
    update(remoteEndpoint, USpan, remoteEndpoint, Span0).


push_span(Key, Span, #state{cspans = C, astacks = Stacks} = State) ->
    case maps:is_key(Key, C) of
        true ->  ?info("Duplicate key: ~p\n", [Key]);
        false -> ok
    end,
    SKey = stack_key(Key),
    Stack = maps:get(SKey, Stacks, []),
    State#state{cspans = maps:put(Key, Span, C),
                astacks = maps:put(SKey, [Key|Stack], Stacks)}.

pop_span(Key, #state{cspans = C, astacks = AStacks} = State) ->
    case maps:take(Key, C) of
        {Span, New} ->
            NewAStacks =
                maps:update_with(stack_key(Key), fun ([_|T]) -> T end, AStacks),
            {Span, State#state{cspans = New, astacks = NewAStacks}};
        error ->
            undefined
    end.

maybe_push_pstack(Id, Span, #state{pstacks = PS} = State) ->
    case is_new_parent(Span) of
        true ->
            Key = span_ut(Span),
            NPS = maps:put(Key, [Id|maps:get(Key, PS, [])], PS),
            State#state{pstacks = NPS};
        false ->
            State
    end.

is_new_parent(Span) ->
    is_new_parent_name(maps:get(name, Span)).

is_new_parent_name(<<"applying transaction">>) -> true;
is_new_parent_name(<<"transforms and transaction hooks">>) -> true;
is_new_parent_name(<<"validate phase">>) -> true;
is_new_parent_name(<<"write-start phase">>) -> true;
is_new_parent_name(<<"prepare phase">>) -> true;
is_new_parent_name(<<"commit phase">>) -> true;
is_new_parent_name(<<"abort phase">>) -> true;
is_new_parent_name(_) -> false.


maybe_pop_pstack(Span, #state{pstacks = PS} = State) ->
    Key = span_ut(Span),
    Id = maps:get(id, Span),
    case maps:find(Key, PS) of
        {ok, Ids} ->
            %% "pop" it even if it is further up the stack
            State#state{pstacks = maps:put(Key, lists:delete(Id, Ids), PS)};
        _ ->
            State
    end.

span_ut(Span) ->
    Tags = maps:get(tags, Span),
    {maps:get(usid, Tags), maps:get(tid, Tags)}.

add_annotation_to_current(AKey, Trace, #state{cspans=C, vspans=V} = State) ->
    UpdateF = fun (Span) -> add_annotation(Trace, Span) end,
    case maps:get(stack_key(AKey), State#state.astacks, undefined) of
        [Key|_] ->
            State#state{cspans = maps:update_with(Key, UpdateF, C)};
        _ ->
            %% 'undefined' or [], orphaned add to transaction vspan
            Key = {musid(Trace), mtid(Trace)},
            State#state{vspans = maps:update_with(Key, UpdateF, V)}
    end.

classify(Trace, State) ->
    Type = trace_type(Trace),
    TS = trace_ts(Trace),
    case trace_has_duration(Trace) of
        _ when TS < State#state.options#options.from orelse
               TS > State#state.options#options.to ->
            ignore;
        true when Type == start ->
            ?info("START MSG W DURATION:\n  ~999p\n", [Trace]);
        true when Type == annotation ->
            ?info("ANN MSG W DURATION:\n  ~999p\n", [Trace]);
        false when Type == stop ->
            ?info("STOP MSG W/O DURATION:\n  ~999p\n", [Trace]);
        _D when Type == unknown ->
            ?info("UNKNOWN (has_duration: ~p)\n  ~999p\n", [_D, Trace]);
        _ ->
            ok
    end,
    {Type, key(Trace)}.

key(Trace) ->
    {musid(Trace), mtid(Trace), trace_name(Trace), trace_device(Trace)}.

stack_key({U,T,_,D}) ->
    {U,T,D}.

%% First look in the pstack, if not there use top-level vspan for tid
parent_id(Trace, _Id, State) ->
    Key = {musid(Trace), mtid(Trace)},
    case maps:find(Key, State#state.pstacks) of
        {ok, [Id|_]} ->
            Id;
        _ ->
            maps:get(id, maps:get(Key, State#state.vspans))
    end.

print_span(Span, #state{outfd = O} = State) ->
    print_nl(O, State#state.span_printed),
    json(O, Span),
    State#state{span_printed = true}.

print_nl(O, true) ->
    io:put_chars(O, ",\n");
print_nl(O, false) ->
    io:put_chars(O, "\n").

%% Take a progress trace line and turn it into a map
read_progress_csv(<<"">>) ->
    empty;
read_progress_csv(Line) ->
    Fields0 = string:split(string:chomp(Line), ",", all),
    case [unquote(string:trim(Field)) || Field <- Fields0] of
        %% Skip title line
        [<<"TIMESTAMP">>, <<"TID">>|_] ->
            empty;
        Fields ->
            pt2map(Fields)
    end.

unquote(<<"\"", _/binary>> = Str) ->
    %% skip un-escaping...
    binary:part(Str, 1, byte_size(Str) - 2);
unquote(Str) ->
    Str.

add_annotation(Trace, Span) ->
    Annotation = #{timestamp => trace_ts(Trace),
                   value => maps:get(message, Trace)},
    Annotations = [Annotation|maps:get(annotations, Span, [])],
    maps:put(annotations, Annotations, Span).

add_stop(Trace, Span) ->
    Duration =
        case maps:get(duration, Trace, 1) of
            N when N =< 0 -> 1;
            N -> N
        end,
    add_annotation(Trace, maps:put(duration, Duration, Span)).

make_span(Trace, Id, ParentId, State) ->
    S0 = #{
           traceId => trace_id(Trace, State),
           name => trace_name(Trace),
           parentId => ParentId,
           id => Id,
           timestamp => trace_ts(Trace),
           localEndpoint => local_endpoint(Trace, State),
           tags => maps:without([name, duration,timestamp], Trace)
          },
    S1 = updatel([device,service], Trace, remoteEndpoint, serviceName, S0),
    span_kind(Trace, S1).

span_kind(Trace, Span) ->
    case maps:is_key(device, Trace) of
        true ->
            Span#{kind => <<"CLIENT">>};
        _ ->
            Span#{kind => <<"SERVER">>}
    end.

trace_id(_Trace, #state{options = #options{traceid = {supplied, TraceId}}}) ->
    TraceId;
trace_id(_Trace, #state{options = #options{traceid = random}} = State) ->
    hex16(State#state.traceid);
trace_id(Trace, #state{options = #options{traceid = random_usid}} = State) ->
    hex16((State#state.traceid + musid(Trace)) band 16#ffffffffffffffff);
trace_id(Trace, #state{options = #options{traceid = usid}}) ->
    hex16(musid(Trace)).

local_endpoint(State) ->
    State#state.options#options.localEndpoint.

local_endpoint(Trace, State) ->
    case maps:find(subsystem, Trace) of
        {ok, Subsystem} ->
            #{ serviceName => concat([local_endpoint(State),".", Subsystem]) };
        _ ->
            #{ serviceName => local_endpoint(State) }
    end.

concat(Strs) ->
    unicode:characters_to_binary(Strs).

update(Key1, Map1, Key2, Map2) ->
    case maps:find(Key1, Map1) of
        {ok, Value} ->
            maps:put(Key2, Value, Map2);
        error ->
            Map2
    end.

updatel(Keys, Map1, Key2, Key3, Map2) ->
    foldlwhile(
      fun (Key, Map) -> updateb(Key, Map, Key2, Key3, Map2) end,
      Map1, Keys).

update(Key1, Map1, Key2, Key3, Map2) ->
    {_, New} = updateb(Key1, Map1, Key2, Key3, Map2),
    New.

updateb(Key1, Map1, Key2, Key3, Map2) ->
    case maps:find(Key1, Map1) of
        {ok, Value} ->
            NewValue2 =
                case maps:find(Key2, Map2) of
                    {ok, M} when is_map(M) ->
                        maps:put(Key3, Value, M);
                    _ ->
                        #{Key3 => Value}
                end,
            {false, maps:put(Key2, NewValue2, Map2)};
        error ->
            {true, Map2}
    end.

foldlwhile(_F, Acc, []) ->
    Acc;
foldlwhile(F, Acc, [H|T]) ->
    case F(H, Acc) of
        {true, NewAcc} ->
            foldlwhile(F, NewAcc, T);
        {false, NewAcc} ->
            NewAcc;
        false ->
            Acc
    end.

musid(M) ->
    maps:get(usid, M, undefined).
mtid(M) ->
    maps:get(tid, M, undefined).

span_id(M) ->
    TS = trace_ts(M), % - maps:get(duration, M, 0),
    span_id(maps:get(usid, M),
            maps:get(tid, M),
            TS,
            trace_name(M),
            trace_device(M)).

span_id(U, T, TS, Str1, Str2) ->
    hexstr(binary:part(hash_term({U, T, TS, Str1, Str2}), 0, 8)).


hex16(Integer) when is_integer(Integer) ->
    iolist_to_binary(io_lib:format("~16.16.0b", [Integer])).

hash_term(Term) ->
    hash(term_to_binary(Term)).

hash(Binary) ->
    %% crypto:hash(sha256, Binary)
    erlang:md5(Binary).

hexstr(Binary) when is_binary(Binary) ->
    iolist_to_binary(
      lists:map(
        fun (Byte) -> io_lib:format("~2.16.0b", [Byte]) end,
        binary_to_list(Binary))).

pt2map(Line) ->
    TraceMap0 = makemap(Line, pt_fmt(length(Line))),
    maps:put(name, transform_message(trace_msg(TraceMap0)), TraceMap0).

pt_fmt(14) ->
    [{timestamp,timestamp},
     {tid, integer},
     {usid, integer},
     context,
     subsystem,
     phase,
     service,
     'service-phase',
     {'commit-queue-id', integer},
     node,
     device,
     'device-phase',
     {duration, fun (Str) ->
                        1000 * round(to_float(Str) * 1000)
                end},
     message];
pt_fmt(15) ->
    [{timestamp,timestamp},
     {tid, integer},
     {usid, integer},
     context,
     subsystem,
     phase,
     service,
     'service-phase',
     {'commit-queue-id', integer},
     node,
     device,
     'device-phase',
     package,
     {duration, fun (Str) ->
                        1000 * round(to_float(Str) * 1000)
                end},
     message].

%% FIXME
transform_message(Msg0) ->
    Msg1 =
        lists:foldl(
          fun (Pattern, Str) ->
                  case string:split(Str, Pattern, trailing) of
                      [Str2] -> Str2;
                      [Str2, <<>>] -> Str2;
                      _ -> Str
                  end
          end, Msg0,
          [<<"...">>, <<" done">>, <<" ok">>, <<" error">>,
           <<" result 'ok'">>]),
    Msg2 =
        lists:foldl(
          fun (Prefix, Str) ->
                  case string:prefix(Str, Prefix) of
                      nomatch -> Str;
                      NewStr -> NewStr
                  end
          end, Msg1,
          [<<"run ">>, <<"check ">>, <<"entering ">>, <<"leaving ">>]),
    transform2(Msg2).

transform2(<<"send NED show">>) -> <<"NED show">>;
transform2(Msg) -> Msg.

makemap(Values, Mapping) ->
    makemap(#{}, Values, Mapping).

makemap(Map, _, []) ->
    Map;
makemap(Map, [Value|Values], [{Key, Type}|Types]) ->
    makemap(addmap(Map, Key, Value, Type), Values, Types);
makemap(Map, [Value|Values], [Key|Types]) ->
    makemap(addmap(Map, Key, Value, string), Values, Types).

addmap(Map, _Key, "", _Type) ->
    Map;
addmap(Map, _Key, <<"">>, _Type) ->
    Map;
addmap(Map, Key, ValueStr, Type) ->
    Value =
        try
            case Type of
                integer ->
                    to_int(ValueStr);
                float ->
                    to_float(ValueStr);
                timestamp ->
                    calendar:rfc3339_to_system_time(binary_to_list(ValueStr),
                                                    [{unit,microsecond}]);
                string when is_atom(ValueStr) ->
                    atom_to_binary(ValueStr, utf8);
                string ->
                    iolist_to_binary(ValueStr);
                F when is_function(Type, 1) ->
                    F(ValueStr)
            end
        catch _:_ ->
                io:format(standard_error,
                          "Warning: failed to convert \"~s\" to ~p\n",
                          [ValueStr, Type]),
                ValueStr
        end,
    Map#{Key => Value}.

to_int(Str) ->
    case string:to_integer(string:trim(Str)) of
        {Int, <<"">>} when is_integer(Int) ->
            Int
    end.

to_float(Str) ->
    case string:to_float(string:trim(Str)) of
        {F, <<"">>} when is_float(F) ->
            F;
        {error, no_float} ->
            to_int(Str) + 0.0
    end.



trace_type(Trace) ->
    case trace_has_usid_and_tid(Trace) of
        true ->
            case trace_msg(Trace, trailing, <<"...">>) of
                true ->
                    start;
                false ->
                    case
                        trace_msg(Trace, trailing,
                                  [<<" done">>, <<" ok">>, <<" error">>])
                        orelse
                        trace_msg(Trace, leading, <<"leaving">>)
                    of
                        true ->
                            stop;
                        false ->
                            annotation
                    end
            end;
        false ->
            unknown
    end.

trace_has_usid_and_tid(Trace) ->
    is_integer(musid(Trace)) andalso is_integer(mtid(Trace)).

trace_has_duration(Trace) ->
    maps:is_key(duration, Trace).

trace_ts(TMap) ->
    maps:get(timestamp, TMap).

trace_msg(TMap) ->
    maps:get(message, TMap, <<"">>).

trace_name(TMap) ->
    maps:get(name, TMap, <<"">>).

trace_device(TraceMap) ->
    maps:get(device, TraceMap, <<"">>).

trace_msg(TraceMap, Direction, Pattern) when is_binary(Pattern) ->
    trace_msg(TraceMap, Direction, [Pattern]);
trace_msg(TraceMap, Direction, Patterns) ->
    Str = trace_msg(TraceMap),
    lists:any(
      fun (Pattern) ->
              case string:split(Str, Pattern, Direction) of
                  [_, <<>>] when Direction == trailing ->
                      true;
                  [<<>>, _] when Direction == leading ->
                      true;
                  _RRR ->
                      false
              end
      end, Patterns).

%% ------------------------------------------------------------------------
%% Tiny JSON encoder
%%
json(O, null)  -> emit(O, <<"null">>);
json(O, false) -> emit(O, <<"false">>);
json(O, true)  -> emit(O, <<"true">>);
json(O, N) when is_integer(N) -> emit(O, integer_to_list(N));
json(O, N) when is_float(N) ->   emit(O, float_to_list(N));

json(O, Object) when map_size(Object) =:= 0 ->
    emit(O, <<"{}">>);
json(O, Object) when is_map(Object) ->
    json_object(O, Object);
json(O, Str) when is_atom(Str) ->
    emit_string(O, atom_to_binary(Str, utf8));
json(O, Str) when is_binary(Str) ->
    emit_string(O, Str);
json(O, []) ->
    emit(O, <<"[]">>);
json(O, Sequence) when is_list(Sequence) ->
    json_sequence(O, Sequence).

json_object(O, Map) ->
    emit(O, <<"{">>),
    maps:fold(
      fun (Key, Value, CommaP) ->
              emit(O, <<",">>, CommaP),
              json(O, Key),
              emit(O, <<":">>),
              json(O, Value),
              true
      end, false, Map),
    emit(O, <<"}">>).

json_sequence(O, List) ->
    emit(O, <<"[">>),
    lists:foldl(
      fun (Value, CommaP) ->
              emit(O, <<",">>, CommaP),
              json(O, Value),
              true
      end, false, List),
    emit(O, <<"]">>).

emit_string(O, Str) ->
    emit(O, [$", string:replace(Str, "\"", "\\\"", all), $"]).

emit(O, Chars) ->
    io:put_chars(O, Chars).

emit(_, _, false) ->
    ok;
emit(O, Chars, true) ->
    io:put_chars(O, Chars).
