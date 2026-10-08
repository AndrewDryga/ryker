defmodule Ryker.PublicFunctionsTest do
  # Emisar's context coverage test holds two halves. Ryker names its tests
  # after the invariant they hold, not the function, so it takes the half
  # that does not depend on describe names: every public function has a
  # caller outside the tests. A function only tests call keeps them green long
  # after the code that used it went, so passing tests cannot tell live
  # surface from dead.
  #
  # On 2026-10-08 the scan behind this test found 10 public functions nothing
  # called and 24 only tests called: a submission builder's `build/2` that 30
  # test files used and production never did, two announcements no page
  # listened to, a source's prompt prose no prompt included. Beside them, 38
  # functions only their own module called were public anyway, against
  # Ryker's rule that a function is public when another module calls it or a
  # test checks it.
  #
  # A call is found by name, as Emisar's test finds it, with aliases, imports
  # and `__MODULE__` resolved: `Mod.fun(...)`, `&Mod.fun/1`, a local call, a
  # `defdelegate` target, a `{Mod, :fun, args}` or `{Mod, :fun}` reference, a
  # call in a `~H` template. A call on a variable reaches a function of that
  # name in any module Ryker passes around as a value.
  use ExUnit.Case, async: true

  @root Path.expand("../..", __DIR__)

  # OTP calls these through a child spec, never by name in Ryker's code.
  @conventions ~w(child_spec start_link init)

  # Public with no caller in Ryker's code, each for its reason. Keep this
  # list at the size of its evidence, as Emisar keeps its own: a function
  # written for a test alone belongs in `Ryker.Inspectors`, not here.
  @kept %{
    # Called from outside Ryker's Elixir code.
    "Ryker.schema" => "`use Ryker, :schema` applies the name it is given",
    "Ryker.changeset" => "`use Ryker, :changeset` applies the name it is given",
    "Ryker.ControlPlane.ErrorHTML.render" =>
      "Phoenix renders an error through its view's `render/2`",
    "Ryker.Repo.transact" => "Ecto runs every `Repo.transaction/2` through it",
    "Ryker.Episodes.RoutingDigests.refresh_all" =>
      "an operator rebuilds every digest from a release shell after a release adds a kind of identifier",
    "Ryker.Runtime.Owner.reconcile" =>
      "an operator applies the saved settings now from a release shell; the owner drops the outcome of an apply it starts itself",
    "Ryker.Runtime.Owner.applied_revision" =>
      "an operator asks which settings revision runs from a release shell",
    # A list a module keeps in an attribute, read by a test that walks it so
    # an entry added later is covered without editing the test.
    "Ryker.ControlPlane.Layouts.stylesheets" => "each stylesheet a page links exists",
    "Ryker.ControlPlane.PageHelp.routes" => "every page has help, and help only pages that exist",
    "Ryker.ControlPlane.WorkbenchLive.page_events" =>
      "every announcement a context makes redraws a page",
    "Ryker.Defaults.owners" => "every owner of a default has its horizons",
    "Ryker.IntegrationSetup.slack_scopes" =>
      "the Slack manifest asks for every scope setup requires",
    "Ryker.Runtime.Assembly.managed_keys" => "a test restores every key assembly writes",
    "Ryker.Settings.Edit.domains" => "every settings domain records its edits",
    # The general case production only reaches through narrower doors.
    "Ryker.CoopFleet.ManagedSources.resolve_submodules" =>
      "the submodule walk's budget is 1,024; a test spends it with a budget of 2",
    "Ryker.Work.Custody.request_transfer" =>
      "every transfer (a rerun, a block, a delivery's redirect) is this one with refs of its own; tests hold its invariants with refs they choose"
  }

  setup_all do
    {:ok, graph: graph()}
  end

  test "every public function has a caller outside the tests", %{graph: graph} do
    uncalled =
      for {module, name} <- graph.functions,
          not called?(graph, module, name),
          not Map.has_key?(@kept, "#{module}.#{name}"),
          do: "#{module}.#{name}"

    assert Enum.sort(uncalled) == []
  end

  # Every Query module starts its queries with `all/0`, the layer's entry
  # point, whether or not another module starts one there.
  test "a function only its own module calls is private unless a test checks it",
       %{graph: graph} do
    private =
      for {module, name} <- graph.functions,
          MapSet.member?(graph.production.own, {module, name}),
          not called_from_elsewhere?(graph, module, name),
          not Map.has_key?(@kept, "#{module}.#{name}"),
          not MapSet.member?(graph.tests.others, {module, name}),
          not (String.ends_with?(module, ".Query") and name == "all"),
          do: "#{module}.#{name}"

    assert Enum.sort(private) == []
  end

  # A reason kept for a function that is gone, or that something now calls,
  # is one nobody needs.
  test "every function kept for its reason is public and has no other caller",
       %{graph: graph} do
    public = MapSet.new(graph.functions, fn {module, name} -> "#{module}.#{name}" end)

    stale =
      for {function, _reason} <- @kept,
          function not in public or called?(graph, split(function)),
          do: function

    assert stale == []
  end

  defp split(function) do
    [name | module] = function |> String.split(".") |> Enum.reverse()
    {module |> Enum.reverse() |> Enum.join("."), name}
  end

  defp called?(graph, {module, name}), do: called?(graph, module, name)

  # Tests read rows through Query modules directly, so a test is a Query
  # function's caller as much as a context is.
  defp called?(graph, module, name) do
    MapSet.member?(graph.production.own, {module, name}) or
      called_from_elsewhere?(graph, module, name) or
      twin_called?(graph, module, name) or
      (String.ends_with?(module, ".Query") and MapSet.member?(graph.tests.others, {module, name}))
  end

  defp called_from_elsewhere?(graph, module, name) do
    MapSet.member?(graph.production.others, {module, name}) or
      MapSet.member?(graph.text, {module, name}) or
      (MapSet.member?(graph.production.dynamic, name) and
         MapSet.member?(graph.production.values, module))
  end

  # A page leaves every topic it joined through the twin of the function that
  # joined it, found by name (`Ryker.ControlPlane.WorkbenchLive`).
  defp twin_called?(graph, module, "unsubscribe" <> topic),
    do: called?(graph, module, "subscribe" <> topic)

  defp twin_called?(_graph, _module, _name), do: false

  defp graph do
    production = calls(["lib/**/*.ex", "evals/**/*.{ex,exs}", "config/**/*.exs"])

    # A function its module's source does not define, a `use` wrote:
    # an Ecto repo's, a Phoenix router's pipelines and helpers.
    functions = Enum.filter(public_functions(), &MapSet.member?(production.defined, &1))

    %{
      functions: functions,
      production: production,
      tests: calls(["test/**/*.{ex,exs}"]),
      text: text_calls()
    }
  end

  # Each public function of a module under lib/, by name, without the
  # callbacks of the behaviours it implements and the functions `use` writes.
  defp public_functions do
    lib = Path.join(@root, "lib") <> "/"

    for module <- Application.spec(:ryker, :modules),
        Code.ensure_loaded!(module),
        module.module_info(:compile)[:source] |> to_string() |> String.starts_with?(lib),
        not function_exported?(module, :__impl__, 1),
        callbacks = callbacks(module),
        {name, arity} <- module.__info__(:functions),
        {name, arity} not in callbacks,
        name = Atom.to_string(name),
        not String.starts_with?(name, "__"),
        name not in @conventions,
        uniq: true,
        do: {inspect(module), name}
  end

  defp callbacks(module) do
    module.module_info(:attributes)
    |> Keyword.get_values(:behaviour)
    |> List.flatten()
    |> Enum.flat_map(fn behaviour ->
      if Code.ensure_loaded?(behaviour) and function_exported?(behaviour, :behaviour_info, 1),
        do: behaviour.behaviour_info(:callbacks),
        else: []
    end)
  end

  # What the sources matching `patterns` call: `others` holds each
  # `{module, name}` a module calls in another module, `own` each a module
  # calls in itself, `dynamic` each name called on a variable, and `values`
  # each module passed around as a value.
  defp calls(patterns) do
    patterns
    |> Enum.flat_map(&Path.wildcard(Path.join(@root, &1)))
    |> Task.async_stream(&scan/1, ordered: false, timeout: :infinity)
    |> Enum.reduce(%{calls: [], dynamic: [], values: [], defined: []}, fn {:ok, scan}, acc ->
      %{
        calls: scan.calls ++ acc.calls,
        dynamic: scan.dynamic ++ acc.dynamic,
        values: scan.values ++ acc.values,
        defined: scan.defined ++ acc.defined
      }
    end)
    |> then(fn %{calls: calls, dynamic: dynamic, values: values, defined: defined} ->
      %{
        defined: MapSet.new(defined),
        others:
          for(
            {caller, module, name} <- calls,
            caller != module,
            into: MapSet.new(),
            do: {module, name}
          ),
        own: for({module, module, name} <- calls, into: MapSet.new(), do: {module, name}),
        dynamic: MapSet.new(dynamic),
        values: MapSet.new(values)
      }
    end)
  end

  # `Ryker.Release.migrate()` in a script, a doc or a workflow.
  defp text_calls do
    [
      "scripts/**/*",
      "deploy/**/*",
      "docs/**/*",
      ".github/**/*",
      "Makefile",
      "Dockerfile",
      "*.yml"
    ]
    |> Enum.flat_map(&Path.wildcard(Path.join(@root, &1), match_dot: true))
    |> Enum.reject(&File.dir?/1)
    |> Enum.flat_map(fn path ->
      ~r/(Ryker(?:\.[A-Z][A-Za-z0-9]*)*)\.([a-z_][a-z0-9_]*[!?]?)/
      |> Regex.scan(File.read!(path))
      |> Enum.map(fn [_match, module, name] -> {module, name} end)
    end)
    |> MapSet.new()
  end

  defp scan(path) do
    {:ok, ast} = path |> File.read!() |> Code.string_to_quoted()

    acc = %{
      modules: [nil],
      aliases: %{nil => %{}},
      imports: %{},
      calls: [],
      dynamic: [],
      values: [],
      defined: []
    }

    {_ast, acc} = Macro.traverse(ast, acc, &visit/2, &leave/2)
    Map.take(acc, [:calls, :dynamic, :values, :defined])
  end

  defp visit({:defmodule, meta, [{:__aliases__, _, parts}, body]}, acc) do
    outer = hd(acc.modules)
    name = Enum.map_join(parts, ".", &Atom.to_string/1)
    module = if outer, do: "#{outer}.#{name}", else: name
    short = parts |> hd() |> Atom.to_string()
    inner = acc.aliases[outer] |> Map.put(short, if(outer, do: "#{outer}.#{short}", else: short))

    acc = %{
      acc
      | modules: [module | acc.modules],
        aliases:
          acc.aliases
          |> Map.put(module, inner)
          |> Map.update!(outer, &Map.merge(&1, Map.take(inner, [short])))
    }

    {{:defmodule, meta, [:ok, body]}, acc}
  end

  defp visit({:alias, _meta, [{{:., _, [base, :{}]}, _, children}]}, acc) do
    base = expand(acc, base)

    acc =
      Enum.reduce(children, acc, fn {:__aliases__, _, parts}, acc ->
        full = Enum.join([base | Enum.map(parts, &Atom.to_string/1)], ".")
        put_alias(acc, full |> String.split(".") |> List.last(), full)
      end)

    {:ok, acc}
  end

  defp visit({:alias, _meta, [target | options]}, acc) do
    full = expand(acc, target)

    as =
      case options do
        [[as: {:__aliases__, _, [as]}]] -> Atom.to_string(as)
        _no_as -> full |> String.split(".") |> List.last()
      end

    {:ok, put_alias(acc, as, full)}
  end

  defp visit({:import, _meta, [target | _options]}, acc) do
    module = hd(acc.modules)

    {:ok,
     %{
       acc
       | imports:
           Map.update(acc.imports, module, [expand(acc, target)], &[expand(acc, target) | &1])
     }}
  end

  defp visit({directive, meta, [_module | options]}, acc) when directive in [:require, :use],
    do: {{directive, meta, options}, acc}

  defp visit({:@, _meta, [{attribute, _, _value}]}, acc)
       when attribute in [:spec, :type, :typep, :opaque, :callback, :macrocallback, :behaviour],
       do: {:ok, acc}

  defp visit({:@, meta, [{attribute, _, value}]}, acc) when is_atom(attribute) and is_list(value),
    do: {{:@, meta, value}, acc}

  defp visit({kind, meta, [head | rest]}, acc)
       when kind in [:def, :defp, :defmacro, :defmacrop] do
    acc = if kind == :def, do: define(acc, head), else: acc
    {{kind, meta, [head_arguments(head) | rest]}, acc}
  end

  defp visit({:defdelegate, meta, [head, options]}, acc) do
    name = head |> name_of() |> Atom.to_string()
    as = options |> Keyword.get(:as, name) |> to_string()
    acc = acc |> define(head) |> call(expand(acc, Keyword.fetch!(options, :to)), as)
    {{:defdelegate, meta, [head_arguments(head), Keyword.delete(options, :to)]}, acc}
  end

  defp visit({:%, meta, [_struct, fields]}, acc), do: {{:%, meta, [:ok, fields]}, acc}

  # Code a macro quotes runs in the module that uses it.
  defp visit({:quote, _meta, _arguments} = node, acc) do
    aliases = Map.get(acc.aliases, hd(acc.modules), %{})

    {node,
     %{
       acc
       | modules: ["(quoted)" | acc.modules],
         aliases: Map.put(acc.aliases, "(quoted)", aliases)
     }}
  end

  defp visit({{:., dot, [target, name]}, meta, arguments}, acc) when is_atom(name) do
    cond do
      module?(target) ->
        acc = call(acc, expand(acc, target), Atom.to_string(name))
        acc = named_in_arguments(acc, name, arguments)
        {{{:., dot, [:ok, name]}, meta, arguments}, acc}

      meta[:no_parens] ->
        {{{:., dot, [target, name]}, meta, arguments}, acc}

      true ->
        {{{:., dot, [target, name]}, meta, arguments},
         %{acc | dynamic: [Atom.to_string(name) | acc.dynamic]}}
    end
  end

  defp visit({:&, _meta, [{:/, _, [{name, _, context}, _arity]}]} = node, acc)
       when is_atom(name) and is_atom(context),
       do: {node, local(acc, Atom.to_string(name))}

  defp visit({:sigil_H, _meta, [{:<<>>, _, parts}, _modifiers]} = node, acc) do
    template = parts |> Enum.filter(&is_binary/1) |> Enum.join()
    {node, template(acc, template)}
  end

  defp visit({:{}, _meta, [module, name, _arguments]} = node, acc) when is_atom(name),
    do: {node, named(acc, module, name)}

  defp visit({module, name} = node, acc) when is_atom(name) and is_tuple(module),
    do: {node, named(acc, module, name)}

  defp visit({:plug, _meta, [name | _options]} = node, acc) when is_atom(name),
    do: {node, local(acc, Atom.to_string(name))}

  defp visit({:apply, _meta, [module, name | _arguments]} = node, acc) when is_atom(name),
    do: {node, named(acc, module, name)}

  defp visit({:__aliases__, _meta, _parts} = node, acc),
    do: {node, %{acc | values: [expand(acc, node) | acc.values]}}

  defp visit({:__MODULE__, _meta, context} = node, acc) when is_atom(context),
    do: {node, %{acc | values: [hd(acc.modules) | acc.values]}}

  defp visit({name, _meta, arguments} = node, acc) when is_atom(name) and is_list(arguments),
    do: {node, local(acc, Atom.to_string(name))}

  defp visit(node, acc), do: {node, acc}

  defp leave({kind, _meta, _arguments} = node, acc) when kind in [:defmodule, :quote],
    do: {node, %{acc | modules: tl(acc.modules)}}

  defp leave(node, acc), do: {node, acc}

  # `Function.capture(Mod, :fun, 1)`, `function_exported?(Mod, :fun, 1)` and
  # `Kernel.apply(Mod, :fun, args)` name a function by an atom.
  defp named_in_arguments(acc, call, [module, name | _rest])
       when call in [:apply, :capture, :function_exported?] and is_atom(name),
       do: named(acc, module, name)

  defp named_in_arguments(acc, _call, _arguments), do: acc

  # A function named by a tuple is handed to whoever calls it, so the call
  # counts as one from another module.
  defp named(acc, module, name) do
    if module?(module) do
      reference = {"(reference)", expand(acc, module), Atom.to_string(name)}
      %{acc | calls: [reference | acc.calls]}
    else
      %{acc | dynamic: [Atom.to_string(name) | acc.dynamic]}
    end
  end

  defp template(acc, template) do
    locals =
      Regex.scan(~r/<\.([a-z_][a-z0-9_]*[!?]?)[\s>\/]/, template) ++
        Regex.scan(~r/(?<![.\w])([a-z_][a-z0-9_]*[!?]?)\(/, template)

    remotes =
      Regex.scan(
        ~r/([A-Z][A-Za-z0-9]*(?:\.[A-Z][A-Za-z0-9]*)*)\.([a-z_][a-z0-9_]*[!?]?)[\s(\/>]/,
        template
      )

    dynamic = Regex.scan(~r/[a-z_\]\)]\.([a-z_][a-z0-9_]*[!?]?)\(/, template)

    acc = Enum.reduce(locals, acc, fn [_match, name], acc -> local(acc, name) end)

    acc =
      Enum.reduce(remotes, acc, fn [_match, module, name], acc ->
        call(acc, expand_text(acc, module), name)
      end)

    %{acc | dynamic: Enum.map(dynamic, &List.last/1) ++ acc.dynamic}
  end

  # A local call reaches the module itself and every module it imports.
  defp local(acc, name) do
    module = hd(acc.modules)
    Enum.reduce([module | Map.get(acc.imports, module, [])], acc, &call(&2, &1, name))
  end

  defp call(acc, module, name), do: %{acc | calls: [{hd(acc.modules), module, name} | acc.calls]}

  defp define(acc, head),
    do: %{acc | defined: [{hd(acc.modules), head |> name_of() |> Atom.to_string()} | acc.defined]}

  defp put_alias(acc, as, full) do
    module = hd(acc.modules)
    %{acc | aliases: Map.update(acc.aliases, module, %{as => full}, &Map.put(&1, as, full))}
  end

  defp module?({:__aliases__, _meta, _parts}), do: true
  defp module?({:__MODULE__, _meta, context}) when is_atom(context), do: true
  defp module?(module) when is_atom(module), do: true
  defp module?(_target), do: false

  defp expand(acc, {:__MODULE__, _meta, _context}), do: hd(acc.modules)

  defp expand(acc, {:__aliases__, _meta, [{:__MODULE__, _, _} | rest]}),
    do: Enum.join([hd(acc.modules) | Enum.map(rest, &Atom.to_string/1)], ".")

  defp expand(acc, {:__aliases__, _meta, parts}),
    do: expand_text(acc, Enum.map_join(parts, ".", &Atom.to_string/1))

  defp expand(_acc, module) when is_atom(module),
    do: module |> Atom.to_string() |> String.replace_prefix("Elixir.", "")

  defp expand(_acc, _module), do: "?"

  defp expand_text(acc, text) do
    [first | rest] = String.split(text, ".")
    aliases = Map.get(acc.aliases, hd(acc.modules), %{})
    Enum.join([Map.get(aliases, first, first) | rest], ".")
  end

  defp name_of({:when, _meta, [head | _guards]}), do: name_of(head)
  defp name_of({name, _meta, _arguments}), do: name

  defp head_arguments({:when, meta, [head | guards]}),
    do: {:when, meta, [head_arguments(head) | guards]}

  defp head_arguments({_name, _meta, arguments}) when is_list(arguments), do: arguments
  defp head_arguments(_head), do: []
end
