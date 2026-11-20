defmodule Ryker.ControlPlane.RepositoryChoices do
  @moduledoc "The last verified picker list, available for selection while GitHub confirms current access."
  use Agent

  @ttl_ms 60_000

  def start_link(_options), do: Agent.start_link(fn -> nil end, name: __MODULE__)

  def begin(scope) do
    ticket = make_ref()
    now = System.monotonic_time(:millisecond)

    Agent.get_and_update(__MODULE__, fn state ->
      {choices, expires} =
        case state do
          {^scope, _previous, rows, until} when until > now -> {rows, until}
          _missing -> {[], now}
        end

      {{ticket, choices}, {scope, ticket, choices, expires}}
    end)
  end

  def finish(ticket, rows) do
    Agent.update(__MODULE__, fn
      {scope, ^ticket, _old, _expires} ->
        {scope, ticket, rows, System.monotonic_time(:millisecond) + @ttl_ms}

      newer ->
        newer
    end)
  end

  def scope(view, actor) do
    key = Enum.find(view.credentials, &(&1.kind == :github_private_key and &1.name == "primary"))

    {actor, view.host_ref, view.revision, view.snapshot.github.app_id,
     view.snapshot.github.api_url, key && key.fingerprint}
  end
end
