defmodule Tai.Trading.OrderOutbox do
  @moduledoc """
  Convert submissions into orders and send them to the exchange
  """

  use GenServer

  require Logger

  alias Tai.PubSub
  alias Tai.Trading.{Orders, OrderResponses, OrderStatus, OrderTypes}

  def start_link(_) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  def init(state) do
    PubSub.subscribe([
      :order_enqueued,
      :order_cancelling
    ])

    {:ok, state}
  end

  def handle_call({:add, submissions}, _from, state) do
    new_orders = submissions
                 |> Orders.add
                 |> Enum.map(&broadcast_enqueued_order/1)

    {:reply, new_orders, state}
  end

  def handle_call({:cancel, client_ids}, _from, state) do
    orders_to_cancel = [client_id: client_ids, status: OrderStatus.pending]
                        |> Orders.where
                        |> Enum.map(&Orders.update(&1.client_id, status: OrderStatus.cancelling))
                        |> Enum.map(&broadcast_cancelling_order/1)

    {:reply, orders_to_cancel, state}
  end

  def handle_info({:order_enqueued, order}, state) do
    cond do
      order.type == OrderTypes.buy_limit ->
        {:ok, _pid} = Task.start_link(fn ->
          Tai.Exchanges.Account.buy_limit(order)
          |> handle_limit_response(order)
        end)
      order.type == OrderTypes.sell_limit ->
        {:ok, _pid} = Task.start_link(fn ->
          Tai.Exchanges.Account.sell_limit(order)
          |> handle_limit_response(order)
        end)
    end

    {:noreply, state}
  end

  def handle_info({:order_cancelling, order}, state) do
    {:ok, _pid} = Task.start_link(fn ->
      Tai.Exchanges.Account.cancel_order(order.exchange, order.server_id)
      |> handle_cancel_order_response(order)
    end)

    {:noreply, state}
  end

  @doc """
  Create new orders to be sent to their exchange in the background
  """
  def add(submissions) do
    GenServer.call(__MODULE__, {:add, submissions})
  end

  @doc """
  Cancel pending orders in the background by client id
  """
  def cancel(client_ids) do
    GenServer.call(__MODULE__, {:cancel, client_ids})
  end

  defp broadcast_enqueued_order(order) do
    PubSub.broadcast(:order_enqueued, {:order_enqueued, order})
    order
  end

  defp broadcast_cancelling_order(order) do
    PubSub.broadcast(:order_cancelling, {:order_cancelling, order})
    order
  end

  defp handle_limit_response(
    {
      :ok,
      %OrderResponses.Created{id: server_id, created_at: created_at}
    },
    order
  ) do
    pending_order = Orders.update(
      order.client_id,
      server_id: server_id,
      created_at: created_at,
      status: OrderStatus.pending
    )
    PubSub.broadcast(:order_create_ok, {:order_create_ok, pending_order})
  end
  defp handle_limit_response({:error, reason}, order) do
    error_order = Orders.update(order.client_id, status: OrderStatus.error)
    PubSub.broadcast(:order_create_error, {:order_create_error, reason, error_order})
  end

  defp handle_cancel_order_response({:ok, _order_id}, order) do
    cancelled_order = Orders.update(order.client_id, status: OrderStatus.cancelled)
    PubSub.broadcast(:order_cancelled, {:order_cancelled, cancelled_order})
  end
end