# The accelerated thirty-day retention simulation drives several thousand
# sessions through real custody and takes minutes; `make check` includes it.
ExUnit.start(capture_log: true, exclude: [:simulation])

if Process.whereis(Responder.Repo) do
  Ecto.Adapters.SQL.Sandbox.mode(Responder.Repo, :manual)
end
