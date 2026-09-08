# Run with MIX_ENV=test scripts/elixir-mix.sh run --no-start scripts/refresh-world-tool-catalogs.exs.
# These are generated host schemas, not captured model responses. Preserve the
# recorded external tool world and catalog references exactly as JSON values.
tools = Responder.StateTools.Tools.list(capabilities: [:event_waits, :publication, :schedules])

for path <- Path.wildcard("testdata/scenarios/*/tool-catalog.json") do
  catalog = path |> File.read!() |> Jason.decode!()

  case catalog do
    %{"version" => 1, "catalog_ref" => _reference} ->
      :ok

    %{"version" => 1, "servers" => servers} ->
      unless Enum.count(servers, &(&1["name"] == "responder-state")) == 1,
        do: raise("expected one Responder schema owner in #{path}")

      updated =
        Map.put(
          catalog,
          "servers",
          Enum.map(servers, fn
            %{"name" => "responder-state"} = server -> Map.put(server, "tools", tools)
            server -> server
          end)
        )

      if updated != catalog do
        File.write!(path, Jason.encode!(updated, pretty: true) <> "\n")
        IO.puts(path)
      end

    _ ->
      raise("unsupported tool catalog in #{path}")
  end
end
