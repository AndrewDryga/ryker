defmodule Ryker.GitHub.Binding do
  @moduledoc """
  Trusted placement for one GitHub App installation and repository.

  Signed webhook payloads identify the item inside this binding. They cannot
  move work to another installation or repository.
  """

  alias Ryker.Ingress.WorkProfile

  @default_max_body_bytes 40_000
  @maximum_id 9_223_372_036_854_775_807
  @fields [
    :authorized_actor_ids,
    :installation_id,
    :max_body_bytes,
    :name,
    :repository_full_name,
    :repository_id,
    :responder_actor_id,
    :secret,
    :work_profile
  ]
  @required_fields @fields -- [:max_body_bytes, :work_profile]
  @name_regex ~r/\A[a-z][a-z0-9_-]{0,63}\z/
  @repository_regex ~r/\A[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+\z/
  @maximum_authorized_actors 1_024

  @enforce_keys @fields
  defstruct @fields

  @type t :: %__MODULE__{
          authorized_actor_ids: [pos_integer()],
          installation_id: pos_integer(),
          max_body_bytes: pos_integer(),
          name: String.t(),
          repository_full_name: String.t(),
          repository_id: pos_integer(),
          responder_actor_id: pos_integer(),
          secret: binary(),
          work_profile: WorkProfile.t() | nil
        }

  @spec new(keyword() | map()) :: {:ok, t()} | {:error, term()}
  def new(attributes) do
    with {:ok, attributes} <- normalize_attributes(attributes),
         {:ok, work_profile} <-
           WorkProfile.prepare(Map.get(attributes, :work_profile)),
         attributes <- Map.put(attributes, :work_profile, work_profile),
         attributes <- normalize_actor_ids(attributes),
         binding <- struct!(__MODULE__, attributes),
         :ok <- validate(binding) do
      {:ok, binding}
    end
  end

  @doc false
  @spec authorize_payload(t(), map()) :: :ok | {:error, term()}
  def authorize_payload(
        %__MODULE__{
          installation_id: installation_id,
          repository_full_name: repository_name,
          repository_id: repository_id
        },
        %{
          "installation" => %{"id" => installation_id},
          "repository" => %{"full_name" => repository_name, "id" => repository_id}
        }
      ),
      do: :ok

  def authorize_payload(%__MODULE__{installation_id: expected}, %{
        "installation" => %{"id" => actual}
      })
      when actual != expected,
      do: {:error, {:invalid_github_input, :installation}}

  def authorize_payload(%__MODULE__{}, %{"installation" => %{"id" => _id}}),
    do: {:error, {:invalid_github_input, :repository}}

  def authorize_payload(%__MODULE__{}, _payload),
    do: {:error, {:invalid_github_input, :installation}}

  def authorize_payload(_binding, _payload),
    do: {:error, {:invalid_github_input, :binding}}

  defp normalize_attributes(attributes) when is_list(attributes) do
    if Keyword.keyword?(attributes) and
         Enum.uniq(Keyword.keys(attributes)) == Keyword.keys(attributes) do
      attributes |> Map.new() |> normalize_attributes()
    else
      {:error, {:invalid_github_binding, :fields}}
    end
  end

  defp normalize_attributes(%{} = attributes) do
    keys = Map.keys(attributes)

    if Enum.sort(keys -- @fields) == [] and Enum.all?(@required_fields, &(&1 in keys)) do
      {:ok,
       attributes
       |> Map.put_new(:max_body_bytes, @default_max_body_bytes)
       |> Map.put_new(:work_profile, nil)}
    else
      {:error, {:invalid_github_binding, :fields}}
    end
  end

  defp normalize_attributes(_attributes), do: {:error, {:invalid_github_binding, :fields}}

  defp validate(binding) do
    validations = [
      {valid_actor_ids?(binding.authorized_actor_ids), :authorized_actor_ids},
      {positive_id?(binding.installation_id), :installation_id},
      {is_integer(binding.max_body_bytes) and binding.max_body_bytes >= 1_024 and
         binding.max_body_bytes <= @default_max_body_bytes, :max_body_bytes},
      {is_binary(binding.name) and Regex.match?(@name_regex, binding.name), :name},
      {is_binary(binding.repository_full_name) and
         Regex.match?(@repository_regex, binding.repository_full_name), :repository_full_name},
      {positive_id?(binding.repository_id), :repository_id},
      {positive_id?(binding.responder_actor_id) and
         binding.responder_actor_id not in binding.authorized_actor_ids, :responder_actor_id},
      {is_binary(binding.secret) and byte_size(binding.secret) >= 32 and
         byte_size(binding.secret) <= 1_024, :secret}
    ]

    Enum.reduce_while(validations, :ok, fn
      {true, _field}, :ok -> {:cont, :ok}
      {false, field}, :ok -> {:halt, {:error, {:invalid_github_binding, field}}}
    end)
  end

  defp positive_id?(value),
    do: is_integer(value) and value > 0 and value <= @maximum_id

  defp normalize_actor_ids(%{authorized_actor_ids: ids} = attributes) when is_list(ids),
    do: Map.put(attributes, :authorized_actor_ids, Enum.sort(Enum.uniq(ids)))

  defp normalize_actor_ids(attributes), do: attributes

  defp valid_actor_ids?(ids) do
    is_list(ids) and ids != [] and length(ids) <= @maximum_authorized_actors and
      Enum.all?(ids, &positive_id?/1)
  end
end
