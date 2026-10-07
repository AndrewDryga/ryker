defmodule Ryker.Admission.CandidateSearchTest do
  use Ryker.DataCase, async: true
  import Ecto.Query
  alias Ryker.Admission.{CandidateSearch, CorrelationScope, Ranking}
  alias Ryker.Episodes
  alias Ryker.Episodes.{Command, CorrelationClaims, Episode, RoutingDigests}
  alias Ryker.Ingress.{Input, RecallText}
  alias Ryker.QueryWork
  alias Ryker.Repo
  alias Ryker.Slack.ChannelMembership
  alias Ryker.Slack.Input, as: SlackInput
  alias Ryker.Work.Session

  @workspace "TCANDIDATES"
  @now ~U[2026-09-11 12:00:00.000000Z]

  setup do
    Enum.each(~w(CDEVOPS CALERTS CENGINEERING), &joined!/1)
    :ok
  end

  test "a matching incident in another channel survives more than a hundred nearer distractors" do
    # Admission only ever searched the destination conversation, so the #devops
    # alert and the #alerts alert for one outage became two episodes with two
    # owners. Ranking by location and time alone reproduces that: the match has
    # to survive noise that is newer, nearer and more numerous.
    match =
      episode!("routing:cross-channel",
        channel_ref: "CDEVOPS",
        text: "Postgres primary pgsql-prod-01 is unreachable and replication is stalled"
      )

    for index <- 1..120 do
      channel = if rem(index, 2) == 0, do: "CALERTS", else: "CENGINEERING"

      episode!("routing:distractor-#{index}",
        channel_ref: channel,
        text: "Routine deploy #{index} finished for the marketing website",
        updated_at: DateTime.add(@now, -index, :second),
        thread_ref: if(channel == "CALERTS" and index <= 44, do: "1789000000.000100")
      )
    end

    result =
      search!(
        channel_ref: "CALERTS",
        thread_ref: "1789000000.000100",
        text: "Is pgsql-prod-01 still unreachable? Replication is stalled on the primary."
      )

    offered = Enum.map(result.selected, & &1.episode.id)
    assert match.id in offered
    assert length(offered) <= 20

    assert result.receipt["lanes"]["thread"]["returned"] >= 20
    assert result.receipt["examined"] > 20
    assert result.receipt["omitted"] > 0
    assert result.receipt["cutoff_reason"] =~ "non-local"
  end

  # The "Same links or IDs" replay over the Tenant alert history (2026-09-30, ID1): every shared
  # identifier scored 350 points, more than a perfect match in words and meaning, even
  # nomad-hst02, which 54 requests named. A host most requests name says little about which
  # request a message is about; a run ID only one request has says it is that one.
  test "an identifier most requests share does not outrank the request the message is about" do
    about =
      episode!("routing:about",
        channel_ref: "CDEVOPS",
        text: "Checkout payment webhook keeps timing out"
      )

    for index <- 1..6 do
      episode!("routing:host-#{index}",
        channel_ref: "CDEVOPS",
        text: "Disk usage alert #{index} on nomad-hst02",
        updated_at: DateTime.add(@now, -index, :second)
      )

      episode!("routing:elsewhere-#{index}",
        channel_ref: "CENGINEERING",
        text: "Marketing site deploy #{index} finished",
        updated_at: DateTime.add(@now, -index, :second)
      )
    end

    result =
      search!(
        channel_ref: "CDEVOPS",
        text: "The checkout payment webhook keeps timing out on nomad-hst02"
      )

    assert hd(result.selected).episode.id == about.id

    rare = episode!("routing:rare", channel_ref: "CDEVOPS", text: "Deploy run run-7f2a1c failed")
    result = search!(channel_ref: "CDEVOPS", text: "Why did run-7f2a1c fail on nomad-hst02?")
    assert hd(result.selected).episode.id == rare.id
  end

  # The replay over the Tenant alert history (2026-09-30, ID7): an alert's Grafana rule page sat
  # only on its attachment title, never searched, so a repeat of one rule's alert found its
  # earlier work by words alone, tied with every alert worded like it.
  test "an alert finds the work for its rule by the rule page it links to" do
    reload =
      "https://grafana.example.net/alerting/grafana/va1-traefik-reload-frequency/view?orgId=1"

    other =
      "https://grafana.example.net/alerting/grafana/va2-traefik-reload-frequency/view?orgId=1"

    same_rule =
      episode!("routing:rule-page",
        channel_ref: "CALERTS",
        content: grafana_alert(reload),
        updated_at: DateTime.add(@now, -7200, :second)
      )

    episode!("routing:other-rule-page",
      channel_ref: "CALERTS",
      content: grafana_alert(other),
      updated_at: DateTime.add(@now, -60, :second)
    )

    result = search!(channel_ref: "CALERTS", content: grafana_alert(reload))
    assert hd(result.selected).episode.id == same_rule.id
    assert reload in result.receipt["identifiers"]
  end

  test "the search record keeps the words, links and places it searched with" do
    # The receipt kept only counts, so the timeline could say "Nothing found"
    # but never what was looked for or where.
    result =
      search!(
        channel_ref: "CALERTS",
        thread_ref: "1789000000.000200",
        text:
          "Is pgsql-prod-01 still unreachable? See https://grafana.example.com/d/abc?orgId=1 for the stalled replication."
      )

    receipt = result.receipt
    assert "pgsql-prod-01" in receipt["words"]
    assert "unreachable" in receipt["words"]
    refute "the" in receipt["words"]
    assert Enum.any?(receipt["identifiers"], &String.contains?(&1, "grafana.example.com"))
    assert receipt["in_thread"] == true
    assert {:ok, _at, 0} = DateTime.from_iso8601(receipt["history_since"])
    assert length(receipt["conversation_refs"]) == receipt["eligible_conversations"]

    # A greeting says nothing to search by, so no past work is matched on it.
    plain = search!(channel_ref: "CALERTS", text: "hello there")
    assert plain.receipt["identifiers"] == []
    assert plain.receipt["words"] == []
  end

  test "a past request is found by another form of the words it used" do
    # The search matched exact spellings: "probe failing" never found "probes
    # failed", so the request that had already worked on this was not offered.
    match =
      episode!("routing:word-forms",
        channel_ref: "CDEVOPS",
        text: "Readiness probes failed on the payments service during the rollout"
      )

    for index <- 1..30 do
      episode!("routing:word-forms-noise-#{index}",
        channel_ref: "CALERTS",
        text: "Routine deploy #{index} finished for the marketing website",
        updated_at: DateTime.add(@now, -index, :second)
      )
    end

    result = search!(channel_ref: "CALERTS", text: "Why is the payment probe failing again?")

    assert match.id in Enum.map(result.selected, & &1.episode.id)
    assert result.receipt["words"] == ~w(payment probe failing)
  end

  # Each word's rarity was counted by a query of its own, so a long message
  # added a round trip per word to every routing decision (2026-10-04 review).
  test "a search counts how rare its words are in one query, however many words it has" do
    episode!("routing:word-count",
      channel_ref: "CDEVOPS",
      text: "Readiness probes failed on the payments service during the rollout"
    )

    reads = fn text ->
      {result, statements} =
        QueryWork.statements(fn -> search!(channel_ref: "CALERTS", text: text) end)

      {result, QueryWork.count(statements, "episode_routing_digests")}
    end

    {short, few} = reads.("Why is the payment probe failing?")

    {long, many} =
      reads.(
        "Why is the payment probe failing again after the rollout of the checkout " <>
          "service, the readiness gate and the canary deploy in production?"
      )

    assert length(long.receipt["words"]) > length(short.receipt["words"]) + 5
    assert few > 0
    assert many == few
  end

  test "work whose title names the subject ranks above work that only mentions it" do
    # A request's title is the one line that says what it is about; the search
    # read only the transcript, so a request about the subject ranked with any
    # request that happened to mention it in passing.
    passing =
      episode!("routing:mentioned",
        channel_ref: "CDEVOPS",
        text:
          "Checkout latency is up. Someone asked whether Redis memory matters; memory looks flat.",
        updated_at: DateTime.add(@now, -60, :second)
      )

    titled =
      episode!("routing:titled",
        channel_ref: "CDEVOPS",
        text: "Cache node alarms again on cache-01",
        updated_at: DateTime.add(@now, -7_200, :second)
      )

    Repo.update_all(
      from(digest in Ryker.Episodes.RoutingDigest, where: digest.episode_id == ^titled.id),
      set: [
        title: "Redis memory pressure on cache-01",
        title_turn_id: Ecto.UUID.generate(),
        title_updated_at: @now
      ]
    )

    result = search!(channel_ref: "CALERTS", text: "Redis memory pressure again")
    offered = Enum.map(result.selected, & &1.episode.id)

    assert titled.id in offered and passing.id in offered

    assert Enum.find_index(offered, &(&1 == titled.id)) <
             Enum.find_index(offered, &(&1 == passing.id))
  end

  test "one saturated lane does not hide the best evidence another lane found" do
    match =
      episode!("routing:lane-evidence",
        channel_ref: "CDEVOPS",
        text: "Terraform run run-TobiKjYqqj17v2YB needs confirmation for tenant-infra"
      )

    # Enough other work that "terraform" still tells work apart (a word in
    # more than a quarter of it would not), and more Terraform work than the
    # wording lane returns.
    for index <- 1..160 do
      episode!("routing:lane-other-#{index}",
        channel_ref: "CDEVOPS",
        text: "Deploy #{index} of the marketing website finished",
        updated_at: DateTime.add(@now, -1_000 - index, :second)
      )
    end

    for index <- 1..50 do
      episode!("routing:lane-filler-#{index}",
        channel_ref: "CDEVOPS",
        text: "Terraform plan summary #{index}",
        updated_at: DateTime.add(@now, -index, :second)
      )
    end

    result =
      search!(
        channel_ref: "CDEVOPS",
        text: "The Terraform run run-TobiKjYqqj17v2YB applied successfully for tenant-infra"
      )

    assert match.id in Enum.map(result.selected, & &1.episode.id)
    assert result.receipt["lanes"]["text"]["saturated"]
    assert result.receipt["pool_saturated"] or result.receipt["examined"] <= 200
  end

  test "the exact source item's owner is offered even when every rank feature favours others" do
    owner =
      episode!("routing:owner",
        channel_ref: "CENGINEERING",
        text: "Older revision of this exact card"
      )

    native_input_id = owner_native_input_id(owner)

    for index <- 1..40 do
      episode!("routing:owner-noise-#{index}",
        channel_ref: "CDEVOPS",
        text: "Unrelated active work #{index}",
        updated_at: DateTime.add(@now, -index, :second)
      )
    end

    result =
      search!(
        channel_ref: "CDEVOPS",
        text: "Unrelated active work text",
        native_input_id: native_input_id
      )

    assert [first | _rest] = result.selected
    assert first.episode.id == owner.id
    assert first.source_owner
  end

  test "a proven occurrence identity outranks thread gravity and recency" do
    incident =
      episode!("routing:occurrence",
        channel_ref: "CDEVOPS",
        text: "Checkout latency alert started"
      )

    {:ok, _claim} =
      Repo.transaction(fn ->
        {:ok, claim} =
          CorrelationClaims.claim_in_transaction(%{
            episode_id: incident.id,
            input_ref: "admit:routing:occurrence",
            scope_ref: "slack:#{@workspace}",
            namespace: "slack:app:A123",
            occurrence_ref: "alert:checkout:started:1",
            established_at: @now
          })

        claim
      end)

    nearest =
      episode!("routing:same-thread",
        channel_ref: "CALERTS",
        text: "Checkout latency alert started",
        thread_ref: "1789000500.000100",
        updated_at: @now
      )

    result =
      search!(
        channel_ref: "CALERTS",
        thread_ref: "1789000500.000100",
        text: "Checkout latency alert recovered",
        occurrences: [%{namespace: "slack:app:A123", occurrence_ref: "alert:checkout:started:1"}]
      )

    assert [first, second | _rest] = result.selected
    assert first.episode.id == incident.id
    assert second.episode.id == nearest.id
    assert Ranking.document(first)["occurrence_identity"]
    refute Ranking.document(second)["occurrence_identity"]
  end

  test "private, direct and other-workspace work never appears, not even as a count" do
    Repo.insert!(%ChannelMembership{
      id: Ecto.UUID.generate(),
      workspace_ref: @workspace,
      channel_ref: "CPRIVATE",
      private: true,
      external_shared: false,
      generation: 1,
      status: :joined,
      joined_at: @now
    })

    private =
      episode!("routing:private",
        channel_ref: "CPRIVATE",
        text: "Payroll database credentials rotation"
      )

    direct =
      episode!("routing:direct",
        channel_ref: "D999",
        text: "Payroll database credentials rotation"
      )

    other =
      episode!("routing:other-workspace",
        channel_ref: "CDEVOPS",
        workspace_ref: "TOTHER",
        text: "Payroll database credentials rotation"
      )

    result = search!(channel_ref: "CDEVOPS", text: "Payroll database credentials rotation")
    offered = Enum.map(result.selected, & &1.episode.id)

    refute private.id in offered
    refute direct.id in offered
    refute other.id in offered
    assert result.receipt["examined"] == length(result.selected)
  end

  test "a direct message correlates only inside its own conversation" do
    channel =
      episode!("routing:dm-channel",
        channel_ref: "CDEVOPS",
        text: "Rotate the staging credentials"
      )

    inside =
      episode!("routing:dm-inside", channel_ref: "D777", text: "Rotate the staging credentials")

    result = search!(channel_ref: "D777", text: "Rotate the staging credentials")
    offered = Enum.map(result.selected, & &1.episode.id)

    assert inside.id in offered
    refute channel.id in offered
    assert result.receipt["scope"] == "conversation"
  end

  test "work pinned to another repository is offered as history, never as the same work" do
    pinned =
      episode!("routing:pinned",
        channel_ref: "CDEVOPS",
        text: "Upgrade the API gateway dependency"
      )

    pin!(pinned, "acme/other-service")

    result =
      search!(
        channel_ref: "CDEVOPS",
        text: "Upgrade the API gateway dependency",
        repository_ref: "acme/api-gateway"
      )

    entry = Enum.find(result.selected, &(&1.episode.id == pinned.id))
    assert entry.repository_ref == "acme/other-service"
  end

  test "an episode that also gathered evidence outside this scope is not offered at all" do
    contaminated =
      episode!("routing:contaminated", channel_ref: "CDEVOPS", text: "Shared outage evidence")

    # An origin that a correction placed in a private channel makes the whole
    # episode ineligible; its digest already mixes both audiences.
    Repo.update_all(
      from(digest in Ryker.Episodes.RoutingDigest,
        where: digest.episode_id == ^contaminated.id
      ),
      set: [conversation_refs: ["slack:#{@workspace}:CDEVOPS", "slack:#{@workspace}:CPRIVATE"]]
    )

    result = search!(channel_ref: "CDEVOPS", text: "Shared outage evidence")
    refute contaminated.id in Enum.map(result.selected, & &1.episode.id)
  end

  defp search!(options) do
    channel_ref = Keyword.fetch!(options, :channel_ref)
    workspace_ref = Keyword.get(options, :workspace_ref, @workspace)
    thread_ref = Keyword.get(options, :thread_ref)

    destination = %{
      conversation_ref: "slack:#{workspace_ref}:#{channel_ref}",
      thread_ref: thread_ref || "1789009999.000100",
      transport: "slack"
    }

    scope = CorrelationScope.for_destination(destination)

    content = Keyword.get_lazy(options, :content, fn -> %{"text" => options[:text]} end)

    CandidateSearch.search(%{
      scope: scope,
      transport: "slack",
      thread_ref: destination.thread_ref,
      text: RecallText.from(content),
      identifiers: RoutingDigests.input_identifiers(content),
      native_input_id: Keyword.get(options, :native_input_id, "slack-message:absent"),
      execution_mode: :live,
      repository_ref: Keyword.get(options, :repository_ref),
      occurrences: Keyword.get(options, :occurrences, []),
      candidate_limit: 20,
      history_cutoff: DateTime.add(@now, -30 * 24 * 60 * 60, :second),
      now: @now
    })
  end

  defp episode!(key, options) do
    channel_ref = Keyword.fetch!(options, :channel_ref)
    workspace_ref = Keyword.get(options, :workspace_ref, @workspace)
    thread_ref = Keyword.get(options, :thread_ref)
    occurred_at = Keyword.get(options, :updated_at, DateTime.add(@now, -3600, :second))

    message_ref =
      thread_ref || "#{DateTime.to_unix(occurred_at)}.#{System.unique_integer([:positive])}"

    {:ok, input} =
      SlackInput.new(%{
        actor: %{kind: :app, ref: "A123"},
        channel_ref: channel_ref,
        content: Keyword.get_lazy(options, :content, fn -> %{"text" => options[:text]} end),
        event_kind: :message,
        event_ref: "Ev-#{key}-#{System.unique_integer([:positive])}",
        message_ref: message_ref,
        occurred_at: occurred_at,
        revision: 1,
        thread_ref: thread_ref,
        workspace_ref: workspace_ref
      })

    id = Ecto.UUID.generate()

    {:ok, _transition} =
      Episodes.apply(%Command.AdmitInput{
        actor_ref: Input.actor_ref(input),
        destination: input.destination,
        episode_id: id,
        episode_key: "#{key}:#{id}",
        linked_episode_id: nil,
        native_input_id: input.native_input_id,
        occurred_at: occurred_at,
        payload: Input.document(input),
        revision: 1,
        turn_ref: "turn:#{id}"
      })

    if updated_at = Keyword.get(options, :updated_at) do
      Repo.update_all(from(episode in Episode, where: episode.id == ^id),
        set: [updated_at: updated_at]
      )
    end

    Repo.get!(Episode, id)
  end

  # A Grafana alert as Slack delivers it, from the Tenant history with its host renamed.
  defp grafana_alert(rule) do
    %{
      "text" => "",
      "attachments" => [
        %{
          "color" => "daa038",
          "fallback" => "[VA1 FIRING:1] WARNING | Traefik config reload frequency high",
          "text" =>
            "*FIRING - 1 alert*\n\n*Traefik completed more than 10 configuration reloads in 10 minutes*",
          "title" => "[VA1 FIRING:1] WARNING | Traefik config reload frequency high",
          "title_link" => rule
        }
      ]
    }
  end

  defp owner_native_input_id(episode) do
    Repo.one!(
      from(origin in Ryker.Episodes.Origin,
        where: origin.episode_id == ^episode.id,
        select: origin.native_input_id
      )
    )
  end

  defp pin!(episode, repository_ref) do
    Repo.insert!(%Session{
      id: Ecto.UUID.generate(),
      episode_id: episode.id,
      execution_kind: :work,
      policy: "engineering",
      policy_digest: String.duplicate("a", 64),
      repository_ref: repository_ref,
      external_ref: "episode:#{episode.id}:session:1",
      generation: 1,
      create_generation: 1
    })
  end

  defp joined!(channel_ref) do
    Repo.insert!(%ChannelMembership{
      id: Ecto.UUID.generate(),
      workspace_ref: @workspace,
      channel_ref: channel_ref,
      private: false,
      external_shared: false,
      generation: 1,
      status: :joined,
      joined_at: @now
    })
  end
end
