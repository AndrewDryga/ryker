defmodule Ryker.ControlPlane.ConfirmModalTest do
  @moduledoc """
  Andrew, 2026-09-27: "all removal confirmations can be modals otherwise that
  table line extends and design breaks (icon, button moves, etc)". A step that
  asks first asks in one modal over the page: the settings pages' own
  questions, and every confirmed action a list offers, such as Delete on a
  rule, which until then opened a bare confirmation page of its own.
  """
  use Ryker.DataCase, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias Ryker.Behaviors.Behavior
  alias Ryker.ControlPlane.{Actions, CSRF, Endpoint, Projection}
  alias Ryker.Fixtures.SavedEntities

  @endpoint Endpoint
  @secret String.duplicate("s", 32)

  setup do
    start_supervised!(
      {Endpoint,
       server: false,
       secret_key_base: String.duplicate("s", 64),
       pubsub_server: Ryker.PubSub.Server,
       live_view: [signing_salt: "confirm-modal-test"],
       check_origin: ["//localhost:4321"],
       url: [host: "localhost", port: 4321],
       control_plane: %{
         actions: Actions.callbacks(),
         projection: Projection.callbacks(),
         observability: %{},
         csrf_secret: @secret
       }}
    )

    :ok
  end

  # The rule's Delete sat in its row's menu and opened a page with the question
  # and nothing else; now it asks over the list, in the same words, and its
  # button posts the very action that page's button posted, token and all.
  test "Delete on a rule asks over the list and posts the same confirmed action" do
    source = SavedEntities.source!("slack:T123:C456")
    rule = rule!(source, "Watch Terraform applies.")
    path = "/actions/behavior/#{URI.encode_www_form(rule.ref)}/deleted"
    {:ok, view, _html} = open("/rules")

    refute has_element?(view, "#action-question")

    view |> element("form.action-control[action='#{path}']") |> render_submit()

    assert has_element?(view, "#action-question[role=alertdialog] h2", "Delete ")
    assert has_element?(view, "#action-question", "This instruction will no longer apply.")
    # The row that asked is as it was: the question is over the page, not in it.
    refute has_element?(view, "article[id='behavior-#{rule.ref}'] #action-question")
    assert has_element?(view, "#action-question button.danger[type=submit]", "Delete")

    [token] =
      view
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.query("#action-question form[method=post][action='#{path}'] input[name=_token]")
      |> LazyHTML.attribute("value")

    assert CSRF.valid?(@secret, "behavior:deleted", rule.ref, token)

    # Cancel closes it and changes nothing.
    view |> element("#action-question button", "Cancel") |> render_click()
    refute has_element?(view, "#action-question")
    assert Repo.get!(Behavior, rule.id).status == :active

    response =
      build_conn()
      |> Map.put(:host, "localhost")
      |> Plug.Conn.put_req_header("content-type", "application/x-www-form-urlencoded")
      |> post(path, URI.encode_query(%{"_token" => token}))

    assert response.status == 303
    assert Repo.get!(Behavior, rule.id).status == :deleted
  end

  test "a question about something already gone is not asked" do
    source = SavedEntities.source!("slack:T123:C456")
    rule = rule!(source, "Watch Terraform applies.")
    path = "/actions/behavior/#{URI.encode_www_form(rule.ref)}/deleted"
    {:ok, view, _html} = open("/rules")

    Repo.update!(Ecto.Changeset.change(Repo.get!(Behavior, rule.id), status: :deleted))
    view |> element("form.action-control[action='#{path}']") |> render_submit()

    refute has_element?(view, "#action-question")
  end

  defp open(path), do: live(build_conn() |> Map.put(:host, "localhost"), path)

  defp rule!(source, task) do
    SavedEntities.behavior!(
      source,
      :standing_assignment,
      %{
        "action" => "triage_alert",
        "expires_in" => "30d",
        "repository" => nil,
        "source_filter" => "human",
        "task" => task,
        "trigger" => "operational_alert"
      },
      scope_ref: "slack:T123:C456",
      expires_at: nil,
      identity_key: String.slice(task, 0, 120)
    )
  end
end
