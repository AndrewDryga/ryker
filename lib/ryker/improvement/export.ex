defmodule Ryker.Improvement.Export do
  @moduledoc """
  Accepted cases as eval case files a developer drops into
  `testdata/scenarios/` and runs with `make eval-world`: one directory per
  case, in the world scenario format `Ryker.Evals.WorldCase` loads.

  What each case maps, as far as the evidence allows:

  - `scenario.json`
    - `id` and the directory: `feedback-<day accepted>-<candidate>`.
    - `provenance`: `production`, the request's Timeline reference, and when
      it was accepted.
    - `clock.start`: when the person's first message was sent.
    - `actors` and `events`: the person's messages in the request, up to the
      first negative feedback, word for word (credentials redacted), in
      order, each an `input` to the same place. An edited message is sent
      once, when it was first sent, in its last words by then; words the
      person took back by editing it were never kept, so it is sent in the
      words they left. Slack people, the workspace and channels are renamed
      (`U-person-1`, `TEVAL`, `CEVAL`), and so are their mentions in the
      text; Ryker's own mention reads `U-ryker`.
    - `expect.quality_rubric`: the analysis's `expected`, weight 3.
    - `tags`: `model-world`, `feedback-harvested`, the step and the category.
  - `tool-catalog.json`: the standard catalog of
    `va1-health-review-repairs-and-finishes`, by reference.
  - `routing.json`: each routing decision's exact prompt and answer, with
    the same people, workspace and channels renamed.
  - `PROVENANCE.md`: what happened, the feedback, the diagnosis, what Ryker
    answered, and what is still to fill in.

  What a developer still fills in: `world.repositories` and
  `world.tool_rules` (the checkout and the tool answers the request needs),
  `expect.hard` and `expect.trajectory` (what the host can prove, such as the
  delivery target or a required tool call), a recorded good answer under
  `host_replay` with the `host-replay` tag to run it in `make eval-replay`,
  and the actors' `authority` (every person is an operator here). Files are
  not replayed: a world event is a message's text.
  """
  alias Ryker.ConversationRef
  alias Ryker.Improvement.Candidate
  alias Ryker.Repo
  alias Ryker.UTCDateTime

  @catalog_ref "../va1-health-review-repairs-and-finishes/tool-catalog.json"

  @doc "The accepted cases that can be exported, oldest decision first."
  @spec accepted() :: [Candidate.t()]
  def accepted, do: Repo.all(Candidate.Query.exportable_cases())

  @doc "The directory name, and the scenario id, of one case."
  @spec case_id(Candidate.t()) :: String.t()
  def case_id(%Candidate{id: id, decided_at: decided_at}) do
    day = decided_at |> DateTime.to_date() |> Date.to_iso8601(:basic)
    # The id's last eight hex digits, random in every UUID Ryker makes; its
    # first eight are a UUIDv7's timestamp, the same for every case decided
    # within the same minute.
    "feedback-#{day}-#{String.slice(id, -8, 8)}"
  end

  @doc "Every file of every accepted case, by its path under the output directory."
  @spec files() :: [{String.t(), iodata()}]
  def files, do: Enum.flat_map(accepted(), &files/1)

  @doc "The files of one accepted case, by path."
  @spec files(Candidate.t()) :: [{String.t(), iodata()}]
  def files(%Candidate{case_evidence: %{} = stored} = candidate) do
    snapshot = lists(stored)
    id = case_id(candidate)
    names = names(snapshot, candidate)

    [
      {Path.join(id, "scenario.json"), json(scenario(candidate, snapshot, names))},
      {Path.join(id, "tool-catalog.json"),
       json(%{"version" => 1, "catalog_ref" => @catalog_ref})},
      {Path.join(id, "routing.json"), json(routing(snapshot, names))},
      {Path.join(id, "PROVENANCE.md"), provenance(candidate, snapshot, names)}
    ]
  end

  def files(_candidate), do: []

  # A kept snapshot is read as it was stored: a list it lacks, or holds as
  # null, is empty, so an older shape exports instead of raising.
  defp lists(snapshot) do
    Enum.reduce(~w(events routing conversation feedback), snapshot, fn key, snapshot ->
      Map.update(snapshot, key, [], &(&1 || []))
    end)
  end

  @doc "Writes every accepted case under `directory`, one directory each, and says how many."
  @spec write(Path.t()) :: {:ok, non_neg_integer()} | {:error, term()}
  def write(directory) when is_binary(directory) do
    cases = accepted()

    Enum.each(cases, fn candidate ->
      for {path, contents} <- files(candidate) do
        target = Path.join(directory, path)
        File.mkdir_p!(Path.dirname(target))
        File.write!(target, contents)
      end
    end)

    {:ok, length(cases)}
  rescue
    error in File.Error -> {:error, {:output, error.reason}}
  end

  @doc "Every accepted case in one zip archive, for the download."
  @spec zip() :: {:ok, binary()} | {:error, term()}
  def zip do
    entries =
      for {path, contents} <- files(),
          do: {String.to_charlist(path), IO.iodata_to_binary(contents)}

    case :zip.create(~c"ryker-eval-cases.zip", entries, [:memory]) do
      {:ok, {_name, archive}} -> {:ok, archive}
      {:error, reason} -> {:error, reason}
    end
  end

  # -- The scenario ------------------------------------------------------------------

  defp scenario(candidate, snapshot, names) do
    events = events(candidate, snapshot, names)

    %{
      "version" => 1,
      "id" => case_id(candidate),
      "provenance" => %{
        "kind" => "production",
        "episode_refs" => [reference(candidate.request_ref)],
        "captured_at" => iso(candidate.decided_at)
      },
      "clock" => %{"start" => events |> List.first() |> then(&(&1 && &1["occurred_at"]))},
      "actors" => actors(events, snapshot, names),
      "events" => events,
      "world" => %{"repositories" => [], "tool_rules" => [], "scheduled_events" => []},
      "host_replay" => %{"model_events" => []},
      "expect" => %{
        "hard" => [],
        "trajectory" => [],
        "quality_rubric" =>
          if(is_binary(candidate.expected),
            do: [%{"criterion" => rename_text(candidate.expected, names), "weight" => 3}],
            else: []
          )
      },
      "tags" =>
        Enum.reject(
          [
            "model-world",
            "feedback-harvested",
            candidate.step && Atom.to_string(candidate.step),
            candidate.category && Atom.to_string(candidate.category)
          ],
          &is_nil/1
        )
    }
  end

  # The person's messages up to the first negative feedback: the conversation
  # as it stood when Ryker let them down. A world event is a message, so an
  # edit is not one of its own: each message is sent once, when it was
  # first sent, in the words of its last revision by then. The words an edit
  # replaced were never kept (`Ryker.Improvement.Evidence`), so a message
  # the person edited since is sent in the words they left.
  defp events(candidate, snapshot, names) do
    said = snapshot["events"]

    before =
      Enum.filter(said, fn event ->
        case UTCDateTime.parse(event["at"]) do
          {:ok, at} -> DateTime.compare(at, candidate.first_signal_at) == :lt
          _invalid -> false
        end
      end)

    if(before == [], do: said, else: before)
    |> as_sent(said)
    |> Enum.map(fn event ->
      %{
        "actor_ref" => actor_ref(event, names),
        "destination" => destination(event["destination"], names),
        "kind" => "input",
        "occurred_at" => utc(event["at"]),
        "payload" => %{"text" => rename_text(event["text"], names)}
      }
    end)
  end

  defp as_sent(revisions, said) do
    revisions
    |> Enum.with_index()
    |> Enum.group_by(fn {event, _index} -> message(event) end)
    |> Enum.flat_map(fn {message, [{first, index} | _later] = all} ->
      case last_words(Enum.map(all, &elem(&1, 0))) ||
             last_words(Enum.filter(said, &(message(&1) == message))) do
        nil -> []
        text -> [{Map.put(first, "text", text), index}]
      end
    end)
    |> Enum.sort_by(&elem(&1, 1))
    |> Enum.map(&elem(&1, 0))
  end

  defp message(event), do: {event["source"], event["message_ref"]}

  defp last_words(revisions),
    do: revisions |> Enum.map(& &1["text"]) |> Enum.filter(&is_binary/1) |> List.last()

  defp actors(events, snapshot, names) do
    refs = events |> Enum.map(& &1["actor_ref"]) |> Enum.uniq()

    for ref <- refs do
      event = Enum.find(snapshot["events"], &(actor_ref(&1, names) == ref))
      actor(event, ref, names)
    end
  end

  defp actor(%{"source" => %{"kind" => "control_plane"}} = event, ref, names) do
    conversation = event["destination"]["conversation_ref"]

    %{
      "actor_ref" => ref,
      "authority" => "operator",
      "input_profile" => %{
        "actor" => %{"kind" => "user", "ref" => rename(event["actor"]["ref"], names)},
        "event_kind" => "message",
        "occurred_at_source" => "ingress",
        "source" => %{"kind" => "control_plane", "ref" => "local"},
        "source_capabilities" => %{
          "post_slack_message" => %{"destination_refs" => [conversation]},
          "react" => %{"emoji_names" => nil}
        }
      },
      "kind" => "human"
    }
  end

  defp actor(event, ref, names) do
    %{
      "actor_ref" => ref,
      "authority" => "operator",
      "input_profile" => %{
        "actor" => %{"kind" => "user", "ref" => rename(event["actor"]["ref"], names)},
        "event_kind" => "message",
        "occurred_at_source" => "source",
        "source" => %{
          "kind" => event["source"]["kind"],
          "ref" => rename(event["source"]["ref"], names)
        },
        "source_capabilities" => %{"react" => %{"emoji_names" => nil}}
      },
      "kind" => "human"
    }
  end

  defp actor_ref(event, names),
    do: "#{event["source"]["kind"]}:user:#{rename(event["actor"]["ref"], names)}"

  defp destination(%{"transport" => "slack"} = destination, names) do
    %{
      "conversation_ref" => rename_conversation(destination["conversation_ref"], names),
      "thread_ref" => destination["thread_ref"],
      "transport" => "slack"
    }
  end

  defp destination(destination, _names),
    do: Map.take(destination, ~w(conversation_ref thread_ref transport))

  # -- Renaming ----------------------------------------------------------------------

  # Slack people, workspaces, channels and bots as the case names them: the
  # same real reference always becomes the same stand-in, in order of
  # appearance, wherever it appears in any file (a mention in a message, a
  # routing prompt quoting the conversation, Ryker's answer, the diagnosis).
  # Ryker's own user is `U-ryker`. A Chat person signed in by name becomes
  # `chat-person-<n>`. Only the person's messages and routing were read for
  # ids before, and Chat people kept their sign-in (2026-10-04 review).
  @slack_id ~r/\b[UWTCGDB](?=[A-Z0-9]*\d)[A-Z0-9]{8,20}\b/

  defp names(snapshot, candidate) do
    events = snapshot["events"]
    slack = Enum.filter(events, &(&1["source"]["kind"] == "slack"))
    bots = slack |> Enum.flat_map(&List.wrap(&1["bot_user_ref"])) |> MapSet.new()

    texts =
      Enum.map(events, & &1["text"]) ++
        Enum.flat_map(snapshot["routing"], &[&1["prompt"], &1["answer"]]) ++
        Enum.map(snapshot["conversation"], & &1["text"]) ++
        Enum.map(snapshot["feedback"], & &1["note"]) ++
        [candidate.what_went_wrong, candidate.expected]

    found =
      texts
      |> Enum.filter(&is_binary/1)
      |> Enum.flat_map(&Regex.scan(@slack_id, &1))
      |> List.flatten()

    workspaces = Enum.map(slack, & &1["source"]["ref"])

    channels =
      slack |> Enum.map(&channel(&1["destination"]["conversation_ref"])) |> Enum.reject(&is_nil/1)

    people = Enum.map(slack, & &1["actor"]["ref"])

    (workspaces ++ channels ++ people ++ MapSet.to_list(bots) ++ found)
    |> Enum.uniq()
    |> Enum.reduce(%{}, fn ref, names ->
      Map.put(names, ref, stand_in(ref, names, bots, workspaces, channels))
    end)
    |> Map.merge(chat_names(events))
  end

  # The anonymous local operator is nobody; anyone signed in through Tailscale
  # or Cloudflare Access is named by their login, which their messages may
  # quote without the provider.
  defp chat_names(events) do
    for(
      %{"source" => %{"kind" => "control_plane"}, "actor" => %{"ref" => ref}} <- events,
      ref != "local-operator",
      do: ref
    )
    |> Enum.uniq()
    |> Enum.with_index(1)
    |> Enum.flat_map(fn {ref, index} ->
      stand_in = "chat-person-#{index}"

      case String.split(ref, ":", parts: 2) do
        [_provider, login] when login != "" -> [{ref, stand_in}, {login, stand_in}]
        _bare -> [{ref, stand_in}]
      end
    end)
    |> Map.new()
  end

  defp stand_in(ref, names, bots, workspaces, channels) do
    cond do
      MapSet.member?(bots, ref) -> "U-ryker"
      ref in workspaces or String.starts_with?(ref, "T") -> numbered("TEVAL", names, "TEVAL")
      ref in channels or String.first(ref) in ~w(C G D) -> numbered("CEVAL", names, "CEVAL")
      String.starts_with?(ref, "B") -> "B-bot-#{count(names, "B-bot-") + 1}"
      true -> "U-person-#{count(names, "U-person-") + 1}"
    end
  end

  defp numbered(stem, names, prefix) do
    case count(names, prefix) do
      0 -> stem
      taken -> "#{stem}#{taken + 1}"
    end
  end

  defp count(names, prefix),
    do: names |> Map.values() |> Enum.count(&String.starts_with?(&1, prefix))

  defp channel(conversation_ref) do
    case ConversationRef.parse_slack(conversation_ref) do
      {:ok, _workspace, channel} -> channel
      :error -> nil
    end
  end

  defp rename(ref, names), do: Map.get(names, ref, ref)

  defp rename_conversation("slack:" <> _rest = conversation_ref, names) do
    case ConversationRef.parse_slack(conversation_ref) do
      {:ok, workspace, channel} ->
        ConversationRef.slack(rename(workspace, names), rename(channel, names))

      :error ->
        conversation_ref
    end
  end

  defp rename_conversation(conversation, _names), do: conversation

  defp rename_text(text, names) when is_binary(text) and map_size(names) > 0 do
    pattern =
      names
      |> Map.keys()
      |> Enum.sort_by(&(-byte_size(&1)))
      |> Enum.map_join("|", &Regex.escape/1)
      |> then(&Regex.compile!("\\b(?:" <> &1 <> ")\\b"))

    Regex.replace(pattern, text, &Map.fetch!(names, &1))
  end

  defp rename_text(text, _names), do: text

  # -- The rest of the case ------------------------------------------------------------

  defp routing(snapshot, names) do
    for routing <- snapshot["routing"], is_binary(routing["prompt"]) do
      routing
      |> Map.take(~w(message_at decision model prompt answer))
      |> Map.update!("prompt", &rename_text(&1, names))
      |> Map.update("answer", nil, &rename_text(&1, names))
    end
  end

  defp provenance(candidate, snapshot, names) do
    answers =
      for %{"from" => "ryker", "text" => text} when is_binary(text) <-
            snapshot["conversation"],
          do: rename_text(text, names)

    feedback =
      for signal <- snapshot["feedback"] do
        note = signal["note"] && "\"#{rename_text(signal["note"], names)}\""
        words = [signal["kind"], signal["value"], note]
        "- #{signal["at"]}: " <> (words |> Enum.reject(&is_nil/1) |> Enum.join(" "))
      end

    """
    # #{case_id(candidate)}

    Harvested from Ryker's feedback: #{Enum.join(candidate.reasons, ", ")} on request
    `#{candidate.request_ref}` (#{candidate.transport}), accepted #{iso(candidate.decided_at)}.

    ## Diagnosis (written by Ryker's self-analysis#{confidence(candidate)})

    #{diagnosis_line(candidate)}

    #{rename_text(candidate.what_went_wrong, names) || "Ryker had not analyzed this request when it was accepted."}

    ## Expected

    #{rename_text(candidate.expected, names) || "Write the expectation into expect.quality_rubric."}

    ## What Ryker answered

    #{Enum.map_join(answers, "\n\n", &quoted/1)}

    ## Feedback

    #{Enum.join(feedback, "\n")}

    ## Before adding this case

    - The events are the person's messages up to their first negative feedback, word for word;
      Slack people, the workspace and channels are renamed. Check the words for anything private.
    - `world.repositories` and `world.tool_rules` are empty: add the checkout and the tool answers
      the request needs, or the model has nothing to check.
    - `expect.hard` and `expect.trajectory` are empty: add what the host can prove, such as the
      delivery target or a required tool call.
    - `host_replay` is empty, so this runs in `make eval-world` only; add a recorded good answer
      and the `host-replay` tag to run it in `make eval-replay` too.
    - Every person is an `operator`; change `authority` where they were not.
    - `routing.json` holds each routing decision's exact prompt and answer, with the same people,
      workspace and channels renamed; it quotes the conversation around the request too.
    """
  end

  defp diagnosis_line(%{category: nil}), do: "Not analyzed."

  defp diagnosis_line(candidate),
    do: "Category: #{words(candidate.category)}. Step: #{candidate.step}."

  defp confidence(%{confidence: nil}), do: ""
  defp confidence(candidate), do: ", #{candidate.confidence} confidence"

  defp words(atom), do: atom |> Atom.to_string() |> String.replace("_", " ")

  defp quoted(text), do: text |> String.split("\n") |> Enum.map_join("\n", &("> " <> &1))

  # -- Encoding ------------------------------------------------------------------------

  defp json(value), do: [Jason.encode_to_iodata!(value, pretty: true), ?\n]

  # A reference the scenario may carry: the characters a world case allows.
  defp reference(ref), do: String.replace(ref, ~r/[^A-Za-z0-9_.:-]/, "-")

  defp utc(at) do
    case DateTime.from_iso8601(at) do
      {:ok, datetime, _offset} -> iso(datetime)
      _invalid -> at
    end
  end

  defp iso(%DateTime{} = at), do: at |> DateTime.shift_zone!("Etc/UTC") |> DateTime.to_iso8601()
  defp iso(nil), do: nil
end
