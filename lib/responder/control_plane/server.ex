defmodule Responder.ControlPlane.Server do
  @moduledoc """
  Optional loopback-only local control plane.

  Loopback reach is the v1 operator identity. Mutations still require a native
  two-step confirmation with a process-local CSRF token, and the listener
  refuses public bind addresses.
  """

  alias Responder.ControlPlane.{Actions, Projection, Router}
  alias Responder.Ingress.WorkProfile
  alias Responder.Observability

  @loopback_v4 {127, 0, 0, 1}
  @loopback_v6 {0, 0, 0, 0, 0, 0, 0, 1}
  @fields [:csrf_secret, :ip, :port, :work_profile]

  @spec child_spec(keyword() | map()) :: Supervisor.child_spec()
  def child_spec(configuration) do
    options = options!(configuration)

    Bandit.child_spec(
      ip: options.ip,
      plug:
        {Router,
         %{
           actions: Actions.callbacks(options.work_profile),
           csrf_secret: options.csrf_secret,
           observability: Observability.callbacks(),
           projection: Projection.callbacks()
         }},
      port: options.port,
      startup_log: false
    )
    |> Map.put(:id, __MODULE__)
  end

  @doc false
  @spec options!(keyword() | map()) :: map()
  def options!(configuration) do
    configuration = normalize!(configuration)
    port = Map.fetch!(configuration, :port)
    ip = Map.get(configuration, :ip, @loopback_v4)

    csrf_secret =
      Map.get_lazy(configuration, :csrf_secret, fn -> :crypto.strong_rand_bytes(32) end)

    work_profile = Map.get(configuration, :work_profile)

    unless is_integer(port) and port in 1..65_535,
      do: raise(ArgumentError, "control-plane port must be between 1 and 65535")

    unless ip in [@loopback_v4, @loopback_v6],
      do: raise(ArgumentError, "control-plane IP must be loopback")

    unless is_binary(csrf_secret) and byte_size(csrf_secret) == 32,
      do: raise(ArgumentError, "control-plane CSRF secret must be 32 bytes")

    work_profile =
      case WorkProfile.prepare(work_profile) do
        {:ok, %WorkProfile{} = profile} -> profile
        _invalid -> raise ArgumentError, "control-plane work profile is invalid"
      end

    %{csrf_secret: csrf_secret, ip: ip, port: port, work_profile: work_profile}
  end

  defp normalize!(configuration) when is_list(configuration) do
    if Keyword.keyword?(configuration) and
         Enum.uniq(Keyword.keys(configuration)) == Keyword.keys(configuration) do
      normalize!(Map.new(configuration))
    else
      raise ArgumentError, "control-plane configuration must use unique fields"
    end
  end

  defp normalize!(%{} = configuration) do
    keys = Map.keys(configuration)

    if :port in keys and :work_profile in keys and keys -- @fields == [],
      do: configuration,
      else:
        raise(
          ArgumentError,
          "control-plane configuration must contain a port and work profile plus optional IP and CSRF secret"
        )
  end

  defp normalize!(_configuration),
    do: raise(ArgumentError, "control-plane configuration must be a map or keyword list")
end
