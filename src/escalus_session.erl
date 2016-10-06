%%%===================================================================
%%% @copyright (C) 2011-2012, Erlang Solutions Ltd.
%%% @doc Module providing basic session manipulation
%%% @end
%%%===================================================================

-module(escalus_session).
-export([start_stream/2,
         authenticate/2,
         starttls/2,
         bind/2,
         compress/2,
         use_ssl/2,
         can_use_amp/2,
         can_use_compression/2,
         can_use_stream_management/2,
         session/2]).

%% New style connection initiation
-export([start_stream/3,
         stream_features/3,
         maybe_use_ssl/3,
         maybe_use_carbons/3,
         maybe_use_compression/3,
         maybe_stream_management/3,
         maybe_stream_resumption/3,
         stream_management/3,
         stream_resumption/3,
         authenticate/3,
         bind/3,
         session/3]).

%% Public Types
-export_type([feature/0,
              features/0,
              step/0,
              step_state/0]).

-type feature() :: {atom(), any()}.
-type features() :: [feature()].
-define(CONNECTION_STEP, (escalus_connection:client(),
                          escalus_users:user_spec(),
                          features()) -> step_state()).
-define(CONNECTION_STEP_SIG(Module), Module?CONNECTION_STEP).
-type step() :: fun(?CONNECTION_STEP).
-type step_state() :: {escalus_connection:client(),
                       escalus_users:user_spec(),
                       features()}.

%% Some shorthands
-type client() :: escalus_connection:client().
-type user_spec() :: escalus_users:user_spec().

-include_lib("exml/include/exml.hrl").
-include_lib("exml/include/exml_stream.hrl").
-include("escalus_xmlns.hrl").
-define(DEFAULT_RESOURCE, <<"escalus-default-resource">>).

%%%===================================================================
%%% Public API
%%%===================================================================

-spec start_stream(client(), user_spec()) -> {user_spec(), features()}.
start_stream(Conn, Props) ->
    {server, Server} = lists:keyfind(server, 1, Props),
    NS = proplists:get_value(stream_ns, Props, <<"jabber:client">>),
    Transport = proplists:get_value(transport, Props, escalus_tcp),
    IsLegacy = proplists:get_value(wslegacy, Props, false),
    StreamStartReq = case {Transport, IsLegacy} of
                         {escalus_ws, false} -> escalus_stanza:ws_open(Server);
                         _ -> escalus_stanza:stream_start(Server, NS)
                     end,
    ok = escalus_connection:send(Conn, StreamStartReq),
    StreamStartRep = escalus_connection:get_stanza(Conn, wait_for_stream),
    assert_stream_start(StreamStartRep, Transport, IsLegacy),
    %% TODO: deprecate 2-tuple return value
    %% To preserve the previous interface we still return a 2-tuple,
    %% but it's guaranteed that the features will be empty.
    {maybe_store_stream_id(StreamStartRep, Props), []}.

-spec starttls(client(), user_spec()) -> {client(), user_spec()}.
starttls(Conn, Props) ->
    escalus_tcp:upgrade_to_tls(Conn, Props).

-spec authenticate(client(), user_spec()) -> user_spec().
authenticate(Conn, Props) ->
    %% FIXME: as default, select authentication scheme based on stream features
    {M, F} = proplists:get_value(auth, Props, {escalus_auth, auth_plain}),
    PropsAfterAuth = case M:F(Conn, Props) of
                         ok -> Props;
                         {ok, P} when is_list(P) -> P
                     end,
    escalus_connection:reset_parser(Conn),
    {Props1, []} = escalus_session:start_stream(Conn, PropsAfterAuth),
    escalus_session:stream_features(Conn, Props1, []),
    Props1.

-spec bind(client(), user_spec()) -> user_spec().
bind(Conn, Props) ->
    Resource = proplists:get_value(resource, Props, ?DEFAULT_RESOURCE),
    escalus_connection:send(Conn, escalus_stanza:bind(Resource)),
    BindReply = escalus_connection:get_stanza(Conn, bind_reply),
    escalus:assert(is_bind_result, BindReply),
    case proplists:get_value(auth_method, Props) of
        <<"SASL-ANON">> ->
            JID = exml_query:path(BindReply, [{element, <<"bind">>}, {element, <<"jid">>}, cdata]),
            TMPUsername = escalus_utils:get_username(JID),
            lists:keyreplace(username, 1, Props, {username, TMPUsername});
        _ ->
            Props
    end.

-spec compress(client(), user_spec()) -> {client(), user_spec()}.
compress(Conn, Props) ->
    case proplists:get_value(compression, Props, false) of
        false ->
            {Conn, Props};
        <<"zlib">> ->
            escalus_tcp:use_zlib(Conn, Props)
        %% TODO: someday maybe lzw too
    end.

-spec session(client(), user_spec()) -> user_spec().
session(Conn, Props) ->
    escalus_connection:send(Conn, escalus_stanza:session()),
    SessionReply = escalus_connection:get_stanza(Conn, session_reply),
    escalus:assert(is_iq_result, SessionReply),
    Props.

-spec use_ssl(user_spec(), features()) -> boolean().
use_ssl(Props, Features) ->
    UserNeedsSSL = proplists:get_value(starttls, Props, false),
    StreamAllowsSSL = proplists:get_value(starttls, Features),
    case {UserNeedsSSL, StreamAllowsSSL} of
        {required, true} -> true;
        {required, false} -> error("Client requires StartTLS "
                                   "but server doesn't offer it");
        {false, _ } -> false;
        {optional, true} -> true;
        _ -> false
    end.

-spec can_use_compression(user_spec(), features()) -> boolean().
can_use_compression(Props, Features) ->
    can_use(compression, Props, Features).

-spec can_use_stream_management(user_spec(), features()) -> boolean().
can_use_stream_management(Props, Features) ->
    can_use(stream_management, Props, Features).

can_use_carbons(Props, _Features) ->
    false /= proplists:get_value(carbons, Props, false).

-spec can_use_amp(user_spec(), features()) -> boolean().
can_use_amp(_Props, Features) ->
    false /= proplists:get_value(advanced_message_processing, Features).

can_use(Feature, Props, Features) ->
    false /= proplists:get_value(Feature, Props, false) andalso
    false /= proplists:get_value(Feature, Features).

%%%===================================================================
%%% New style connection initiation
%%%===================================================================

-spec ?CONNECTION_STEP_SIG(start_stream).
start_stream(Conn, Props, [] = _Features) ->
    {Props1, []} = start_stream(Conn, Props),
    {Conn, Props1, []}.

-spec ?CONNECTION_STEP_SIG(stream_features).
stream_features(Conn, Props, [] = _Features) ->
    StreamFeatures = escalus_connection:get_stanza(Conn, wait_for_features),
    Transport = proplists:get_value(transport, Props, tcp),
    IsLegacy = proplists:get_value(wslegacy, Props, false),
    assert_stream_features(StreamFeatures, Transport, IsLegacy),
    {Conn, Props, get_stream_features(StreamFeatures)}.

-spec ?CONNECTION_STEP_SIG(maybe_use_ssl).
maybe_use_ssl(Conn, Props, Features) ->
    case use_ssl(Props, Features) of
        true ->
            {Conn1, Props1} = starttls(Conn, Props),
            {Conn2, Props2, Features2} = stream_features(Conn1, Props1, []),
            {Conn2, Props2, Features2};
        false ->
            {Conn, Props, Features}
    end.

-spec ?CONNECTION_STEP_SIG(maybe_use_carbons).
maybe_use_carbons(Conn, Props, Features) ->
    case can_use_carbons(Props, Features) of
        true ->
            use_carbons(Conn, Props, Features);
        false ->
            {Conn, Props, Features}
    end.

-spec ?CONNECTION_STEP_SIG(use_carbons).
use_carbons(Conn, Props, Features) ->
    escalus_connection:send(Conn, escalus_stanza:carbons_enable()),
    Result = escalus_connection:get_stanza(Conn, carbon_iq_response),
    escalus:assert(is_iq, [<<"result">>], Result),
    {Conn, Props, Features}.

-spec ?CONNECTION_STEP_SIG(maybe_use_compression).
maybe_use_compression(Conn, Props, Features) ->
    case can_use_compression(Props, Features) of
        true ->
            {Conn1, Props1} = compress(Conn, Props),
            {Conn2, Props2, Features2} = stream_features(Conn1, Props1, []),
            {Conn2, Props2, Features2};
        false ->
            {Conn, Props, Features}
    end.

-spec ?CONNECTION_STEP_SIG(maybe_stream_management).
maybe_stream_management(Conn, Props, Features) ->
    case can_use_stream_management(Props, Features) of
        true ->
            stream_management(Conn, Props, Features);
        false ->
            {Conn, Props, Features}
    end.

-spec ?CONNECTION_STEP_SIG(stream_management).
stream_management(Conn, Props, Features) ->
    escalus_connection:send(Conn, escalus_stanza:enable_sm()),
    Enabled = escalus_connection:get_stanza(Conn, stream_management),
    true = escalus_pred:is_sm_enabled(Enabled),
    {Conn, Props, Features}.

-spec ?CONNECTION_STEP_SIG(maybe_stream_resumption).
maybe_stream_resumption(Conn, Props, Features) ->
    case can_use_stream_management(Props, Features) of
        true ->
            stream_resumption(Conn, Props, Features);
        false ->
            {Conn, Props, Features}
    end.

-spec ?CONNECTION_STEP_SIG(stream_resumption).
stream_resumption(Conn, Props, Features) ->
    escalus_connection:send(Conn, escalus_stanza:enable_sm([resume])),
    Enabled = escalus_connection:get_stanza(Conn, stream_resumption),
    true = escalus_pred:is_sm_enabled([resume], Enabled),
    SMID = exml_query:attr(Enabled, <<"id">>),
    {Conn, [{smid, SMID} | Props], Features}.

-spec ?CONNECTION_STEP_SIG(authenticate).
authenticate(Conn, Props, Features) ->
    {Conn, authenticate(Conn, Props), Features}.

-spec ?CONNECTION_STEP_SIG(bind).
bind(Conn, Props, Features) ->
    {Conn, bind(Conn, Props), Features}.

-spec ?CONNECTION_STEP_SIG(session).
session(Conn, Props, Features) ->
    {Conn, session(Conn, Props), Features}.

%%%===================================================================
%%% Helpers
%%%===================================================================

assert_stream_start(StreamStartRep, Transport, IsLegacy) ->
    case {StreamStartRep, Transport, IsLegacy} of
        {#xmlel{name = <<"open">>}, escalus_ws, false} ->
            ok;
        {#xmlel{name = <<"open">>}, escalus_ws, true} ->
            error("<open/> with legacy WebSocket",
                  [StreamStartRep]);
        {#xmlstreamstart{}, escalus_ws, false} ->
            error("<stream:stream> with non-legacy WebSocket",
                  [StreamStartRep]);
        {#xmlstreamstart{}, _, _} ->
            ok;
        _ ->
            error("Not a valid stream start", [StreamStartRep])
    end.

assert_stream_features(StreamFeatures, Transport, IsLegacy) ->
    case {StreamFeatures, Transport, IsLegacy} of
        {#xmlel{name = <<"features">>}, escalus_ws, false} ->
            ok;
        {#xmlel{name = <<"features">>}, escalus_ws, true} ->
            error("<features> with legacy WebSocket");
        {#xmlel{name = <<"stream:features">>}, escalus_ws, false} ->
            error("<stream:features> with non-legacy WebSocket",
                  [StreamFeatures]);
        {#xmlel{name = <<"stream:features">>}, _, _} ->
            ok;
        _ ->
           error(
             lists:flatten(
               io_lib:format(
                 "Expected stream features, got ~p",
                 [StreamFeatures])))
    end.

-spec get_stream_features(exml:element()) -> features().
get_stream_features(Features) ->
    [{compression, get_compression(Features)},
     {starttls, get_starttls(Features)},
     {stream_management, get_stream_management(Features)},
     {advanced_message_processing, get_advanced_message_processing(Features)},
     {client_state_indication, get_client_state_indication(Features)},
     {sasl_mechanisms, get_sasl_mechanisms(Features)},
     {caps, get_server_caps(Features)}].

-spec get_compression(exml:element()) -> boolean().
get_compression(Features) ->
    case exml_query:subelement(Features, <<"compression">>) of
        #xmlel{children = MethodEls} ->
            [exml_query:cdata(MethodEl) || MethodEl <- MethodEls];
        _ -> false
    end.

-spec get_starttls(exml:element()) -> boolean().
get_starttls(Features) ->
    undefined =/= exml_query:subelement(Features, <<"starttls">>).

-spec get_stream_management(exml:element()) -> boolean().
get_stream_management(Features) ->
    undefined =/= exml_query:subelement(Features, <<"sm">>).

-spec get_advanced_message_processing(exml:element()) -> boolean().
get_advanced_message_processing(Features) ->
    undefined =/= exml_query:subelement(Features, <<"amp">>).

-spec get_client_state_indication(exml:element()) -> boolean().
get_client_state_indication(Features) ->
    undefined =/= exml_query:subelement(Features, <<"csi">>).

-spec get_sasl_mechanisms(exml:element()) -> [exml:element() | binary()].
get_sasl_mechanisms(Features) ->
    exml_query:paths(Features, [{element, <<"mechanisms">>},
                                {element, <<"mechanism">>}, cdata]).

-spec get_server_caps(exml:element()) -> map().
get_server_caps(Features) ->
    case exml_query:subelement(Features, <<"c">>) of
        #xmlel{attrs = Attrs} ->
            maps:from_list(Attrs);
        _ ->
            undefined
    end.


-spec stream_start_to_element(exml_stream:element()) -> exml:element().
stream_start_to_element(#xmlel{name = <<"open">>} = Open) -> Open;
stream_start_to_element(#xmlstreamstart{name = Name, attrs = Attrs}) ->
    #xmlel{name = Name, attrs = Attrs, children = []}.

maybe_store_stream_id(StreamStartResponse, Props) ->
    case exml_query:attr(stream_start_to_element(StreamStartResponse),
                         <<"id">>, no_id) of
        no_id -> Props;
        ID when is_binary(ID) ->
            lists:keystore(stream_id, 1, Props, {stream_id, ID})
    end.
