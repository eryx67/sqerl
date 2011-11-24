%% -*- erlang-indent-level: 4;indent-tabs-mode: nil;fill-column: 92 -*-
%% ex: ts=4 sw=4 et
%% @author Kevin Smith <kevin@opscode.com>
%% @copyright 2011 Opscode, Inc.
-module(sqerl_sup).

-behaviour(supervisor).

-include_lib("eunit/include/eunit.hrl").

%% API
-export([start_link/0,
         new_connection/5]).

%% Supervisor callbacks
-export([init/1]).

-define(SERVER, ?MODULE).

new_connection(Host, Port, User, Pass, Database) ->
    supervisor:start_child(?SERVER, [Host, Port, User, Pass, Database]).

start_link() ->
    supervisor:start_link({local, ?SERVER}, ?MODULE, []).

init([]) ->
    {ok, Host} = application:get_env(sqerl, db_host),
    {ok, Port} = application:get_env(sqerl, db_port),
    {ok, User} = application:get_env(sqerl, db_user),
    {ok, Pass} = application:get_env(sqerl, db_pass),
    {ok, Db} = application:get_env(sqerl, db_name),
    {ok, MaxPool} = application:get_env(sqerl, db_pool_size),
    {ok, Type} = application:get_env(sqerl, db_type),
    {ok, PreparedStatement} = application:get_env(sqerl, db_prepared_statements),
    CTransforms =
        case application:get_env(sqerl, db_column_transforms) of
            {ok, CT} -> CT;
            _ -> undefined
        end,
    ClientMod = db_client_mod(Type),
    PoolConfig = [{name, {local, sqerl}},
                  {worker_module, ClientMod},
                  {size, MaxPool}, {max_overflow, MaxPool},
                  {host, Host}, {port, Port}, {user, User},
                  {pass, Pass}, {db, Db},
                  {prepared_statement_source, PreparedStatement},
                  {column_transforms, CTransforms}
                 ],
    error_logger:info_msg("sqerl starting ~p connections to ~s(~p) database running on ~s:~p~n",
                          [MaxPool, Db, Type, Host, Port]),
    {ok, {{one_for_one, 5, 10},[{sqerl_pool, {poolboy, start_link, [PoolConfig]},
                                  permanent, 5000, worker, [poolboy]}]}}.

db_client_mod(mysql) ->
    sqerl_mysql_client;
db_client_mod(pgsql) ->
    sqerl_pgsql_client.
