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

%% This header file is inteded for internal use in schema modules.

-ifndef(HOCONSC_HRL).
-define(HOCONSC_HRL, true).

-define(ARRAY(OfTYpe), {array, OfTYpe}).
-define(UNION(OfTypes), {union, OfTypes}).
-define(ENUM(OfSymbols), {enum, OfSymbols}).
-define(REF(Name), {ref, Name}).
-define(R_REF(Module, Name), {ref, Module, Name}). % remote ref
-define(IS_TYPEREFL(X), (is_tuple(X) andalso element(1, Type) =:= '$type_refl')).

%% A field having lazy type is not type-checked as a part of its enclosing struct
%% the user of this field is responsible for type checks at runtime
%% the hint type is useful when generating documents
-define(LAZY(HintType), {lazy, HintType}).

%% Map keys are always strings, `Name' is only for documentation
-define(MAP(Name, Type), {map, Name, Type}).

-endif.
