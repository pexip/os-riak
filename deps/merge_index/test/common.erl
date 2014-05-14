%% -------------------------------------------------------------------
%%
%% Copyright (c) 2007-2011 Basho Technologies, Inc.  All Rights Reserved.
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
%% -------------------------------------------------------------------

-module(common).
-compile(export_all).

-ifdef(EQC).

-include_lib("eqc/include/eqc.hrl").
-include_lib("eunit/include/eunit.hrl").
-include("common.hrl").

g_i() -> elements([<<"i1">>,<<"i2">>,<<"i3">>,non_empty(binary())]).

g_f() -> elements([<<"f1">>,<<"f2">>,<<"f3">>,non_empty(binary())]).

g_t() -> elements([<<"t1">>,<<"t2">>,<<"t3">>,non_empty(binary())]).

g_ift() ->
    {g_i(), g_f(), g_t()}.

g_ift_range(IFTs) ->
    ?SUCHTHAT({{I1, F1, _T1}=Start, {I2, F2, _T2}=End},
              {oneof(IFTs), oneof(IFTs)},
              (End >= Start) andalso (I1 =:= I2) andalso (F1 =:= F2)).

g_value() -> elements([<<"v1">>,<<"v2">>,<<"v3">>,non_empty(binary())]).

g_props() ->
    elements([[{p, 1}], [{p, 2}],list({p, choose(0, ?POW_2(31))})]).

%% Generate inverted tstamps to match mi_server
g_tstamp() ->
    choose(-?POW_2(31), 0).

fold_iterator(Itr, Fn, Acc0) ->
    fold_iterator_inner(Itr(), Fn, Acc0).

fold_iterator_inner(eof, _Fn, Acc) ->
    lists:reverse(Acc);
fold_iterator_inner({Term, NextItr}, Fn, Acc0) ->
    Acc = Fn(Term, Acc0),
    fold_iterator_inner(NextItr(), Fn, Acc).

fold_iterators([], _Fun, Acc) ->
    lists:reverse(Acc);
fold_iterators([Itr|Itrs], Fun, Acc0) ->
    Acc = fold_iterator(Itr, Fun, Acc0),
    fold_iterators(Itrs, Fun, Acc).

%% Remember, tstamps are inverted by mi_server.
unique_latest({{Index, Field, Term}, Value, Tstamp, Props}, Acc) ->
    Key = {Index, Field, Term, Value},
    case orddict:find(Key, Acc) of
        {ok, {ExistingTstamp, _}} when Tstamp < ExistingTstamp ->
            orddict:store(Key, {Tstamp, Props}, Acc);
        error ->
            orddict:store(Key, {Tstamp, Props}, Acc);
        _ ->
            Acc
    end.

test_spec(Root, PropertyFn) ->
    test_spec(Root, PropertyFn, 250).

test_spec(Root, F, Runs) ->
    {timeout, 30,
     fun() ->
             application:load(merge_index),
             os:cmd(?FMT("rm -rf ~s; mkdir -p ~s", [Root, Root])),
             R = eqc:quickcheck(
                   eqc:numtests(Runs, ?QC_OUT(F(Root ++ "/t1")))),
             %% I know this looks weird but it's so that you know
             %% which `F` failed.
             {name, Name} = erlang:fun_info(F, name),
             ?assertEqual({Name, true}, {Name, R})
     end}.

-endif.
