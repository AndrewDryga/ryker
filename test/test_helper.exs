# The accelerated thirty-day retention simulation drives several thousand
# sessions through real custody and takes minutes; `make check` includes it.
# assert_receive, assert_patch and assert_redirect wait this long for a message
# that has not arrived yet. ExUnit's 100 ms missed a LiveView patch sent from
# handle_info while the gate shared the machine with five agents' builds
# (2026-09-28); a longer wait costs only a test that is failing anyway.
ExUnit.start(capture_log: true, exclude: [:simulation], assert_receive_timeout: 1_000)

:ok =
  :logger.add_primary_filter(
    :dropped_test_clients,
    {&Ryker.TestSupport.LogFilters.dropped_client/2, nil}
  )

if Process.whereis(Ryker.Repo) do
  Ecto.Adapters.SQL.Sandbox.mode(Ryker.Repo, :manual)
end
