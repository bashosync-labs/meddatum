%%
%% Copyright (C) 2013-2014 UENISHI Kota
%%
%%    Licensed under the Apache License, Version 2.0 (the "License");
%%    you may not use this file except in compliance with the License.
%%    You may obtain a copy of the License at
%%
%%        http://www.apache.org/licenses/LICENSE-2.0
%%
%%    Unless required by applicable law or agreed to in writing, software
%%    distributed under the License is distributed on an "AS IS" BASIS,
%%    WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%%    See the License for the specific language governing permissions and
%%    limitations under the License.
%%

-module(hl7).

-behaviour(md_record).

-export([from_file/2, from_file/3,
         to_json/1, from_json/1,
         key/1, bucket/1, patient_id/1, hospital_id/1]).

-export([annotate/1,
         get_segment/2, update_hospital_id/2,
         msg_type/1]).

-include_lib("eunit/include/eunit.hrl").
-include("hl7.hrl").
-include("meddatum.hrl").

bucket(#hl7msg{msg_type_s=MsgType, hospital_id=HospitalID}) ->
    IsStaticRecord =
        case MsgType of
            <<"ADT^A08", _/binary>> -> true; %% 患者基本情報の更新
            <<"ADT^A23", _/binary>> -> true; %% 患者基本情報の削除
            <<"ADT^A54", _/binary>> -> true; %% 担当医の変更
            <<"ADT^A55", _/binary>> -> true; %% 担当医の取消
            <<"ADT^A60", _/binary>> -> true; %% アレルギー情報の登録／更新
            <<"PPR^ZD1", _/binary>> -> true; %% 病名(歴)情報の登録／更新
            _B when is_binary(_B) -> false
        end,
    Bucket0 = case IsStaticRecord of
                  true -> ?SSMIX_PATIENTS_BUCKET;
                  false -> ?SSMIX_BUCKET
              end,
    Bucket1 = <<Bucket0/binary, ?BUCKET_NAME_SEPARATOR/binary, HospitalID/binary>>,
    case meddatum_config:use_bucket_types() of
        true -> {?BUCKET_TYPE, Bucket1};
        false -> Bucket0
    end.

key(#hl7msg{file=File}) ->
    filename:basename(File).

patient_id(#hl7msg{patient_id=PatientID}) -> PatientID.

-spec annotate(#hl7msg{}) -> #hl7msg{}.
annotate(HL70 = #hl7msg{segments=Segs,
                        hospital_id=HospitalID0}) ->
    {PatientID, HospitalID} =
        extract(Segs, {undefined, HospitalID0}),

    HL70#hl7msg{patient_id=PatientID, hospital_id=HospitalID}.

hospital_id(#hl7msg{hospital_id=HospitalID}) ->
    HospitalID.

update_hospital_id(HL7 = #hl7msg{}, HospitalID) ->
    HL7#hl7msg{hospital_id=HospitalID}.

extract([], Tuple) -> Tuple;
extract([Seg|Segs], {P0, H0}) ->
    case Seg of
        [{<<"segid">>, <<"PID">>}|Rest] ->
            case proplists:get_value(<<"idlist">>, Rest) of
                undefined ->
                    extract(Segs, {P0, H0});
                IDList ->
                    ID = proplists:get_value(id, IDList),
                    {ID, H0}
            end;
        _ ->
            extract(Segs, {P0, H0})
    end.

get_segment(#hl7msg{segments = Segments}, SegName) ->
    lists:foldl(fun({Segment}, Acc0) ->
                        case proplists:get_value(<<"segid">>, Segment) of
                            SegName -> {ok, Segment};
                            _ -> Acc0
                        end
                end, {error, not_found}, Segments).

msg_type(#hl7msg{msg_type_s=MsgType}) when is_binary(MsgType) ->
    binary_to_list(MsgType);
msg_type(#hl7msg{msg_type_s=MsgType}) -> MsgType.

-spec from_file(filename:filename(), file:file_info()) -> ok | {error, any()}.
from_file(Filename, Info)->
    hl7_parser:parse(Filename, Info).

from_file(Filename, Info, PostProcessor)->
    hl7_parser:parse(Filename, Info, PostProcessor).

decoder() ->
    jsonx:decoder([{hl7msg, record_info(fields, hl7msg)}],
                  [{ignore, [null]}]).

encoder() ->
    jsonx:encoder([{hl7msg, record_info(fields, hl7msg)}],
                  [{ignore, [null]}]).

from_json(Json) when is_binary(Json) ->
    D = decoder(),
    D(Json).

to_json(#hl7msg{segments=_Segs} = HL7Msg) ->
    E = encoder(),
    case E(HL7Msg) of
        Bin when is_binary(Bin) -> Bin;
        Other -> error(Other)
    end.
