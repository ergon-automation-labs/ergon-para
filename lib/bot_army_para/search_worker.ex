defmodule BotArmyPara.SearchWorker do
  @moduledoc """
  Async worker for para.fs.search requests.

  Spawned as a Task under BotArmyPara.SearchTaskSupervisor to prevent
  blocking the NATS consumer GenServer during long filesystem walks.

  The task:
  1. Runs ParaFs.handle_search(payload)
  2. Publishes the reply directly via Gnat.pub(conn, reply_to, response)
  3. Returns or crashes silently if conn is unavailable (caller timeouts normally)
  """

  require Logger

  alias BotArmyLibraryRuntime.NATS.Reply
  alias BotArmyPara.ParaFs

  @doc """
  Spawn an async search task.

  Called from Consumer to offload the search from the GenServer's message handling.
  Captures `conn` and `reply_to` at spawn time; task publishes reply itself.
  """
  def spawn_search(supervisor, payload, conn, reply_to, msg_topic) do
    Task.Supervisor.start_child(supervisor, fn ->
      handle_search_async(payload, conn, reply_to, msg_topic)
    end)
  end

  defp handle_search_async(payload, conn, reply_to, msg_topic) do
    Logger.info("[para.fs.search-async] Starting async search on #{msg_topic}")

    response =
      case decode_request_body(payload) do
        {:ok, decoded_payload} ->
          case ParaFs.handle_search(decoded_payload) do
            {:ok, data} ->
              Logger.debug("[para.fs.search-async] Search succeeded")
              Reply.ok(data)

            {:error, message, code} ->
              Logger.warning("[para.fs.search-async] Search error: #{message} (#{code})")
              Reply.error(message, code)

            {:error, :invalid_json} ->
              Logger.warning("[para.fs.search-async] Invalid JSON in request body")
              Reply.error("invalid JSON", :validation_error)
          end

        {:error, :invalid_json} ->
          Logger.warning("[para.fs.search-async] Failed to decode request body")
          Reply.error("invalid JSON", :validation_error)
      end

    if conn do
      Logger.info("[para.fs.search-async] Publishing reply to #{reply_to}")
      Gnat.pub(conn, reply_to, response)
      Logger.info("[para.fs.search-async] Reply published successfully")
    else
      Logger.error("[para.fs.search-async] NO NATS CONNECTION - reply not sent!")
    end
  rescue
    e ->
      Logger.error("[para.fs.search-async] Unhandled error: #{inspect(e)}")
  end

  defp decode_request_body(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, payload} when is_map(payload) -> {:ok, payload}
      _ -> {:error, :invalid_json}
    end
  end

  defp decode_request_body(%{} = payload), do: {:ok, payload}
  defp decode_request_body(_), do: {:error, :invalid_json}
end
