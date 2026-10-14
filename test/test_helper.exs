# The accelerated thirty-day retention simulation drives several thousand
# sessions through real custody and takes minutes; `make check` includes it.
# assert_receive, assert_patch and assert_redirect wait this long for a message
# that has not arrived yet. ExUnit's 100 ms missed a LiveView patch sent from
# handle_info while the gate shared the machine with five agents' builds
# (2026-09-28), and the second that replaced it failed a gate under load on
# 2026-10-14; a longer wait costs only a test that is failing anyway. A test
# that claims something happens soon names its own, shorter, wait.
# scripts/elixir-test.sh names RYKER_TEST_TIMES to learn each serial file's time.
formatters =
  if System.get_env("RYKER_TEST_TIMES"),
    do: [ExUnit.CLIFormatter, Ryker.TestSupport.FileTimes],
    else: [ExUnit.CLIFormatter]

ExUnit.start(
  capture_log: true,
  exclude: [:simulation],
  assert_receive_timeout: 5_000,
  formatters: formatters
)

:ok =
  :logger.add_primary_filter(
    :dropped_test_clients,
    {&Ryker.TestSupport.LogFilters.dropped_client/2, nil}
  )

if Process.whereis(Ryker.Repo) do
  Ecto.Adapters.SQL.Sandbox.mode(Ryker.Repo, :manual)
end
