-module(progress2span).

-compile(export_all).

%% Post to http://127.0.0.1:9411/api/v2/spans
%% with Content-Type: application/json
%%
%% curl -v -v -X POST -H 'Content-Type: application/json' http://127.0.0.1:9411/api/v2/spans -d @-


test() ->
    code:add_path("/Users/seb/Desktop/src/eparse/ejson/ebin"),
    application:start(ejson),
    io:put_chars("[\n"),
    start("/tmp/progress-trace-nso2.csv"),
    io:put_chars("{}\n]\n"),
    erlang:halt(0).

start(FName) ->
    {ok, F} = open(FName),
    loop(F).

loop(F) ->
    loop(F, file:read_line(F)).

loop(F, eof) ->
    file:close(F),
    ok;
loop(F, {ok, Line}) ->
    M = pline2map(string:split(chop(Line), ",", all)),
    %%io:format("~999p\n", [M]),
    span(M),
    loop(F).


span(#{timestamp := <<"TIMESTAMP">>}) ->
    ok;
span(#{duration := D} = M) when D > 10000 ->
    Tags = maps:without([duration,timestamp], M),
    S0 = #{id => id(M),
           traceId => traceid(M),
           timestamp => maps:get(timestamp,M) - D,
           duration => D,
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
    io:put_chars(sejst:encode(S3)),
    io:put_chars(",\n"),
    S3;
span(_) ->
    ok.

id(M) ->
    hexstr(binary:part(
             hash_term({maps:get(usid, M),
                        maps:get(tid, M),
                        maps:get(timestamp, M)}),
             0, 8)).

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

name(#{message := <<"partial-sync-from done">>}) ->
    <<"partial-sync-from">>;
name(#{message := <<"calculating southbound diff ok">>}) ->
    <<"diff">>;
name(#{message := <<"device get-trans-id ok">>}) ->
    <<"transid">>;
name(#{message := <<"device connect ok">>}) ->
    <<"connect">>;
name(#{message := <<"device initialize ok">>}) ->
    <<"initialize">>;
name(#{tid := Tid}) when is_integer(Tid) andalso Tid >= 1 ->
    <<"transaction">>;
name(#{'commit-queue-id' := CQ}) when is_integer(CQ) ->
    <<"CQ">>;
name(_) ->
    undefined.



hex16(Integer) ->
    lists:flatten(io_lib:format("~16.16.0b", [Integer])).

hash_term(Term) ->
    hash(term_to_binary(Term)).

hash(Binary) ->
    %% crypto:hash(sha256, Binary)
    erlang:md5(Binary).

hexstr(Binary) ->
    iolist_to_binary(
      lists:map(
        fun (Byte) -> io_lib:format("~2.16.0b", [Byte]) end,
        binary_to_list(Binary))).


newmap(OldMap, KeyMapping) ->
    lists:foldl(
      fun ({K,NK}, M0) ->
              case maps:is_key(K, OldMap) of
                  true ->
                      M0#{NK => maps:get(K, OldMap)};
                  false ->
                      M0
              end
      end, #{}, KeyMapping).


open(FName) ->
    file:open(FName, [read,raw,binary,read_ahead]).

chop(B) ->
    binary:part(B, 0, byte_size(B) - 1).


pline2map(Line) ->
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
                                      1000 * round(binary_to_float(Str) * 1000)
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
                    binary_to_integer(ValueStr);
                float ->
                    %% Might need to try binary_to_float(<<ValueStr/binary, ".0">>).
                    binary_to_float(ValueStr);
                timestamp ->
                    calendar:rfc3339_to_system_time(binary_to_list(ValueStr),
                                                    [{unit,microsecond}]);
                string ->
                    ValueStr;
                quoted ->
                    %% shortcut
                    binary:part(ValueStr, 1, byte_size(ValueStr) - 2);
                F when is_function(Type, 1) ->
                    F(ValueStr)
            end
        catch _:_ ->
                ValueStr
        end,
    Map#{Key => Value}.
