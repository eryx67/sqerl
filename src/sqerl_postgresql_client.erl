%% -*- erlang-indent-level: 4;indent-tabs-mode: nil; fill-column: 92 -*-
%% ex: ts=4 sw=4 et
%% @author Mark Anderson <mark@opscode.com>
%% @copyright Copyright 2011 Opscode, Inc.
%% @end
%% @doc Abstraction around interacting with pgsql databases
-module(sqerl_postgresql_client).

-behaviour(sqerl_client).

-include_lib("epgsql/include/pgsql.hrl").
-include_lib("eunit/include/eunit.hrl").

%% API
-export([start_link/1]).

%% sqerl_client callbacks
-export([init/1,
         exec_prepared_statement/3,
         exec_prepared_select/3]).

-record(state, {cn,
                statements = dict:new() }).

start_link(Config) ->
    sqerl_client:start_link(?MODULE, Config).

exec_prepared_select(Name, Args, #state{cn=Cn}=State) ->
    ok = pgsql:bind(Cn, Name, Args),
    %% Note: we might get partial results here for big selects!
    case pgsql:execute(Cn, Name, Args) of
        {ok, _Count, RowData} ->
            Rows = unpack_rows(RowData),
            {{ok, Rows}, State};
        Result ->
            {{error, Result}, State}
    end.

exec_prepared_statement(Name, Args, #state{cn=Cn}=State) ->
    ok = pgsql:bind(Cn, Name, Args),
    %% Note: we might get partial results here for big selects!
    case pgsql:execute(Cn, Name, Args) of
        {ok, Count} -> 
            {{ok, Count}, State};
        Result ->
            {{error, Result}, State}
    end.

init(Config) ->
    {host, Host} = lists:keyfind(host, 1, Config),
    {port, Port} = lists:keyfind(port, 1, Config),
    {user, User} = lists:keyfind(user, 1, Config),
    {pass, Pass} = lists:keyfind(pass, 1, Config),
    {db, Db} = lists:keyfind(db, 1, Config),
    {prepared_statement_source, PreparedStatementFile} = lists:keyfind(prepared_statement_source, 1, Config),

    Opts = [{database, Db}, {port, Port}],
    case catch pgsql:connect(Host, User, Pass, Opts) of
        {error, timeout} ->
            {stop, timeout};
        {ok, Connection} ->
            %% Link to pid so if this process dies we clean up
            %% the socket
            erlang:link(Connection),
            erlang:process_flag(trap_exit, true),
            {ok, Statements} = file:consult(PreparedStatementFile),
            {ok, Prepared} = load_statements(Connection, Statements, []),
            {ok, #state{cn=Connection, statements=Prepared}}
    end.

%% Internal functions
load_statements(_Connection, [], Dict) ->
    {ok, Dict};
load_statements(Connection, [{Name, SQL}|T], Dict) ->
    case pgsql:parse(Connection, SQL) of
        {ok, Statement} ->
            load_statements(Connection, T, dict:store(Name, Statement, Dict));
        Error ->
            %% TODO: Discover what errors can flow out of this, and write tests.
            Error
    end.

%% Converts contents of result_packet into our "standard"
%% representation of a list of proplists. In other words,
%% each row is converted into a proplist and then collected
%% up into a list containing all the converted rows for
%% a given query result.
%% unpack_rows(#result_packet{field_list=Fields, rows=Rows}) ->
%%     unpack_rows(Fields, Rows, []).

%% unpack_rows(_Fields, [], []) ->
%%     none;
%% unpack_rows(_Fields, [], Accum) ->
%%     lists:reverse(Accum);
%% unpack_rows(Fields, [Values|T], Accum) ->
%%     F = fun(Field, {Idx, Row}) ->
%%                 {Idx + 1, [{Field#field.name, lists:nth(Idx, Values)}|Row]} end,
%%     {_, Row} = lists:foldl(F, {1, []}, Fields),
%%     unpack_rows(Fields, T, [lists:reverse(Row)|Accum]).

unpack_rows(X) ->
    ?debugVal(X),
    X.
