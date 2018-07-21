defmodule Tai.Exchanges.AccountsSupervisor do
  @moduledoc """
  Start an account supervisor for every configured account
  """

  use Supervisor

  def start_link(_) do
    Supervisor.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  def init(:ok) do
    Tai.Exchanges.Config.account_ids()
    |> Enum.map(&account_supervisor_spec/1)
    |> Supervisor.init(strategy: :one_for_one)
  end

  defp account_supervisor_spec(account_id) do
    Supervisor.child_spec(
      {Tai.Exchanges.AccountSupervisor, account_id},
      id: "#{Tai.Exchanges.AccountSupervisor}_#{account_id}"
    )
  end
end
