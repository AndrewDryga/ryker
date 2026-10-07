defmodule Ryker.Settings.Work do
  @moduledoc """
  Where Work runs and on which models.

  The workspace names an enrolled worker workspace; a browser never invents
  one. Each kind of work the bundled worker runs has its own ordered list of
  models: routing, conversation, standard, deep and contributor work,
  schedules, incident rooms and learning. The first is used; each later one is
  fallback Coop moves to when the one before it hits a usage limit. Invalid
  sign-ins require repair rather than fallback. A model is `provider:model/effort@account`, one
  account each, and Coop takes at most four.

  `model_accounts` lists the accounts the worker has signed in, as
  `provider@name`. A model may only name a listed account; Coop validates the
  actual worker credentials when admitting the immutable job's target ladder.
  `ready_routing_sessions` is how
  many routing sessions Ryker starts ahead of time (`Ryker.Admission.ReadyPool`);
  0 turns that off.

  The local routing model is a model the operator runs, such as the one
  `scripts/routing-model-service.sh` runs on the Mac beside Ryker, reached at `local_routing_endpoint` and asked for
  `local_routing_model`. At `local_routing_mode` `:shadow` it is asked each
  routing prompt after the provider has decided (`Ryker.LocalRouting`); it
  never decides anything. Comparing needs both an endpoint and a model, and
  the endpoint follows `Ryker.LocalRouting.Endpoint`.
  """
  use Ryker, :schema

  @primary_key {:id, :string, autogenerate: false}
  # The providers the bundled worker runs, each of which takes these four
  # reasoning efforts. Gemini takes only low and high, and only on some
  # models, so it is not offered until it has an effort list of its own.
  @providers ~w(codex claude)
  @efforts ~w(low medium high xhigh)
  @account ~r/\A(codex|claude)@[a-z0-9][a-z0-9_-]{0,63}\z/
  @most_models 4
  @most_accounts 16
  @models [
    routing_models: ["codex:gpt-5.6-sol/medium@default"],
    conversation_models: ["codex:gpt-5.6-terra/medium@default"],
    standard_models: ["codex:gpt-5.6-sol/medium@default"],
    deep_models: ["codex:gpt-5.6-sol/xhigh@default"],
    contributor_models: ["codex:gpt-5.6-sol/medium@default"],
    schedule_models: ["codex:gpt-5.6-sol/medium@default"],
    incident_models: ["codex:gpt-5.6-sol/medium@default"],
    learning_models: ["codex:gpt-5.6-sol/medium@default"]
  ]
  @model_fields Keyword.keys(@models)
  @maximum_ready_routing_sessions 5
  # A model as a local server lists it: qwen2.5:3b, llama3.2:3b-instruct-q4_K_M
  # or hf.co/bartowski/Qwen2.5-3B-Instruct-GGUF:Q4_K_M.
  @local_model ~r/\A[A-Za-z0-9][A-Za-z0-9._:\/@+-]{0,199}\z/

  schema "work_settings" do
    field(:workspace_ref, :string)
    field(:ready_routing_sessions, :integer, default: 1)
    field(:model_accounts, {:array, :string}, default: ["codex@default"])

    for {name, default} <- @models do
      field(name, {:array, :string}, default: default)
    end

    field(:local_routing_mode, Ecto.Enum, values: [:off, :shadow], default: :off)
    field(:local_routing_endpoint, :string)
    field(:local_routing_model, :string)
  end

  @type t :: %__MODULE__{}

  def model_fields, do: @model_fields
  def providers, do: @providers
  def efforts, do: @efforts
  def most_models, do: @most_models
  def most_accounts, do: @most_accounts
  def maximum_ready_routing_sessions, do: @maximum_ready_routing_sessions

  @doc "Whether `value` names a model the way a local server lists one."
  @spec local_model?(term()) :: boolean()
  def local_model?(value), do: is_binary(value) and Regex.match?(@local_model, value)

  @doc "Whether `value` is an account as Model accounts lists it: `provider@name`."
  @spec account?(term()) :: boolean()
  def account?(value), do: is_binary(value) and Regex.match?(@account, value)

  @doc """
  Whether typing more could still make `value` an account, so a form can say
  what is wrong with one as it is typed without refusing it half-written.
  """
  @spec account_start?(String.t()) :: boolean()
  def account_start?(value) when is_binary(value) do
    account?(value) or account?(value <> "x") or
      Enum.any?(@providers, &String.starts_with?(&1 <> "@", value))
  end

  @doc "The account a model runs on, as `provider@name`."
  @spec account(String.t()) :: String.t() | nil
  def account(target) when is_binary(target) do
    case String.split(target, "@", parts: 2) do
      [head, name] -> (head |> String.split(":", parts: 2) |> hd()) <> "@" <> name
      [_no_account] -> nil
    end
  end

  def account(_target), do: nil
end
