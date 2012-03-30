%% Those macros behave like they belong to Elixir.Builtin,
%% but do not since they need to be implemented in Erlang.
-module(elixir_macros).
-export([translate_macro/2]).
-import(elixir_translator, [translate_each/2, translate/2, translate_args/2, translate_apply/7]).
-import(elixir_variables, [umergec/2]).
-import(elixir_errors, [syntax_error/3, syntax_error/4, assert_no_function_scope/3, assert_module_scope/3]).
-include("elixir.hrl").

%% Operators

translate_macro({ '+', _Line, [Expr] }, S) when is_number(Expr) ->
  translate_each(Expr, S);

translate_macro({ '-', _Line, [Expr] }, S) when is_number(Expr) ->
  translate_each(-1 * Expr, S);

translate_macro({ Op, Line, Exprs }, S) when is_list(Exprs),
  Op == '+'; Op == '-'; Op == '*'; Op == '/'; Op == '<-';
  Op == '++'; Op == '--'; Op == 'not'; Op == 'and';
  Op == 'or'; Op == 'xor'; Op == '<'; Op == '>';
  Op == '<='; Op == '>='; Op == '=='; Op == '!=';
  Op == '==='; Op == '!==' ->
  translate_each({ '__op__', Line, [Op|Exprs] }, S);

%% @

translate_macro({'@', Line, [{ Name, _, Args }]}, S) ->
  assert_module_scope(Line, '@', S),
  assert_no_function_scope(Line, '@', S),
  case is_reserved_data(Name) andalso (elixir_compiler:get_opts())#elixir_compile.internal of
    true ->
      { { nil, Line }, S };
    _ ->
      case Args of
        [Arg] ->
          translate_each({
            { '.', Line, ['__MAIN__.Module', merge_data] },
              Line,
              [ { '__MODULE__', Line, false }, [{ Name, Arg }] ]
          }, S);
        _ when is_atom(Args) or (Args == []) ->
            translate_each({
              { '.', Line, ['__MAIN__.Module', read_data] },
              Line,
              [ { '__MODULE__', Line, false }, Name ]
            }, S);
        _ ->
          syntax_error(Line, S#elixir_scope.filename, "expected 0 or 1 argument for @~s, got: ~p", [Name, length(Args)])
      end
  end;

%% Case

translate_macro({'case', Line, [Expr, RawClauses]}, S) ->
  Clauses = orddict:erase(do, RawClauses),
  { TExpr, NS } = translate_each(Expr, S),
  { TClauses, TS } = elixir_clauses:match(Line, Clauses, NS),
  { { 'case', Line, TExpr, TClauses }, TS };

%% Try

translate_macro({'try', Line, [Clauses]}, RawS) ->
  Do    = proplists:get_value('do', Clauses, []),
  Catch = orddict:erase('after', orddict:erase('do', Clauses)),
  S     = RawS#elixir_scope{noname=true},

  { TDo, SB } = translate([Do], S),
  { TCatch, SC } = elixir_try:clauses(Line, Catch, umergec(S, SB)),

  { TAfter, SA } = case orddict:find('after', Clauses) of
    { ok, After } -> translate([After], umergec(S, SC));
    error -> { [], SC }
  end,

  { { 'try', Line, unpack(TDo), [], TCatch, unpack(TAfter) }, umergec(RawS, SA) };

%% Receive

translate_macro({'receive', Line, [RawClauses] }, S) ->
  Clauses = orddict:erase(do, RawClauses),
  case orddict:find('after', Clauses) of
    { ok, After } ->
      AClauses = orddict:erase('after', Clauses),
      { TClauses, SC } = elixir_clauses:match(Line, AClauses ++ [{'after',After}], S),
      { FClauses, [TAfter] } = lists:split(length(TClauses) - 1, TClauses),
      { _, _, [FExpr], _, FAfter } = TAfter,
      { { 'receive', Line, FClauses, FExpr, FAfter }, SC };
    error ->
      { TClauses, SC } = elixir_clauses:match(Line, Clauses, S),
      { { 'receive', Line, TClauses }, SC }
  end;

%% Definitions

translate_macro({defmodule, Line, [Ref, KV]}, S) ->
  { TRef, _ } = translate_each(Ref, S),

  Block = case orddict:find(do, KV) of
    { ok, DoValue } -> DoValue;
    error -> syntax_error(Line, S#elixir_scope.filename, "expected do: argument in defmodule")
  end,

  NS = case TRef of
    { atom, _, Module } ->
      S#elixir_scope{scheduled=[Module|S#elixir_scope.scheduled]};
    _ -> S
  end,

  { elixir_module:translate(Line, TRef, Block, S), NS };

translate_macro({Kind, Line, [Call]}, S) when Kind == def; Kind == defmacro; Kind == defp ->
  translate_macro({Kind, Line, [Call, skip_definition]}, S);

translate_macro({Kind, Line, [Call, Expr]}, S) when Kind == def; Kind == defp; Kind == defmacro ->
  assert_module_scope(Line, Kind, S),
  assert_no_function_scope(Line, Kind, S),
  { TCall, Guards } = elixir_clauses:extract_guards(Call),
  { Name, Args }    = elixir_clauses:extract_args(TCall),
  TName             = elixir_tree_helpers:abstract_syntax(Name),
  TArgs             = elixir_tree_helpers:abstract_syntax(Args),
  TGuards           = elixir_tree_helpers:abstract_syntax(Guards),
  TExpr             = elixir_tree_helpers:abstract_syntax(Expr),
  { elixir_def:wrap_definition(Kind, Line, TName, TArgs, TGuards, TExpr, S), S };

translate_macro({Kind, Line, [Name, Args, Guards, Expr]}, S) when Kind == def; Kind == defp; Kind == defmacro ->
  assert_module_scope(Line, Kind, S),
  assert_no_function_scope(Line, Kind, S),
  { TName, NS }   = translate_each(Name, S),
  { TArgs, AS }   = translate_each(Args, NS),
  { TGuards, TS } = translate_each(Guards, AS),
  TExpr           = elixir_tree_helpers:abstract_syntax(Expr),
  { elixir_def:wrap_definition(Kind, Line, TName, TArgs, TGuards, TExpr, TS), TS };

%% Modules directives

translate_macro({use, Line, [Raw]}, S) ->
  translate_macro({use, Line, [Raw, []]}, S);

translate_macro({use, Line, [Raw, Args]}, S) ->
  assert_module_scope(Line, use, S),
  Module = S#elixir_scope.module,
  { TRef, SR } = translate_each(Raw, S),

  Ref = case TRef of
    { atom, _, RefAtom } -> RefAtom;
    _ -> syntax_error(Line, S#elixir_scope.filename, "invalid args for use, expected a reference as argument")
  end,

  elixir_ref:ensure_loaded(Line, Ref, SR, true),

  Call = { '__block__', Line, [
    { require, Line, [Ref] },
    { { '.', Line, [Ref, '__using__'] }, Line, [Module, Args] }
  ] },

  translate_each(Call, S);

%% Access

translate_macro({ access, Line, [Element, Orddict] }, S) ->
  case S#elixir_scope.guard of
    true ->
      case translate_each(Element, S) of
        { { atom, _, Atom }, _ } ->
          case is_orddict(Orddict) of
            true -> [];
            false ->
              Message0 = "expected contents inside brackets to be an Orddict",
              syntax_error(Line, S#elixir_scope.filename, Message0)
          end,

          elixir_ref:ensure_loaded(Line, Atom, S, true),

          try Atom:'__record__'(fields) of
            Fields ->
              Match = lists:map(fun({Field,_}) ->
                case orddict:find(Field, Orddict) of
                  { ok, Value } -> Value;
                  error -> { '_', Line, nil }
                end
              end, Fields),

              translate_each({ '{}', Line, [Atom|Match] }, S)
          catch
            error:undef ->
              Message1 = "cannot use module ~s in access protocol because it doesn't represent a record",
              syntax_error(Line, S#elixir_scope.filename, Message1, [Atom])
          end;
        _ ->
          syntax_error(Line, S#elixir_scope.filename, "invalid usage of access protocol in signature")
      end;
    false ->
      Fallback = { { '.', Line, ['__MAIN__.Access', access] }, Line, [Element, Orddict] },
      translate_each(Fallback, S)
  end;

%% Apply - Optimize apply by checking what doesn't need to be dispatched dynamically

translate_macro({ apply, Line, [Left, Right, Args] }, S) when is_list(Args) ->
  { TLeft,  SL } = translate_each(Left, S),
  { TRight, SR } = translate_each(Right, umergec(S, SL)),
  translate_apply(Line, TLeft, TRight, Args, S, SL, SR);

translate_macro({ apply, Line, Args }, S) ->
  { TArgs, NS } = translate_args(Args, S),
  { ?ELIXIR_WRAP_CALL(Line, erlang, apply, TArgs), NS };

%% Handle forced variables

translate_macro({ 'var!', _, [{Name, Line, Atom}] }, S) when is_atom(Name), is_atom(Atom) ->
  elixir_variables:translate_each(Line, Name, S);

translate_macro({ 'var!', Line, [_] }, S) ->
  syntax_error(Line, S#elixir_scope.filename, "invalid args for var!").

%% HELPERS

is_orddict(Orddict) -> is_list(Orddict) andalso lists:all(fun is_orddict_tuple/1, Orddict).

is_orddict_tuple({X,_}) when is_atom(X) -> true;
is_orddict_tuple(_) -> false.

is_reserved_data(moduledoc) -> true;
is_reserved_data(doc)       -> true;
is_reserved_data(_)         -> false.

% Unpack a list of expressions from a block.
unpack([{ '__block__', _, Exprs }]) -> Exprs;
unpack(Exprs)                       -> Exprs.