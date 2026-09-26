defmodule Ryker.Settings.EnvironmentsTest do
  use Ryker.DataCase, async: false

  import Ecto.Query

  alias Ryker.Settings
  alias Ryker.Settings.{Edit, EmisarConnection, Environment}

  @actor "control-plane:local"

  setup do
    {:ok, snapshot} = Settings.initialize(@actor)

    snapshot =
      Enum.reduce(~w(payments ledger runbooks), snapshot, fn ref, current ->
        {:ok, saved} = Settings.put_repository(%{ref: ref}, current.installation.revision, @actor)
        saved
      end)

    %{snapshot: snapshot}
  end

  # The first repository of an environment is the one work changes when
  # nothing chose another, so the order an operator gives is the authority: a
  # list that came back sorted by name would silently change that default.
  test "an environment keeps its repositories in the order given, the first as the default",
       %{snapshot: snapshot} do
    assert {:ok, saved} =
             Settings.put_environment(
               %{
                 ref: "production",
                 display_name: "Production",
                 description: "Customer traffic",
                 repositories: ["runbooks", "payments", "ledger"]
               },
               snapshot.installation.revision,
               @actor
             )

    assert [%Environment{ref: "production", parallel_goal_limit: 3} = environment] =
             saved.environments

    assert Environment.repository_refs(environment) == ["runbooks", "payments", "ledger"]

    assert Enum.map(environment.repositories, &{&1.repository_ref, &1.position}) == [
             {"runbooks", 0},
             {"payments", 1},
             {"ledger", 2}
           ]

    assert {:ok, reordered} =
             Settings.put_environment(
               %{ref: "production", repositories: ["ledger", "runbooks"]},
               saved.installation.revision,
               @actor
             )

    assert [environment] = reordered.environments
    assert Environment.repository_refs(environment) == ["ledger", "runbooks"]
    assert environment.display_name == "Production"

    # Saving the same list again is not an edit.
    assert {:ok, ^reordered} =
             Settings.put_environment(
               %{ref: "production", repositories: ["ledger", "runbooks"]},
               reordered.installation.revision,
               @actor
             )

    assert Repo.all(Edit) |> Enum.map(& &1.domain) |> Enum.frequencies() ==
             %{installation: 1, repositories: 3, environments: 2}
  end

  # Chat and every conversation without its own setting use the default, so
  # two defaults would make the answer depend on which row a query saw first.
  test "one environment is the default, and choosing another moves it", %{snapshot: snapshot} do
    assert Environment.default(snapshot) == nil

    {:ok, saved} =
      Settings.put_environment(
        %{ref: "production", display_name: "Production", is_default: true},
        snapshot.installation.revision,
        @actor
      )

    assert %Environment{ref: "production"} = Environment.default(saved)

    {:ok, saved} =
      Settings.put_environment(
        %{ref: "staging", display_name: "Staging", is_default: true, repositories: ["payments"]},
        saved.installation.revision,
        @actor
      )

    assert %Environment{ref: "staging"} = Environment.default(saved)

    assert Enum.map(saved.environments, &{&1.ref, &1.is_default}) == [
             {"production", false},
             {"staging", true}
           ]

    {:ok, saved} =
      Settings.put_environment(
        %{ref: "staging", is_default: false},
        saved.installation.revision,
        @actor
      )

    assert Environment.default(saved) == nil
  end

  # Removing an environment a channel or a webhook source selects would move
  # that conversation's work somewhere nobody chose, so the refusal names who
  # still selects it.
  test "an environment a channel or a webhook source selects cannot be removed",
       %{snapshot: snapshot} do
    {:ok, saved} =
      Settings.put_environment(
        %{ref: "production", display_name: "Production", repositories: ["payments"]},
        snapshot.installation.revision,
        @actor
      )

    select_in_channel!("production")

    {:ok, saved} =
      Settings.put_webhook_source(
        %{
          name: "alerts",
          adapter_kind: :universal,
          auth_kind: :hmac_sha256,
          secret_name: "alerts",
          destination_transport: "slack",
          destination_conversation_ref: "slack:T0123456789:C0123456789",
          environment_ref: "production"
        },
        saved.installation.revision,
        @actor
      )

    assert {:error, {:invalid_settings, [ref: {:referenced, %{channels: 1, webhook_sources: 1}}]}} =
             Settings.delete_environment("production", saved.installation.revision, @actor)

    assert {:ok, ^saved} = Settings.fetch()

    Repo.delete_all(from(c in "slack_channel_configurations"))

    {:ok, saved} =
      Settings.delete_webhook_source("alerts", saved.installation.revision, @actor)

    assert {:ok, saved} =
             Settings.delete_environment("production", saved.installation.revision, @actor)

    assert saved.environments == []
    assert Repo.aggregate(from(r in "environment_repository_settings"), :count) == 0
  end

  test "a repository in an environment cannot be deleted", %{snapshot: snapshot} do
    {:ok, saved} =
      Settings.put_environment(
        %{ref: "production", display_name: "Production", repositories: ["payments", "ledger"]},
        snapshot.installation.revision,
        @actor
      )

    assert {:error, {:invalid_settings, [{:ref, :referenced}]}} =
             Settings.delete_repository("ledger", saved.installation.revision, @actor)

    assert {:ok, saved} =
             Settings.delete_repository("runbooks", saved.installation.revision, @actor)

    assert Enum.map(saved.repositories, & &1.ref) == ["ledger", "payments"]
  end

  test "an environment names only a slug, known repositories and a known Emisar account",
       %{snapshot: snapshot} do
    revision = snapshot.installation.revision

    refusals = [
      {%{ref: "Production"}, {:ref, :format}},
      {%{ref: "prod_eu"}, {:ref, :format}},
      {%{display_name: nil}, {:display_name, :required}},
      {%{display_name: String.duplicate("x", 81)}, {:display_name, :length}},
      {%{description: String.duplicate("x", 501)}, {:description, :length}},
      {%{repositories: ["payments", "missing"]}, {:repositories, :unknown_repository}},
      {%{repositories: ["payments", "payments"]}, {:repositories, :list}},
      {%{emisar_connection_ref: "missing"}, {:emisar_connection_ref, :unknown_connection}},
      {%{parallel_goal_limit: 4}, {:parallel_goal_limit, :inclusion}}
    ]

    for {change, error} <- refusals do
      attributes = Map.merge(%{ref: "production", display_name: "Production"}, change)

      assert {:error, {:invalid_settings, errors}} =
               Settings.put_environment(attributes, revision, @actor),
             inspect(change)

      assert error in errors, "#{inspect(change)} gave #{inspect(errors)}"
    end
  end

  # Any repository of an environment may be the one a task changes, and then
  # every other one is mounted read-only beside it under its own name. Coop
  # cannot mount a repository named "primary" or one over 48 characters that
  # way, so an environment with several repositories refuses such a name in
  # any position. The first pass exempted the first repository, which
  # environments with a choice would then have been unable to mount.
  test "every repository of a shared environment can be mounted beside the one a task changes",
       %{snapshot: snapshot} do
    long = String.duplicate("r", 49)

    for companion <- ["primary", long] do
      {:ok, current} =
        Settings.put_repository(
          %{ref: companion},
          Settings.fetch!().installation.revision,
          @actor
        )

      for repositories <- [["payments", companion], [companion, "payments"]] do
        assert {:error, {:invalid_settings, [{:repositories, :companion_name}]}} =
                 Settings.put_environment(
                   %{ref: "production", display_name: "Production", repositories: repositories},
                   current.installation.revision,
                   @actor
                 ),
               inspect(repositories)
      end

      # Alone, it is always the working copy and needs no such name.
      assert {:ok, _saved} =
               Settings.put_environment(
                 %{ref: "solo", display_name: "Solo", repositories: [companion]},
                 current.installation.revision,
                 @actor
               )

      {:ok, _deleted} =
        Settings.delete_environment("solo", Settings.fetch!().installation.revision, @actor)
    end

    assert Settings.fetch!().installation.revision > snapshot.installation.revision
  end

  # An environment points at its Emisar account; removing the account under
  # it would leave work in that environment pinned to nothing.
  test "an Emisar account an environment uses cannot be deleted", %{snapshot: snapshot} do
    {:ok, saved} =
      Settings.put_emisar_connection(
        %{
          ref: "production",
          display_name: "Production approvals",
          rpc_url: "https://emisar.dev/api/mcp/rpc",
          account_ref: "account-production",
          verified_at: ~U[2026-09-25 12:00:00.000000Z]
        },
        snapshot.installation.revision,
        @actor
      )

    {:ok, saved} =
      Settings.put_environment(
        %{ref: "production", display_name: "Production", emisar_connection_ref: "production"},
        saved.installation.revision,
        @actor
      )

    connection = hd(saved.emisar_connections)

    assert {:error, [ref: {:referenced, %{environments: 1, sessions: 0, approvals: 0}}]} =
             EmisarConnection.deletable(connection, saved)

    assert {:error, {:invalid_settings, [ref: {:referenced, %{environments: 1}}]}} =
             Settings.delete_emisar_connection("production", saved.installation.revision, @actor)
  end

  defp select_in_channel!(environment_ref) do
    now = NaiveDateTime.utc_now()

    Repo.insert_all("slack_channel_configurations", [
      %{
        id: Ecto.UUID.bingenerate(),
        workspace_ref: "T0123456789",
        channel_ref: "C0123456789",
        environment_ref: environment_ref,
        alert_policy: "reply",
        invite_user_refs: [],
        invite_user_group_refs: [],
        revision: 1,
        saved_at: now,
        inserted_at: now,
        updated_at: now
      }
    ])
  end
end
