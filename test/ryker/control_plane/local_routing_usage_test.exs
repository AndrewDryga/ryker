defmodule Ryker.ControlPlane.LocalRoutingUsageTest do
  @moduledoc """
  Usage & cost says how the local routing model compares (Andrew,
  2026-09-27: "with accuracy and cost measured on Usage"): how many routing
  prompts it answered, how many answers routing's checks took and how many
  decided what the provider decided, how long it took beside the provider,
  what the provider spent on those messages, and where it decided
  differently, each opening its request's timeline.
  """
  use Ryker.DataCase, async: false

  alias Ryker.Admission.Decision
  alias Ryker.ControlPlane.{UsagePage, UsageProjection}
  alias Ryker.Fixtures.LocalRouting, as: Harvested
  alias Ryker.Ingress.Inbox
  alias Ryker.Ingress.Inbox.EntryChangeset
  alias Ryker.Learning.Observations
  alias Ryker.LocalRouting
  alias Ryker.LocalRouting.Comparison
  alias Ryker.Settings
  alias Ryker.Slack.Input, as: SlackInput

  @actor "control-plane:local"
  @model "qwen2.5:3b"

  test "while the local routing model is off, Usage says so in one line and links to its setting" do
    {:ok, _snapshot} = Settings.initialize(@actor)
    section = section!()

    assert text(section, "h2") == "Local routing model"
    assert [line] = LazyHTML.query(section, ".kit-status-line") |> Enum.to_list()
    assert LazyHTML.text(line) =~ "Off"

    assert LazyHTML.attribute(LazyHTML.query(line, "a"), "href") == [
             "/settings/models#local-routing"
           ]

    assert Enum.empty?(LazyHTML.query(section, ".kit-counts"))
    assert Enum.empty?(LazyHTML.query(section, ".entity-row"))
  end

  test "Usage shows how often the local model was valid and agreed, what it took, what the provider spent, and where it differed" do
    {:ok, snapshot} = Settings.initialize(@actor)

    {:ok, _saved} =
      Settings.save_work(
        %{
          local_routing_mode: :shadow,
          local_routing_endpoint: "http://host.docker.internal:11434/v1",
          local_routing_model: @model
        },
        snapshot.installation.revision,
        @actor
      )

    # Four answers: two agreeing, one deciding otherwise, one refused by
    # routing's checks. One more could not reach the model, one waits.
    agreed = decided!("Ev-usage-agreed-1", Harvested.hi_quick_reply())

    compared!(agreed, Harvested.hi_again_quick_reply(),
      agrees: true,
      local_ms: 900,
      cost: "0.028316",
      provider_ms: 16_770
    )

    also = decided!("Ev-usage-agreed-2", Harvested.hi_quick_reply())

    compared!(also, Harvested.hi_quick_reply(),
      agrees: true,
      local_ms: 1_100,
      cost: "0.020000",
      provider_ms: 9_000
    )

    differed = decided!("Ev-usage-differed", Harvested.hi_quick_reply())

    compared!(differed, Harvested.deploy_script_reply(),
      agrees: false,
      differing: ["action", "work_class"],
      local_ms: 1_300,
      cost: "0.030000",
      provider_ms: 12_000
    )

    refused = decided!("Ev-usage-invalid", Harvested.hi_quick_reply())

    compared!(refused, Harvested.hi_again_old_contract(),
      valid: false,
      local_ms: 5_000,
      cost: "0.025000",
      provider_ms: 8_000
    )

    failed!(decided!("Ev-usage-failed", Harvested.hi_quick_reply()))
    waiting!(decided!("Ev-usage-waiting", Harvested.hi_quick_reply()))

    section = section!()
    assert text(section, ".kit-status-line") =~ "Comparing"
    assert text(section, ".kit-status-line") =~ @model

    assert counts(section, ".kit-counts:not(.kit-counts-secondary)") == [
             {"4", "comparisons"},
             {"75%", "valid"},
             {"50%", "agreed with the provider"},
             {"1.2s", "median local time"},
             {"≈ $0.10", "provider cost of these messages"}
           ]

    assert counts(section, ".kit-counts-secondary") == [
             {"10.5s", "median provider time"},
             {"≈ $0.05", "of it on messages the local model agreed on"},
             {"1", "waiting"},
             {"1", "could not be asked"}
           ]

    # Only the answer that would have made Ryker do something else is a
    # disagreement; the refused one counts against valid and is listed
    # apart, with why.
    assert [row] =
             LazyHTML.query(section, "#local-routing-differences .entity-row") |> Enum.to_list()

    assert text(row, ".entity-name") == Harvested.hi_text()

    assert LazyHTML.attribute(LazyHTML.query(row, ".entity-name a"), "href") == [
             "/timeline/ingress-input%3A#{differed.id}#admission-#{differed.id}-1"
           ]

    assert text(row, ".entity-text") ==
             "The provider chose a quick reply. The local model chose to reply."

    assert text(row, ".entity-meta") =~ "Differs in what to do and kind of work"

    assert [refused_row] =
             LazyHTML.query(section, "#local-routing-refused .entity-row") |> Enum.to_list()

    assert text(refused_row, ".entity-text") ==
             "The local model gave a decision routing could not read. " <>
               "The provider chose a quick reply."
  end

  # The Mac running Ollama went to sleep: comparisons stop coming back, and
  # the section says so where the numbers would otherwise just stop moving.
  test "when the local model's last answer never came, Usage says so and why" do
    {:ok, snapshot} = Settings.initialize(@actor)

    {:ok, _saved} =
      Settings.save_work(
        %{
          local_routing_mode: :shadow,
          local_routing_endpoint: "http://host.docker.internal:11434/v1",
          local_routing_model: @model
        },
        snapshot.installation.revision,
        @actor
      )

    earlier = decided!("Ev-usage-earlier", Harvested.hi_quick_reply())

    compared!(earlier, Harvested.hi_quick_reply(),
      agrees: true,
      local_ms: 900,
      cost: "0.028316",
      provider_ms: 16_770
    )

    failed!(decided!("Ev-usage-asleep", Harvested.hi_quick_reply()), DateTime.utc_now())

    state = LazyHTML.query(section!(), ".kit-status-line .state-word")
    assert LazyHTML.text(state) == "Not reaching the local model"
    assert LazyHTML.attribute(state, "data-tone") == ["warn"]

    assert LazyHTML.attribute(state, "title") == [
             "could not reach the local model: connection refused"
           ]
  end

  # 2026-09-30, the first comparison on the live install: qwen2.5:3b answered
  # "Which repositories can you read in this environment?" by starting work
  # on earlier work it made up, and routing's checks refused it. Usage then
  # said "Every valid answer decided what the provider decided" when there
  # was no valid answer at all, called the provider's spend on agreed
  # messages "Not measured" when it was nothing, and said nowhere why the
  # answer was refused, so 0% valid read as a broken setup rather than a
  # model that makes things up.
  test "a refused answer says why in plain words, and no valid answer claims no agreement" do
    shadow!()
    refused = decided!("Ev-usage-made-up-work", Harvested.hi_quick_reply())

    compared!(refused, Harvested.made_up_earlier_work(),
      valid: false,
      invalid_reason: "rejected:unknown_candidate",
      local_ms: 6_044,
      cost: "0.0017",
      provider_ms: 7_400
    )

    section = section!()

    refute LazyHTML.text(section) =~ "Every valid answer decided what the provider decided"
    assert Enum.empty?(LazyHTML.query(section, "#local-routing-differences"))

    assert {"$0", "of it on messages the local model agreed on"} in counts(
             section,
             ".kit-counts-secondary"
           )

    assert text(section, "#local-routing-refused h2") == "Answers routing refused"
    assert [row] = LazyHTML.query(section, "#local-routing-refused .entity-row") |> Enum.to_list()
    assert text(row, ".entity-name") == Harvested.hi_text()

    assert LazyHTML.attribute(LazyHTML.query(row, ".entity-name a"), "href") == [
             "/timeline/ingress-input%3A#{refused.id}#admission-#{refused.id}-1"
           ]

    assert text(row, ".entity-text") ==
             "The local model named earlier work that was not offered. " <>
               "The provider chose a quick reply."
  end

  test "an open Usage page redraws when a comparison is queued or settles" do
    assert {LocalRouting, :subscribe_comparisons, []} in UsagePage.subscriptions()
  end

  defp shadow! do
    {:ok, snapshot} = Settings.initialize(@actor)

    {:ok, _saved} =
      Settings.save_work(
        %{
          local_routing_mode: :shadow,
          local_routing_endpoint: "http://host.docker.internal:8181/v1",
          local_routing_model: @model
        },
        snapshot.installation.revision,
        @actor
      )
  end

  defp section! do
    %{"window" => "7d"}
    |> UsageProjection.page()
    |> UsagePage.render()
    |> IO.iodata_to_binary()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("#local-routing")
  end

  defp text(node, selector),
    do:
      node
      |> LazyHTML.query(selector)
      |> LazyHTML.text()
      |> String.replace(~r/\s+/, " ")
      |> String.trim()

  defp counts(section, selector) do
    section
    |> LazyHTML.query(selector <> " .kit-count")
    |> Enum.map(fn count ->
      {text(count, "b"),
       count
       |> LazyHTML.text()
       |> String.replace(~r/\s+/, " ")
       |> String.trim()
       |> String.replace_prefix(text(count, "b") <> " ", "")}
    end)
  end

  defp decided!(event_ref, provider_answer) do
    {:ok, input} =
      SlackInput.new(%{
        actor: %{kind: :user, ref: "U123"},
        channel_ref: "C456",
        content: %{"text" => Harvested.hi_text()},
        event_kind: :message,
        event_ref: event_ref,
        message_ref: "1787832001.#{:erlang.phash2(event_ref, 999_999)}",
        occurred_at: ~U[2026-09-27 14:53:25.000000Z],
        revision: 1,
        thread_ref: nil,
        workspace_ref: "TE5D7C8842D32"
      })

    {:ok, %{entry: entry}} = Inbox.record(input)
    {:ok, decision} = provider_answer |> Jason.decode!() |> Decision.parse()

    entry
    |> EntryChangeset.decide(decision, "coop-admission:#{event_ref}", nil)
    |> Repo.update!()
  end

  defp compared!(entry, answer, options) do
    valid = Keyword.get(options, :valid, true)
    agrees = if valid, do: Keyword.fetch!(options, :agrees)
    now = DateTime.utc_now()

    comparison(entry, %{
      status: :compared,
      attempt_count: 1,
      valid: valid,
      agrees: agrees,
      invalid_reason:
        if(valid, do: nil, else: Keyword.get(options, :invalid_reason, "decision:fields")),
      differing_fields: Keyword.get(options, :differing, []),
      local_answer: answer,
      local_ms: Keyword.fetch!(options, :local_ms),
      provider_cost_usd: Decimal.new(Keyword.fetch!(options, :cost)),
      provider_cost_estimated: true,
      provider_ms: Keyword.fetch!(options, :provider_ms),
      compared_at: now
    })
  end

  # Given up an hour ago, unless said otherwise.
  defp failed!(entry, at \\ DateTime.add(DateTime.utc_now(), -3_600)),
    do:
      comparison(entry, %{
        status: :failed,
        attempt_count: 4,
        last_error: "could not reach the local model: connection refused",
        inserted_at: at,
        updated_at: at
      })

  defp waiting!(entry), do: comparison(entry, %{status: :pending})

  defp comparison(entry, fields) do
    now = DateTime.utc_now()

    Repo.insert!(
      struct!(
        Comparison,
        Map.merge(
          %{
            input_id: entry.id,
            source_identity: Observations.source_identity(entry),
            generation: 1,
            execution_mode: :live,
            local_model: @model,
            inserted_at: now,
            updated_at: now
          },
          fields
        )
      )
    )
  end
end
