-module(obj_user).

-export([
         '#insert_fields'/0,
         '#update_fields'/0,
         '#statements'/0,
         '#table_name'/0
        ]).

-compile({parse_transform, sqerl_gobot}).

-record(obj_user, {id, first_name, last_name, high_score, active}).

'#insert_fields'() ->
    [name].

'#update_fields'() ->
    [name].

'#table_name'() -> "users".

'#statements'() -> [
    {new_user,
        <<"INSERT INTO users (first_name, last_name, high_score, created, active) VALUES ($1, $2, $3, $4, $5)">>},

    {new_user_returning,
        <<"INSERT INTO users (first_name, last_name, high_score, created, active)"
          " VALUES ($1, $2, $3, $4, $5) "
          "RETURNING id, first_name, last_name, high_score, created, active">>},

    {find_user_by_lname,
         <<"SELECT id, first_name, last_name, high_score, active from users where last_name = $1">>},

    {delete_user_by_id,
         <<"DELETE FROM users WHERE id = $1">>},

    {delete_user_by_lname,
         <<"DELETE FROM users where last_name = $1">>},

    {find_score_by_lname,
         <<"SELECT high_score FROM users WHERE last_name = $1">>},

    {update_created_by_lname,
         <<"UPDATE users SET created = $1 WHERE last_name = $2">>},

    {find_created_by_lname,
         <<"SELECT created FROM users WHERE last_name = $1">>},

    {find_lname_by_created,
         <<"SELECT last_name FROM users WHERE created = $1">>},

    {update_datablob_by_lname,
         <<"UPDATE users SET datablob = $1 WHERE last_name = $2">>},

    {find_datablob_by_lname,
         <<"SELECT datablob FROM users WHERE last_name = $1">>},

    {new_users,
         <<"SELECT insert_users($1, $2, $3, $4, $5)">>},

    {new_id,
         <<"INSERT INTO uuids (id) VALUES($1)">>},

    {new_ids,
         <<"SELECT insert_ids($1)">>},

    {select_sleep,
        <<"select pg_sleep(30)">>}

    ].