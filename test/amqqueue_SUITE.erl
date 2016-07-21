%% The contents of this file are subject to the Mozilla Public License
%% Version 1.1 (the "License"); you may not use this file except in
%% compliance with the License. You may obtain a copy of the License
%% at http://www.mozilla.org/MPL/
%%
%% Software distributed under the License is distributed on an "AS IS"
%% basis, WITHOUT WARRANTY OF ANY KIND, either express or implied. See
%% the License for the specific language governing rights and
%% limitations under the License.
%%
%% The Original Code is RabbitMQ.
%%
%% The Initial Developer of the Original Code is GoPivotal, Inc.
%% Copyright (c) 2007-2016 Pivotal Software, Inc.  All rights reserved.
%%

-module(amqqueue_SUITE).

-compile(export_all).

-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").
-include_lib("amqp_client/include/amqp_client.hrl").
-include("rabbit_stomp.hrl").
-include("rabbit_stomp_frame.hrl").
-include("rabbit_stomp_headers.hrl").

-define(QUEUE, <<"TestQueue">>).
-define(DESTINATION, "/amq/queue/TestQueue").

all() ->
    [{group, list_to_atom("version_" ++ V)} || V <- ?SUPPORTED_VERSIONS].

groups() ->
    Tests = [
        publish_no_dest_error,
        publish_unauthorized_error,
        subscribe_error,
        subscribe,
        unsubscribe_ack,
        subscribe_ack,
        send,
        delete_queue_subscribe,
        temp_destination_queue,
        temp_destination_in_send,
        blank_destination_in_send
    ],

    [{list_to_atom("version_" ++ V), [sequence], Tests} 
     || V <- ?SUPPORTED_VERSIONS].

init_per_suite(Config) ->
    rabbit_ct_helpers:log_environment(),
    rabbit_ct_helpers:run_setup_steps(Config, 
                                      rabbit_ct_broker_helpers:setup_steps()).

end_per_suite(Config) ->
    rabbit_ct_helpers:run_teardown_steps(Config).

init_per_group(Group, Config) ->
    Version = string:sub_string(atom_to_list(Group), 9),
    rabbit_ct_helpers:set_config(Config, [{version, Version}]).

end_per_group(_Group, Config) -> Config.

init_per_testcase(_, Config) ->
    Version = ?config(version, Config),
    StompPort = rabbit_ct_broker_helpers:get_node_config(Config, 0, tcp_port_stomp),
    {ok, Connection} = amqp_connection:start(#amqp_params_direct{
        node = rabbit_ct_broker_helpers:get_node_config(Config, 0, nodename)
    }),
    {ok, Channel} = amqp_connection:open_channel(Connection),
    {ok, Client} = rabbit_stomp_client:connect(Version, StompPort),
    rabbit_ct_helpers:set_config(Config, [
        {amqp_connection, Connection},
        {amqp_channel, Channel},
        {stomp_client, Client}
      ]).

end_per_testcase(_, Config) ->
    Connection = ?config(amqp_connection, Config),
    Channel = ?config(amqp_channel, Config),
    Client = ?config(stomp_client, Config),
    rabbit_stomp_client:disconnect(Client),
    amqp_channel:close(Channel),
    amqp_connection:close(Connection),
    Config.

publish_no_dest_error(Config) ->
    Client = ?config(stomp_client, Config),
    rabbit_stomp_client:send(
      Client, "SEND", [{"destination", "/exchange/non-existent"}], ["hello"]),
    {ok, _Client1, Hdrs, _} = stomp_receive(Client, "ERROR"),
    "not_found" = proplists:get_value("message", Hdrs),
    ok.

publish_unauthorized_error(Config) ->
    Channel = ?config(amqp_channel, Config),
    Version = ?config(version, Config),
    #'queue.declare_ok'{} =
        amqp_channel:call(Channel, #'queue.declare'{queue       = <<"RestrictedQueue">>,
                                                    auto_delete = true}),

    rabbit_ct_broker_helpers:rpc(Config, 0, rabbit_auth_backend_internal, add_user, [<<"user">>, <<"pass">>]),
    rabbit_ct_broker_helpers:rpc(Config, 0, rabbit_auth_backend_internal, set_permissions, [
        <<"user">>, <<"/">>, <<"nothing">>, <<"nothing">>, <<"nothing">>]),
    StompPort = rabbit_ct_broker_helpers:get_node_config(Config, 0, tcp_port_stomp),
    {ok, ClientFoo} = rabbit_stomp_client:connect(Version, "user", "pass", StompPort),
    try
        rabbit_stomp_client:send(
          ClientFoo, "SEND", [{"destination", "/amq/queue/RestrictedQueue"}], ["hello"]),
        {ok, _Client1, Hdrs, _} = stomp_receive(ClientFoo, "ERROR"),
        "access_refused" = proplists:get_value("message", Hdrs), 
        ok
    catch _:Err ->
        Err
    after 
        rabbit_stomp_client:disconnect(ClientFoo),
        rabbit_ct_broker_helpers:rpc(Config, 0, rabbit_auth_backend_internal, delete_user, [<<"user">>])
    end.    

subscribe_error(Config) ->
    Client = ?config(stomp_client, Config),
    %% SUBSCRIBE to missing queue
    rabbit_stomp_client:send(
      Client, "SUBSCRIBE", [{"destination", ?DESTINATION}]),
    {ok, _Client1, Hdrs, _} = stomp_receive(Client, "ERROR"),
    "not_found" = proplists:get_value("message", Hdrs),
    ok.

subscribe(Config) ->
    Channel = ?config(amqp_channel, Config),
    Client = ?config(stomp_client, Config),
    #'queue.declare_ok'{} =
        amqp_channel:call(Channel, #'queue.declare'{queue       = ?QUEUE,
                                                    auto_delete = true}),

    %% subscribe and wait for receipt
    rabbit_stomp_client:send(
      Client, "SUBSCRIBE", [{"destination", ?DESTINATION}, {"receipt", "foo"}]),
    {ok, Client1, _, _} = stomp_receive(Client, "RECEIPT"),

    %% send from amqp
    Method = #'basic.publish'{exchange = <<"">>, routing_key = ?QUEUE},

    amqp_channel:call(Channel, Method, #amqp_msg{props = #'P_basic'{},
                                                 payload = <<"hello">>}),

    {ok, _Client2, _, [<<"hello">>]} = stomp_receive(Client1, "MESSAGE"),
    ok.

unsubscribe_ack(Config) ->
    Channel = ?config(amqp_channel, Config),
    Client = ?config(stomp_client, Config),
    Version = ?config(version, Config),
    #'queue.declare_ok'{} =
        amqp_channel:call(Channel, #'queue.declare'{queue       = ?QUEUE,
                                                    auto_delete = true}),
    %% subscribe and wait for receipt
    rabbit_stomp_client:send(
      Client, "SUBSCRIBE", [{"destination", ?DESTINATION},
                            {"receipt", "rcpt1"},
                            {"ack", "client"},
                            {"id", "subscription-id"}]),
    {ok, Client1, _, _} = stomp_receive(Client, "RECEIPT"),

    %% send from amqp
    Method = #'basic.publish'{exchange = <<"">>, routing_key = ?QUEUE},

    amqp_channel:call(Channel, Method, #amqp_msg{props = #'P_basic'{},
                                                 payload = <<"hello">>}),

    {ok, Client2, Hdrs1, [<<"hello">>]} = stomp_receive(Client1, "MESSAGE"),

    rabbit_stomp_client:send(
      Client2, "UNSUBSCRIBE", [{"destination", ?DESTINATION},
                              {"id", "subscription-id"}]),

    rabbit_stomp_client:send(
      Client2, "ACK", [{rabbit_stomp_util:ack_header_name(Version),
                        proplists:get_value(
                          rabbit_stomp_util:msg_header_name(Version), Hdrs1)},
                       {"receipt", "rcpt2"}]),

    {ok, _Client3, Hdrs2, _Body2} = stomp_receive(Client2, "ERROR"),
    ?assertEqual("Subscription not found",
                 proplists:get_value("message", Hdrs2)),
    ok.

subscribe_ack(Config) ->
    Channel = ?config(amqp_channel, Config),
    Client = ?config(stomp_client, Config),
    Version = ?config(version, Config),
    #'queue.declare_ok'{} =
        amqp_channel:call(Channel, #'queue.declare'{queue       = ?QUEUE,
                                                    auto_delete = true}),

    %% subscribe and wait for receipt
    rabbit_stomp_client:send(
      Client, "SUBSCRIBE", [{"destination", ?DESTINATION},
                            {"receipt",     "foo"},
                            {"ack",         "client"}]),
    {ok, Client1, _, _} = stomp_receive(Client, "RECEIPT"),

    %% send from amqp
    Method = #'basic.publish'{exchange = <<"">>, routing_key = ?QUEUE},

    amqp_channel:call(Channel, Method, #amqp_msg{props = #'P_basic'{},
                                                 payload = <<"hello">>}),

    {ok, _Client2, Headers, [<<"hello">>]} = stomp_receive(Client1, "MESSAGE"),
    false = (Version == "1.2") xor proplists:is_defined(?HEADER_ACK, Headers),

    MsgHeader = rabbit_stomp_util:msg_header_name(Version),
    AckValue  = proplists:get_value(MsgHeader, Headers),
    AckHeader = rabbit_stomp_util:ack_header_name(Version),

    rabbit_stomp_client:send(Client, "ACK", [{AckHeader, AckValue}]),
    #'basic.get_empty'{} =
        amqp_channel:call(Channel, #'basic.get'{queue = ?QUEUE}),
    ok.

send(Config) ->
    Channel = ?config(amqp_channel, Config),
    Client = ?config(stomp_client, Config),
    #'queue.declare_ok'{} =
        amqp_channel:call(Channel, #'queue.declare'{queue       = ?QUEUE,
                                                    auto_delete = true}),

    %% subscribe and wait for receipt
    rabbit_stomp_client:send(
      Client, "SUBSCRIBE", [{"destination", ?DESTINATION}, {"receipt", "foo"}]),
    {ok, Client1, _, _} = stomp_receive(Client, "RECEIPT"),

    %% send from stomp
    rabbit_stomp_client:send(
      Client1, "SEND", [{"destination", ?DESTINATION}], ["hello"]),

    {ok, _Client2, _, [<<"hello">>]} = stomp_receive(Client1, "MESSAGE"),
    ok.

delete_queue_subscribe(Config) ->
    Channel = ?config(amqp_channel, Config),
    Client = ?config(stomp_client, Config),
    #'queue.declare_ok'{} =
        amqp_channel:call(Channel, #'queue.declare'{queue       = ?QUEUE,
                                                    auto_delete = true}),

    %% subscribe and wait for receipt
    rabbit_stomp_client:send(
      Client, "SUBSCRIBE", [{"destination", ?DESTINATION}, {"receipt", "bah"}]),
    {ok, Client1, _, _} = stomp_receive(Client, "RECEIPT"),

    %% delete queue while subscribed
    #'queue.delete_ok'{} =
        amqp_channel:call(Channel, #'queue.delete'{queue = ?QUEUE}),

    {ok, _Client2, Headers, _} = stomp_receive(Client1, "ERROR"),

    ?DESTINATION = proplists:get_value("subscription", Headers),

    % server closes connection
    ok.

temp_destination_queue(Config) ->
    Channel = ?config(amqp_channel, Config),
    Client = ?config(stomp_client, Config),
    #'queue.declare_ok'{} =
        amqp_channel:call(Channel, #'queue.declare'{queue       = ?QUEUE,
                                                    auto_delete = true}),
    rabbit_stomp_client:send( Client, "SEND", [{"destination", ?DESTINATION},
                                               {"reply-to", "/temp-queue/foo"}],
                                              ["ping"]),
    amqp_channel:call(Channel,#'basic.consume'{queue  = ?QUEUE, no_ack = true}),
    receive #'basic.consume_ok'{consumer_tag = _Tag} -> ok end,
    ReplyTo = receive {#'basic.deliver'{delivery_tag = _DTag},
             #'amqp_msg'{payload = <<"ping">>,
                         props   = #'P_basic'{reply_to = RT}}} -> RT
    end,
    ok = amqp_channel:call(Channel,
                           #'basic.publish'{routing_key = ReplyTo},
                           #amqp_msg{payload = <<"pong">>}),
    {ok, _Client1, _, [<<"pong">>]} = stomp_receive(Client, "MESSAGE"),
    ok.

temp_destination_in_send(Config) ->
    Client = ?config(stomp_client, Config),
    rabbit_stomp_client:send( Client, "SEND", [{"destination", "/temp-queue/foo"}],
                                              ["poing"]),
    {ok, _Client1, Hdrs, _} = stomp_receive(Client, "ERROR"),
    "Invalid destination" = proplists:get_value("message", Hdrs),
    ok.

blank_destination_in_send(Config) ->
    Client = ?config(stomp_client, Config),
    rabbit_stomp_client:send( Client, "SEND", [{"destination", ""}],
                                              ["poing"]),
    {ok, _Client1, Hdrs, _} = stomp_receive(Client, "ERROR"),
    "Invalid destination" = proplists:get_value("message", Hdrs),
    ok.

stomp_receive(Client, Command) ->
    {#stomp_frame{command     = Command,
                  headers     = Hdrs,
                  body_iolist = Body},   Client1} =
    rabbit_stomp_client:recv(Client),
    {ok, Client1, Hdrs, Body}.

