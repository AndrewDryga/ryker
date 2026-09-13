defmodule Ryker.Evals.WorldCase do
  @moduledoc """
  Loads one versioned, production-shaped scenario for both host replay and
  interactive model-world evaluation.

  Scenario directories are immutable evidence bundles. Paths cannot escape the
  directory, catalogs are canonical and bounded, and production provenance is
  explicit rather than inferred from prose.
  """

  alias Ryker.CanonicalJSON
  alias Ryker.Evals.WorldMatch
  alias Ryker.Ingress.Input

  @root "testdata/scenarios"
  @maximum_scenario_bytes 512 * 1_024
  @maximum_catalog_bytes 256 * 1_024
  @maximum_repository_bytes 2 * 1_024 * 1_024
  @maximum_repository_files 256
  @git_commit_regex ~r/\A(?:[0-9a-f]{40}|[0-9a-f]{64})\z/
  @reference_regex ~r/\A[A-Za-z0-9_.:-]{1,256}\z/
  @sha256_regex ~r/\A[0-9a-f]{64}\z/
  @root_fields ~w(actors clock events expect host_replay id provenance tags version world)
  @catalog_fields ~w(servers version)
  @provenance_fields ~w(captured_at episode_refs kind)
  @world_fields ~w(repositories scheduled_events tool_rules)
  @expect_fields ~w(hard quality_rubric trajectory)
  @host_replay_fields ~w(model_events)
  @model_event_fields ~w(calls candidates input_index preflight_candidate_index)
  @model_event_optional_fields ~w(faults output_artifacts)
  @model_event_faults ~w(
    crash_after_submit lose_delivery_response lose_submit_response lose_validation_response
    rate_limit_submit_once
  )
  @model_call_fields ~w(arguments kind tool)
  @model_call_error_fields ~w(arguments expected_error kind tool)
  @output_artifact_fields ~w(bytes data_base64 id media_type name sha256)
  @raw_candidate_fields ~w(bytes kind)
  @final_candidate_fields ~w(document kind)
  @input_event_fields ~w(actor_ref destination kind occurred_at payload)
  @input_event_optional_fields ~w(source_item_ref)
  @destination_fields ~w(conversation_ref thread_ref transport)
  @wait_wakeup_fields ~w(kind occurred_at)
  @actor_fields ~w(actor_ref authority input_profile kind)
  @input_profile_fields ~w(actor event_kind occurred_at_source source source_capabilities)
  @actor_authorities ~w(
    operator read_only repository_feedback repository_write_offer schedule_offer source_event
  )
  @actor_kinds ~w(automation human)

  @enforce_keys [
    :actors,
    :clock,
    :events,
    :expect,
    :host_replay,
    :id,
    :path,
    :provenance,
    :tags,
    :tool_catalog,
    :tool_catalog_digest,
    :world
  ]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          actors: [map()],
          clock: map(),
          events: [map()],
          expect: map(),
          host_replay: map(),
          id: String.t(),
          path: Path.t(),
          provenance: map(),
          tags: [String.t()],
          tool_catalog: map(),
          tool_catalog_digest: String.t(),
          world: map()
        }

  @spec all(Path.t()) :: {:ok, [t()]} | {:error, term()}
  def all(root \\ @root) do
    with true <- is_binary(root),
         {:ok, directories} <- scenario_directories(root) do
      load_directories(directories)
    else
      false -> {:error, {:invalid_world_cases, :root}}
      {:error, reason} -> {:error, {:invalid_world_cases, reason}}
    end
  end

  @spec fetch(String.t(), Path.t()) :: {:ok, t()} | {:error, term()}
  def fetch(id, root \\ @root)

  def fetch(id, root) when is_binary(id) do
    with :ok <- reference(id, :id),
         {:ok, cases} <- all(root),
         %__MODULE__{} = scenario <- Enum.find(cases, &(&1.id == id)) do
      {:ok, scenario}
    else
      nil -> {:error, {:world_case_not_found, id}}
      {:error, _reason} = error -> error
    end
  end

  def fetch(id, _root), do: {:error, {:world_case_not_found, id}}

  defp load_directories(directories) do
    result =
      Enum.reduce_while(directories, {:ok, []}, fn directory, {:ok, cases} ->
        case load(directory) do
          {:ok, scenario} -> {:cont, {:ok, [scenario | cases]}}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)

    case result do
      {:ok, cases} -> unique(Enum.reverse(cases))
      {:error, _reason} = error -> error
    end
  end

  @spec load(Path.t()) :: {:ok, t()} | {:error, term()}
  def load(directory) when is_binary(directory) do
    id = Path.basename(directory)

    with :ok <- reference(id, :directory),
         {:ok, scenario} <-
           read_json(Path.join(directory, "scenario.json"), @maximum_scenario_bytes),
         {:ok, catalog} <- read_catalog(directory),
         {:ok, compiled} <- compile(scenario, catalog, directory) do
      {:ok, compiled}
    else
      {:error, field} -> {:error, {:invalid_world_case, id, field}}
    end
  end

  def load(_directory), do: {:error, {:invalid_world_case, "unknown", :directory}}

  @spec document(t()) :: map()
  def document(%__MODULE__{} = scenario) do
    %{
      "scenario" => scenario_document(scenario),
      "tool_catalog" => scenario.tool_catalog,
      "tool_catalog_sha256" => scenario.tool_catalog_digest
    }
  end

  @spec state_tools(t()) :: [map()]
  def state_tools(%__MODULE__{tool_catalog: %{"servers" => servers}}) do
    Enum.find_value(servers, [], fn
      %{"name" => "responder-state", "tools" => tools} -> tools
      _other -> nil
    end)
  end

  @doc """
  Authorizes a durable answer save for exactly the operators this scenario declares.

  The scenario is the whole world, so an actor it declares with operator authority is
  the operator and nobody else is. Without this the evaluation runs a host that denies
  every save, which is not the host production runs: a scenario whose point is that an
  answer is remembered can then never pass, however well the model behaves.
  """
  @spec answer_authorizer(t()) :: (map() -> boolean())
  def answer_authorizer(%__MODULE__{actors: actors}) do
    operators =
      actors
      |> Enum.filter(&(&1["authority"] == "operator"))
      |> MapSet.new(&operator_identity/1)

    fn entry -> MapSet.member?(operators, entry_identity(entry)) end
  end

  defp operator_identity(%{"input_profile" => %{"actor" => actor, "source" => source}}),
    do: {source["kind"], source["ref"], actor["kind"], actor["ref"]}

  defp entry_identity(%{
         source_kind: source_kind,
         source_ref: source_ref,
         actor_kind: actor_kind,
         actor_ref: actor_ref
       })
       when is_binary(source_kind) and is_binary(source_ref) and is_binary(actor_ref),
       do: {source_kind, source_ref, to_string(actor_kind), actor_ref}

  defp entry_identity(_other), do: nil

  @spec fabricated_tools(t()) :: [map()]
  def fabricated_tools(%__MODULE__{tool_catalog: %{"servers" => servers}}) do
    Enum.find_value(servers, [], fn
      %{"name" => "fabricated-world", "tools" => tools} -> tools
      _other -> nil
    end)
  end

  @spec repository_requirements(t()) :: [map()]
  def repository_requirements(%__MODULE__{world: %{"repositories" => repositories}}) do
    Enum.map(repositories, fn repository ->
      %{
        "base_commit" => repository["base_commit"],
        "name" => repository["ref"]
      }
    end)
  end

  # The vocabulary an actor's input profile may use. The runner reads the same
  # profile back when it builds ingress inputs, so the two must never drift.
  @doc false
  @spec profile_atom(term(), :actor_kind | :event_kind | :occurred_at_source) ::
          {:ok, atom()} | :error
  def profile_atom("app", :actor_kind), do: {:ok, :app}
  def profile_atom("bot", :actor_kind), do: {:ok, :bot}
  def profile_atom("system", :actor_kind), do: {:ok, :system}
  def profile_atom("user", :actor_kind), do: {:ok, :user}
  def profile_atom("message", :event_kind), do: {:ok, :message}
  def profile_atom("edit", :event_kind), do: {:ok, :edit}
  def profile_atom("delete", :event_kind), do: {:ok, :delete}
  def profile_atom("event", :event_kind), do: {:ok, :event}
  def profile_atom("source", :occurred_at_source), do: {:ok, :source}
  def profile_atom("ingress", :occurred_at_source), do: {:ok, :ingress}
  def profile_atom(_value, _field), do: :error

  defp compile(scenario, catalog, directory) do
    with :ok <- exact_fields(scenario, @root_fields, :scenario),
         true <- scenario["version"] == 1 or {:error, :version},
         :ok <- reference(scenario["id"], :id),
         true <- scenario["id"] == Path.basename(directory) or {:error, :id},
         :ok <- provenance(scenario["provenance"]),
         :ok <- clock(scenario["clock"]),
         :ok <- actors(scenario["actors"]),
         :ok <- events(scenario["events"], scenario["actors"]),
         :ok <- world(scenario["world"], directory),
         :ok <- tags(scenario["tags"]),
         :ok <- host_replay(scenario["host_replay"], scenario["tags"]),
         :ok <- expectation(scenario["expect"]),
         :ok <- catalog(catalog) do
      {:ok,
       %__MODULE__{
         actors: scenario["actors"],
         clock: scenario["clock"],
         events: scenario["events"],
         expect: scenario["expect"],
         host_replay: scenario["host_replay"],
         id: scenario["id"],
         path: directory,
         provenance: scenario["provenance"],
         tags: scenario["tags"],
         tool_catalog: catalog,
         tool_catalog_digest: CanonicalJSON.digest(catalog),
         world: scenario["world"]
       }}
    else
      false -> {:error, :scenario}
      {:error, _field} = error -> error
    end
  end

  defp scenario_document(scenario) do
    %{
      "actors" => scenario.actors,
      "clock" => scenario.clock,
      "events" => scenario.events,
      "expect" => scenario.expect,
      "host_replay" => scenario.host_replay,
      "id" => scenario.id,
      "provenance" => scenario.provenance,
      "tags" => scenario.tags,
      "version" => 1,
      "world" => scenario.world
    }
  end

  defp scenario_directories(root) do
    case File.ls(root) do
      {:ok, entries} ->
        directories =
          entries
          |> Enum.map(&Path.join(root, &1))
          |> Enum.filter(&File.dir?/1)
          |> Enum.sort()

        if directories == [], do: {:error, :empty}, else: {:ok, directories}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp read_json(path, maximum) do
    with {:ok, bytes} <- File.read(path),
         true <- byte_size(bytes) <= maximum or {:error, :too_large},
         {:ok, %{} = document} <- Jason.decode(bytes) do
      {:ok, document}
    else
      {:ok, _other} -> {:error, :json_object}
      {:error, :too_large} -> {:error, :too_large}
      {:error, _reason} -> {:error, :json}
    end
  end

  defp read_catalog(directory) do
    path = Path.join(directory, "tool-catalog.json")

    with {:ok, document} <- read_json(path, @maximum_catalog_bytes) do
      catalog_document(document, directory, path)
    end
  end

  defp catalog_document(
         %{"catalog_ref" => reference, "version" => 1} = wrapper,
         directory,
         path
       )
       when map_size(wrapper) == 2 do
    with {:ok, target} <- catalog_path(directory, reference),
         true <- target != Path.expand(path) or {:error, :tool_catalog_reference},
         {:ok, catalog} <- read_json(target, @maximum_catalog_bytes),
         false <- Map.has_key?(catalog, "catalog_ref") do
      {:ok, catalog}
    else
      _invalid -> {:error, :tool_catalog_reference}
    end
  end

  defp catalog_document(catalog, _directory, _path), do: {:ok, catalog}

  defp catalog_path(directory, reference) when is_binary(reference) do
    root = directory |> Path.dirname() |> Path.expand()
    target = Path.expand(reference, directory)

    if String.starts_with?(target <> "/", root <> "/") and Path.extname(target) == ".json",
      do: {:ok, target},
      else: {:error, :path}
  end

  defp catalog_path(_directory, _reference), do: {:error, :path}

  defp provenance(value) do
    with :ok <- exact_fields(value, @provenance_fields, :provenance),
         true <- value["kind"] in ~w(production synthetic) or {:error, :provenance},
         :ok <- references(value["episode_refs"], 64, :provenance),
         {:ok, _captured_at, 0} <- DateTime.from_iso8601(value["captured_at"]) do
      :ok
    else
      _invalid -> {:error, :provenance}
    end
  end

  defp clock(%{"start" => start} = value) when map_size(value) == 1 do
    case DateTime.from_iso8601(start) do
      {:ok, _datetime, 0} -> :ok
      _invalid -> {:error, :clock}
    end
  end

  defp clock(_value), do: {:error, :clock}

  defp actors(values) when is_list(values) and values != [] and length(values) <= 256 do
    with true <- Enum.all?(values, &(actor(&1) == :ok)),
         refs <- Enum.map(values, & &1["actor_ref"]),
         true <- Enum.uniq(refs) == refs do
      :ok
    else
      _invalid -> {:error, :actors}
    end
  end

  defp actors(_values), do: {:error, :actors}

  defp events(values, actors) do
    with :ok <- object_list(values, 2_048, :events) do
      Enum.reduce_while(values, :ok, fn value, :ok ->
        validation_step(event(value, actors))
      end)
    end
  end

  defp event(%{"kind" => "input"} = value, actors) do
    with :ok <- exact_fields(value, @input_event_fields, @input_event_optional_fields, :events),
         :ok <- reference(value["actor_ref"], :events),
         %{"input_profile" => profile} <-
           Enum.find(actors, &(&1["actor_ref"] == value["actor_ref"])),
         :ok <- destination(value["destination"]),
         :ok <- optional_reference(value["source_item_ref"], :events),
         :ok <- source_item_authority(profile, value["source_item_ref"]),
         {:ok, _occurred_at, 0} <- DateTime.from_iso8601(value["occurred_at"]),
         true <- is_map(value["payload"]) and map_size(value["payload"]) > 0 do
      :ok
    else
      _invalid -> {:error, :events}
    end
  end

  defp event(%{"kind" => "semantic_correction"} = value, _actors) do
    with :ok <- exact_fields(value, ~w(actor_ref kind occurred_at payload), :events),
         :ok <- reference(value["actor_ref"], :events),
         {:ok, _occurred_at, 0} <- DateTime.from_iso8601(value["occurred_at"]),
         true <- is_map(value["payload"]) and map_size(value["payload"]) > 0 do
      :ok
    else
      _invalid -> {:error, :events}
    end
  end

  defp event(_value, _actors), do: {:error, :events}

  defp source_item_authority(
         %{
           "source" => %{"kind" => "github"},
           "source_capabilities" => %{"react" => _capability}
         },
         source_item_ref
       )
       when is_binary(source_item_ref) do
    case String.split(source_item_ref, ":", parts: 3) do
      ["github", kind, id] when kind in ["issue_comment", "pull_request_review_comment"] ->
        case Integer.parse(id) do
          {id, ""} when id > 0 -> :ok
          _invalid -> {:error, :events}
        end

      _invalid ->
        {:error, :events}
    end
  end

  defp source_item_authority(
         %{
           "source" => %{"kind" => "github"},
           "source_capabilities" => %{"react" => _capability}
         },
         _source_item_ref
       ),
       do: {:error, :events}

  defp source_item_authority(_profile, _source_item_ref), do: :ok

  defp destination(%{} = value) do
    with :ok <- exact_fields(value, @destination_fields, :events),
         :ok <- reference(value["conversation_ref"], :events),
         true <- is_nil(value["thread_ref"]) or reference(value["thread_ref"], :events) == :ok,
         true <- value["transport"] in ~w(control_plane github slack) do
      :ok
    else
      _invalid -> {:error, :events}
    end
  end

  defp destination(_value), do: {:error, :events}

  defp actor(
         %{
           "actor_ref" => actor_ref,
           "authority" => authority,
           "input_profile" => input_profile,
           "kind" => kind
         } = actor
       ) do
    with :ok <- exact_fields(actor, @actor_fields, :actors),
         :ok <- reference(actor_ref, :actors),
         true <- authority in @actor_authorities,
         true <- kind in @actor_kinds,
         :ok <- input_profile(actor_ref, input_profile) do
      :ok
    else
      _invalid -> {:error, :actors}
    end
  end

  defp actor(_actor), do: {:error, :actors}

  defp input_profile(
         actor_ref,
         %{
           "actor" => %{"kind" => actor_kind, "ref" => actor_identity},
           "event_kind" => event_kind,
           "occurred_at_source" => occurred_at_source,
           "source" => %{"kind" => source_kind, "ref" => source_ref},
           "source_capabilities" => source_capabilities
         } = profile
       ) do
    with :ok <- exact_fields(profile, @input_profile_fields, :actors),
         {:ok, actor_kind} <- profile_atom(actor_kind, :actor_kind),
         {:ok, event_kind} <- profile_atom(event_kind, :event_kind),
         {:ok, occurred_at_source} <- profile_atom(occurred_at_source, :occurred_at_source),
         {:ok, input} <-
           Input.new(%{
             actor: %{kind: actor_kind, ref: actor_identity},
             content: %{"kind" => "world_case_profile"},
             destination: profile_destination(profile),
             event_kind: event_kind,
             event_ref: "world-case-profile",
             native_input_id: "world-case-profile",
             occurred_at: ~U[2026-01-01 00:00:00.000000Z],
             occurred_at_source: occurred_at_source,
             revision: 1,
             source: %{kind: source_kind, ref: source_ref},
             source_capabilities: source_capabilities,
             source_item_ref: profile_source_item_ref(source_capabilities)
           }),
         true <- Input.actor_ref(input) == actor_ref do
      :ok
    else
      _invalid -> {:error, :actors}
    end
  end

  defp input_profile(_actor_ref, _profile), do: {:error, :actors}

  defp profile_destination(%{
         "source" => %{"kind" => "control_plane", "ref" => "local"},
         "source_capabilities" => %{
           "post_slack_message" => %{"destination_refs" => [conversation_ref]}
         }
       }) do
    %{
      conversation_ref: conversation_ref,
      thread_ref: conversation_ref,
      transport: "control_plane"
    }
  end

  defp profile_destination(_profile) do
    %{conversation_ref: "slack:TEVAL:CEVAL", thread_ref: "1788019200.000100", transport: "slack"}
  end

  defp profile_source_item_ref(capabilities) when map_size(capabilities) == 0, do: nil
  defp profile_source_item_ref(_capabilities), do: "1788019200.000100"

  defp world(value, directory) do
    with :ok <- exact_fields(value, @world_fields, :world),
         :ok <- repositories(value["repositories"], directory),
         :ok <- tool_rules(value["tool_rules"]) do
      wait_wakeups(value["scheduled_events"])
    end
  end

  defp wait_wakeups(values) do
    with :ok <- object_list(values, 2_048, :scheduled_events) do
      Enum.reduce_while(values, :ok, fn value, :ok ->
        validation_step(wait_wakeup(value))
      end)
    end
  end

  defp validation_step(:ok), do: {:cont, :ok}
  defp validation_step({:error, _field} = error), do: {:halt, error}

  defp wait_wakeup(%{"kind" => "wait_wakeup"} = value) do
    with :ok <- exact_fields(value, @wait_wakeup_fields, :scheduled_events),
         {:ok, _occurred_at, 0} <- DateTime.from_iso8601(value["occurred_at"]) do
      :ok
    else
      _invalid -> {:error, :scheduled_events}
    end
  end

  defp wait_wakeup(_value), do: {:error, :scheduled_events}

  defp repositories(repositories, directory)
       when is_list(repositories) and length(repositories) <= 16 do
    Enum.reduce_while(repositories, :ok, fn repository, :ok ->
      case repository_entry(repository, directory) do
        :ok -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp repositories(_repositories, _directory), do: {:error, :repositories}

  defp repository_entry(
         %{
           "base_commit" => base_commit,
           "path" => path,
           "ref" => ref,
           "sha256" => digest
         } = repository,
         directory
       )
       when map_size(repository) == 4 do
    with :ok <- reference(ref, :repository_ref),
         true <- is_binary(base_commit) and Regex.match?(@git_commit_regex, base_commit),
         true <- Regex.match?(@sha256_regex, digest),
         {:ok, repository_path} <- safe_relative_path(directory, path),
         {:ok, ^digest} <- repository_digest(repository_path) do
      :ok
    else
      {:ok, _different_digest} -> {:error, :repository_digest}
      {:error, :repository_digest} -> {:error, :repository_digest}
      _invalid -> {:error, :repository_path}
    end
  end

  defp repository_entry(_repository, _directory), do: {:error, :repository_path}

  defp safe_relative_path(directory, path) when is_binary(path) do
    expanded = Path.expand(path, directory)
    root = Path.expand(directory) <> "/"

    if String.starts_with?(expanded <> "/", root), do: {:ok, expanded}, else: {:error, :path}
  end

  defp safe_relative_path(_directory, _path), do: {:error, :path}

  defp repository_digest(path) do
    with {:ok, %File.Stat{type: :directory}} <- File.lstat(path),
         {:ok, entries} <- repository_entries(path, path, []),
         true <- entries != [] and length(entries) <= @maximum_repository_files,
         true <- Enum.sum(Enum.map(entries, & &1["bytes"])) <= @maximum_repository_bytes do
      {:ok, CanonicalJSON.digest(entries)}
    else
      _invalid -> {:error, :repository_digest}
    end
  end

  defp repository_entries(root, directory, entries) do
    case File.ls(directory) do
      {:ok, names} -> reduce_repository_entries(names, root, directory, entries)
      {:error, _reason} -> {:error, :repository_digest}
    end
  end

  defp reduce_repository_entries(names, root, directory, entries) do
    names
    |> Enum.sort()
    |> Enum.reduce_while({:ok, entries}, fn name, {:ok, collected} ->
      collect_repository_path(root, Path.join(directory, name), collected)
    end)
    |> sort_repository_entries()
  end

  defp collect_repository_path(root, path, collected) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :directory}} ->
        collect_repository_directory(root, path, collected)

      {:ok, %File.Stat{type: :regular, size: size}}
      when size >= 0 and size <= @maximum_repository_bytes ->
        collect_repository_file(root, path, collected)

      _unsupported ->
        {:halt, {:error, :repository_digest}}
    end
  end

  defp collect_repository_directory(root, path, collected) do
    case repository_entries(root, path, collected) do
      {:ok, nested} -> {:cont, {:ok, nested}}
      {:error, _reason} = error -> {:halt, error}
    end
  end

  defp collect_repository_file(root, path, collected) do
    case File.read(path) do
      {:ok, bytes} -> add_repository_entry(root, path, bytes, collected)
      {:error, _reason} -> {:halt, {:error, :repository_digest}}
    end
  end

  defp add_repository_entry(root, path, bytes, collected) do
    entry = %{
      "bytes" => byte_size(bytes),
      "path" => Path.relative_to(path, root),
      "sha256" => sha256(bytes)
    }

    next = [entry | collected]

    if repository_entries_within_limits?(next),
      do: {:cont, {:ok, next}},
      else: {:halt, {:error, :repository_digest}}
  end

  defp repository_entries_within_limits?(entries) do
    length(entries) <= @maximum_repository_files and
      Enum.sum(Enum.map(entries, & &1["bytes"])) <= @maximum_repository_bytes
  end

  defp sort_repository_entries({:ok, values}),
    do: {:ok, Enum.sort_by(values, & &1["path"])}

  defp sort_repository_entries({:error, _reason} = error), do: error

  defp tool_rules(rules) when is_list(rules) and length(rules) <= 256 do
    Enum.reduce_while(rules, :ok, fn rule, :ok ->
      case tool_rule(rule) do
        :ok -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp tool_rules(_rules), do: {:error, :tool_rules}

  defp tool_rule(
         %{"id" => id, "match" => match, "responses" => rule_responses, "tool" => tool} = rule
       )
       when map_size(rule) == 4 and is_map(match) and is_list(rule_responses) and
              rule_responses != [] and length(rule_responses) <= 32 do
    with :ok <- reference(id, :rule_id),
         :ok <- reference(tool, :tool),
         true <- WorldMatch.valid?(match) or {:error, :tool_rule_match},
         :ok <- canonical(match, 16 * 1_024, :tool_rule) do
      responses(rule_responses)
    end
  end

  defp tool_rule(_rule), do: {:error, :tool_rules}

  defp responses(responses) do
    Enum.reduce_while(responses, :ok, fn response, :ok ->
      case response(response) do
        :ok -> {:cont, :ok}
        {:error, _field} = error -> {:halt, error}
      end
    end)
  end

  defp response(%{"kind" => "result", "value" => value} = response)
       when map_size(response) == 2,
       do: canonical(value, 64 * 1_024, :tool_response)

  defp response(%{"code" => code, "kind" => "error", "message" => message} = response)
       when map_size(response) == 3 do
    with :ok <- reference(code, :tool_error) do
      bounded_text(message, 4_096, :tool_error)
    end
  end

  defp response(_response), do: {:error, :tool_response}

  defp host_replay(value, tags) do
    with :ok <- exact_fields(value, @host_replay_fields, :host_replay),
         events when is_list(events) and length(events) <= 2_048 <- value["model_events"],
         true <- events != [] == "host-replay" in tags or {:error, :host_replay},
         :ok <- model_events(events) do
      :ok
    else
      {:error, _field} = error -> error
      _invalid -> {:error, :model_events}
    end
  end

  defp model_events([]), do: :ok

  defp model_events(events) do
    result =
      Enum.reduce_while(events, :ok, fn event, :ok ->
        case model_event(event) do
          :ok -> {:cont, :ok}
          {:error, _field} = error -> {:halt, error}
        end
      end)

    indexes = Enum.map(events, & &1["input_index"])

    with :ok <- result,
         true <- indexes == Enum.to_list(1..length(events)) or {:error, :input_index} do
      :ok
    end
  end

  defp model_event(event) do
    with :ok <- model_event_fields(event),
         true <-
           (is_integer(event["input_index"]) and event["input_index"] > 0) or
             {:error, :input_index},
         :ok <- model_calls(event["calls"]),
         :ok <- model_event_faults(Map.get(event, "faults", [])),
         :ok <- output_artifacts(Map.get(event, "output_artifacts", [])),
         :ok <- model_candidates(event["candidates"]) do
      preflight_candidate(event["preflight_candidate_index"], event["candidates"])
    end
  end

  defp model_event_fields(event) when is_map(event) do
    fields = Map.keys(event)
    required = MapSet.new(@model_event_fields)
    actual = MapSet.new(fields)
    allowed = MapSet.new(@model_event_fields ++ @model_event_optional_fields)

    if MapSet.subset?(required, actual) and MapSet.subset?(actual, allowed),
      do: :ok,
      else: {:error, :fields}
  end

  defp model_event_fields(_event), do: {:error, :model_event}

  defp model_event_faults(faults) when is_list(faults) and length(faults) <= 8 do
    if Enum.uniq(faults) == faults and Enum.all?(faults, &(&1 in @model_event_faults)),
      do: :ok,
      else: {:error, :model_event_faults}
  end

  defp model_event_faults(_faults), do: {:error, :model_event_faults}

  defp output_artifacts(values) when is_list(values) and length(values) <= 4 do
    with {:ok, artifacts} <- prepare_output_artifacts(values),
         true <- unique_by?(artifacts, :id) or {:error, :output_artifacts},
         true <- unique_by?(artifacts, :sha256) or {:error, :output_artifacts},
         true <-
           Enum.sum(Enum.map(artifacts, & &1.bytes)) <= 8 * 1_024 * 1_024 or
             {:error, :output_artifacts} do
      :ok
    end
  end

  defp output_artifacts(_values), do: {:error, :output_artifacts}

  defp prepare_output_artifacts(values) do
    Enum.reduce_while(values, {:ok, []}, fn value, {:ok, artifacts} ->
      case output_artifact(value) do
        {:ok, artifact} -> {:cont, {:ok, [artifact | artifacts]}}
        {:error, _field} = error -> {:halt, error}
      end
    end)
  end

  defp output_artifact(value) when is_map(value) do
    with :ok <- exact_fields(value, @output_artifact_fields, :output_artifacts),
         :ok <- reference(value["id"], :output_artifacts),
         true <- valid_artifact_name?(value["name"]) or {:error, :output_artifacts},
         true <-
           value["media_type"] in ~w(image/png image/jpeg image/webp image/gif) or
             {:error, :output_artifacts},
         true <-
           (is_integer(value["bytes"]) and value["bytes"] in 1..(8 * 1_024 * 1_024)) or
             {:error, :output_artifacts},
         true <- is_binary(value["data_base64"]) or {:error, :output_artifacts},
         {:ok, data} <- Base.decode64(value["data_base64"]),
         true <- byte_size(data) == value["bytes"] or {:error, :output_artifacts},
         true <- sha256(data) == value["sha256"] or {:error, :output_artifacts},
         true <-
           artifact_media_matches?(value["media_type"], data) or
             {:error, :output_artifacts} do
      {:ok,
       %{
         bytes: value["bytes"],
         id: value["id"],
         sha256: value["sha256"]
       }}
    else
      :error -> {:error, :output_artifacts}
      {:error, _field} -> {:error, :output_artifacts}
      false -> {:error, :output_artifacts}
    end
  end

  defp output_artifact(_value), do: {:error, :output_artifacts}

  defp unique_by?(values, field) do
    selected = Enum.map(values, &Map.fetch!(&1, field))
    Enum.uniq(selected) == selected
  end

  defp valid_artifact_name?(value) when is_binary(value) do
    String.valid?(value) and byte_size(value) in 1..255 and value not in [".", ".."] and
      not String.contains?(value, ["/", "\\"]) and
      not Enum.any?(String.to_charlist(value), &(&1 < 32 or &1 == 127))
  end

  defp valid_artifact_name?(_value), do: false

  defp artifact_media_matches?("image/png", <<137, 80, 78, 71, 13, 10, 26, 10, _::binary>>),
    do: true

  defp artifact_media_matches?("image/jpeg", <<255, 216, 255, _::binary>>), do: true
  defp artifact_media_matches?("image/gif", <<"GIF87a", _::binary>>), do: true
  defp artifact_media_matches?("image/gif", <<"GIF89a", _::binary>>), do: true

  defp artifact_media_matches?("image/webp", <<"RIFF", _::binary-size(4), "WEBP", _::binary>>),
    do: true

  defp artifact_media_matches?(_media_type, _data), do: false

  defp model_calls(calls) when is_list(calls) and length(calls) <= 128 do
    Enum.reduce_while(calls, :ok, fn call, :ok ->
      case model_call(call) do
        :ok -> {:cont, :ok}
        {:error, _field} = error -> {:halt, error}
      end
    end)
  end

  defp model_calls(_calls), do: {:error, :model_calls}

  defp model_call(call) do
    with :ok <- model_call_fields(call),
         true <- call["kind"] in ~w(state fabricated) or {:error, :model_call},
         :ok <- reference(call["tool"], :model_call),
         :ok <- optional_model_call_error(Map.get(call, "expected_error")) do
      canonical(call["arguments"], 64 * 1_024, :model_call)
    end
  end

  defp model_call_fields(call) when is_map(call) do
    fields = Enum.sort(Map.keys(call))

    if fields in [Enum.sort(@model_call_fields), Enum.sort(@model_call_error_fields)],
      do: :ok,
      else: {:error, :fields}
  end

  defp model_call_fields(_call), do: {:error, :model_call}

  defp optional_model_call_error(nil), do: :ok
  defp optional_model_call_error(error), do: reference(error, :model_call)

  defp model_candidates(candidates)
       when is_list(candidates) and candidates != [] and length(candidates) <= 16 do
    Enum.reduce_while(candidates, :ok, fn candidate, :ok ->
      case model_candidate(candidate) do
        :ok -> {:cont, :ok}
        {:error, _field} = error -> {:halt, error}
      end
    end)
  end

  defp model_candidates(_candidates), do: {:error, :candidates}

  defp model_candidate(%{"kind" => "raw"} = candidate) do
    with :ok <- exact_fields(candidate, @raw_candidate_fields, :candidate) do
      bounded_text(candidate["bytes"], 256 * 1_024, :candidate)
    end
  end

  defp model_candidate(%{"kind" => "final"} = candidate) do
    with :ok <- exact_fields(candidate, @final_candidate_fields, :candidate),
         true <- is_map(candidate["document"]) or {:error, :candidate} do
      canonical(candidate["document"], 256 * 1_024, :candidate)
    end
  end

  defp model_candidate(_candidate), do: {:error, :candidate}

  defp preflight_candidate(index, candidates)
       when is_integer(index) and index > 0 and index <= length(candidates) do
    case Enum.at(candidates, index - 1) do
      %{"kind" => "final"} -> :ok
      _candidate -> {:error, :preflight_candidate}
    end
  end

  defp preflight_candidate(_index, _candidates), do: {:error, :preflight_candidate_index}

  defp expectation(value) do
    with :ok <- exact_fields(value, @expect_fields, :expect),
         :ok <- object_list(value["hard"], 256, :hard),
         :ok <- object_list(value["trajectory"], 256, :trajectory) do
      object_list(value["quality_rubric"], 256, :quality_rubric)
    end
  end

  defp catalog(value) do
    with :ok <- exact_fields(value, @catalog_fields, :tool_catalog),
         true <- value["version"] == 1 or {:error, :tool_catalog},
         servers when is_list(servers) and servers != [] and length(servers) <= 16 <-
           value["servers"],
         true <-
           Enum.all?(servers, fn
             %{"name" => name, "tools" => tools}
             when map_size(%{"name" => name, "tools" => tools}) == 2 ->
               reference(name, :server) == :ok and is_list(tools) and tools != []

             _invalid ->
               false
           end) or {:error, :tool_catalog},
         :ok <- canonical(value, @maximum_catalog_bytes, :tool_catalog) do
      :ok
    else
      _invalid -> {:error, :tool_catalog}
    end
  end

  defp tags(tags), do: references(tags, 64, :tags)

  defp references(values, maximum, field)
       when is_list(values) and values != [] and length(values) <= maximum do
    if Enum.all?(values, &(reference(&1, field) == :ok)) and Enum.uniq(values) == values,
      do: :ok,
      else: {:error, field}
  end

  defp references(_values, _maximum, field), do: {:error, field}

  defp object_list(values, maximum, _field)
       when is_list(values) and length(values) <= maximum and is_integer(maximum) do
    if Enum.all?(values, &is_map/1), do: :ok, else: {:error, :object_list}
  end

  defp object_list(_values, _maximum, field), do: {:error, field}

  defp exact_fields(value, fields, _field) when is_map(value) do
    if Enum.sort(Map.keys(value)) == Enum.sort(fields), do: :ok, else: {:error, :fields}
  end

  defp exact_fields(_value, _fields, field), do: {:error, field}

  defp exact_fields(value, required, optional, _field) when is_map(value) do
    fields = Map.keys(value)
    allowed = MapSet.new(required ++ optional)

    if Enum.all?(required, &(&1 in fields)) and MapSet.subset?(MapSet.new(fields), allowed),
      do: :ok,
      else: {:error, :fields}
  end

  defp exact_fields(_value, _required, _optional, field), do: {:error, field}

  defp canonical(value, maximum, field) do
    case CanonicalJSON.validate(value, max_bytes: maximum) do
      :ok -> :ok
      {:error, _reason} -> {:error, field}
    end
  end

  defp bounded_text(value, maximum, _field)
       when is_binary(value) and value != "" and byte_size(value) <= maximum,
       do: :ok

  defp bounded_text(_value, _maximum, field), do: {:error, field}

  defp reference(value, _field) when is_binary(value) do
    if Regex.match?(@reference_regex, value), do: :ok, else: {:error, :reference}
  end

  defp reference(_value, field), do: {:error, field}

  defp optional_reference(nil, _field), do: :ok
  defp optional_reference(value, field), do: reference(value, field)

  defp unique(cases) do
    ids = Enum.map(cases, & &1.id)

    if Enum.uniq(ids) == ids,
      do: {:ok, cases},
      else: {:error, {:invalid_world_cases, :duplicate_id}}
  end

  defp sha256(value), do: :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)
end
