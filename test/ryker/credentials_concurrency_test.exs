defmodule Ryker.CredentialsConcurrencyTest do
  @moduledoc """
  Two first saves of one credential race each other.

  A save read whether the credential existed and then inserted or replaced
  it, holding nothing in between, so the later of two first saves raised on
  the unique index instead of replacing the earlier (2026-10-04 review).

  These commit for real, on connections of their own, and remove what they
  wrote.
  """
  use Ryker.ConcurrencyCase, async: false
  alias Ecto.Adapters.SQL.Sandbox
  alias Ryker.Config
  alias Ryker.Credential
  alias Ryker.Credential.Event
  alias Ryker.Credentials
  alias Ryker.Repo

  @actor "control-plane:test"

  setup do
    Config.put_override(:credential_key, :binary.copy(<<23>>, 32))
  end

  test "two first saves of one credential both succeed and the later one is kept" do
    Sandbox.unboxed_run(Repo, fn ->
      name = "race-#{System.unique_integer([:positive])}"
      parent = self()

      try do
        first =
          unboxed_task(fn ->
            pause_after_reading!(parent)

            try do
              Credentials.put(:webhook, name, "first-secret-value", @actor)
            after
              :telemetry.detach({__MODULE__, self()})
            end
          end)

        assert_receive {:read, first_backend}, 5_000

        second =
          unboxed_task(fn ->
            send(parent, {:second_ready, backend_pid()})
            Credentials.put(:webhook, name, "second-secret-value", @actor)
          end)

        assert_receive {:second_ready, second_backend}, 5_000

        try do
          await_finished_or_blocked(second, second_backend, first_backend)
          send(first.pid, :save)

          assert {:ok, _first} = Task.await(first, 5_000)
          assert {:ok, _second} = Task.await(second, 5_000)
        after
          stop_tasks([first, second])
        end

        assert Credentials.fetch(:webhook, name) == {:ok, "second-secret-value"}

        assert Repo.all(
                 from(event in Event,
                   where: event.kind == :webhook and event.name == ^name,
                   order_by: [asc: event.inserted_at],
                   select: event.action
                 )
               ) == [:created, :replaced]
      after
        Repo.delete_all(
          from(event in Event, where: event.kind == :webhook and event.name == ^name)
        )

        Repo.delete_all(
          from(credential in Credential,
            where: credential.kind == :webhook and credential.name == ^name
          )
        )
      end
    end)
  end

  defp pause_after_reading!(parent) do
    :ok =
      :telemetry.attach(
        {__MODULE__, self()},
        [:ryker, :repo, :query],
        &__MODULE__.pause/4,
        {self(), parent, backend_pid()}
      )
  end

  # The first save has read that the credential does not exist yet and is
  # about to insert it.
  def pause(
        _event,
        _measurements,
        %{source: "integration_credentials", query: query},
        {saver, parent, backend}
      ) do
    if self() == saver and not Process.get(:paused?, false) and
         String.starts_with?(query, "SELECT") do
      Process.put(:paused?, true)
      send(parent, {:read, backend})

      receive do
        :save -> :ok
      after
        5_000 -> :ok
      end
    end
  end

  def pause(_event, _measurements, _metadata, _config), do: :ok
end
