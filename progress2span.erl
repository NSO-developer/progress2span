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
    io:put_chars(O, "[\n"),
    loop(I, O, file:read_line(I), undefined, #{}),
    io:put_chars(O, "]\n"),
    ok.

loop(I, O, eof, Span, _State) ->
    print_span(O, Span, false),
    file:close(I),
    ok;
loop(I, O, {ok, Line}, Span, State0) ->
    print_span(O, Span, true),
    {NextSpan, State1} = line2span(Line, State0),
    loop(I, O, file:read_line(I), NextSpan, State1).

print_span(_, undefined, _CommaP) ->
    ok;
print_span(O, Span, CommaP) ->
    io:put_chars(O, sejst:encode(Span)),
    print_nl(O, CommaP),
    ok.

print_nl(O, true) ->
    io:put_chars(O, ",\n");
print_nl(O, false) ->
    io:put_chars(O, "\n").

line2span(Line, State) ->
    M = pline2map(string:split(string:chomp(Line), ",", all)),
%    io:format("~999p\n", [M]),
    span(M, State).

span(#{timestamp := <<"TIMESTAMP">>}, State) ->
    {undefined, State};
span(M, State0) ->
    Id = id(M),
    State = update_state(M, Id, State0),
    ParentId = parent_id(M, State),

    TS = maps:get(timestamp,M),
    S00 =
        case maps:find(duration, M) of
            {ok, N} when N =< 0 ->
                #{duration => 1, timestamp => TS};
            {ok, N} ->
                #{duration => N, timestamp => TS - N};
            error ->
                #{duration => 1, timestamp => TS}
        end,
    Tags = maps:without([duration,timestamp], M),
    S0 = S00#{id => Id,
              parentId => ParentId,
              traceId => traceid(M),
              tags => Tags},
    S1 =
        case maps:is_key(subsystem, M) of
            true ->
                S0#{localEndPoint => #{serviceName => maps:get(subsystem, M)}};
            false ->
                S0
        end,
    S2 =
        case maps:is_key(device, M) of
            true ->
                S1#{remoteEndpoint => #{serviceName => maps:get(device, M)}};
            false ->
                S1
        end,
    S3 = addname(M, S2),
    {S3, State}.

parent_id(M, State) ->
    case mtid(M) of
        undefined -> maps:get({usid, musid(M)}, State);
        Tid -> maps:get({tid,Tid}, State)
    end.

update_state(M, Id, State) ->
    update_state(mtid(M), musid(M), Id, State).

mtid(M) ->
    maps:get(tid, M, undefined).
musid(M) ->
    maps:get(usid, M, undefined).

%% If this is the first time we see this usid, save it's id and
%% make others use it as parentID
%%
%% If this is the first time we see this tid, save it's id and
%% make others use it as parentId
update_state(T, U, Id, State) ->
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


id(M) ->
    hexstr(binary:part(
             hash_term({maps:get(usid, M),
                        maps:get(tid, M),
                        maps:get(timestamp, M),
                        transform_message(maps:get(message, M))}),
             0, 8)).

traceid(#{usid := USId}) when is_integer(USId) andalso USId >= 1 ->
    hex16(USId);
traceid(#{tid := Tid}) when is_integer(Tid) andalso Tid >= 1 ->
    hex16(Tid);
traceid(#{'commit-queue-id' := CQ}) when is_integer(CQ) ->
    hex16(CQ);
traceid(M) ->
    hexstr(binary:part(
             hash_term({maps:get(usid, M), maps:get(tid, M)}), 0, 8)).

addname(M, S) ->
    case name(M) of
        undefined ->
            S;
        Name ->
            S#{ name => Name }
    end.

name(#{message := Msg}) ->
    transform_message(Msg);
name(#{tid := Tid}) when is_integer(Tid) andalso Tid >= 1 ->
    <<"transaction">>;
name(#{'commit-queue-id' := CQ}) when is_integer(CQ) ->
    <<"commit queue">>;
name(_) ->
    undefined.

transform_message(Msg) ->
    lists:foldl(
      fun (Pattern, Str) ->
              case string:split(Str, Pattern, trailing) of
                  [Str2] -> Str2;
                  [Str2, <<>>] -> Str2;
                  _ -> Str
              end
      end, Msg, [<<"...">>, <<" done">>, <<" ok">>]).

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

pline2map(Line) when length(Line) == 14 ->
    makemap(Line, [{timestamp,timestamp},
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
                   {message, quoted}]);
pline2map(Line) when length(Line) == 15 ->
    makemap(Line, [{timestamp,timestamp},
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
                   {message, quoted}]).

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
                quoted ->
                    %% shortcut
                    Str = string:trim(ValueStr),
                    binary:part(Str, 1, byte_size(Str) - 2);
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
