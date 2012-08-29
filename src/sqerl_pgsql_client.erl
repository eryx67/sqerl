%% -*- erlang-indent-level: 4;indent-tabs-mode: nil; fill-column: 92 -*-
%% ex: ts=4 sw=4 et
%% @author Mark Anderson <mark@opscode.com>
%% @doc Abstraction around interacting with pgsql databases
%% Copyright 2011-2012 Opscode, Inc. All Rights Reserved.
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

-module(sqerl_pgsql_client).

-behaviour(sqerl_client).

-include_lib("eunit/include/eunit.hrl").
-include_lib("epgsql/include/pgsql.hrl").

%% sqerl_client callbacks
-export([init/1,
         execute/3,
         exec_prepared_statement/3,
         exec_prepared_select/3,
         is_connected/1,
         sql_parameter_style/0]).

-record(state,  {cn,
                 statements = dict:new() :: dict(),
                 ctrans :: dict() | undefined }).

-record(prepared_statement,
        {name :: string(),
         input_types  :: any(),
         output_fields :: any(),
         stmt :: any() } ).

-type connection() :: pid().
-type state() :: any().

-define(PING_QUERY, <<"SELECT 'pong' as ping LIMIT 1">>).

%% Simple query execution
execute(Query, [], #state{cn=Cn}=State) when is_list(Query) ->
    Result = pgsql:squery(Cn, Query),
    case Result of
        {ok, Columns, Rows} ->
            {{ok, format_result(Columns, Rows)}, State};
        {ok, Count} ->
            {{ok, Count}, State};
        {ok, Count, Columns, Rows} ->
            {{ok, Count, format_result(Columns, Rows)}, State};
        {error, Error} ->
            {{error, Error}, State};
        X ->
            {{error, X}, State}
    end;

%% Statement execution
execute(StatementName, Parameters, State) when is_atom(StatementName) ->
    %% Use existing function for prepared statements
    exec_prepared_select(StatementName, Parameters, State).

%% See sqerl_sql:sql_parameter_strings
sql_parameter_style() -> dollarn.


-spec exec_prepared_select(atom(), [], state()) -> {{ok, [[tuple()]]} | {error, any()}, state()}.
exec_prepared_select(Name, Args, #state{cn=Cn, statements=Statements, ctrans=CTrans}=State) ->
    PrepStmt = dict:fetch(Name, Statements),
    Stmt = PrepStmt#prepared_statement.stmt,
    NArgs = input_transforms(Args, PrepStmt, State),
    ok = pgsql:bind(Cn, Stmt, NArgs),
    %% Note: we might get partial results here for big selects!
    Result = pgsql:execute(Cn, Stmt),
    case Result of
        {ok, RowData} ->
            Rows = unpack_rows(PrepStmt, RowData),
            TRows = sqerl_transformers:by_column_name(Rows, CTrans),
            {{ok, TRows}, State};
        Result ->
            {{error, Result}, State}
    end.

-spec exec_prepared_statement(atom(), [], any()) -> {{ok, integer()} | {error, any()}, state()}.
exec_prepared_statement(Name, Args, #state{cn=Cn, statements=Statements}=State) ->
    PrepStmt = dict:fetch(Name, Statements),
    Stmt = PrepStmt#prepared_statement.stmt,
    NArgs = input_transforms(Args, PrepStmt, State),
    ok = pgsql:bind(Cn, Stmt, NArgs),
    %% Note: we might get partial results here for big selects!
    Rv =
        try
            case pgsql:execute(Cn, Stmt) of
                {ok, Count} ->
                    commit(Cn, Count, State);
                Result ->
                    rollback(Cn, {error, Result}, State)
            end
        catch
            _:X ->
                rollback(Cn, {error, X}, State)
        end,
    Rv.

is_connected(#state{cn=Cn}=State) ->
    case catch pgsql:squery(Cn, ?PING_QUERY) of
        {ok, _, _} ->
            {true, State};
        _ ->
            false
    end.

init(Config) ->
    {host, Host} = lists:keyfind(host, 1, Config),
    {port, Port} = lists:keyfind(port, 1, Config),
    {user, User} = lists:keyfind(user, 1, Config),
    {pass, Pass} = lists:keyfind(pass, 1, Config),
    {db, Db} = lists:keyfind(db, 1, Config),
    {prepared_statements, Statements} = lists:keyfind(prepared_statements, 1, Config),
    Opts = [{database, Db}, {port, Port}],
    CTrans =
        case lists:keyfind(column_transforms, 1, Config) of
            {column_transforms, CT} -> CT;
            false -> undefined
        end,
    case pgsql:connect(Host, User, Pass, Opts) of
        {error, timeout} ->
            {stop, timeout};
        {ok, Connection} ->
            %% Link to pid so if this process dies we clean up
            %% the socket
            erlang:link(Connection),
            erlang:process_flag(trap_exit, true),
            {ok, Prepared} = load_statements(Connection, Statements, dict:new()),
            {ok, #state{cn=Connection, statements=Prepared, ctrans=CTrans}};
        {error, {syntax, Msg}} ->
            {stop, {syntax, Msg}};
        X ->
            error_logger:error_report(X),
            {stop, X}
    end.

%% Internal functions

-spec load_statements(connection(), [tuple()], dict()) -> {ok, dict()} |  {error, any()}.
load_statements(_Connection, [], Dict) ->
    {ok, Dict};
load_statements(Connection, [{Name, SQL}|T], Dict) when is_atom(Name) ->
    case prepare_statement(Connection, Name, SQL) of
        {ok, {Name, P}} ->
            load_statements(Connection, T, dict:store(Name, P, Dict));
        {error, {error, error, _ErrorCode, Msg, Position}} ->
            {error, {syntax, {Msg, Position}}};
        Error ->
            %% TODO: Discover what errors can flow out of this, and write tests.
            {error, Error}
    end.

prepare_statement(Connection, Name, SQL) when is_atom(Name) ->
    case pgsql:parse(Connection, atom_to_list(Name), SQL, []) of
        {ok, Statement} ->
            {ok, {statement, SName, Desc, DataTypes}} = pgsql:describe(Connection, Statement),
            ColumnData = [ {CN, CT} || {column, CN, CT, _, _, _} <- Desc ],
            P = #prepared_statement{
              name = SName,
              input_types = DataTypes,
              output_fields = ColumnData,
              stmt = Statement},
            {ok, {Name, P}};
        {error, {error, error, _ErrorCode, Msg, Position}} ->
            {error, {syntax, {Msg, Position}}};
        Error ->
            %% TODO: Discover what errors can flow out of this, and write tests.
            {error, Error}
    end.


%%%
%%% Data format conversion
%%%
format_result(Columns, Rows) ->
    %% Results from simple queries return Columns, Rows
    %% Columns are records
    %% Rows are tuples
    %%?debugFmt("format_result(~p, ~p)~n", [Columns, Rows]),
    Names = extract_column_names({result_column_data, Columns}),
    unpack_rows({names, Names}, Rows).

format_result_test() ->
    Columns = [{column,<<"id">>,int4,4,-1,0},
               {column,<<"first_name">>,varchar,-1,84,0}],
    Rows = [{<<"1">>,<<"Kevin">>},
            {<<"2">>,<<"Mark">>}],
    Output = format_result(Columns, Rows),
    ExpectedOutput = [[{<<"id">>,<<"1">>},
                       {<<"first_name">>,<<"Kevin">>}],
                      [{<<"id">>,<<"2">>},
                       {<<"first_name">>,<<"Mark">>}]],
    ?assertEqual(ExpectedOutput, Output).

%% Converts contents of result_packet into our "standard"
%% representation of a list of proplists. In other words,
%% each row is converted into a proplist and then collected
%% up into a list containing all the converted rows for
%% a given query result., 
%% Result packet can be from a prepared statement execution
%% (column data is embedded in prepared statement record),
%% or from a simple query
-spec unpack_rows(any(), [[any()]]) -> [[{any(), any()}]].
unpack_rows(#prepared_statement{output_fields=ColumnData}, Rows) ->
    %% Takes in a prepared statement record that
    %% holds column data that holds column names
    Columns = extract_column_names({prepared_column_data, ColumnData}),
    unpack_rows({names, Columns}, Rows);
unpack_rows({names, ColumnNames}, Rows) ->
    %% Takes in a list of colum names
    [lists:zip(ColumnNames, tuple_to_list(Row)) || Row <- Rows].

extract_column_names({result_column_data, Columns}) ->
    %% For column data coming from a query result
    [Name || {column, Name, _Type, _Size, _Modifier, _Format} <- Columns];
extract_column_names({prepared_column_data, ColumnData}) ->
    %% For column data coming from a prepared statement
    [Name || {Name, _Type} <- ColumnData].

extract_column_names_test() ->
    Type = result_column_data,
    Columns = [{column,<<"id">>,int4,4,-1,0},
               {column,<<"first_name">>,varchar,-1,84,0}],
    ExpectedOutput = [<<"id">>, <<"first_name">>],
    Output = extract_column_names({Type, Columns}),
    ?assertEqual(ExpectedOutput, Output).

%%%
%%% Simple hooks to support coercion inputs to match the type expected by pgsql
%%%
transform(timestamp, {datetime, X}) ->
    X;
transform(timestamp, X) when is_binary(X) ->
    sqerl_transformers:parse_timestamp_to_datetime(X);
transform(_Type, X) ->
    X.

input_transforms(Data, #prepared_statement{input_types=Types}, _State) ->
    [ transform(T, E) || {T,E} <- lists:zip(Types, Data) ].

commit(Cn, Result, State) ->
    case pgsql:squery(Cn, "COMMIT") of
        {ok, [], []} ->
            {{ok, Result}, State};
        Error when is_tuple(Error) ->
            {Error, State}
    end.

rollback(Cn, Error, State) ->
    case pgsql:squery(Cn, "ROLLBACK") of
        {ok, [], []} ->
            {Error, State};
        _Err ->
            {Error, State}
    end.
