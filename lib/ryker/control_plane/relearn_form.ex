defmodule Ryker.ControlPlane.RelearnForm do
  @moduledoc """
  The relearning form's submission, however it arrives: through the console's
  LiveView, which shows a refusal inside the panel the person chose sources
  in, or as a plain POST from a page without JavaScript
  (`Ryker.ControlPlane.Router`). Both read the same fields, check the same
  confirmation and run the same operation.
  """
  alias Ryker.CanonicalJSON
  alias Ryker.ControlPlane.{CSRF, RelearnPanel}
  alias Ryker.Crypto
  alias Ryker.Maps
  alias Ryker.Operator

  @doc """
  Relearns topic `id` (`kind` `"relearn"`), or chooses new sources for the
  learning request `id` already made for it (`"reselect"`), from the form's
  fields once its confirmation token matches what the panel was drawn for:
  `{:ok, batch_id}`, or `{:error, reason}` for `RelearnPanel.reason/1` to put
  in words. `:form` is a field out of shape and `:token` a form drawn for a
  version of the topic that has since changed.
  """
  @spec submit(String.t(), String.t(), map(), String.t(), binary()) ::
          {:ok, Ecto.UUID.t()} | {:error, term()}
  def submit("relearn", id, params, actor_ref, secret) do
    with {:ok, id} <- uuid(id),
         {:ok, form} <- parse(params, [:version, :generation]),
         :ok <-
           confirmed(
             secret,
             "knowledge:relearn",
             RelearnPanel.resource(id, form.version, form.generation),
             form.token
           ) do
      id
      |> Operator.Learning.rebuild(
        form.version,
        form.generation,
        form.sources,
        actor_ref,
        "control-plane:knowledge-relearn:#{id}:#{form.version}:#{form.generation}"
      )
      |> batch()
    end
  end

  def submit("reselect", id, params, actor_ref, secret) do
    with {:ok, id} <- uuid(id),
         {:ok, form} <- parse(params, [:budget_version, :version, :generation]),
         :ok <-
           confirmed(
             secret,
             "learning:reselect",
             RelearnPanel.reselect_resource(
               id,
               form.budget_version,
               form.version,
               form.generation
             ),
             form.token
           ) do
      id
      |> Operator.Learning.reselect(
        form.budget_version,
        %{version: form.version, generation: form.generation},
        form.sources,
        actor_ref,
        "control-plane:learning-reselect:#{id}:#{form.budget_version}"
      )
      |> batch()
    end
  end

  def submit(_kind, _id, _params, _actor_ref, _secret), do: {:error, :form}

  @doc """
  The form's fields, checked: the token, the chosen sources (1 to 16, each a
  source the panel issued, none twice), and the versions `fields` names.
  `{:ok, form}`, or `{:error, :form}` for anything else, extra fields included.
  The panel's own `kind` and `target` are read where the form arrives.
  """
  @spec parse(map(), [atom()]) :: {:ok, map()} | {:error, :form}
  def parse(%{"_token" => token, "sources" => sources} = params, fields) when is_binary(token) do
    keys = Enum.map(fields, &Atom.to_string/1)

    with true <-
           Maps.exact_keys?(params, ["_token", "sources" | keys], ["kind", "target"]),
         {:ok, versions} <- versions(params, fields),
         {:ok, sources} <- selection(sources) do
      {:ok, Map.merge(versions, %{token: token, sources: sources})}
    else
      _invalid -> {:error, :form}
    end
  end

  def parse(_params, _fields), do: {:error, :form}

  defp uuid(id) do
    case Ecto.UUID.cast(id) do
      {:ok, ^id} -> {:ok, id}
      _invalid -> {:error, :form}
    end
  end

  defp confirmed(secret, action, resource, token) do
    if CSRF.valid?(secret, action, resource, token), do: :ok, else: {:error, :token}
  end

  defp batch({:ok, %{outcome: %{"batch_id" => batch_id}}}), do: {:ok, batch_id}
  defp batch({:error, reason}), do: {:error, reason}

  defp versions(params, fields) do
    Enum.reduce_while(fields, {:ok, %{}}, fn field, {:ok, parsed} ->
      minimum = if field == :budget_version, do: 0, else: 1

      case version(params[Atom.to_string(field)], minimum) do
        number when is_integer(number) -> {:cont, {:ok, Map.put(parsed, field, number)}}
        nil -> {:halt, {:error, :form}}
      end
    end)
  end

  defp version(value, minimum) when is_binary(value) do
    case Integer.parse(value) do
      {number, ""} when number >= minimum and number <= 2_147_483_647 -> number
      _ -> nil
    end
  end

  defp version(_value, _minimum), do: nil

  defp selection(values) when is_list(values) and length(values) in 1..16 do
    sources = Enum.map(values, &source/1)
    unique = Enum.uniq_by(sources, & &1["source_input_id"])

    if Enum.all?(sources, &is_map/1) and length(unique) == length(sources),
      do: {:ok, sources},
      else: {:error, :form}
  end

  defp selection(_values), do: {:error, :form}

  defp source(value) when is_binary(value) and byte_size(value) <= 512 do
    with {:ok, raw} <- Base.url_decode64(value, padding: false),
         {:ok,
          %{"source_input_id" => id, "revision" => revision, "fingerprint" => fingerprint} =
            source} <- Jason.decode(raw),
         true <- Maps.exact_keys?(source, ["fingerprint", "revision", "source_input_id"]),
         {:ok, ^id} <- Ecto.UUID.cast(id),
         true <- is_integer(revision) and revision >= 1 and revision <= 9_223_372_036_854_775_807,
         true <- Crypto.sha256_hex?(fingerprint),
         true <- raw == CanonicalJSON.encode!(source) do
      source
    else
      _ -> nil
    end
  end

  defp source(_value), do: nil
end
