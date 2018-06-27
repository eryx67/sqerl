%% @doc Module fetching sqerl configuration from application environment using
%%      envy.
%% Copyright 2017 CHEF Software, Inc. All Rights Reserved.
%%
%% This file is provided to you under the Apache License,
%% Version 2.0 (the "License"); you may not use this file
%% except in compliance with the License.  You may obtain
%% a copy of the License at
%%
%%   http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing,
%% software distributed under the License is distributed on an
%% "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
%% KIND, either express or implied.  See the License for the
%% specific language governing permissions and limitations
%% under the License.
%%

-module(sqerl_config_env).

-export([config/0]).

%% utility exports
-export([read_statements_from_config/0]).

-spec config() -> [{atom(), term()}].
config() ->
    IdleCheck = envy:get(sqerl, idle_check, 1000, non_neg_integer),

    Statements = read_statements_from_config(),

    %% The ip_mode key in the sqerl clause determines if we parse db_host as IPv4 or IPv6
    [{host, envy_parse:host_to_ip(sqerl, db_host)},
     {port, envy:get(sqerl, db_port, pos_integer)},
     {user, envy:get(sqerl, db_user, string)},
     {pass, envy:get(sqerl, db_pass, string)},
     {db, envy:get(sqerl, db_name, string)},
     {extra_options, envy:get(sqerl, db_options, [], list)},
     {timeout, envy:get(sqerl,db_timeout, 5000, pos_integer)},
     {idle_check, IdleCheck},
     {prepared_statements, Statements},
     {column_transforms, envy:get(sqerl, column_transforms, list)}].

%% @doc Prepared statements can be provides as a list of `{atom(), binary()}' tuples, as a
%% path to a file that can be consulted for such tuples, or as `{M, F, A}' such that
%% `apply(M, F, A)' returns the statements tuples.
-spec read_statements([{atom(), term()}]
                      | string()
                      | {atom(), atom(), list()})
                     -> [{atom(), binary()}].
read_statements({Mod, Fun, Args}) ->
    apply(Mod, Fun, Args);
read_statements(L = [{Label, SQL}|_T]) when is_atom(Label) andalso is_binary(SQL) ->
    L;
read_statements(Path) when is_list(Path) ->
    {ok, Statements} = file:consult(Path),
    Statements.

-ifdef(no_stacktrace).
read_statements_from_config() ->
    StatementSource = envy:get(sqerl, prepared_statements, any),
    try
        read_statements(StatementSource)
    catch
        error:Reason:Trace ->
            Msg = {incorrect_application_config, sqerl, {prepared_statements, Reason, Trace}},
            error_logger:error_report(Msg),
            error(Msg)
    end.
-else.
read_statements_from_config() ->
    StatementSource = envy:get(sqerl, prepared_statements, any),
    try
        read_statements(StatementSource)
    catch
        error:Reason ->
            Msg = {incorrect_application_config, sqerl, {prepared_statements, Reason, erlang:get_stacktrace()}},
            error_logger:error_report(Msg),
            error(Msg)
    end.
-endif.

