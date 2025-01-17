%%--------------------------------------------------------------------
%% Copyright (c) 2021 EMQ Technologies Co., Ltd. All Rights Reserved.
%%
%% Licensed under the Apache License, Version 2.0 (the "License");
%% you may not use this file except in compliance with the License.
%% You may obtain a copy of the License at
%%
%%     http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing, software
%% distributed under the License is distributed on an "AS IS" BASIS,
%% WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%% See the License for the specific language governing permissions and
%% limitations under the License.
%%--------------------------------------------------------------------

-module(hocon_schema).

-elvis([{elvis_style, god_modules, disable}]).

%% behaviour APIs
-export([ roots/1
        , fields/2
        , fields_and_meta/2
        , translations/1
        , translation/2
        , validations/1
        ]).

%% data validation and transformation
-export([map/2, map/3, map/4]).
-export([translate/3]).
-export([generate/2, generate/3, map_translate/3]).
-export([check/2, check/3, check_plain/2, check_plain/3, check_plain/4]).
-export([merge_env_overrides/4]).
-export([richmap_to_map/1, get_value/2, get_value/3]).

%% schema access
-export([namespace/1, resolve_struct_name/2, root_names/1]).
-export([field_schema/2, override/2]).

-export([find_structs/1]). %% internal use

-include("hoconsc.hrl").
-include("hocon_private.hrl").

-ifdef(TEST).
-export([deep_get/2, deep_put/4]).
-export([nest/1]).
-endif.

-export_type([ field_schema/0
             , name/0
             , opts/0
             , schema/0
             , typefunc/0
             , translationfunc/0
             ]).

-type name() :: atom() | string() | binary().
-type type() :: typerefl:type() %% primitive (or complex, but terminal) type
              | name() %% reference to another struct
              | ?ARRAY(type()) %% array of
              | ?UNION([type()]) %% one-of
              | ?ENUM([atom()]) %% one-of atoms, data is allowed to be binary()
              .

-type typefunc() :: fun((_) -> _).
-type translationfunc() :: fun((hocon:config()) -> hocon:config()).
-type validationfun() :: fun((hocon:config()) -> ok | boolean() | {error, term()}).
-type field_schema() :: typerefl:type()
                      | ?UNION([type()])
                      | ?ARRAY(type())
                      | ?ENUM(type())
                      | field_schema_map()
                      | field_schema_fun().
-type field_schema_fun() :: fun((_) -> _).
-type field_schema_map() ::
        #{ type := type()
         , default => term()
         , mapping => undefined | string()
         , converter => undefined | translationfunc()
         , validator => undefined | validationfun()
           %% set true if a field is allowed to be `undefined`
           %% NOTE: has no point setting it to `true` if field has a default value
         , nullable => true | false | {true, recursively} % default = true
           %% for sensitive data obfuscation (password, token)
         , sensitive => boolean()
         , desc => iodata()
         , hidden => boolean() %% hide it from doc generation
         }.

-type field() :: {name(), typefunc() | field_schema()}.
-type fields() :: [field()] | #{fields := [field()],
                                desc => iodata()
                               }.
-type translation() :: {name(), translationfunc()}.
-type validation() :: {name(), validationfun()}.
-type root_type() :: name() | field().
-type schema() :: module()
                | #{ roots := [root_type()]
                   , fields := #{name() => fields()} | fun((name()) -> fields())
                   , translations => #{name() => [translation()]} %% for config mappings
                   , validations => [validation()] %% for config integrity checks
                   , namespace => atom()
                   }.

-define(FROM_ENV_VAR(Name, Value), {'$FROM_ENV_VAR', Name, Value}).
-define(IS_NON_EMPTY_STRING(X), (is_list(X) andalso X =/= [] andalso is_integer(hd(X)))).
-type loggerfunc() :: fun((atom(), map()) -> ok).
%% Config map/check options.
-type opts() :: #{ logger => loggerfunc()
                   %% only_fill_defaults is to only to fill default values for the input
                   %% config to be checked, only primitive value type check (validation)
                   %% but not complex value validation and mapping
                 , only_fill_defaults => boolean()
                 , atom_key => boolean()
                 , return_plain => boolean()
                   %% apply environment variable overrides when
                   %% apply_override_envs is set to true and also
                   %% HOCON_ENV_OVERRIDE_PREFIX is set.
                   %% default is true.
                 , apply_override_envs => boolean()
                   %% By default allow all fields to be undefined.
                   %% if `nullable` is set to `false`
                   %% map or check APIs fail with validation_error.
                   %% NOTE: this option serves as default value for field's `nullable` spec
                 , nullable => boolean() %% default: true for map, false for check

                 %% below options are generated internally and should not be passed in by callers
                 , format => map | richmap
                 , stack => [name()]
                 , schema => schema()
                 , check_lazy => boolean()
                 }.

-callback namespace() -> name().
-callback roots() -> [root_type()].
-callback fields(name()) -> fields().
-callback translations() -> [name()].
-callback translation(name()) -> [translation()].
-callback validations() -> [validation()].

-optional_callbacks([ namespace/0
                    , roots/0
                    , fields/1
                    , translations/0
                    , translation/1
                    , validations/0
                    ]).

-define(ERR(Code, Context), {Code, Context}).
-define(ERRS(Code, Context), [?ERR(Code, Context)]).
-define(VALIDATION_ERRS(Context), ?ERRS(validation_error, Context)).
-define(TRANSLATION_ERRS(Context), ?ERRS(translation_error, Context)).

-define(DEFAULT_NULLABLE, true).

-define(EMPTY_MAP, #{}).
-define(META_BOX(Tag, Metadata), #{?METADATA => #{Tag => Metadata}}).
-define(NULL_BOX, #{?METADATA => #{made_for => null_value}}).
-define(MAGIC, '$magic_chicken').
-define(MAGIC_SCHEMA, #{type => ?MAGIC}).

%% @doc Make a higher order schema by overriding `Base' with `OnTop'
-spec override(field_schema(), field_schema_map()) -> field_schema_fun().
override(Base, OnTop) ->
    fun(SchemaKey) ->
            case maps:is_key(SchemaKey, OnTop) of
                true -> field_schema(OnTop, SchemaKey);
                false -> field_schema(Base, SchemaKey)
            end
    end.

%% behaviour APIs
-spec roots(schema()) -> [{name(), {name(), field_schema()}}].
roots(Schema) ->
    All =
      lists:map(fun({N, T}) -> {bin(N), {N, T}};
                   (N) when is_atom(Schema) -> {bin(N), {N, ?R_REF(Schema, N)}};
                   (N) -> {bin(N), {N, ?REF(N)}}
                end, do_roots(Schema)),
    AllNames = [Name || {Name, _} <- All],
    UniqueNames = lists:usort(AllNames),
    case length(UniqueNames) =:= length(AllNames) of
        true  ->
            All;
        false ->
            error({duplicated_root_names, AllNames -- UniqueNames})
    end.

%% @private Collect all structs defined in the given schema.
-spec find_structs(schema()) ->
        {RootNs :: name(), RootFields :: [field()],
         [{Namespace :: name(), Name :: name(), fields()}]}.
find_structs(Schema) ->
    RootFields = unify_roots(Schema),
    All = find_structs(Schema, RootFields),
    RootNs = hocon_schema:namespace(Schema),
    {RootNs, RootFields,
     [{Ns, Name, Fields} || {{Ns, Name}, Fields} <- lists:keysort(1, maps:to_list(All))]}.

unify_roots(Schema) ->
    Roots = ?MODULE:roots(Schema),
    lists:map(fun({_BinName, {RootFieldName, RootFieldSchema}}) ->
                      {RootFieldName, RootFieldSchema}
              end, Roots).

do_roots(Mod) when is_atom(Mod) -> Mod:roots();
do_roots(#{roots := Names}) -> Names.

%% @doc Get fields of the struct for the given struct name.
-spec fields(schema(), name()) -> [field()].
fields(Sc, Name) ->
    #{fields := Fields} = fields_and_meta(Sc, Name),
    Fields.

%% @doc Get fields and meta data of the struct for the given struct name.
-spec fields_and_meta(schema(), name()) -> fields().
fields_and_meta(Mod, Name) when is_atom(Mod) ->
    ensure_struct_meta(Mod:fields(Name));
fields_and_meta(#{fields := Fields}, Name) when is_function(Fields) ->
    ensure_struct_meta(Fields(Name));
fields_and_meta(#{fields := Fields}, Name) when is_map(Fields) ->
    ensure_struct_meta(maps:get(Name, Fields)).

ensure_struct_meta(Fields) when is_list(Fields) -> #{fields => Fields};
ensure_struct_meta(#{fields := _} = Fields) -> Fields.

-spec translations(schema()) -> [name()].
translations(Mod) when is_atom(Mod) ->
    case erlang:function_exported(Mod, translations, 0) of
        false -> [];
        true -> Mod:translations()
    end;
translations(#{translations := Trs}) -> maps:keys(Trs);
translations(Sc) when is_map(Sc) -> [].

-spec translation(schema(), name()) -> [translation()].
translation(Mod, Name) when is_atom(Mod) -> Mod:translation(Name);
translation(#{translations := Trs}, Name) -> maps:get(Name, Trs).

-spec validations(schema()) -> [validation()].
validations(Mod) when is_atom(Mod) ->
    case erlang:function_exported(Mod, validations, 0) of
        false -> [];
        true -> Mod:validations()
    end;
validations(Sc) -> maps:get(validations, Sc, []).

%% @doc Get namespace of a schema.
-spec namespace(schema()) -> undefined | binary().
namespace(Schema) ->
    case is_atom(Schema) of
        true ->
            case erlang:function_exported(Schema, namespace, 0) of
                true  -> Schema:namespace();
                false -> undefined
            end;
        false ->
            maps:get(namespace, Schema, undefined)
    end.

%% @doc Resolve struct name from a guess.
resolve_struct_name(Schema, StructName) ->
    case lists:keyfind(bin(StructName), 1, roots(Schema)) of
        {_, {N, _Sc}} -> N;
        false -> throw({unknown_struct_name, Schema, StructName})
    end.

%% @doc Get all root names from a schema.
-spec root_names(schema()) -> [binary()].
root_names(Schema) -> [Name || {Name, _} <- roots(Schema)].

%% @doc generates application env from a parsed .conf and a schema module.
%% For example, one can set the output values by
%%    lists:foreach(fun({AppName, Envs}) ->
%%        [application:set_env(AppName, Par, Val) || {Par, Val} <- Envs]
%%    end, hocon_schema_generate(Schema, Conf)).
-spec(generate(schema(), hocon:config()) -> [proplists:property()]).
generate(Schema, Conf) ->
    generate(Schema, Conf, #{}).

generate(Schema, Conf, Opts) ->
    {Mapped, _NewConf} = map_translate(Schema, Conf, Opts),
    Mapped.

-spec(map_translate(schema(), hocon:config(), opts()) ->
    {[proplists:property()], hocon:config()}).
map_translate(Schema, Conf, Opts) ->
    {Mapped, NewConf} = map(Schema, Conf, all, Opts),
    Translated = translate(Schema, NewConf, Mapped),
    {nest(Translated), NewConf}.

%% @private returns a nested proplist with atom keys
-spec(nest([proplists:property()]) -> [proplists:property()]).
nest(Proplist) ->
    nest(Proplist, []).

nest([], Acc) ->
    Acc;
nest([{Field, Value} | More], Acc) ->
    nest(More, set_value(Field, Acc, Value)).

set_value([LastToken], Acc, Value) ->
    Token = list_to_atom(LastToken),
    lists:keystore(Token, 1, Acc, {Token, Value});
set_value([HeadToken | MoreTokens], PList, Value) ->
    Token = list_to_atom(HeadToken),
    OldValue = proplists:get_value(Token, PList, []),
    lists:keystore(Token, 1, PList, {Token, set_value(MoreTokens, OldValue, Value)}).

-spec translate(schema(), hocon:config(), [proplists:property()]) -> [proplists:property()].
translate(Schema, Conf, Mapped) ->
    case translations(Schema) of
        [] -> Mapped;
        Namespaces ->
            Res = lists:append([do_translate(translation(Schema, N), str(N), Conf, Mapped) ||
                        N <- Namespaces]),
            ok = assert_no_error(Schema, Res),
            %% rm field if translation returns undefined
            [{K, V} || {K, V} <- lists:ukeymerge(1, Res, Mapped), V =/= undefined]
    end.

do_translate([], _Namespace, _Conf, Acc) -> Acc;
do_translate([{MappedField, Translator} | More], TrNamespace, Conf, Acc) ->
    MappedField0 = TrNamespace ++ "." ++ MappedField,
    try Translator(Conf) of
        Value ->
            do_translate(More, TrNamespace, Conf, [{string:tokens(MappedField0, "."), Value} | Acc])
    catch
        Exception : Reason : St ->
            Error = {error, ?TRANSLATION_ERRS(#{reason => Reason,
                                                stacktrace => St,
                                                value_path => MappedField0,
                                                exception => Exception
                                               })},
            do_translate(More, TrNamespace, Conf, [Error | Acc])
    end.

assert_integrity(Schema, Conf0, #{format := Format}) ->
    Conf = case Format of
               richmap -> richmap_to_map(Conf0);
               map -> Conf0
           end,
    Names = validations(Schema),
    Errors = assert_integrity(Schema, Names, Conf, []),
    ok = assert_no_error(Schema, Errors).

assert_integrity(_Schema, [], _Conf, Result) -> lists:reverse(Result);
assert_integrity(Schema, [{Name, Validator} | Rest], Conf, Acc) ->
    try Validator(Conf) of
        OK when OK =:= true orelse OK =:= ok ->
            assert_integrity(Schema, Rest, Conf, Acc);
        Other ->
            assert_integrity(Schema, Rest, Conf,
                             [{error, ?VALIDATION_ERRS(#{reason => integrity_validation_failure,
                                                         validation_name => Name,
                                                         result => Other})}])
    catch
        Exception : Reason : St ->
            Error = {error, ?VALIDATION_ERRS(#{reason => integrity_validation_crash,
                                               validation_name => Name,
                                               exception => {Exception, Reason},
                                               stacktrace => St
                                              })},
            assert_integrity(Schema, Rest, Conf, [Error | Acc])
    end.

merge_opts(Default, Opts) ->
    maps:merge(Default#{apply_override_envs => false,
                        atom_key => false
                       }, Opts).

%% @doc Check richmap input against schema.
%% Returns a new config with:
%% 1) default values from schema if not found in input config
%% 2) environment variable overrides applyed
-spec(check(schema(), hocon:config()) -> hocon:config()).
check(Schema, Conf) ->
    check(Schema, Conf, #{}).

check(Schema, Conf, Opts0) ->
    Opts = merge_opts(#{format => richmap}, Opts0),
    do_check(Schema, Conf, Opts, all).

%% @doc Check plain-map input against schema.
%% Returns a new config with:
%% 1) default values from schema if not found in input config
%% 2) environment variable overrides applyed.
%% Returns a plain map (not richmap).
check_plain(Schema, Conf) ->
    check_plain(Schema, Conf, #{}).

check_plain(Schema, Conf, Opts0) ->
    Opts = merge_opts(#{format => map}, Opts0),
    check_plain(Schema, Conf, Opts, all).

check_plain(Schema, Conf, Opts0, RootNames) ->
    Opts = merge_opts(#{format => map}, Opts0),
    do_check(Schema, Conf, Opts, RootNames).

do_check(Schema, Conf, Opts0, RootNames) ->
    Opts = merge_opts(#{nullable => false}, Opts0),
    %% discard mappings for check APIs
    {_DiscardMappings, NewConf} = map(Schema, Conf, RootNames, Opts),
    NewConf.

maybe_convert_to_plain_map(Conf, #{format := richmap, return_plain := true}) ->
    richmap_to_map(Conf);
maybe_convert_to_plain_map(Conf, _Opts) ->
    Conf.

-spec map(schema(), hocon:config()) -> {[proplists:property()], hocon:config()}.
map(Schema, Conf) ->
    Roots = [N || {N, _} <- roots(Schema)],
    map(Schema, Conf, Roots, #{}).

-spec map(schema(), hocon:config(), all | [name()]) ->
        {[proplists:property()], hocon:config()}.
map(Schema, Conf, RootNames) ->
    map(Schema, Conf, RootNames, #{}).

-spec map(schema(), hocon:config(), all | [name()], opts()) ->
        {[proplists:property()], hocon:config()}.
map(Schema, Conf, all, Opts) ->
    map(Schema, Conf, root_names(Schema), Opts);
map(Schema, Conf0, Roots0, Opts0) ->
    Opts = merge_opts(#{schema => Schema,
                        format => richmap
                       }, Opts0),
    Roots = resolve_root_types(roots(Schema), Roots0),
    %% assert
    lists:foreach(fun({RootName, _RootSc}) ->
                          ok = assert_no_dot(Schema, RootName)
                  end, Roots),
    Conf1 = filter_by_roots(Opts, Conf0, Roots),
    Conf = apply_envs(Schema, Conf1, Opts, Roots),
    {Mapped0, NewConf} = do_map(Roots, Conf, Opts, ?MAGIC_SCHEMA),
    ok = assert_no_error(Schema, Mapped0),
    ok = assert_integrity(Schema, NewConf, Opts),
    Mapped = log_and_drop_env_overrides(Opts, Mapped0),
    {Mapped, maybe_convert_to_plain_map(NewConf, Opts)}.

%% @doc Apply environment variable overrides on top of the given Conf0
merge_env_overrides(Schema, Conf0, all, Opts) ->
    merge_env_overrides(Schema, Conf0, root_names(Schema), Opts);
merge_env_overrides(Schema, Conf0, Roots0, Opts0) ->
    Opts = Opts0#{apply_override_envs => true}, %% force
    Roots = resolve_root_types(roots(Schema), Roots0),
    Conf = filter_by_roots(Opts, Conf0, Roots),
    apply_envs(Schema, Conf, Opts, Roots).

%% the config 'map' call returns env overrides in mapping
%% resutls, this function helps to drop them from  the list
%% and log the overrides
log_and_drop_env_overrides(_Opts, []) -> [];
log_and_drop_env_overrides(Opts, [#{hocon_env_var_name := _} = H | T]) ->
    _ = log(Opts, info, H),
    log_and_drop_env_overrides(Opts, T);
log_and_drop_env_overrides(Opts, [H | T]) ->
    [H | log_and_drop_env_overrides(Opts, T)].

%% Merge environment overrides into HOCON value before checking it against the schema.
apply_envs(_Schema, Conf, #{apply_override_envs := false}, _Roots) -> Conf;
apply_envs(Schema, Conf, Opts, Roots) ->
    {EnvNamespace, Envs} = collect_envs(Schema, Opts, Roots),
    do_apply_envs(EnvNamespace, Envs, Opts, Roots, Conf).

do_apply_envs(_EnvNamespace, _Envs, _Opts, [], Conf) -> Conf;
do_apply_envs(EnvNamespace, Envs, Opts, [{RootName, RootSc} | Roots], Conf) ->
    ShouldApply =
        case field_schema(RootSc, type) of
            ?LAZY(_) -> maps:get(check_lazy, Opts, false);
            _ -> true
        end,
    NewConf = case ShouldApply of
                  true -> apply_env(EnvNamespace, Envs, RootName, Conf, Opts);
                  false -> Conf
                end,
    do_apply_envs(EnvNamespace, Envs, Opts, Roots, NewConf).

%% silently drop unknown data (root level only)
filter_by_roots(Opts, Conf, Roots) ->
    Names = lists:map(fun({N, _}) -> bin(N) end, Roots),
    boxit(Opts, maps:with(Names, unbox(Opts, Conf)), Conf).

resolve_root_types(_Roots, []) -> [];
resolve_root_types(Roots, [Name | Rest]) ->
    case lists:keyfind(bin(Name), 1, Roots) of
        {_, {OrigName, Sc}} ->
            [{OrigName, Sc} | resolve_root_types(Roots, Rest)];
        false ->
            %% maybe a private struct which is not exposed in roots/0
            [{Name, hoconsc:ref(Name)} | resolve_root_types(Roots, Rest)]
    end.

%% Assert no dot in root struct name.
%% This is because the dot will cause root name to be splited,
%% which in turn makes the implimentation complicated.
%%
%% e.g. if a root name is 'a.b.c', the schema is only defined
%% for data below `c` level.
%% `a` and `b` are implicitly single-field roots.
%%
%% In this case if a non map value is assigned, such as `a.b=1`,
%% the check code will crash rather than reporting a useful error reason.
assert_no_dot(Schema, RootName) ->
    case split(RootName) of
        [_] -> ok;
        _ -> error({bad_root_name, Schema, RootName})
    end.

str(A) when is_atom(A) -> atom_to_list(A);
str(B) when is_binary(B) -> binary_to_list(B);
str(S) when is_list(S) -> S.

bin(A) when is_atom(A) -> atom_to_binary(A, utf8);
bin(S) -> iolist_to_binary(S).

do_map(Fields, Value, Opts, ParentSchema) ->
    case unbox(Opts, Value) of
        undefined ->
            case is_nullable(Opts, ParentSchema) of
                {true, recursively} ->
                    {[], boxit(Opts, undefined, undefined)};
                true ->
                    do_map2(Fields, boxit(Opts, undefined, undefined), Opts,
                            ParentSchema);
                false ->
                    {validation_errs(Opts, not_nullable, undefined), undefined}
            end;
        V when is_map(V) ->
            do_map2(Fields, Value, Opts, ParentSchema);
        _ ->
            {validation_errs(Opts, bad_value_for_struct, Value), Value}
    end.

do_map2(Fields, Value0, Opts, _ParentSchema) ->
    SchemaFieldNames = lists:map(fun({N, _Schema}) -> N end, Fields),
    DataFields0 = unbox(Opts, Value0),
    DataFields = drop_nulls(Opts, DataFields0),
    Value = boxit(Opts, DataFields, Value0),
    case check_unknown_fields(Opts, SchemaFieldNames, DataFields) of
      ok -> map_fields(Fields, Value, [], Opts);
      Errors -> {Errors, Value}
    end.

map_fields([], Conf, Mapped, _Opts) ->
    {Mapped, Conf};
map_fields([{FieldName, FieldSchema} | Fields], Conf0, Acc, Opts) ->
    FieldType = field_schema(FieldSchema, type),
    FieldValue = get_field(Opts, FieldName, Conf0),
    NewOpts = push_stack(Opts, FieldName),
    {FAcc, FValue} =
        try
            map_one_field(FieldType, FieldSchema, FieldValue, NewOpts)
        catch
            %% there is no test coverage for these lines
            %% if this happens, it's a bug!
            C : #{reason := failed_to_check_field} = E : St ->
                erlang:raise(C, E, St);
            C : E : St ->
                Err = #{reason => failed_to_check_field,
                        field => FieldName,
                        path => try path(Opts) catch _ : _ -> [] end,
                        exception => E},
                catch log(Opts, error, io_lib:format("input-config:~n~p~n~p~n",
                                                     [FieldValue, Err])),
                erlang:raise(C, Err, St)
        end,
    Conf = put_value(Opts, FieldName, unbox(Opts, FValue), Conf0),
    map_fields(Fields, Conf, FAcc ++ Acc, Opts).

map_one_field(FieldType, FieldSchema, FieldValue0, Opts) ->
    {MaybeLog, FieldValue} = resolve_field_value(FieldSchema, FieldValue0, Opts),
    Converter = field_schema(FieldSchema, converter),
    {Acc0, NewValue} = map_field_maybe_convert(FieldType, FieldSchema, FieldValue, Opts, Converter),
    Acc = MaybeLog ++ Acc0,
    NoConversion = only_fill_defaults(Opts),
    Validators =
        case is_primitive_type(FieldType) of
            true ->
                %% primitive values are already validated
                [];
            false ->
                %% otherwise valdiate using the schema defined callbacks
                validators(field_schema(FieldSchema, validator))
        end,
    case find_errors(Acc) of
        ok when NoConversion ->
            %% when only_fill_defaults, we are only filling default values (recursively)
            %% for the input FieldValue.
            %% i.e. no config mapping, value validation (because it's unconverted)
            {Acc, NewValue};
        ok ->
            Pv = plain_value(NewValue, Opts),
            ValidationResult = validate(Opts, FieldSchema, Pv, Validators),
            case ValidationResult of
                [] ->
                    Mapped = maybe_mapping(field_schema(FieldSchema, mapping), Pv),
                    {Acc ++ Mapped, NewValue};
                Errors ->
                    {Acc ++ Errors, NewValue}
            end;
        _ ->
            {Acc, FieldValue}
    end.

map_field_maybe_convert(Type, Schema, Value0, Opts, undefined) ->
    map_field(Type, Schema, Value0, Opts);
map_field_maybe_convert(Type, Schema, Value0, Opts, Converter) ->
    Value1 = plain_value(unbox(Opts, Value0), Opts),
    try Converter(Value1) of
        Value2 ->
            Value3 = maybe_mkrich(Opts, Value2, Value0),
            {Mapped, Value} = map_field(Type, Schema, Value3, Opts),
            case only_fill_defaults(Opts) of
                true -> {Mapped, ensure_bin_str(Value0)};
                false -> {Mapped, Value}
            end
    catch
        throw : Reason ->
            {validation_errs(Opts, #{reason => Reason}), Value0};
        C : E : St ->
            {validation_errs(Opts, #{reason => converter_crashed,
                                     exception => {C, E},
                                     stacktrace => St
                                    }), Value0}
    end.

map_field(?MAP(_Name, Type), FieldSchema, Value, Opts) ->
    %% map type always has string keys
    Keys = maps_keys(unbox(Opts, Value)),
    FieldNames = [str(K) || K <- Keys],
    %% All objects in this map should share the same schema.
    NewSc = override(FieldSchema, #{type => Type, mapping => undefined}),
    NewFields = [{FieldName, NewSc} || FieldName <- FieldNames],
    do_map(NewFields, Value, Opts, NewSc); %% start over
map_field(?R_REF(Module, Ref), FieldSchema, Value, Opts) ->
    %% Switching to another module, good luck.
    do_map(fields(Module, Ref), Value, Opts#{schema := Module}, FieldSchema);
map_field(?REF(Ref), FieldSchema, Value, #{schema := Schema} = Opts) ->
    Fields = fields(Schema, Ref),
    do_map(Fields, Value, Opts, FieldSchema);
map_field(Ref, FieldSchema, Value, #{schema := Schema} = Opts) when is_list(Ref) ->
    Fields = fields(Schema, Ref),
    do_map(Fields, Value, Opts, FieldSchema);
map_field(?UNION(Types), Schema0, Value, Opts) ->
    %% union is not a boxed value
    F = fun(Type) ->
                %% go deep with union member's type, but all
                %% other schema information should be inherited from the enclosing schema
                Schema = sub_schema(Schema0, Type),
                map_field(Type, Schema, Value, Opts)
        end,
    case do_map_union(Types, F, #{}, Opts) of
        {ok, {Mapped, NewValue}} -> {Mapped, NewValue};
        Error -> {Error, Value}
    end;
map_field(?LAZY(Type), Schema, Value, Opts) ->
    SubType = sub_type(Schema, Type),
    case maps:get(check_lazy, Opts, false) of
        true -> map_field(SubType, Schema, Value, Opts);
        false -> {[], Value}
    end;
map_field(?ARRAY(Type), _Schema, Value0, Opts) ->
    %% array needs an unbox
    Array = unbox(Opts, Value0),
    F = fun(I, Elem) ->
               NewOpts = push_stack(Opts, integer_to_binary(I)),
               map_one_field(Type, Type, Elem, NewOpts)
       end,
    Do = fun(ArrayForSure) ->
                 case do_map_array(F, ArrayForSure, [], 1, []) of
                     {ok, {NewArray, Mapped}} ->
                         true = is_list(NewArray), %% assert
                         %% and we need to box it back
                         {Mapped, boxit(Opts, NewArray, Value0)};
                     {error, Reasons} ->
                         {[{error, Reasons}], Value0}
                 end
         end,
    case is_list(Array) of
        true -> Do(Array);
        false when Array =:= undefined ->
            {[], undefined};
        false when is_map(Array) ->
            case check_indexed_array(maps:to_list(Array)) of
                {ok, Arr} ->
                    Do(Arr);
                {error, Reason} ->
                    {validation_errs(Opts, Reason), Value0}
            end;
        false ->
            Reason = #{expected_data_type => array, got => type_hint(Array)},
            {validation_errs(Opts, Reason), Value0}
    end;
map_field(Type, Schema, Value0, Opts) ->
    %% primitive type
    Value = unbox(Opts, Value0),
    PlainValue = plain_value(Value, Opts),
    ConvertedValue = hocon_schema_builtin:convert(PlainValue, Type),
    Validators = validators(field_schema(Schema, validator)) ++ builtin_validators(Type),
    ValidationResult = validate(Opts, Schema, ConvertedValue, Validators),
    case only_fill_defaults(Opts) of
        true -> {ValidationResult, ensure_bin_str(Value0)};
        false -> {ValidationResult, boxit(Opts, ConvertedValue, Value0)}
    end.

is_primitive_type(Type) when ?IS_TYPEREFL(Type) -> true;
is_primitive_type(Atom) when is_atom(Atom) -> true;
is_primitive_type(?ENUM(_)) -> true;
is_primitive_type(_) -> false.

sub_schema(EnclosingSchema, MaybeType) ->
    fun(type) -> field_schema(MaybeType, type);
       (Other) -> field_schema(EnclosingSchema, Other)
    end.

sub_type(EnclosingSchema, MaybeType) ->
    SubSc = sub_schema(EnclosingSchema, MaybeType),
    SubSc(type).

maps_keys(undefined) -> [];
maps_keys(Map) -> maps:keys(Map).

check_unknown_fields(Opts, SchemaFieldNames, DataFields) ->
    case find_unknown_fields(SchemaFieldNames, DataFields) of
        [] ->
            ok;
        Unknowns ->
            Err = #{reason => unknown_fields,
                    path => path(Opts),
                    expected => SchemaFieldNames,
                    unknown => Unknowns
                   },
            validation_errs(Opts, Err)
    end.

find_unknown_fields(_SchemaFieldNames, undefined) -> [];
find_unknown_fields(SchemaFieldNames0, DataFields) ->
    SchemaFieldNames = lists:map(fun bin/1, SchemaFieldNames0),
    maps:fold(fun(DfName, DfValue, Acc) ->
                      case is_known_name(DfName, SchemaFieldNames) of
                          true ->
                              Acc;
                          false ->
                              Unknown = case meta(DfValue) of
                                            undefined -> DfName;
                                            Meta -> {DfName, Meta}
                                        end,
                              [Unknown | Acc]
                      end
              end, [], DataFields).

is_known_name(Name, ExpectedNames) ->
    lists:any(fun(N) -> N =:= bin(Name) end, ExpectedNames).

is_nullable(Opts, Schema) ->
    case field_schema(Schema, nullable) of
        undefined -> maps:get(nullable, Opts, ?DEFAULT_NULLABLE);
        Maybe -> Maybe
    end.

field_schema(Atom, type) when is_atom(Atom) -> Atom;
field_schema(Atom, _Other) when is_atom(Atom) -> undefined;
field_schema(Type, SchemaKey) when ?IS_TYPEREFL(Type) ->
    field_schema(hoconsc:mk(Type), SchemaKey);
field_schema(?MAP(_Name, _Type) = Map, SchemaKey) ->
    field_schema(hoconsc:mk(Map), SchemaKey);
field_schema(?LAZY(_) = Lazy, SchemaKey) ->
    field_schema(hoconsc:mk(Lazy), SchemaKey);
field_schema(Ref, SchemaKey) when is_list(Ref) ->
    field_schema(hoconsc:mk(Ref), SchemaKey);
field_schema(?REF(_) = Ref, SchemaKey) ->
    field_schema(hoconsc:mk(Ref), SchemaKey);
field_schema(?R_REF(_, _) = Ref, SchemaKey) ->
    field_schema(hoconsc:mk(Ref), SchemaKey);
field_schema(?ARRAY(_) = Array, SchemaKey) ->
    field_schema(hoconsc:mk(Array), SchemaKey);
field_schema(?UNION(_) = Union, SchemaKey) ->
    field_schema(hoconsc:mk(Union), SchemaKey);
field_schema(?ENUM(_) = Enum, SchemaKey) ->
    field_schema(hoconsc:mk(Enum), SchemaKey);
field_schema(FieldSchema, SchemaKey) when is_function(FieldSchema, 1) ->
    FieldSchema(SchemaKey);
field_schema(FieldSchema, SchemaKey) when is_map(FieldSchema) ->
    maps:get(SchemaKey, FieldSchema, undefined).

maybe_mapping(undefined, _) -> []; % no mapping defined for this field
maybe_mapping(_, undefined) -> []; % no value retrieved for this field
maybe_mapping(MappedPath, PlainValue) ->
    [{string:tokens(MappedPath, "."), PlainValue}].

push_stack(#{stack := Stack} = X, New) ->
    X#{stack := [New | Stack]};
push_stack(X, New) ->
    X#{stack => [New]}.

%% get type validation stack.
path(#{stack := Stack}) -> path(Stack);
path(Stack) when is_list(Stack) ->
    string:join(lists:reverse(lists:map(fun str/1, Stack)), ".").

do_map_union([], _TypeCheck, PerTypeResult, Opts) ->
    validation_errs(Opts, #{reason => matched_no_union_member,
                            mismatches => PerTypeResult});
do_map_union([Type | Types], TypeCheck, PerTypeResult, Opts) ->
    {Mapped, Value} = TypeCheck(Type),
    case find_errors(Mapped) of
        ok ->
            {ok, {Mapped, Value}};
        {error, Reasons} ->
            do_map_union(Types, TypeCheck, PerTypeResult#{Type => Reasons}, Opts)
    end.

do_map_array(_F, [], Elems, _Index, Acc) ->
    {ok, {lists:reverse(Elems), Acc}};
do_map_array(F, [Elem | Rest], Res, Index, Acc) ->
    {Mapped, NewElem} = F(Index, Elem),
    case find_errors(Mapped) of
        ok -> do_map_array(F, Rest, [NewElem | Res], Index + 1, Mapped ++ Acc);
        {error, Reasons} -> {error, Reasons}
    end.

resolve_field_value(Schema, FieldValue, Opts) ->
    case unbox(Opts, FieldValue) of
        ?FROM_ENV_VAR(EnvName, EnvValue) ->
            {[env_override_for_log(Schema, EnvName, path(Opts), EnvValue)],
             maybe_mkrich(Opts, EnvValue, ?META_BOX(from_env, EnvName))};
        _ ->
            {[],
             maybe_use_default(field_schema(Schema, default), FieldValue, Opts)}
    end.

%% use default value if field value is 'undefined'
maybe_use_default(undefined, Value, _Opts) -> Value;
maybe_use_default(Default, undefined, Opts) ->
    maybe_mkrich(Opts, Default, ?META_BOX(made_for, default_value));
maybe_use_default(_, Value, _Opts) -> Value.

collect_envs(Schema, Opts, Roots) ->
    Ns = hocon_util:env_prefix(_Default = undefined),
    case Ns of
        undefined -> {undefined, []};
        _ -> {Ns, lists:keysort(1, collect_envs(Schema, Ns, Opts, Roots))}
    end.

collect_envs(Schema, Ns, Opts, Roots) ->
    Pairs = [begin
                 [Name, Value] = string:split(KV, "="),
                 {Name, Value}
             end || KV <- os:getenv(), string:prefix(KV, Ns) =/= nomatch],
    Envs = lists:map(fun({N, V}) ->
                             {check_env(Schema, Roots, Ns, N), N, V}
                     end, Pairs),
    case [Name || {warn, Name, _} <- Envs] of
        [] -> ok;
        Names ->
            UnknownVars = lists:sort(Names),
            Msg = bin(io_lib:format("unknown_env_vars: ~p", [UnknownVars])),
            log(Opts, warning, Msg)
    end,
    [{Name, read_hocon_val(Value, Opts)} || {keep, Name, Value} <- Envs].

%% return keep | warn | ignore for the given environment variable
check_env(Schema, Roots, Ns, EnvVarName) ->
    case env_name_to_path(Ns, EnvVarName) of
        false ->
            %% bad format
            ignore;
        [RootName | Path] ->
            case is_field(Roots, RootName) of
                {true, Type} ->
                    case is_path(Schema, Type, Path) of
                        true -> keep;
                        false -> warn
                    end;
                false ->
                    %% unknown root
                    ignore
            end
    end.

is_field([], _Name) -> false;
is_field([{FN, FT} | Fields], Name) ->
    case bin(FN) =:= bin(Name) of
        true ->
            Type = hocon_schema:field_schema(FT, type),
            {true, Type};
        false ->
            is_field(Fields, Name)
    end.

is_path(_Schema, _Name, []) -> true;
is_path(Schema, Name, Path) when is_list(Name) ->
    is_path2(Schema, Name, Path);
is_path(Schema, ?REF(Name), Path) ->
    is_path2(Schema, Name, Path);
is_path(_Schema, ?R_REF(Module, Name), Path) ->
    is_path2(Module, Name, Path);
is_path(Schema, ?LAZY(Type), Path) ->
    is_path(Schema, Type, Path);
is_path(Schema, ?ARRAY(Type), [Name | Path]) ->
    case is_array_index(Name) of
        {true, _} -> is_path(Schema, Type, Path);
        false -> false
    end;
is_path(Schema, ?UNION(Types), Path) ->
    lists:any(fun(T) -> is_path(Schema, T, Path) end, Types);
is_path(Schema, ?MAP(_, Type), [_ | Path]) ->
    is_path(Schema, Type, Path);
is_path(_Schema, _Type, _Path) ->
    false.

is_path2(Schema, RefName, [Name | Path]) ->
    Fields = fields(Schema, RefName),
    case is_field(Fields, Name) of
        {true, Type} -> is_path(Schema, Type, Path);
        false -> false
    end.

%% EMQX_FOO__BAR -> ["foo", "bar"]
env_name_to_path(Ns, VarName) ->
    K = string:prefix(VarName, Ns),
    Path0 = string:split(string:lowercase(K), "__", all),
    case lists:filter(fun(N) -> N =/= [] end, Path0) of
        [] -> false;
        Path -> Path
    end.

read_hocon_val("", _Opts) -> "";
read_hocon_val(Value, Opts) ->
    case hocon:binary(Value, #{}) of
        {ok, HoconVal} -> HoconVal;
        {error, _} -> read_informal_hocon_val(Value, Opts)
    end.

read_informal_hocon_val(Value, Opts) ->
    BoxedVal = "fake_key=" ++ Value,
    case hocon:binary(BoxedVal, #{}) of
        {ok, HoconVal} ->
            maps:get(<<"fake_key">>, HoconVal);
        {error, Reason} ->
            Msg = iolist_to_binary(io_lib:format("invalid_hocon_string: ~p, reason: ~p",
                      [Value, Reason])),
            log(Opts, debug, Msg),
            Value
    end.

apply_env(_Ns, [], _RootName, Conf, _Opts) -> Conf;
apply_env(Ns, [{VarName, V} | More], RootName, Conf, Opts) ->
    %% match [_ | _] here because the name is already validated
    [_ | _] = Path0 = env_name_to_path(Ns, VarName),
    NewConf =
        case Path0 =/= [] andalso bin(RootName) =:= bin(hd(Path0)) of
            true ->
                Path = string:join(Path0, "."),
                %% It lacks schema info here, so we need to tag the value '$FROM_ENV_VAR'
                %% and the value will be logged later when checking against schema
                %% so we know if the value is sensitive or not.
                %% NOTE: never translate to atom key here
                Value = case only_fill_defaults(Opts) of
                            true -> V;
                            false -> ?FROM_ENV_VAR(VarName, V)
                        end,
                try
                    put_value(Opts#{atom_key => false}, Path, Value, Conf)
                catch
                    throw : {bad_array_index, Reason} ->
                        Msg = ["bad_array_index from ",  VarName, ", ", Reason],
                        log(Opts, error, iolist_to_binary(Msg)),
                        error({bad_array_index, VarName})
                end;
            false ->
                Conf
        end,
    apply_env(Ns, More, RootName, NewConf, Opts).

env_override_for_log(Schema, Var, K, V0) ->
    V = obfuscate(Schema, V0),
    #{hocon_env_var_name => Var, path => K, value => V}.

obfuscate(Schema, Value) ->
    case field_schema(Schema, sensitive) of
        true -> "*******";
        _ -> Value
    end.

log(#{logger := Logger}, Level, Msg) ->
    Logger(Level, Msg);
log(_Opts, Level, Msg) when is_binary(Msg) ->
    logger:log(Level, "~s", [Msg]);
log(_Opts, Level, Msg) ->
    logger:log(Level, Msg).

meta(#{?METADATA := M}) -> M;
meta(_) -> undefined.

unbox(_, undefined) -> undefined;
unbox(#{format := map}, Value) -> Value;
unbox(#{format := richmap}, Boxed) -> unbox(Boxed).

unbox(Boxed) ->
    case is_map(Boxed) andalso maps:is_key(?HOCON_V, Boxed) of
        true -> maps:get(?HOCON_V, Boxed);
        false -> error({bad_richmap, Boxed})
    end.

safe_unbox(MaybeBox) ->
    case maps:get(?HOCON_V, MaybeBox, undefined) of
        undefined -> ?EMPTY_MAP;
        Value -> Value
    end.

boxit(#{format := map}, Value, _OldValue) -> Value;
boxit(#{format := richmap}, Value, undefined) -> boxit(Value, ?NULL_BOX);
boxit(#{format := richmap}, Value, Box) -> boxit(Value, Box).

boxit(Value, Box) -> Box#{?HOCON_V => Value}.

%% nested boxing
maybe_mkrich(#{format := map}, Value, _Box) ->
    Value;
maybe_mkrich(#{format := richmap}, Value, Box) ->
    hocon_util:deep_merge(Box, mkrich(Value, Box)).

mkrich(Arr, Box) when is_list(Arr) ->
    NewArr = [mkrich(I, Box) || I <- Arr],
    boxit(NewArr, Box);
mkrich(Map, Box) when is_map(Map) ->
    boxit(maps:from_list(
            [{Name, mkrich(Value, Box)} || {Name, Value} <- maps:to_list(Map)]),
          Box);
mkrich(Val, Box) ->
    boxit(Val, Box).

get_field(#{format := richmap}, Path, Conf) -> deep_get(Path, Conf);
get_field(#{format := map}, Path, Conf) -> get_value(Path, Conf).

%% put (maybe deep) value to map/richmap
%% e.g. "path.to.my.value"
put_value(_Opts, _Path, undefined, Conf) ->
    Conf;
put_value(#{format := richmap} = Opts, Path, V, Conf) ->
    deep_put(Opts, Path, V, Conf);
put_value(#{format := map} = Opts, Path, V, Conf) ->
    plain_put(Opts, split(Path), V, Conf).

split(Path) -> lists:flatten(do_split(str(Path))).

do_split([]) -> [];
do_split(Path) when ?IS_NON_EMPTY_STRING(Path) ->
    [bin(I) || I <- string:tokens(Path, ".")];
do_split([H | T]) ->
    [do_split(H) | do_split(T)].

validators(undefined) -> [];
validators(Validator) when is_function(Validator) ->
    validators([Validator]);
validators(Validators) when is_list(Validators) ->
    true = lists:all(fun(F) -> is_function(F, 1) end, Validators), %% assert
    Validators.

builtin_validators(?ENUM(Symbols)) ->
    [fun(Value) -> check_enum_sybol(Value, Symbols) end];
builtin_validators(Type) ->
    TypeChecker = fun (Value) -> typerefl:typecheck(Type, Value) end,
    [TypeChecker].

check_enum_sybol(Value, Symbols) when is_atom(Value) ->
    case lists:member(Value, Symbols) of
        true -> ok;
        false -> {error, not_a_enum_symbol}
    end;
check_enum_sybol(_Value, _Symbols) ->
    {error, unable_to_convert_to_enum_symbol}.


validate(Opts, Schema, Value, Validators) ->
    validate(Opts, Schema, Value, is_nullable(Opts, Schema), Validators).

validate(_Opts, _Schema, undefined, true, _Validators) ->
    []; % do not validate if no value is set
validate(Opts, _Schema, undefined, false, _Validators) ->
    validation_errs(Opts, not_nullable, undefined);
validate(Opts, Schema, Value, _IsNullable, Validators) ->
    do_validate(Opts, Schema, Value, Validators).

%% returns on the first failure
do_validate(_Opts, _Schema, _Value, []) -> [];
do_validate(Opts, Schema, Value, [H | T]) ->
    try H(Value) of
        OK when OK =:= ok orelse OK =:= true ->
            do_validate(Opts, Schema, Value, T);
        false ->
            validation_errs(Opts, returned_false, obfuscate(Schema, Value));
        {error, Reason} ->
            validation_errs(Opts, Reason, obfuscate(Schema, Value))
    catch
        C : E : St ->
            validation_errs(Opts, #{exception => {C, E},
                                    stacktrace => St
                                   }, obfuscate(Schema, Value))
    end.

validation_errs(Opts, Reason, Value) ->
    Err = case meta(Value) of
              undefined -> #{reason => Reason, value => Value};
              Meta -> #{reason => Reason, value => richmap_to_map(Value), location => Meta}
          end,
    validation_errs(Opts, Err).

validation_errs(Opts, Context) ->
    [{error, ?VALIDATION_ERRS(Context#{path => path(Opts)})}].

plain_value(Value, #{format := map}) -> Value;
plain_value(Value, #{format := richmap}) -> richmap_to_map(Value).

%% @doc get a child node from richmap.
%% Key (first arg) can be "foo.bar.baz" or ["foo.bar", "baz"] or ["foo", "bar", "baz"].
-spec deep_get(string() | [string()], hocon:config()) -> hocon:config() | undefined.
deep_get(Path, Conf) ->
    do_deep_get(split(Path), Conf).

do_deep_get([], Value) ->
    %% terminal value
    Value;
do_deep_get([H | T], EnclosingMap) ->
    %% `value` must exist, must be a richmap otherwise
    %% a bug in in the caller
    Value = maps:get(?HOCON_V, EnclosingMap),
    case is_map(Value) of
        true ->
            case maps:get(H, Value, undefined) of
                undefined ->
                    %% no such field
                    undefined;
                FieldValue ->
                    do_deep_get(T, FieldValue)
            end;
        false ->
            undefined
    end.

maybe_atom(#{atom_key := true}, Name) when is_binary(Name) ->
    try
        binary_to_existing_atom(Name, utf8)
    catch
        _ : _ ->
            error({non_existing_atom, Name})
    end;
maybe_atom(_Opts, Name) ->
    Name.

-spec plain_put(opts(), [binary()], term(), hocon:confing()) -> hocon:config().
plain_put(_Opts, [], Value, _Old) -> Value;
plain_put(Opts, [Name | Path], Value, Conf0) ->
    GoDeep = fun(V) -> plain_put(Opts, Path, Value, V) end,
    do_put(Opts, Conf0, Name, GoDeep).

%% put unboxed value to the richmap box
%% this function is called places where there is no boxing context
%% so it has to accept unboxed value.
deep_put(Opts, Path, Value, Conf) ->
    put_rich(Opts, split(Path), Value, Conf).

put_rich(_Opts, [], Value, Box) ->
    boxit(Value, Box);
put_rich(Opts, [Name | Path], Value, Box) ->
    V0 = safe_unbox(Box),
    GoDeep = fun(Elem) -> put_rich(Opts, Path, Value, Elem) end,
    V = do_put(Opts, V0, Name, GoDeep),
    boxit(V, Box).

do_put(Opts, V, Name, GoDeep) ->
    case maybe_array(V) andalso is_array_index(Name) of
        {true, Index} -> update_array_element(V, Index, GoDeep);
        false when is_map(V) -> update_map_field(Opts, V, Name, GoDeep);
        false -> update_map_field(Opts, #{}, Name, GoDeep)
    end.

maybe_array(V) when is_list(V) -> true;
maybe_array(V) -> V =:= ?EMPTY_MAP.

update_array_element(?EMPTY_MAP, Index, GoDeep) ->
    update_array_element([], Index, GoDeep);
update_array_element(List, Index, GoDeep) when is_list(List) ->
    hocon_util:update_array_element(List, Index, GoDeep).

update_map_field(Opts, Map, FieldName, GoDeep) ->
    FieldV0 = maps:get(FieldName, Map, ?EMPTY_MAP),
    FieldV = GoDeep(FieldV0),
    Map1 = maps:without([FieldName], Map),
    Map1#{maybe_atom(Opts, FieldName) => FieldV}.

%% {true, integer()} if yes, otherwise false
is_array_index(L) when is_list(L) ->
    is_array_index(list_to_binary(L));
is_array_index(I) -> hocon_util:is_array_index(I).

check_indexed_array(List) ->
    case check_indexed_array(List, [], []) of
        {Good, []} -> check_index_seq(1, lists:keysort(1, Good), []);
        {_, Bad} -> {error, #{bad_array_index_keys => Bad}}
    end.

check_indexed_array([], Good, Bad) -> {Good, Bad};
check_indexed_array([{I, V} | Rest], Good, Bad) ->
    case is_array_index(I) of
        {true, Index} -> check_indexed_array(Rest, [{Index, V} | Good], Bad);
        false -> check_indexed_array(Rest, Good, [I | Bad])
    end.

check_index_seq(_, [], Acc) ->
    {ok, lists:reverse(Acc)};
check_index_seq(I, [{Index, V} | Rest], Acc) ->
    case I =:= Index of
        true ->
            check_index_seq(I + 1, Rest, [V | Acc]);
        false ->
            {error, #{expected_index => I,
                      got_index => Index}}
    end.

type_hint(B) when is_binary(B) -> string; %% maybe secret, do not hint value
type_hint(X) -> X.

%% @doc Convert richmap to plain-map.
richmap_to_map(MaybeRichMap) ->
    hocon_util:richmap_to_map(MaybeRichMap).

%% treat 'null' as absence
drop_nulls(_Opts, undefined) -> undefined;
drop_nulls(Opts, Map) when is_map(Map) ->
    maps:filter(fun(_Key, Value) ->
                        case unbox(Opts, Value) of
                            null -> false;
                            {'$FROM_ENV_VAR', _, null} -> false;
                            _ -> true
                        end
                end, Map).

%% @doc Get (maybe nested) field value for the given path.
%% This function works for both plain and rich map,
%% And it always returns plain map.
-spec get_value(string(), hocon:config()) -> term().
get_value(Path, Conf) ->
    %% ensure plain map
    do_get(split(Path), richmap_to_map(Conf)).

do_get([], Conf) ->
    %% value as-is
    Conf;
do_get(_, undefined) ->
    undefined;
do_get([H | T], Conf) ->
    do_get(T, try_get(H, Conf)).

try_get(Key, Conf) when is_map(Conf) ->
    case maps:get(Key, Conf, undefined) of
        undefined ->
            try binary_to_existing_atom(Key, utf8) of
                AtomKey -> maps:get(AtomKey, Conf, undefined)
            catch
                error : badarg ->
                    undefined
            end;
        Value ->
            Value
    end;
try_get(Key, Conf) when is_list(Conf) ->
    try binary_to_integer(Key) of
        N ->
            lists:nth(N, Conf)
    catch
        error : badarg ->
            undefined
    end.


-spec get_value(string(), hocon:config(), term()) -> term().
get_value(Path, Config, Default) ->
    case get_value(Path, Config) of
        undefined -> Default;
        V -> V
    end.

assert_no_error(Schema, List) ->
    case find_errors(List) of
        ok -> ok;
        {error, Reasons} -> throw({Schema, Reasons})
    end.

%% find error but do not throw, return result
find_errors(Proplist) ->
    case do_find_error(Proplist, []) of
        [] -> ok;
        Reasons -> {error, lists:flatten(Reasons)}
    end.

do_find_error([], Res) ->
    Res;
do_find_error([{error, E} | More], Errors) ->
    do_find_error(More, [E | Errors]);
do_find_error([_ | More], Errors) ->
    do_find_error(More, Errors).

find_structs(Schema, Fields) ->
    find_structs(Schema, Fields, #{}, _ValueStack = [], _TypeStack = []).

find_structs(Schema, #{fields := Fields}, Acc, Stack, TStack) ->
    find_structs(Schema, Fields, Acc, Stack, TStack);
find_structs(_Schema, [], Acc, _Stack, _TStack) -> Acc;
find_structs(Schema, [{FieldName, FieldSchema} | Fields], Acc0, Stack, TStack) ->
    Type = hocon_schema:field_schema(FieldSchema, type),
    Acc = find_structs_per_type(Schema, Type, Acc0, [str(FieldName) | Stack], TStack),
    find_structs(Schema, Fields, Acc, Stack, TStack).

find_structs_per_type(Schema, Name, Acc, Stack, TStack) when is_list(Name) ->
    find_ref(Schema, Name, Acc, Stack, TStack);
find_structs_per_type(Schema, ?REF(Name), Acc, Stack, TStack) ->
    find_ref(Schema, Name, Acc, Stack, TStack);
find_structs_per_type(_Schema, ?R_REF(Module, Name), Acc, Stack, TStack) ->
    find_ref(Module, Name, Acc, Stack, TStack);
find_structs_per_type(Schema, ?LAZY(Type), Acc, Stack, TStack) ->
    find_structs_per_type(Schema, Type, Acc, Stack, TStack);
find_structs_per_type(Schema, ?ARRAY(Type), Acc, Stack, TStack) ->
    find_structs_per_type(Schema, Type, Acc, ["$INDEX" | Stack], TStack);
find_structs_per_type(Schema, ?UNION(Types), Acc, Stack, TStack) ->
    lists:foldl(fun(T, AccIn) ->
                        find_structs_per_type(Schema, T, AccIn, Stack, TStack)
                end, Acc, Types);
find_structs_per_type(Schema, ?MAP(Name, Type), Acc, Stack, TStack) ->
    find_structs_per_type(Schema, Type, Acc, ["$" ++ str(Name) | Stack], TStack);
find_structs_per_type(_Schema, _Type, Acc, _Stack, _TStack) ->
    Acc.

find_ref(Schema, Name, Acc, Stack, TStack) ->
    Namespace = hocon_schema:namespace(Schema),
    Key = {Namespace, Name},
    Path = path(Stack),
    Paths =
        case maps:find(Key, Acc) of
            {ok, #{paths := Ps}} -> Ps;
            error -> #{}
        end,
    case lists:member(Key, TStack) of
        true ->
            %% loop reference, break here, otherwise never exit
            Acc;
        false ->
            Fields0 = fields_and_meta(Schema, Name),
            Fields = Fields0#{paths => Paths#{Path => true}},
            find_structs(Schema, Fields, Acc#{Key => Fields}, Stack, [Key | TStack])
    end.

only_fill_defaults(#{only_fill_defaults := true}) -> true;
only_fill_defaults(_) -> false.

ensure_bin_str(Value) when is_list(Value) ->
    case io_lib:printable_unicode_list(Value) of
        true -> unicode:characters_to_binary(Value, utf8);
        false -> Value
    end;
ensure_bin_str(Value) -> Value.

