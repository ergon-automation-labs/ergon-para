defmodule BotArmyPara.NATS.Consumer do
  @moduledoc """
  NATS message consumer for para.

  Subscribes to NATS subjects and routes messages to handlers.
  Uses standardized Reply format for request/reply patterns.

  All request/reply handlers should return responses using Reply helpers:
  - BotArmyLibraryRuntime.NATS.Reply.ok(data) for success
  - BotArmyLibraryRuntime.NATS.Reply.error(message, code) for errors
  """

  use GenServer
  require Logger
  alias BotArmyLibraryCore.NATS.Decoder
  alias BotArmyPara.{ParaFs, ParaNotes}
  alias BotArmyLibraryRuntime.NATS.{Connection, Reply}
  alias BotArmyLibraryRuntime.{Registry, Tracing}

  @reconnect_delay_ms 5000
  @registry_heartbeat_ms 20_000
  @registry_bot_name "para"
  @version Mix.Project.config()[:version]

  # Register subjects with their metadata for runtime discovery
  @subjects [
    %{
      subject: "para.fs.write",
      type: :request_reply,
      description: "Write or append files under PARA_FS_ROOT with path guards"
    },
    %{
      subject: "para.fs.read",
      type: :request_reply,
      description: "Read file content from PARA_FS_ROOT"
    },
    %{
      subject: "para.fs.list",
      type: :request_reply,
      description: "List directory contents under PARA_FS_ROOT"
    },
    %{
      subject: "para.fs.search",
      type: :request_reply,
      description: "Search files by name or content under PARA_FS_ROOT"
    },
    %{
      subject: "para.capture.append",
      type: :request_reply,
      description: "Append a timestamped bot note into inbox/bots/<source>.md"
    },
    %{
      subject: "para.note.route",
      type: :request_reply,
      description: "Route a note into project/area logs (or inbox fallback)"
    },
    %{
      subject: "para.digest.generate",
      type: :request_reply,
      description: "Generate digest markdown from selected PARA files"
    },
    %{
      subject: "para.system.config",
      type: :request_reply,
      description: "Return PARA system configuration including root directory"
    },
    %{
      subject: "para.auth.get_write_token",
      type: :request_reply,
      description:
        "Retrieve PARA write token for authenticated operations (bootstrap endpoint, no auth required)"
    }
  ]

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(opts) do
    Logger.info("Starting NATS consumer")

    state = %{
      subscriptions: [],
      conn: nil,
      opts: opts,
      registry_registered?: false
    }

    {:ok, state, {:continue, :connect}}
  end

  @impl true
  @dialyzer {:no_missing_calls, handle_continue: 2}
  def handle_continue(:connect, state) do
    case GenServer.call(Connection, :get_connection, 5000) do
      {:ok, conn} ->
        Connection.subscribe_to_status()
        Logger.info("Connected to NATS, subscribing to topics")

        node_suffix = System.get_env("PARA_SYSTEM_NODE", "")

        base_subjects = [
          "para.fs.write",
          "para.fs.read",
          "para.fs.list",
          "para.fs.search",
          "para.capture.append",
          "para.note.route",
          "para.digest.generate",
          "para.system.config",
          "para.auth.get_write_token"
        ]

        # Subscribe to base subjects AND node-specific variants (e.g., para.system.config.air)
        subjects_to_subscribe =
          base_subjects ++
            if node_suffix != "" do
              Enum.map(base_subjects, &"#{&1}.#{node_suffix}")
            else
              []
            end

        subscriptions = subscribe_subjects(conn, subjects_to_subscribe)

        # Register subjects for runtime discovery and refresh before stale timeout.
        deployment_status = Application.get_env(:bot_army_para, :deployment_status, "deployed")
        Registry.register(@registry_bot_name, @subjects, @version, deployment_status)
        Process.send_after(self(), :registry_heartbeat, @registry_heartbeat_ms)

        {:noreply,
         %{
           state
           | subscriptions: subscriptions,
             conn: conn,
             registry_registered?: subscriptions != []
         }}

      {:error, _reason} ->
        Logger.warning("NATS connection not ready, will retry")
        Process.send_after(self(), :connect_retry, @reconnect_delay_ms)
        {:noreply, state}
    end
  end

  @impl true
  def handle_info(:connect_retry, state) do
    {:noreply, state, {:continue, :connect}}
  end

  @impl true
  def handle_info({:msg, msg}, state) do
    Tracing.with_consumer_span(msg.topic, Map.get(msg, :headers), fn ->
      Logger.debug("Received NATS message on subject: #{msg.topic}")
      handle_message(msg, state)
    end)

    {:noreply, state}
  end

  @impl true
  def handle_info({:nats, :disconnected}, state) do
    Logger.warning("Disconnected from NATS, will reconnect")
    Process.send_after(self(), :connect_retry, @reconnect_delay_ms)
    {:noreply, %{state | subscriptions: [], conn: nil, registry_registered?: false}}
  end

  @impl true
  def handle_info({:nats, :connected}, state) do
    Logger.info("Reconnected to NATS, re-subscribing")
    {:noreply, state, {:continue, :connect}}
  end

  @impl true
  def handle_info(:registry_heartbeat, state) do
    if state.registry_registered? and state.subscriptions != [] do
      Registry.register(@registry_bot_name, @subjects, @version)
      Process.send_after(self(), :registry_heartbeat, @registry_heartbeat_ms)
    end

    {:noreply, state}
  end

  @impl true
  def handle_info(:reconnect, state) do
    {:noreply, state, {:continue, :connect}}
  end

  # Message routing
  defp route_message(_message, topic) do
    # Route decoded messages to appropriate handlers
    Logger.debug("Routing message from #{topic}")
  end

  defp subscribe_subjects(conn, subjects) do
    subjects
    |> Enum.map(&subscribe_subject(conn, &1))
    |> Enum.reject(&is_nil/1)
  end

  defp subscribe_subject(conn, subject) do
    case Gnat.sub(conn, self(), subject) do
      {:ok, sub} ->
        Logger.info("Subscribed to #{subject}")
        sub

      {:error, reason} ->
        Logger.error("Failed to subscribe to #{subject}: #{inspect(reason)}")
        nil
    end
  end

  defp handle_message(msg, state) do
    if msg.reply_to do
      handle_request(msg, state)
    else
      handle_pubsub(msg)
    end
  end

  defp normalize_subject(topic) do
    """
    Strip .air or .mini suffix from topic to get base subject.
    E.g., "para.system.config.air" -> "para.system.config"
    """

    topic
    |> String.replace_suffix(".air", "")
    |> String.replace_suffix(".mini", "")
  end

  defp handle_request(msg, state) do
    base_subject = normalize_subject(msg.topic)
    msg_with_base = %{msg | topic: base_subject}

    case base_subject do
      "para.fs.write" -> handle_para_fs_write(msg_with_base, state)
      "para.fs.read" -> handle_para_fs_read(msg_with_base, state)
      "para.fs.list" -> handle_para_fs_list(msg_with_base, state)
      "para.fs.search" -> handle_para_fs_search(msg_with_base, state)
      "para.capture.append" -> handle_para_capture_append(msg_with_base, state)
      "para.note.route" -> handle_para_note_route(msg_with_base, state)
      "para.digest.generate" -> handle_para_digest_generate(msg_with_base, state)
      "para.system.config" -> handle_para_system_config(msg_with_base, state)
      "para.auth.get_write_token" -> handle_para_auth_get_write_token(msg_with_base, state)
      _ -> Logger.debug("Unknown request/reply subject: #{msg.topic}")
    end
  end

  defp handle_pubsub(msg) do
    case Decoder.decode(msg.body) do
      {:ok, decoded_message} ->
        route_message(decoded_message, msg.topic)

      {:error, reason} ->
        Logger.warning("Failed to decode message from #{msg.topic}: #{inspect(reason)}")
    end
  end

  # Request/reply handlers
  defp handle_para_fs_write(msg, state) do
    response =
      with {:ok, payload} <- decode_request_body(msg.body),
           {:ok, data} <- ParaFs.handle_write(payload) do
        Reply.ok(data)
      else
        {:error, message, code} ->
          Reply.error(message, code)

        {:error, :invalid_json} ->
          Reply.error("invalid JSON", :validation_error)
      end

    if state.conn do
      Gnat.pub(state.conn, msg.reply_to, response)
    end
  end

  defp handle_para_fs_read(msg, state) do
    response =
      with {:ok, payload} <- decode_request_body(msg.body),
           {:ok, data} <- ParaFs.handle_read(payload) do
        Reply.ok(data)
      else
        {:error, message, code} ->
          Reply.error(message, code)

        {:error, :invalid_json} ->
          Reply.error("invalid JSON", :validation_error)
      end

    if state.conn do
      Gnat.pub(state.conn, msg.reply_to, response)
    end
  end

  defp handle_para_fs_list(msg, state) do
    response =
      with {:ok, payload} <- decode_request_body(msg.body),
           {:ok, data} <- ParaFs.handle_list(payload) do
        Reply.ok(data)
      else
        {:error, message, code} ->
          Reply.error(message, code)

        {:error, :invalid_json} ->
          Reply.error("invalid JSON", :validation_error)
      end

    if state.conn do
      Gnat.pub(state.conn, msg.reply_to, response)
    end
  end

  defp handle_para_fs_search(msg, state) do
    response =
      with {:ok, payload} <- decode_request_body(msg.body),
           {:ok, data} <- ParaFs.handle_search(payload) do
        Reply.ok(data)
      else
        {:error, message, code} ->
          Reply.error(message, code)

        {:error, :invalid_json} ->
          Reply.error("invalid JSON", :validation_error)
      end

    if state.conn do
      Gnat.pub(state.conn, msg.reply_to, response)
    end
  end

  defp handle_para_capture_append(msg, state) do
    response =
      with {:ok, payload} <- decode_request_body(msg.body),
           {:ok, data} <- ParaNotes.capture_append(payload) do
        Reply.ok(data)
      else
        {:error, message, code} -> Reply.error(message, code)
        {:error, :invalid_json} -> Reply.error("invalid JSON", :validation_error)
      end

    if state.conn, do: Gnat.pub(state.conn, msg.reply_to, response)
  end

  defp handle_para_note_route(msg, state) do
    response =
      with {:ok, payload} <- decode_request_body(msg.body),
           {:ok, data} <- ParaNotes.route_note(payload) do
        Reply.ok(data)
      else
        {:error, message, code} -> Reply.error(message, code)
        {:error, :invalid_json} -> Reply.error("invalid JSON", :validation_error)
      end

    if state.conn, do: Gnat.pub(state.conn, msg.reply_to, response)
  end

  defp handle_para_digest_generate(msg, state) do
    response =
      with {:ok, payload} <- decode_request_body(msg.body),
           {:ok, data} <- ParaNotes.digest_generate(payload) do
        Reply.ok(data)
      else
        {:error, message, code} -> Reply.error(message, code)
        {:error, :invalid_json} -> Reply.error("invalid JSON", :validation_error)
      end

    if state.conn, do: Gnat.pub(state.conn, msg.reply_to, response)
  end

  defp handle_para_system_config(msg, state) do
    # Determine system node from environment variable or extract from Erlang node name
    system_node =
      case System.get_env("PARA_SYSTEM_NODE") do
        nil ->
          # Extract hostname from Erlang node name (format: para_bot@hostname)
          case Node.self() do
            :nonode@nohost ->
              "unknown"

            node ->
              node
              |> Atom.to_string()
              |> String.split("@")
              |> List.last()
          end

        value ->
          value
      end

    response =
      Reply.ok(%{
        "root_directory" =>
          System.get_env("PARA_FS_ROOT") || Path.expand("~/Documents/personal_os"),
        "version" => @version,
        "system_node" => system_node,
        "available_subjects" => Enum.map(@subjects, & &1.subject)
      })

    if state.conn, do: Gnat.pub(state.conn, msg.reply_to, response)
  end

  defp handle_para_auth_get_write_token(msg, state) do
    response =
      case System.get_env("PARA_FS_WRITE_TOKEN") do
        token when is_binary(token) and byte_size(token) > 0 ->
          Reply.ok(%{
            "write_token" => token,
            "expires_at" => nil,
            "auth_required" => true,
            "token_length" => byte_size(token)
          })

        _ ->
          Reply.ok(%{
            "auth_required" => false,
            "write_token" => nil,
            "message" => "No write token configured - all operations are public"
          })
      end

    if state.conn, do: Gnat.pub(state.conn, msg.reply_to, response)
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
