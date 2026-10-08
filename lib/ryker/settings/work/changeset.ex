defmodule Ryker.Settings.Work.Changeset do
  @moduledoc "Changes to where Work runs and on which models (`Ryker.Settings.Work`)."
  @behaviour Ryker.Settings.Section.Changeset
  use Ryker, :changeset
  alias Ryker.LocalRouting
  alias Ryker.Settings.Work

  @target ~r/\A(codex|claude):[a-z0-9][a-z0-9._-]{0,63}\/(low|medium|high|xhigh)@[a-z0-9][a-z0-9_-]{0,63}\z/
  @model_fields Work.model_fields()
  # A request can move between these three kinds of work, so Ryker pins one
  # set of permissions for all of them (`Ryker.Ingress.WorkProfile`), and Coop
  # counts the provider and account of each model, in order, as part of it.
  @shared_accounts [:conversation_models, :standard_models, :deep_models]
  @local_routing_fields [:local_routing_mode, :local_routing_endpoint, :local_routing_model]
  @fields [:workspace_ref, :ready_routing_sessions, :model_accounts | @model_fields] ++
            @local_routing_fields

  @impl true
  def fields, do: @fields

  @impl true
  def update(%Work{} = work, attributes, snapshot) do
    work
    |> cast(attributes, @fields)
    |> validate_length(:workspace_ref, min: 1, max: 256, count: :codepoints)
    |> validate_required([:ready_routing_sessions, :model_accounts | @model_fields])
    |> validate_number(:ready_routing_sessions,
      greater_than_or_equal_to: 0,
      less_than_or_equal_to: Work.maximum_ready_routing_sessions()
    )
    |> check_constraint(:ready_routing_sessions,
      name: :work_settings_ready_routing_sessions_valid
    )
    |> validate_accounts()
    |> validate_models(work, snapshot)
    |> validate_shared_accounts()
    |> validate_local_routing()
  end

  # An endpoint or a model is checked when this save changes it; comparing is
  # checked against what the save leaves, since turning it on with either
  # missing would queue comparisons that can only fail.
  defp validate_local_routing(changeset) do
    changeset =
      changeset
      |> validate_required([:local_routing_mode])
      |> validate_change(:local_routing_endpoint, fn field, endpoint ->
        case LocalRouting.Endpoint.check(endpoint) do
          :ok -> []
          {:error, reason} -> [{field, {"is invalid", validation: reason}}]
        end
      end)
      |> validate_change(:local_routing_model, fn field, model ->
        if Work.local_model?(model), do: [], else: [{field, {"is invalid", validation: :format}}]
      end)
      |> check_constraint(:local_routing_mode, name: :work_settings_local_routing_valid)

    if get_field(changeset, :local_routing_mode) == :shadow,
      do: validate_required(changeset, [:local_routing_endpoint, :local_routing_model]),
      else: changeset
  end

  # Each check below runs only for a value this save changes, so a save of
  # something else never trips over what is already saved.
  defp validate_accounts(changeset) do
    validate_change(changeset, :model_accounts, fn :model_accounts, accounts ->
      reason =
        cond do
          length(accounts) not in 1..Work.most_accounts() -> :length
          not Enum.all?(accounts, &Work.account?/1) -> :format
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
        Enum.any?(get_field(changeset, field) || [], &(Work.account(&1) not in accounts))
    end)
  end

  defp validate_models(changeset, work, snapshot) do
    accounts = get_field(changeset, :model_accounts) || []
    priced = MapSet.new(snapshot.pricing_rates, & &1.execution_target)

    Enum.reduce(@model_fields, changeset, &validate_model_list(&2, &1, work, accounts, priced))
  end

  defp validate_model_list(changeset, field, work, accounts, priced) do
    # A model already saved for this kind of work stays, priced or not.
    saved = MapSet.new(Map.get(work, field) || [], &price_key/1)
    offered = MapSet.union(priced, saved)

    validate_change(changeset, field, fn ^field, models ->
      model_errors(field, model_reason(models, accounts, offered))
    end)
  end

  defp model_errors(_field, nil), do: []
  defp model_errors(field, reason), do: [{field, {"is invalid", validation: reason}}]

  defp model_reason(models, accounts, offered) do
    cond do
      length(models) not in 1..Work.most_models() -> :length
      not Enum.all?(models, &(is_binary(&1) and Regex.match?(@target, &1))) -> :format
      Enum.uniq(models) != models -> :duplicate
      Enum.any?(models, &(Work.account(&1) not in accounts)) -> :unknown_account
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
    do: Enum.map(get_field(changeset, field) || [], &Work.account/1)

  # The provider and model a saved price names: the model without its effort
  # and account.
  defp price_key(model) when is_binary(model),
    do: model |> String.split("@", parts: 2) |> hd() |> String.split("/", parts: 2) |> hd()

  defp price_key(_model), do: nil
end
