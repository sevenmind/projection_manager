defmodule ProjectionManager do
  @moduledoc """
  ProjectionManager manages projection projectors.

  Given init arguments, ProjectionManager queries its provided projector for running
  projections, starts workers to build each projection, and handoff when an old
  projection version is terminated.

  Add ProjectionManager to your supervision tree

  ```elixir
  defmodule MyApp.Application do
    use Application

    def start(_type, _args) do
      import Supervisor.Spec

      children = [
        supervisor(Supervisor, [
        [],
        [strategy: :one_for_one, name: MyApp.ProjectionSupervisor]
      ]),
      supervisor(
        ProjectionManager,
        [%{
          projector: MyApp.MyProjector,
          supervisor: MyApp.ProjectionSupervisor,
          polling_frequency: 10_000
        }])
      ]

        opts = [strategy: :one_for_one, name: MyApp.Supervisor]
      Supervisor.start_link(children, opts)
    end
  end
  ```

  All management of projection version , queries, and database interactions are
  the responsibility of Projector callbacks and the supervised projector.

  ProjectionManager has handles moving projections from `:init` to `:building`
  to `:active` and finally to `:terminated`. These state transitions are managed in
  the `Projector.projection_status/1` callback.

  ProjectionManager starts a supevised child task for all projectors returned
  from `Projector.list_projections/1`. The status of each projection is updated
  via `Projector.projection_status/1`.

  If there are two projectors with the same `:id` but differing `:version`,
  ProjectionManager will wait until the largest value `:version` has `status:
  :active`. Then any other versions projectors will be stopped and the
  `Projector.after_terminate/1` callback will fire.


  ProjectionManager checks for new projections or incremented versions every
  `polling_frequency` ms, default of `10_000`.
  """

  defprotocol Projector do
    @moduledoc """
    `ProjectionManager.Projector` is a protocol used to define projections (or any
    other supervised resource which requires versioning)

    Example implementation

    ```elixir
    defmodule MyApp.MyProjector do
      defstruct [:id, :projection_id, :version, :child, :status]

      defimpl ProjectionManager.Projector do
        def child_spec(projector) do
          Worker.child_spec(projector: projector)
        end

        def list_projections(projector) do
          MyRepo.all(Resource)
          |> Enum.map(fn %{id: id, version: version} ->
            %MyProjector{
              projector
              | projection_id: "\#{id}.v\#{version}",
              id: id,
              version: version
            }
          end)
        end

        def projection_status(%MyProjector{status: status} = projector) when status in [:init, :building] do
          if projection_ready?(projector) do
            :active
          else
            :building
          end
        end

        def projection_status(%MyProjector{status: status}), do: status

        def after_terminate(_) do
          Repo.Resoucrce.delete_all()
          # ....
        end
      end
    end
    ```

    """
    defstruct [:id, :projection_id, :version, :child, :status]

    @callback child_spec(map) :: Supervisor.child_spec()
    def child_spec(projector)
    # def repo(projector)

    @callback list_projections(map) :: [map]
    def list_projections(projector)

    @type status :: :init | :active | :building | :terminated

    @callback projection_status(map) :: status()
    def projection_status(projector)

    @callback after_terminate(map) :: any
    def after_terminate(projector)
  end

  use GenServer
  require Logger
  alias ProjectionManager

  # @derive Jason.Encoder
  defstruct [:projections, :supervisor, :projector, polling_frequency: 10_000]

  def child_spec(arg) when is_map(arg) do
    %{
      id: Map.get(arg, :id, __MODULE__),
      start: {__MODULE__, :start_link, [arg]}
    }
  end

  def start_link(%{projector: _, supervisor: _} = args) do
    GenServer.start_link(__MODULE__, args, name: Map.get(args, :name, __MODULE__))
  end

  @impl true
  def init(%{supervisor: supervisor, projector: projector} = state) do
    projections =
      projector
      |> list_projections()
      |> Enum.map(&start_projection_child(&1, supervisor))

    state =
      ProjectionManager
      |> struct(state)
      |> Map.merge(%{projections: projections})

    Process.send_after(self(), :refresh, state.polling_frequency)

    {:ok, state, {:continue, :update_projection_status}}
  end

  # updates projection status from projector callback
  @impl true
  def handle_continue(:update_projection_status, %{projections: projections} = state) do
    # Logger.debug("ProjectionManager :update_projection_status")

    projections =
      projections
      |> Enum.map(fn pj ->
        %{pj | status: Projector.projection_status(pj)}
      end)

    {:noreply, %{state | projections: projections}, {:continue, :check_for_handovers}}
  end

  def handle_continue(:check_for_handovers, %{projections: projections} = state) do
    # Logger.debug("ProjectionManager :check_for_handovers")

    projections =
      projections
      |> Enum.group_by(& &1.id)
      |> Enum.flat_map(&update_replaced_projections/1)

    if Enum.any?(projections, &(&1.status == :terminated)) do
      {:noreply, %{state | projections: projections}, {:continue, :stop_replaced_projections}}
    else
      {:noreply, state}
    end
  end

  def handle_continue(
        :stop_replaced_projections,
        %{projections: projections, supervisor: supervisor} = state
      ) do
    Logger.debug("ProjectionManager :stop_replaced_projections")
    terminated = Enum.filter(projections, &(&1.status == :terminated))

    Enum.each(terminated, fn %{child: child_pid} ->
      child_name =
        child_pid
        |> Process.info()
        |> Keyword.get(:registered_name)

      Supervisor.terminate_child(supervisor, child_name)
    end)

    Enum.each(terminated, &Projector.after_terminate/1)

    {:noreply, %{state | projections: Enum.reject(projections, &(&1.status == :terminated))}}
  end

  @impl true
  def handle_info(
        :refresh,
        %{
          projections: projections,
          polling_frequency: polling_frequency,
          projector: projector,
          supervisor: supervisor
        } = state
      ) do
    Logger.debug("ProjectionManager :refresh", projections: projection_info(projections))
    Process.send_after(self(), :refresh, polling_frequency)

    projection_ids = Enum.map(projections, & &1.projection_id)

    new_projections =
      projector
      |> list_projections()
      |> Enum.reject(fn %{projection_id: projection_id} = _ -> projection_id in projection_ids end)
      |> Enum.map(&start_projection_child(&1, supervisor))

    projections = Enum.concat(projections, new_projections)

    if Enum.any?(new_projections) do
      Logger.debug("ProjectionManager new projections",
        projections: projection_info(new_projections)
      )
    end

    if Enum.any?(projections, &(&1.status != :active)) do
      {:noreply, %{state | projections: projections}, {:continue, :update_projection_status}}
    else
      {:noreply, %{state | projections: projections}}
    end
  end

  @impl true
  def handle_call(:state, _from, state) do
    {:reply, state, state}
  end

  def state do
    GenServer.call(ProjectionManager, :state)
  end

  defp list_projections(projector) do
    projector
    |> struct()
    |> Projector.list_projections()
  end

  defp start_projection_child(%{child: pid} = projection, _supervisor) when is_pid(pid),
    do: projection

  defp start_projection_child(%{child: nil} = projection, supervisor) do
    child_spec = Projector.child_spec(projection)
    {:ok, pid} = Supervisor.start_child(supervisor, child_spec)
    %{projection | child: pid, status: :init}
  end

  defp projection_info(projections) do
    Enum.into(projections, %{}, fn pj -> {pj.projection_id, pj.status} end)
  end

  defp update_replaced_projections({_, projections}) when length(projections) == 1,
    do: projections

  defp update_replaced_projections({_, projections}) do
    latest = Enum.max_by(projections, & &1.version)

    # if most recent projection is :active, mark any others as :terminated]
    if latest.status == :active do
      others =
        projections
        |> Enum.reject(fn x -> x.projection_id == latest.projection_id end)
        |> Enum.map(fn pj -> %{pj | status: :terminated} end)

      [latest | others]
    else
      projections
    end
  end
end
