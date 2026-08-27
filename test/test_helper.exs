ExUnit.start(capture_log: true)

if Process.whereis(Responder.Repo) do
  Ecto.Adapters.SQL.Sandbox.mode(Responder.Repo, :manual)
end
