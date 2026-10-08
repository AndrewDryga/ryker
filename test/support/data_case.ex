defmodule Ryker.DataCase do
  @moduledoc false
  use ExUnit.CaseTemplate
  alias Ecto.Adapters.SQL.Sandbox

  using do
    quote do
      @moduletag :database
      import Ryker.DataCase, only: [errors_on: 1]
      alias Ryker.Repo
    end
  end

  @doc """
  A changeset's errors by field, each message with its options filled in, so
  a test asserts what a person reads rather than that some error is there.
  """
  def errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, options} ->
      Regex.replace(~r"%{(\w+)}", message, fn _, key ->
        options |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end

  setup tags do
    options = [shared: not tags[:async]]

    options =
      if isolation = tags[:isolation], do: [{:isolation, isolation} | options], else: options

    # A long accelerated simulation owns one connection for its whole run.
    options =
      if timeout = tags[:ownership_timeout],
        do: [{:ownership_timeout, timeout} | options],
        else: options

    owner = Sandbox.start_owner!(Ryker.Repo, options)

    on_exit(fn ->
      try do
        if tags[:async], do: refuse_settings_write!(owner)
      after
        Sandbox.stop_owner(owner)
      end
    end)
  end

  # Saving settings takes the one installation row and the settings lock, and
  # a test keeps both until its transaction ends, so async tests that save
  # settings run one at a time. On 2026-10-07 twenty-three such modules
  # queued behind each other under gate load until two waited past the 15 s
  # query timeout. A test that saves settings runs serially, with a database
  # of its own in the gate.
  defp refuse_settings_write!(owner) do
    Sandbox.allow(Ryker.Repo, owner, self())

    case Ryker.Repo.query("SELECT EXISTS (SELECT 1 FROM installation_settings)") do
      {:ok, %{rows: [[true]]}} ->
        raise "an async test saved settings; make its module `async: false`"

      _none_or_unreadable ->
        :ok
    end
  end
end
