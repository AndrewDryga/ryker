defmodule Ryker.ControlPlane.LearningSwitchTest do
  @moduledoc """
  The Learning page's one switch, driven through the page the way a person
  uses it.
  """
  use Ryker.DataCase, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias Ryker.ControlPlane.{Actions, Endpoint, Projection}
  alias Ryker.Learning.Batch
  alias Ryker.Settings

  @endpoint Endpoint

  setup do
    previous = Application.get_env(:ryker, :learning)
    Application.put_env(:ryker, :learning, %{policy: "learning-switch-test"})

    on_exit(fn ->
      if previous,
        do: Application.put_env(:ryker, :learning, previous),
        else: Application.delete_env(:ryker, :learning)
    end)

    start_supervised!(
      {Endpoint,
       server: false,
       secret_key_base: String.duplicate("s", 64),
       pubsub_server: Ryker.PubSub.Server,
       live_view: [signing_salt: "learning-switch-test"],
       check_origin: ["//localhost:4321"],
       url: [host: "localhost", port: 4321],
       control_plane: %{
         actions: Actions.callbacks(),
         projection: Projection.callbacks(),
         observability: %{},
         csrf_secret: String.duplicate("s", 32)
       }}
    )

    {:ok, _snapshot} = Settings.initialize("control-plane:local")
    :ok
  end

  test "turning learning off asks first, and the page says it is off as soon as it is" do
    # QA, 2026-09-25: one click turned learning off with no question, and the
    # page's "Learning is on" stayed one step behind the button until a reload,
    # because the line read the running configuration before it had changed.
    {:ok, view, _html} = live(build_conn() |> Map.put(:host, "localhost"), "/memory/learning")
    refute has_element?(view, ".kit-status-line .state-word", "Learning is off")

    view |> element("button", "Turn off learning") |> render_click()
    assert has_element?(view, ".learning-switch [role=group]", "Turn off learning?")
    assert enabled?()

    view |> element(".learning-switch button", "Cancel") |> render_click()
    refute has_element?(view, ".learning-switch [role=group]")
    assert enabled?()

    view |> element("button", "Turn off learning") |> render_click()
    view |> element(".learning-switch [role=group] button.danger") |> render_click()

    refute enabled?()
    assert has_element?(view, ".kit-status-line .state-word", "Learning is off")
    assert has_element?(view, ".learning-switch button", "Turn on learning")

    # Turning it back on changes nothing that was learned, so it does not ask.
    view |> element("button", "Turn on learning") |> render_click()
    assert enabled?()
    refute has_element?(view, ".kit-status-line .state-word", "Learning is off")
    assert has_element?(view, ".learning-switch button", "Turn off learning")
  end

  test "the switch belongs to the Learning list alone; a batch's page leads back to it instead" do
    # Andrew, 2026-09-27: "i don't need turn off button on subpages". A
    # batch's page carried the list's switch opposite its title, and its way
    # back to the list was a small grey link under it.
    batch =
      Repo.insert!(%Batch{
        id: Ecto.UUID.generate(),
        scope_key: "learning-switch-test",
        transport: "slack",
        conversation_ref: "slack:T123:C456",
        execution_mode: :live,
        policy: "learning-switch-test",
        policy_digest: String.duplicate("a", 64),
        status: :applied,
        input_count: 1,
        completed_at: DateTime.utc_now()
      })

    conn = build_conn() |> Map.put(:host, "localhost")
    {:ok, page, _html} = live(conn, "/memory/learning?batch=#{batch.id}")
    refute has_element?(page, ".learning-switch")

    assert has_element?(
             page,
             ".page-header > nav.kit-back a[href='/memory/learning']",
             "All learning"
           )

    assert has_element?(page, ".page-heading h1", "Learning from Slack channel C456")

    {:ok, list, _html} = live(conn, "/memory/learning")
    assert has_element?(list, ".page-action .learning-switch button", "Turn off learning")
    refute has_element?(list, ".page-header nav.kit-back")
  end

  defp enabled? do
    {:ok, snapshot} = Settings.fetch()
    snapshot.learning.enabled
  end
end
