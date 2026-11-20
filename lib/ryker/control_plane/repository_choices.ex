defmodule Ryker.ControlPlane.RepositoryChoices do
  @moduledoc "The last verified picker list, available for selection while GitHub confirms current access."
  use Agent

  @ttl_ms 60_000

  def start_link(_options), do: Agent.start_link(fn -> nil end, name: __MODULE__)

  # A disconnected mount can show the last list for this viewer. It neither
  # starts a discovery nor interferes with another visit's in-flight result.
  def preview(scope) do
    now = System.monotonic_time(:millisecond)
    Agent.get(__MODULE__, &elem(current(&1, scope, now), 0))
  end

  def begin(scope) do
    ticket = make_ref()
    now = System.monotonic_time(:millisecond)

    Agent.get_and_update(__MODULE__, fn state ->
      {choices, expires} = current(state, scope, now)

      {{ticket, choices}, {scope, ticket, choices, expires}}
    end)
  end

  defp current({scope, _ticket, rows, until}, scope, now) when until > now, do: {rows, until}
  defp current(_state, _scope, now), do: {[], now}

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
