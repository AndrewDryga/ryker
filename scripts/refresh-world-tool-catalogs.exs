# Run with MIX_ENV=test scripts/elixir-mix.sh run --no-start scripts/refresh-world-tool-catalogs.exs.
# These are generated host schemas, not captured model responses. Preserve the
# recorded external tool world and catalog references exactly as JSON values.
tools = Ryker.StateTools.Tools.list(capabilities: [:event_waits, :publication, :schedules])

# From the checkout, wherever it runs: a relative wildcard found nothing outside
# it and said nothing (2026-10-04 review).
for path <- Path.wildcard(Path.expand("../testdata/scenarios/*/tool-catalog.json", __DIR__)) do
  catalog = path |> File.read!() |> Jason.decode!()

  case catalog do
    %{"version" => 1, "catalog_ref" => _reference} ->
      :ok

    %{"version" => 1, "servers" => servers} ->
      unless Enum.count(servers, &(&1["name"] == "controller-tools")) == 1,
        do: raise("expected one Ryker schema owner in #{path}")

      updated =
        Map.put(
          catalog,
          "servers",
          Enum.map(servers, fn
            %{"name" => "controller-tools"} = server ->
              Map.put(server, "tools", tools)

            server ->
              server
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
