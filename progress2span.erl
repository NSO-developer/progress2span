-module(progress2span).

%% -compile(export_all).
-export([main/1]).

init() ->
    code:add_path("/Users/seb/Desktop/src/eparse/ejson/ebin"),
    application:start(ejson).

main(Args) ->
    {I, O} =
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
        end,
    init(),
    process(I, O),
    erlang:halt(0).

ropen(FileName) ->
    file:open(FileName, [read,raw,binary,read_ahead]).

wopen(FileName) ->
    file:open(FileName, [write]).

process(I, O) ->
    process_flag(trap_exit, true),
    try
        Collector = spawn_link(fun () -> start_collector(O) end),
        loop(I, Collector, file:read_line(I)),
        receive
            {'EXIT', Collector, _} ->
                ok
        end
    after
        file:close(I),
        file:close(O)
    end.

loop(_I, Collector, eof) ->
    Collector ! eof,
    ok;
loop(I, Collector, {ok, Line}) ->
    case read_progress_csv(Line) of
        empty ->
            ok;
        PMap ->
            Collector ! {progress, PMap}
    end,
    loop(I, Collector, file:read_line(I)).


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
                outfd,
                span_printed = false,
                traceid = hex16(rand:uniform(16#ffffffffffffffff)),
                localEndpoint = "nso",
                utmap = #{},
                current = #{},
                stacks = #{}
               }).

start_collector(O) ->
    io:put_chars(O, "["),
    collector_loop(#state{outfd = O}).

stop_collector(#state{outfd = O} = State) ->
    print_nl(O, false),
    io:put_chars(O, "]\n"),
    case maps:size(State#state.current) of
        0 -> ok;
        N -> io:format("~p unmatched start events left\n", [N])
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
    case classify(Trace) of
        {start, Key} ->
            Id = span_id(Trace),
            State1 = update_utmap(Trace, Id, S0),
            ParentId = parent_id(Trace, Id, State1),
            Span = make_span(Trace, Id, ParentId, State1),
            push_span(Key, Span, State1);
        {stop, Key} ->
            case pop_span(Key, S0) of
                undefined ->
                    io:format("unmatched stop event: ~p\n", [trace_msg(Trace)]),
                    S0;
                {Span, S1} ->
                    print_span(add_stop(Trace, Span), S1)
            end;
        {annotation, Key} ->
            add_annotation_to_current(Key, Trace, S0)
    end.

push_span(Key, Span, #state{current = C, stacks = Stacks} = State) ->
    case maps:is_key(Key, C) of
        true ->  io:format("Duplicate key: ~p\n", [Key]);
        false -> ok
    end,
    SKey = stack_key(Key),
    Stack = maps:get(SKey, Stacks, []),
    State#state{current = maps:put(Key, Span, C),
                stacks = maps:put(SKey, [Key|Stack], Stacks)}.

pop_span(Key, #state{current = C, stacks = Stacks} = State) ->
    case maps:take(Key, C) of
        {Span, New} ->
            NewStacks =
                maps:update_with(stack_key(Key), fun ([_|T]) -> T end, Stacks),
            {Span, State#state{current = New, stacks = NewStacks}};
        error ->
            undefined
    end.

add_annotation_to_current(AKey, Trace, #state{current = C} = State) ->
    case maps:get(stack_key(AKey), State#state.stacks, undefined) of
        undefined ->
            io:format("dropping annotation: ~p\n", [trace_msg(Trace)]),
            State;
        [] ->
            io:format("dropping annotation (): ~p\n", [trace_msg(Trace)]),
            State;
        [Key|_] ->
            UpdateF = fun (Span) -> add_annotation(Trace, Span) end,
            State#state{current = maps:update_with(Key, UpdateF, C)}
    end.

classify(Trace) ->
    Type = trace_type(Trace),
    case trace_has_duration(Trace) of
        true when Type == start ->
            io:format("START MSG W DURATION:\n  ~999p\n", [Trace]);
        true when Type == annotation ->
            io:format("ANN MSG W DURATION:\n  ~999p\n", [Trace]);
        false when Type == stop ->
            io:format("STOP MSG W/O DURATION:\n  ~999p\n", [Trace]);
        _D when Type == unknown ->
            io:format("UNKNOWN (has_duration: ~p)\n  ~999p\n", [_D, Trace]);
        _ ->
            ok
    end,
    {Type, key(Trace)}.

key(Trace) ->
    {musid(Trace), mtid(Trace), trace_name(Trace), trace_device(Trace)}.

stack_key({U,T,_,D}) ->
    {U,T,D}.

%% XXX
parent_id(Trace, _Id, State) ->
    case mtid(Trace) of
        undefined -> maps:get({usid, musid(Trace)}, State#state.utmap);
        Tid -> maps:get({tid,Tid}, State#state.utmap)
    end.



print_span(Span, #state{outfd = O} = State) ->
    print_nl(O, State#state.span_printed),
    io:put_chars(O, sejst:encode(Span)),
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
    Annotation = #{timestamp => maps:get(timestamp, Trace),
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
%           traceId => State#state.traceid,
           traceId => hex16(musid(Trace)),
           name => trace_name(Trace),
           parentId => ParentId,
           id => Id,
           %% kind => ???
           kind => <<"CLIENT">>,
           timestamp => maps:get(timestamp, Trace),
           localEndpoint => local_endpoint(Trace, State),
           tags => maps:without([name, duration,timestamp], Trace)
          },
    updatel([device,service], Trace, remoteEndpoint, serviceName, S0).

local_endpoint(Trace, State) ->
    case maps:find(subsystem, Trace) of
        {ok, Subsystem} ->
            #{ serviceName => Subsystem };
        _ ->
            #{ serviceName => State#state.localEndpoint }
    end.

%% update(Key1, Map1, Key2, Map2) ->
%%     case maps:find(Key1, M) of
%%         {ok, Value} ->
%%             maps:put(Key2, Value, Map2);
%%         error ->
%%             Map2
%%     end.

updatel(Keys, Map1, Key2, Key3, Map2) ->
    foldlwhile(
      fun (Key, Map) -> update(Key, Map, Key2, Key3, Map2) end,
      Map1, Keys).

update(Key1, Map1, Key2, Key3, Map2) ->
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

update_utmap(M, Id, #state{utmap = UTMap} = State) ->
    State#state{utmap = update_utmap(musid(M), mtid(M), Id, UTMap)}.

musid(M) ->
    maps:get(usid, M, undefined).
mtid(M) ->
    maps:get(tid, M, undefined).

%% If this is the first time we see this usid, save it's id and
%% make others use it as parentID
%%
%% If this is the first time we see this tid, save it's id and
%% make others use it as parentId
update_utmap(U, T, Id, State) ->
    case maps:is_key({tid, T}, State) of
        false ->
            case maps:is_key({usid,U}, State) of
                %% false ->
                %%     State#{{tid,T} => Id, {usid,U} => Id};
                %% true ->
                %%     State#{{tid,T} => Id}
                false when T /= undefined ->
                    State#{{tid,T} => Id, {usid,U} => Id};
                false ->
                    State#{{usid,U} => Id};
                true ->
                    State#{{tid,T} => Id}
            end;
        true ->
            State
    end.


span_id(M) ->
    TS = maps:get(timestamp, M), % - maps:get(duration, M, 0),
    hexstr(binary:part(
             hash_term({maps:get(usid, M),
                        maps:get(tid, M),
                        TS,
                        trace_name(M),
                        trace_device(M)
                       }),
             0, 8)).

hex16(Integer) when is_integer(Integer) ->
    lists:flatten(io_lib:format("~16.16.0b", [Integer])).

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
          fun (Pattern, Str) ->
                  case string:split(Str, Pattern, leading) of
                      [Str2] -> Str2;
                      [<<>>, Str2] -> Str2;
                      _ -> Str
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
                string ->
                    ValueStr;
                F when is_function(Type, 1) ->
                    F(ValueStr)
            end
        catch _:_ ->
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
