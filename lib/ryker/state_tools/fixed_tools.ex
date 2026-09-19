defmodule Ryker.StateTools.FixedTools do
  @moduledoc false

  alias Ryker.Episodes.Origins
  alias Ryker.State.Records
  alias Ryker.Work.{Contract, Final}

  alias Ryker.StateTools.{
    AutomationTools,
    Catalog,
    ErrorCode,
    EvidenceTools,
    MemoryTools,
    RecordWriter,
    SchemaCheck,
    TaskTools,
    WorkStateTools
  }

  @confirmation_tools ~w(propose_automation propose_memory propose_preference request_task)
  @names ~w(
    get_work_state
    cite_source
    record_finding
    request_input
    wait_for
    list_automations
    get_automation
    propose_automation
    plan_goal
    update_goal
    request_task
    search_memory
    propose_memory
    propose_preference
    remember_answer
    update_conversation_summary
    record_feedback
    validate_final
  )

  @spec names() :: [String.t()]
  def names, do: @names

  @spec known?(term()) :: boolean()
  def known?(name), do: name in @names

  defdelegate citation_record?(record, turn, arguments), to: RecordWriter

  @spec list(keyword() | map()) :: [map()]
  def list(options \\ %{}) do
    mode = execution_mode(options)

    options
    |> capabilities()
    |> Catalog.tools(Final.json_schema(mode))
    |> Enum.reject(fn tool ->
      not Contract.fixed_tool_allowed?(mode, tool["name"]) or
        (tool["name"] in @confirmation_tools and not confirmation_surface?(options))
    end)
  end

  @spec call(String.t(), map(), keyword() | map()) :: {:ok, map()} | {:error, String.t()}
  def call(name, arguments, options) when name in @names and is_map(arguments) do
    options = Map.new(options)

    with :ok <- contract_capability_available(name, options),
         :ok <- capability_available(name, arguments, options),
         {:ok, binding} <- tool_binding(options),
         :ok <- SchemaCheck.exact_schema(name, arguments, list(options)) do
      binding =
        Map.merge(binding, %{
          capabilities: capabilities(options),
          cursor_secret: options[:cursor_secret],
          answer_authorizer: options[:answer_authorizer],
          source_tools: Enum.map(options[:additional_tools] || [], & &1["name"])
        })

      case dispatch(name, arguments, binding) do
        {:ok, _result} = success -> success
        {:error, reason} -> {:error, ErrorCode.code(reason)}
      end
    else
      {:error, reason} -> {:error, ErrorCode.code(reason)}
    end
  end

  def call(_name, _arguments, _options), do: {:error, "unknown_tool"}

  defp contract_capability_available(name, options) do
    if Contract.fixed_tool_allowed?(execution_mode(options), name),
      do: :ok,
      else: {:error, :unknown_tool}
  end

  defp dispatch("get_work_state", arguments, binding),
    do: WorkStateTools.get_work_state(arguments, binding)

  defp dispatch("cite_source", arguments, binding),
    do: EvidenceTools.cite_source(arguments, binding)

  defp dispatch("request_input", arguments, binding),
    do: EvidenceTools.request_input(arguments, binding)

  defp dispatch("record_finding", arguments, binding),
    do: EvidenceTools.record_finding(arguments, binding)

  defp dispatch("wait_for", arguments, binding), do: EvidenceTools.wait_for(arguments, binding)

  defp dispatch("list_automations", arguments, binding),
    do: AutomationTools.list_automations(arguments, binding)

  defp dispatch("get_automation", arguments, binding),
    do: AutomationTools.get_automation(arguments, binding)

  defp dispatch("propose_automation", arguments, binding),
    do: AutomationTools.propose_automation(arguments, binding)

  defp dispatch("request_task", arguments, binding),
    do: TaskTools.request_task(arguments, binding)

  defp dispatch("plan_goal", arguments, binding), do: TaskTools.plan_goal(arguments, binding)

  defp dispatch("update_goal", arguments, binding),
    do: TaskTools.update_goal(arguments, binding)

  defp dispatch("search_memory", arguments, binding),
    do: MemoryTools.search_memory(arguments, binding)

  defp dispatch("propose_memory", arguments, binding),
    do: MemoryTools.propose_memory(arguments, binding)

  defp dispatch("propose_preference", arguments, binding),
    do: MemoryTools.propose_preference(arguments, binding)

  defp dispatch("remember_answer", arguments, binding),
    do: MemoryTools.remember_answer(arguments, binding)

  defp dispatch("update_conversation_summary", arguments, binding),
    do: MemoryTools.update_conversation_summary(arguments, binding)

  defp dispatch("record_feedback", arguments, binding),
    do: EvidenceTools.record_feedback(arguments, binding)

  defp dispatch("validate_final", arguments, binding),
    do: WorkStateTools.validate_final(arguments, binding)

  defp tool_binding(options) when is_list(options), do: options |> Map.new() |> tool_binding()

  defp tool_binding(%{
         binding: %{episode: episode, session: session, state_token: token, turn: turn}
       })
       when is_binary(token),
       do: {:ok, %{episode: episode, session: session, state_token: token, turn: turn}}

  defp tool_binding(%{"binding" => binding}), do: tool_binding(%{binding: binding})
  defp tool_binding(_options), do: {:error, :unauthorized}

  defp capability_available(name, _arguments, options) when name in @confirmation_tools do
    if confirmation_surface?(options), do: :ok, else: {:error, :unknown_tool}
  end

  # A question parks the episode until a person answers it, so an episode no
  # person has ever spoken in cannot ask one: the wait would sit open until
  # somebody happened to read the channel. Production had three such questions,
  # every one still open, against seven answered where a person was present.
  defp capability_available("request_input", arguments, options) do
    case tool_binding(options) do
      {:ok, %{episode: %{id: episode_id}} = binding} ->
        operation = RecordWriter.operation_id(binding, "request_input", arguments)

        cond do
          not Origins.person_participated?(episode_id) -> {:error, :no_addressee}
          Records.question_open?(episode_id, operation) -> {:error, :question_already_open}
          true -> :ok
        end

      _unbound ->
        :ok
    end
  end

  defp capability_available("wait_for", _arguments, options) do
    if :event_waits in capabilities(options), do: :ok, else: {:error, :not_configured}
  end

  defp capability_available(_name, _arguments, _options), do: :ok

  defp confirmation_surface?(options) when is_list(options) do
    if Keyword.keyword?(options), do: confirmation_surface?(Map.new(options)), else: true
  end

  defp confirmation_surface?(%{
         binding: %{
           episode: %{destination_transport: transport, execution_mode: execution_mode}
         }
       }),
       do: transport in ["slack", "control_plane", "github"] and execution_mode == :live

  defp confirmation_surface?(%{
         "binding" => %{
           "episode" => %{
             "destination_transport" => transport,
             "execution_mode" => execution_mode
           }
         }
       }),
       do: transport in ["slack", "control_plane", "github"] and execution_mode == "live"

  defp confirmation_surface?(_options), do: true

  defp capabilities(options) when is_list(options) do
    if Keyword.keyword?(options),
      do: Keyword.get(options, :capabilities, [:event_waits, :publication, :schedules]),
      else: []
  end

  defp capabilities(%{} = options),
    do: Map.get(options, :capabilities, [:event_waits, :publication, :schedules])

  defp capabilities(_options), do: []

  defp execution_mode(options) when is_list(options) do
    if Keyword.keyword?(options), do: options |> Map.new() |> execution_mode(), else: :live
  end

  defp execution_mode(%{binding: %{episode: %{execution_mode: mode}}})
       when mode in [:live, :shadow],
       do: mode

  defp execution_mode(%{"binding" => %{"episode" => %{"execution_mode" => "shadow"}}}),
    do: :shadow

  defp execution_mode(_options), do: :live
end
