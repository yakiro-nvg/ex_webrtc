defmodule SaveToFile.PeerHandler do
  require Logger

  alias ExWebRTC.{
    ICECandidate,
    MediaStreamTrack,
    PeerConnection,
    RTPCodecParameters,
    SessionDescription
  }

  alias ExWebRTC.Media.{IVF, Ogg}
  alias ExWebRTC.RTP.{Depayloader, JitterBuffer}

  @behaviour WebSock

  @jitter_buffer_latency_ms 100

  @video_file "./video.ivf"
  @audio_file "./audio.ogg"

  @ice_servers [
    %{urls: "stun:stun.l.google.com:19302"}
  ]

  @video_codecs [
    %RTPCodecParameters{
      payload_type: 96,
      mime_type: "video/VP8",
      clock_rate: 90_000
    }
  ]

  @audio_codecs [
    %RTPCodecParameters{
      payload_type: 111,
      mime_type: "audio/opus",
      clock_rate: 48_000,
      channels: 2
    }
  ]

  @impl true
  def init(_) do
    {:ok, pc} =
      PeerConnection.start_link(
        ice_servers: @ice_servers,
        video_codecs: @video_codecs,
        audio_codecs: @audio_codecs
      )

    state = %{
      peer_connection: pc,
      video_track_id: nil,
      audio_track_id: nil,
      video_writer: nil,
      video_depayloader: nil,
      video_buffer: nil,
      audio_writer: nil,
      audio_depayloader: nil,
      audio_buffer: nil,
      frames_cnt: 0
    }

    {:ok, state}
  end

  @impl true
  def handle_in({msg, [opcode: :text]}, state) do
    msg
    |> Jason.decode!()
    |> handle_ws_msg(state)
  end

  @impl true
  def handle_info({:ex_webrtc, _from, msg}, state) do
    handle_webrtc_msg(msg, state)
  end

  @impl true
  def handle_info({:jitter_buffer_timer, kind}, state) do
    case kind do
      :video -> state.video_buffer
      :audio -> state.audio_buffer
    end
    |> JitterBuffer.handle_timeout()
    |> handle_jitter_buffer_result(kind, state)
  end

  @impl true
  def handle_info({:EXIT, pc, reason}, %{peer_connection: pc} = state) do
    # Bandit traps exits under the hood so our PeerConnection.start_link
    # won't automatically bring this process down.
    Logger.info("Peer connection process exited, reason: #{inspect(reason)}")
    {:stop, {:shutdown, :pc_closed}, state}
  end

  @impl true
  def terminate(reason, state) do
    Logger.info("WebSocket connection was terminated, reason: #{inspect(reason)}")

    state = flush_jitter_buffers(state)

    if state.video_writer, do: IVF.Writer.close(state.video_writer)
    if state.audio_writer, do: Ogg.Writer.close(state.audio_writer)
  end

  defp handle_ws_msg(%{"type" => "offer", "data" => data}, state) do
    Logger.info("Received SDP offer: #{inspect(data)}")

    offer = SessionDescription.from_json(data)
    :ok = PeerConnection.set_remote_description(state.peer_connection, offer)

    {:ok, answer} = PeerConnection.create_answer(state.peer_connection)
    :ok = PeerConnection.set_local_description(state.peer_connection, answer)

    answer_json = SessionDescription.to_json(answer)

    msg =
      %{"type" => "answer", "data" => answer_json}
      |> Jason.encode!()

    Logger.info("Sent SDP answer: #{inspect(answer_json)}")

    {:push, {:text, msg}, state}
  end

  defp handle_ws_msg(%{"type" => "ice", "data" => data}, state) do
    Logger.info("Received ICE candidate: #{inspect(data)}")

    candidate = ICECandidate.from_json(data)
    :ok = PeerConnection.add_ice_candidate(state.peer_connection, candidate)
    {:ok, state}
  end

  defp handle_webrtc_msg({:connection_state_change, conn_state}, state) do
    Logger.info("Connection state changed: #{conn_state}")

    if conn_state == :failed do
      {:stop, {:shutdown, :pc_failed}, state}
    else
      {:ok, state}
    end
  end

  defp handle_webrtc_msg({:ice_candidate, candidate}, state) do
    candidate_json = ICECandidate.to_json(candidate)

    msg =
      %{"type" => "ice", "data" => candidate_json}
      |> Jason.encode!()

    Logger.info("Sent ICE candidate: #{inspect(candidate_json)}")

    {:push, {:text, msg}, state}
  end

  defp handle_webrtc_msg({:track, %MediaStreamTrack{kind: :video, id: id}}, state) do
    <<fourcc::little-32>> = "VP80"

    # Width, height and FPS (timebase_denum/num)
    # are the same as we set in video constraints
    # on the frontend side (in getUserMedia).
    # However, keep in mind they can change in time
    # so this is best effort saving.
    # `num_frames` is set to 900 and it will be updated
    # every `num_frames` by `num_frames`.
    {:ok, video_writer} =
      IVF.Writer.open(@video_file,
        fourcc: fourcc,
        height: 640,
        width: 480,
        num_frames: 900,
        timebase_denum: 15,
        timebase_num: 1
      )

    {:ok, video_depayloader} = @video_codecs |> hd() |> Depayloader.new()
    video_buffer = JitterBuffer.new(latency: @jitter_buffer_latency_ms)

    state = %{
      state
      | video_depayloader: video_depayloader,
        video_writer: video_writer,
        video_buffer: video_buffer,
        video_track_id: id
    }

    {:ok, state}
  end

  defp handle_webrtc_msg({:track, %MediaStreamTrack{kind: :audio, id: id}}, state) do
    # by default uses 1 mono channel and 48k clock rate
    {:ok, audio_writer} = Ogg.Writer.open(@audio_file)
    {:ok, audio_depayloader} = @audio_codecs |> hd() |> Depayloader.new()
    audio_buffer = JitterBuffer.new(latency: @jitter_buffer_latency_ms)

    state = %{
      state
      | audio_depayloader: audio_depayloader,
        audio_writer: audio_writer,
        audio_buffer: audio_buffer,
        audio_track_id: id
    }

    {:ok, state}
  end

  defp handle_webrtc_msg({:rtp, _id, %{payload: <<>>}}, state) do
    # we're ignoring packets with padding only, as these are most likely used
    # for network bandwidth probing
    {:ok, state}
  end

  defp handle_webrtc_msg({:rtp, id, nil, packet}, %{video_track_id: id} = state) do
    state.video_buffer
    |> JitterBuffer.insert(packet)
    |> handle_jitter_buffer_result(:video, state)
  end

  defp handle_webrtc_msg({:rtp, id, nil, packet}, %{audio_track_id: id} = state) do
    state.audio_buffer
    |> JitterBuffer.insert(packet)
    |> handle_jitter_buffer_result(:audio, state)
  end

  defp handle_webrtc_msg(_msg, state), do: {:ok, state}

  defp handle_jitter_buffer_result({packets, timer, buffer}, kind, state) do
    state =
      case kind do
        :video -> %{state | video_buffer: buffer}
        :audio -> %{state | audio_buffer: buffer}
      end

    state =
      Enum.reduce(packets, state, fn packet, state -> handle_packet(packet, kind, state) end)

    unless is_nil(timer), do: Process.send_after(self(), {:jitter_buffer_timer, kind}, timer)

    {:ok, state}
  end

  defp handle_packet(packet, :video, state) do
    case Depayloader.depayload(state.video_depayloader, packet) do
      {nil, video_depayloader} ->
        %{state | video_depayloader: video_depayloader}

      {vp8_frame, video_depayloader} ->
        frame = %IVF.Frame{timestamp: state.frames_cnt, data: vp8_frame}
        {:ok, video_writer} = IVF.Writer.write_frame(state.video_writer, frame)

        %{
          state
          | video_depayloader: video_depayloader,
            video_writer: video_writer,
            frames_cnt: state.frames_cnt + 1
        }
    end
  end

  defp handle_packet(packet, :audio, state) do
    {opus_packet, depayloader} = Depayloader.depayload(state.audio_depayloader, packet)
    {:ok, audio_writer} = Ogg.Writer.write_packet(state.audio_writer, opus_packet)

    %{state | audio_depayloader: depayloader, audio_writer: audio_writer}
  end

  defp flush_jitter_buffers(state),
    do: state |> flush_jitter_buffer(:video) |> flush_jitter_buffer(:audio)

  defp flush_jitter_buffer(state, kind) do
    buffer =
      case kind do
        :video -> state.video_buffer
        :audio -> state.audio_buffer
      end

    if is_nil(buffer) do
      state
    else
      {:ok, state} =
        buffer
        |> JitterBuffer.flush()
        |> handle_jitter_buffer_result(kind, state)

      state
    end
  end
end
