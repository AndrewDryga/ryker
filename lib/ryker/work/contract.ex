defmodule Ryker.Work.Contract do
  @moduledoc "The host-selected model contract for one durable Work execution mode."

  alias Ryker.Work.Final

  @shadow_fixed_tools MapSet.new(~w(
    get_work_state
    cite_source
    record_finding
    list_automations
    get_automation
    search_memory
    validate_final
  ))

  @effectful_platform_tools MapSet.new(~w(
    cancel_github_ci
    post_slack_message
    rerun_github_ci
    set_github_reaction
    set_slack_reaction
    submit_github_review
  ))

  @type t :: %{
          contract_version: String.t(),
          mode: :live | :shadow,
          output_schema: map()
        }

  @spec select(:live | :shadow) :: {:ok, t()} | {:error, term()}
  def select(:live) do
    {:ok,
     %{
       contract_version: "work-final-live-v2",
       mode: :live,
       output_schema: Final.json_schema(:live)
     }}
  end

  def select(:shadow) do
    {:ok,
     %{
       contract_version: "work-final-shadow-v2",
       mode: :shadow,
       output_schema: Final.json_schema(:shadow)
     }}
  end

  def select(_mode), do: {:error, {:invalid_work_contract, :execution_mode}}

  @spec fixed_tool_allowed?(:live | :shadow, String.t()) :: boolean()
  def fixed_tool_allowed?(:live, name) when is_binary(name), do: true
  def fixed_tool_allowed?(:shadow, name), do: MapSet.member?(@shadow_fixed_tools, name)
  def fixed_tool_allowed?(_mode, _name), do: false

  @spec platform_tool_allowed?(:live | :shadow, String.t()) :: boolean()
  def platform_tool_allowed?(:live, name) when is_binary(name), do: true

  def platform_tool_allowed?(:shadow, name) when is_binary(name),
    do: not MapSet.member?(@effectful_platform_tools, name)

  def platform_tool_allowed?(_mode, _name), do: false

  @spec authorize_continuation(t(), map() | nil, map()) :: :ok | {:error, term()}
  def authorize_continuation(
        %{contract_version: version},
        %{session_id: session_id, submission: %{"contract_version" => version}},
        %{id: session_id}
      ),
      do: :ok

  def authorize_continuation(
        _contract,
        %{session_id: session_id},
        %{id: session_id}
      ),
      do: {:error, {:invalid_work_contract, :continuation_variant}}

  def authorize_continuation(_contract, _previous, _session), do: :ok
end
