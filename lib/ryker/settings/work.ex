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
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :string, autogenerate: false}
  # The providers the bundled worker runs, each of which takes these four
  # reasoning efforts. Gemini takes only low and high, and only on some
  # models, so it is not offered until it has an effort list of its own.
  @providers ~w(codex claude)
  @efforts ~w(low medium high xhigh)
  @target ~r/\A(codex|claude):[a-z0-9][a-z0-9._-]{0,63}\/(low|medium|high|xhigh)@[a-z0-9][a-z0-9_-]{0,63}\z/
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
  # A request can move between these three kinds of work, so Ryker pins one
  # set of permissions for all of them (`Ryker.Ingress.WorkProfile`), and Coop
  # counts the provider and account of each model, in order, as part of it.
  @shared_accounts [:conversation_models, :standard_models, :deep_models]
  @fields [:workspace_ref, :ready_routing_sessions, :model_accounts | @model_fields]
  @maximum_ready_routing_sessions 5

  schema "work_settings" do
    field(:workspace_ref, :string)
    field(:ready_routing_sessions, :integer, default: 1)
    field(:model_accounts, {:array, :string}, default: ["codex@default"])

    for {name, default} <- @models do
      field(name, {:array, :string}, default: default)
    end
  end

  def fields, do: @fields
  def model_fields, do: @model_fields
  def providers, do: @providers
  def efforts, do: @efforts
  def most_models, do: @most_models
  def most_accounts, do: @most_accounts
  def maximum_ready_routing_sessions, do: @maximum_ready_routing_sessions

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

  def changeset(current, attributes, snapshot) do
    current
    |> cast(attributes, @fields)
    |> validate_length(:workspace_ref, min: 1, max: 256)
    |> validate_required([:ready_routing_sessions, :model_accounts | @model_fields])
    |> validate_number(:ready_routing_sessions,
      greater_than_or_equal_to: 0,
      less_than_or_equal_to: @maximum_ready_routing_sessions
    )
    |> check_constraint(:ready_routing_sessions,
      name: :work_settings_ready_routing_sessions_valid
    )
    |> validate_accounts()
    |> validate_models(current, snapshot)
    |> validate_shared_accounts()
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

  # Each check below runs only for a value this save changes, so a save of
  # something else never trips over what is already saved.
  defp validate_accounts(changeset) do
    validate_change(changeset, :model_accounts, fn :model_accounts, accounts ->
      reason =
        cond do
          length(accounts) not in 1..@most_accounts -> :length
          not Enum.all?(accounts, &account?/1) -> :format
          Enum.uniq(accounts) != accounts -> :list
          stranded?(changeset, accounts) -> :in_use
          true -> nil
        end

      if reason, do: [model_accounts: {"is invalid", validation: reason}], else: []
    end)
  end

  # A model this save leaves as it is must keep its account. One this save
  # changes is checked against the new accounts with its own field.
  defp stranded?(changeset, accounts) do
    Enum.any?(@model_fields, fn field ->
      not Map.has_key?(changeset.changes, field) and
        Enum.any?(get_field(changeset, field) || [], &(account(&1) not in accounts))
    end)
  end

  defp validate_models(changeset, current, snapshot) do
    accounts = get_field(changeset, :model_accounts) || []
    priced = MapSet.new(snapshot.pricing_rates, & &1.execution_target)

    Enum.reduce(@model_fields, changeset, &validate_model_list(&2, &1, current, accounts, priced))
  end

  defp validate_model_list(changeset, field, current, accounts, priced) do
    # A model already saved for this kind of work stays, priced or not.
    saved = MapSet.new(Map.get(current || %{}, field) || [], &price_key/1)
    offered = MapSet.union(priced, saved)

    validate_change(changeset, field, fn ^field, models ->
      model_errors(field, model_reason(models, accounts, offered))
    end)
  end

  defp model_errors(_field, nil), do: []
  defp model_errors(field, reason), do: [{field, {"is invalid", validation: reason}}]

  defp model_reason(models, accounts, offered) do
    cond do
      length(models) not in 1..@most_models -> :length
      not Enum.all?(models, &(is_binary(&1) and Regex.match?(@target, &1))) -> :format
      Enum.uniq(models) != models -> :duplicate
      Enum.any?(models, &(account(&1) not in accounts)) -> :unknown_account
      Enum.any?(models, &(price_key(&1) not in offered)) -> :unpriced
      true -> nil
    end
  end

  defp validate_shared_accounts(changeset) do
    if Enum.any?(@shared_accounts, &Map.has_key?(changeset.changes, &1)) do
      [first | others] = @shared_accounts
      expected = accounts_in_order(changeset, first)
      Enum.reduce(others, changeset, &same_accounts(&2, &1, expected))
    else
      changeset
    end
  end

  defp same_accounts(changeset, field, expected) do
    if accounts_in_order(changeset, field) == expected,
      do: changeset,
      else:
        add_error(changeset, field, "must use the same accounts as conversation",
          validation: :shared_accounts
        )
  end

  defp accounts_in_order(changeset, field),
    do: Enum.map(get_field(changeset, field) || [], &account/1)

  # The provider and model a saved price names: the model without its effort
  # and account.
  defp price_key(model) when is_binary(model),
    do: model |> String.split("@", parts: 2) |> hd() |> String.split("/", parts: 2) |> hd()

  defp price_key(_model), do: nil
end
