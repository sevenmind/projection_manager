defmodule TestProj do
  defstruct [:id, :projection_id, :version, :child, :status]

  defmodule Worker do
    def child_spec(arg) do
      %{
        id: __MODULE__,
        start: {__MODULE__, :start_link, [arg]}
      }
    end

    def start_link(args) do
      GenServer.start_link(__MODULE__, args, name: __MODULE__)
    end

    def init(state) do
      {:ok, state}
    end
  end

  defimpl ProjectionManager.Projector do
    def child_spec(projector) do
      Worker.child_spec(proj: projector)
    end

    def list_projections(projector) do
      [projector]
    end

    def projection_status(_projector) do
      :active
    end

    def after_terminate(_) do
      send(self(), :after_terminate)
    end
  end
end

defmodule TestProjListMore do
  defstruct [:id, :projection_id, :version, :child, :status]

  defmodule Worker do
    def child_spec(arg) do
      %{
        id: __MODULE__,
        start: {__MODULE__, :start_link, [arg]}
      }
    end

    def start_link(args) do
      GenServer.start_link(__MODULE__, args, name: __MODULE__)
    end

    def init(state) do
      {:ok, state}
    end
  end

  defimpl ProjectionManager.Projector do
    def child_spec(projector) do
      Worker.child_spec(proj: projector)
    end

    def list_projections(projector) do
      [projector, Map.merge(projector, %{child: self(), projection_id: "uniq"})]
    end

    def projection_status(_projector) do
      :active
    end

    def after_terminate(_) do
      send(self(), :after_terminate)
    end
  end
end

defmodule ProjectionManagerTest do
  use ExUnit.Case

  alias TestProj

  setup do
    {:ok, _} =
      start_supervised(%{
        id: TestSupervisor,
        start:
          {Supervisor, :start_link,
           [
             [],
             [strategy: :one_for_one, name: TestSupervisor]
           ]}
      })

    :ok
  end

  describe "child_spec" do
    test "returns valid child_spec" do
      assert ProjectionManager.child_spec(%{}) == %{
               id: ProjectionManager,
               start: {ProjectionManager, :start_link, [%{}]}
             }
    end
  end

  describe "start_link" do
    test "starts genserver" do
      assert {:ok, _pid} =
               ProjectionManager.start_link(%{supervisor: TestSupervisor, projector: TestProj})
    end
  end

  describe "init" do
    test "starts child projections" do
      assert {:ok,
              %ProjectionManager{
                polling_frequency: _,
                projections: [%TestProj{child: pid}],
                projector: TestProj,
                supervisor: TestSupervisor
              },
              {:continue, :update_projection_status}} =
               ProjectionManager.init(%{supervisor: TestSupervisor, projector: TestProj})

      assert is_pid(pid)
    end
  end

  describe "handle_continue :update_projection_status" do
    test "updates projections statuses" do
      assert {:noreply, %ProjectionManager{projections: [%TestProj{status: :active}]},
              {:continue, :check_for_handovers}} =
               ProjectionManager.handle_continue(:update_projection_status, %ProjectionManager{
                 projections: [%TestProj{status: :init}]
               })
    end
  end

  describe "handle_continue :check_projection_changes" do
    test "when no duplicate projections do nothing" do
      assert {:noreply, %ProjectionManager{projections: [%TestProj{status: :active}]}} =
               ProjectionManager.handle_continue(:check_for_handovers, %ProjectionManager{
                 projections: [%TestProj{id: "0", version: 0, status: :active}]
               })
    end

    test "when no duplicate projections are still building do nothing" do
      assert {:noreply,
              %ProjectionManager{
                projections: [
                  %TestProj{id: "0", version: 0, status: :active},
                  %TestProj{id: "1", version: 0, status: :active}
                ]
              }} =
               ProjectionManager.handle_continue(:check_for_handovers, %ProjectionManager{
                 projections: [
                   %TestProj{id: "0", version: 0, status: :active},
                   %TestProj{id: "1", version: 0, status: :active}
                 ]
               })

      assert {:noreply,
              %ProjectionManager{
                projections: [
                  %TestProj{id: "0", version: 0, status: :active},
                  %TestProj{id: "0", version: 1, status: :building}
                ]
              }} =
               ProjectionManager.handle_continue(:check_for_handovers, %ProjectionManager{
                 projections: [
                   %TestProj{id: "0", version: 0, status: :active},
                   %TestProj{id: "0", version: 1, status: :building}
                 ]
               })
    end

    test "when latest status is active, replace reset" do
      assert {:noreply,
              %ProjectionManager{
                projections: [
                  %TestProj{projection_id: "0.1", id: "0", version: 1, status: :active},
                  %TestProj{projection_id: "0.0", id: "0", version: 0, status: :terminated}
                ]
              },
              {:continue, :stop_replaced_projections}} =
               ProjectionManager.handle_continue(:check_for_handovers, %ProjectionManager{
                 projections: [
                   %TestProj{projection_id: "0.0", id: "0", version: 0, status: :active},
                   %TestProj{projection_id: "0.1", id: "0", version: 1, status: :active}
                 ]
               })
    end
  end

  describe "handle_continue :stop_replaced_projections" do
    test "suspends projector children" do
      assert {:ok,
              %ProjectionManager{
                polling_frequency: _,
                projections: [%TestProj{child: pid}],
                projector: TestProj,
                supervisor: TestSupervisor
              },
              {:continue, :update_projection_status}} =
               ProjectionManager.init(%{supervisor: TestSupervisor, projector: TestProj})

      ProjectionManager.handle_continue(:stop_replaced_projections, %ProjectionManager{
        supervisor: TestSupervisor,
        projections: [
          %TestProj{projection_id: "0.0", id: "0", version: 0, status: :terminated, child: pid},
          %TestProj{projection_id: "0.1", id: "0", version: 1, status: :active}
        ]
      })

      refute Process.alive?(pid)
    end

    test "removes :terminated projections" do
      assert {:noreply,
              %ProjectionManager{
                projections: [
                  %TestProj{projection_id: "0.1", id: "0", version: 1, status: :active}
                ]
              }} =
               ProjectionManager.handle_continue(:stop_replaced_projections, %ProjectionManager{
                 supervisor: TestSupervisor,
                 projections: [
                   %TestProj{
                     projection_id: "0.0",
                     id: "0",
                     version: 0,
                     status: :terminated,
                     child: self()
                   },
                   %TestProj{projection_id: "0.1", id: "0", version: 1, status: :active}
                 ]
               })
    end

    test "calls after_terminate Projector callback" do
      ProjectionManager.handle_continue(:stop_replaced_projections, %ProjectionManager{
        supervisor: TestSupervisor,
        projections: [
          %TestProj{
            projection_id: "0.0",
            id: "0",
            version: 0,
            status: :terminated,
            child: self()
          },
          %TestProj{projection_id: "0.1", id: "0", version: 1, status: :active}
        ]
      })

      assert_received :after_terminate
    end
  end

  describe "handle_info :refresh" do
    test "sends refresh after :polling_frequency" do
      assert {:noreply, _, _} =
               ProjectionManager.handle_info(
                 :refresh,
                 %{
                   polling_frequency: 1,
                   projections: [%TestProj{child: self()}],
                   projector: TestProj,
                   supervisor: TestSupervisor
                 }
               )

      assert_receive :refresh
    end

    test "appends new projections to projections state" do
      # defmodule

      assert {:noreply, %{projections: projections}, {:continue, :update_projection_status}} =
               ProjectionManager.handle_info(
                 :refresh,
                 %{
                   polling_frequency: 1,
                   projections: [%TestProj{projection_id: "ab", child: self()}],
                   projector: TestProj,
                   supervisor: TestSupervisor
                 }
               )

      assert [
               %TestProj{
                 child: _,
                 id: nil,
                 projection_id: "ab",
                 status: nil,
                 version: nil
               },
               %TestProj{child: _, id: nil, projection_id: nil, status: :init, version: nil}
             ] = projections
    end

    test "starts workers for new projections" do
      assert {:noreply, %{projections: projections}, {:continue, :update_projection_status}} =
               ProjectionManager.handle_info(
                 :refresh,
                 %{
                   polling_frequency: 1,
                   projections: [%TestProjListMore{projection_id: "ab", child: self()}],
                   projector: TestProjListMore,
                   supervisor: TestSupervisor
                 }
               )

      local_pid = self()

      assert [
               %TestProjListMore{
                 child: ^local_pid,
                 id: nil,
                 projection_id: "ab",
                 status: nil,
                 version: nil
               },
               %TestProjListMore{
                 child: _,
                 id: nil,
                 projection_id: nil,
                 status: :init,
                 version: nil
               },
               %TestProjListMore{
                 child: ^local_pid,
                 id: nil,
                 projection_id: "uniq",
                 status: nil,
                 version: nil
               }
             ] = projections
    end
  end

  describe "handle_call :state" do
    test "returns state" do
      assert {:reply, :state, :state} = ProjectionManager.handle_call(:state, self(), :state)
    end
  end

  describe "&state/1" do
    test "trigggers GenServer.call(:state)" do
      assert {:ok, _pid} =
               ProjectionManager.start_link(%{supervisor: TestSupervisor, projector: TestProj})

      assert %ProjectionManager{
               polling_frequency: 10000,
               projections: [
                 %TestProj{child: _, id: nil, projection_id: nil, status: :active, version: nil}
               ],
               projector: TestProj,
               supervisor: TestSupervisor
             } = ProjectionManager.state()
    end
  end
end
