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

-module(mi_segment_tests).
-import(common, [g_i/0, g_f/0, g_t/0, g_ift/0, g_ift_range/1, g_value/0,
                 g_props/0, g_tstamp/0, fold_iterator/3, fold_iterators/3,
                 test_spec/2]).

-include("merge_index.hrl").
-ifdef(EQC).
-include_lib("eqc/include/eqc.hrl").
-endif.
-include_lib("eunit/include/eunit.hrl").

fake_seg(Size, MTime) ->
    #segment{root=ignore, offsets_table=ignore, mtime=MTime, size=Size}.

compact_by_average_and_staleness_test() ->
    application:load(merge_index),
    DT2GS = fun(DateTime) -> calendar:datetime_to_gregorian_seconds(DateTime) end,
    GS2DT = fun(GS) -> calendar:gregorian_seconds_to_datetime(GS) end,
    LocalTimeS = DT2GS(calendar:local_time()),
    %% 30 mins ago
    MinsAgoS = LocalTimeS - (30 * 60),
    SegMinsAgo = fake_seg(4096, GS2DT(MinsAgoS)),
    %% 3 hours ago
    HoursAgoS = LocalTimeS - (3 * 3600),
    SegHoursAgo = fake_seg(4096, GS2DT(HoursAgoS)),

    Seg1 = fake_seg(512, GS2DT(LocalTimeS)),
    Seg2 = fake_seg(512, GS2DT(LocalTimeS)),
    Seg3 = fake_seg(512, GS2DT(LocalTimeS)),

    Segs = [Seg1, Seg2, Seg3, SegMinsAgo, SegHoursAgo],

    %% Verify that undefined threshold results in 1 hour
    ?assertEqual(lists:sort([Seg1, Seg2, Seg3, SegHoursAgo]),
                 lists:sort(mi_segment:compact_by_average_and_staleness(Segs))),

    %% Verify 30 mins
    application:set_env(merge_index, compact_staleness_threshold, {30, minutes}),
    ?assertEqual(lists:sort([Seg1, Seg2, Seg3, SegMinsAgo, SegHoursAgo]),
                 lists:sort(mi_segment:compact_by_average_and_staleness(Segs))),

    %% Verify threshold over 3 hours
    application:set_env(merge_index, compact_staleness_threshold, {10, hours}),
    ?assertEqual(lists:sort([Seg1, Seg2, Seg3]),
                 lists:sort(mi_segment:compact_by_average_and_staleness(Segs))),
    application:unload(merge_index).


-ifdef(EQC).
-compile(export_all).
-include("common.hrl").

get_count(Entries) ->
    fun ({{I1, F1, T1}, _, _, _}) ->
            Fun = fun({I2, F2, T2, _, _, _}) ->
                          (I1 =:= I2) and (F1 =:= F2) and (T1 =:= T2)
                  end,
            length(lists:filter(Fun, Entries))
    end.

use_info(Segment) ->
    fun ({{I, F, T}, _, _, _}) ->
            mi_segment:info(I, F, T, Segment)
    end.

prop_basic_test(Root) ->
    ?FORALL({Entries, Size, VCT, VSS, BS, FBS},
            {list({g_ift(), g_value(), g_tstamp(), g_props()}),
             choose(64,1024),
             choose(0,24),
             choose(1,24),
             choose(64, 4096),
             choose(64, 4096)},
            begin
                application:set_env(merge_index, segment_full_read_size, Size),
                application:set_env(merge_index, segment_values_compression_threshold, VCT),
                application:set_env(merge_index, segment_values_staging_size, VSS),
                application:set_env(merge_index, segment_block_size, BS),
                application:set_env(merge_index, segment_file_buffer_size, FBS),
                SegName = Root ++ "_segment",

                L1 = [{Index, Field, Term, Value, Tstamp, Props} ||
                         {{Index, Field, Term, Value}, {Tstamp, Props}}
                             <- lists:foldl(fun common:unique_latest/2,
                                            [], lists:sort(Entries))],

                Buffer = mi_buffer:write(Entries, mi_buffer:new(Root ++ "_buffer")),
                mi_segment:from_buffer(Buffer, mi_segment:open_write(SegName)),
                Segment = mi_segment:open_read(SegName),

                %% Fold over the entire segment
                SL = fold_iterator(mi_segment:iterator(Segment),
                                   fun(Item, Acc0) -> [Item | Acc0] end, []),

                Three = lists:sublist(Entries, 3),
                C1 = lists:map(get_count(L1), Three),
                C2 = lists:map(use_info(Segment), Three),

                mi_buffer:delete(Buffer),
                mi_segment:delete(Segment),
                Exists = mi_segment:exists(Segment),
                Name = mi_segment:filename(Segment),
                conjunction([{filename, equals(Name, SegName)},
                             {exists, equals(false, Exists)},
                             {entires, equals(L1, SL)},
                             {info, equals(true, C2 >= C1)}])
            end).

prop_iter_range_test(Root) ->
    ?LET({I, F}, {g_i(), g_f()},
    ?LET(IFTs, non_empty(list(frequency([{10, {I, F, g_t()}}, {1, g_ift()}]))),
    ?FORALL({Entries, Range},
            {list({oneof(IFTs), g_value(), g_tstamp(), g_props()}),
             g_ift_range(IFTs)},
            check_range(Root, Entries, Range)))).

check_range(Root, Entries, Range) ->
    Buffer = mi_buffer:write(Entries, mi_buffer:new(Root ++ "_buffer")),
    mi_segment:from_iterator(mi_buffer:iterator(Buffer),
                             mi_segment:open_write(Root ++ "_segment")),
    Segment = mi_segment:open_read(Root ++ "_segment"),

    {Start, End} = Range,
    {Index, Field, StartTerm} = Start,
    {Index, Field, EndTerm} = End,
    Itrs = mi_segment:iterators(Index, Field, StartTerm, EndTerm, all, Segment),
    L1 = fold_iterators(Itrs, fun(Item, Acc0) -> [Item | Acc0] end, []),

    L2 = [{V, K, P}
          || {Ii, Ff, Tt, V, K, P} <- fold_iterator(mi_segment:iterator(Segment),
                                                    fun(I,A) -> [I|A] end, []),
             {Ii, Ff, Tt} >= Start, {Ii, Ff, Tt} =< End],
    mi_buffer:delete(Buffer),
    mi_segment:delete(Segment),
    equals(lists:sort(L1), lists:sort(L2)).

prop_iter_test(Root) ->
    ?LET(IFT, {g_i(), g_f(), g_t()},
    ?LET(IFTs, non_empty(list(frequency([{10, IFT}, {1, g_ift()}]))),
    ?FORALL(Entries,
            list({oneof(IFTs), g_value(), g_tstamp(), g_props()}),
            check_iter(Root, Entries, IFT)))).

check_iter(Root, Entries, IFT) ->
    {I, F, T} = IFT,

    L1 = [{Value, Tstamp, Props} ||
             {{Index, Field, Term, Value}, {Tstamp, Props}}
                 <- lists:foldl(fun common:unique_latest/2,
                                [], lists:sort(Entries)),
             Index =:= I, Field =:= F, Term =:= T],
    Buffer = mi_buffer:write(Entries, mi_buffer:new(Root ++ "_buffer")),
    mi_segment:from_buffer(Buffer, mi_segment:open_write(Root ++ "_segment")),
    Segment = mi_segment:open_read(Root ++ "_segment"),

    Itr = mi_segment:iterator(I, F, T, Segment),
    L2 = fold_iterator(Itr, fun(X, Acc) -> [X|Acc] end, []),

    mi_segment:delete(Segment),
    mi_buffer:delete(Buffer),
    equals(L1, L2).

prop_basic_test_() ->
    test_spec("/tmp/test/mi_segment_basic", fun prop_basic_test/1).

prop_iter_range_test_() ->
    test_spec("/tmp/test/mi_segment_iter_range", fun prop_iter_range_test/1).

prop_iter_test_() ->
    test_spec("/tmp/test/mi_segment_iter", fun prop_iter_test/1).

-endif.
