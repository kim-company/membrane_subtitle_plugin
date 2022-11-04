defmodule Membrane.SubtitleMixer.FLV.Mixer do
  use Membrane.Filter

  require Membrane.Logger

  alias Membrane.Buffer
  alias Subtitle.Cue
  alias SubtitleMixer.FLV

  @flv_footer_size 4

  def_input_pad :video,
    availability: :always,
    demand_unit: :buffers,
    caps: :any

  def_input_pad :subtitle,
    availability: :always,
    demand_unit: :buffers,
    caps: :any

  def_output_pad :output,
    demand_mode: :auto,
    caps: :any

  @impl true
  def handle_init(_opts) do
    {:ok,
     %{
       header_present?: true,
       previous_tag_size: 0,
       partial: <<>>,
       subtitles: []
     }}
  end

  @impl true
  def handle_demand(_pad, size, :buffers, _ctx, state) do
    {{:ok, demand: {:video, size}, demand: {:subtitle, size}}, state}
  end

  @impl true
  def handle_caps(:video, caps, _ctx, state) do
    {{:ok, [caps: {:output, caps}]}, state}
  end

  def handle_caps(:subtitle, _caps, _ctx, state) do
    {:ok, state}
  end

  @impl true
  def handle_prepared_to_playing(_ctx, state) do
    {{:ok, demand: :video, demand: :subtitle}, state}
  end

  @impl true
  def handle_process(:video, %Buffer{payload: payload}, _ctx, %{header_present?: true} = state) do
    case Membrane.FLV.Parser.parse_header(state.partial <> payload) do
      {:ok, header, rest} ->
        {actions, state} = prepare_to_send(header, state)
        actions = Enum.concat(actions, demand: :video)
        {{:ok, actions}, %{state | partial: rest, header_present?: false}}

      {:error, :not_enough_data} ->
        {{:ok, demand: :video}, %{state | partial: state.partial <> payload}}

      {:error, :not_a_header} ->
        raise "Invalid data detected on the input. Expected Membrane.FLV header"
    end
  end

  @impl true
  def handle_process(:video, %Buffer{payload: payload}, _ctx, %{header_present?: false} = state) do
    case Membrane.FLV.Parser.parse_body(state.partial <> payload) do
      {:ok, frames, rest} ->
        {actions, state} = prepare_to_send(frames, state)
        actions = Enum.concat(actions, demand: :video)
        {{:ok, actions}, %{state | partial: rest}}

      {:error, :not_enough_data} ->
        {{:ok, demand: :video}, %{state | partial: state.partial <> payload}}
    end
  end

  def handle_process(
        :subtitle,
        %Membrane.Buffer{payload: text, metadata: %{from: from, to: to}},
        _ctx,
        %{subtitles: queue} = state
      ) do
    {{:ok, demand: :subtitle},
     %{state | subtitles: queue ++ [%Cue{from: from, to: to, text: text}]}}
  end

  @impl true
  def handle_end_of_stream(:video, _context, state) do
    last = <<state.previous_tag_size::32>>
    {{:ok, buffer: {:output, %Buffer{payload: last}}, end_of_stream: :output}, state}
  end

  def handle_end_of_stream(:subtitle, _context, state) do
    {:ok, state}
  end

  defp prepare_to_send(packets, state) when is_list(packets) do
    {buffers, state} =
      Enum.reduce(packets, {[], state}, fn packet, {buffers, state} ->
        {tag, tag_size} = Membrane.FLV.Serializer.serialize(packet, state.previous_tag_size)

        {tag, state} =
          if packet.type == :video do
            pts = Membrane.Time.milliseconds(packet.pts)

            {{tag, tag_size}, state} = maybe_sub(tag, state.previous_tag_size, pts, state)
            {tag, %{state | previous_tag_size: tag_size}}
          else
            {tag, %{state | previous_tag_size: tag_size}}
          end

        {[%Buffer{payload: tag} | buffers], state}
      end)

    {[buffer: {:output, Enum.reverse(buffers)}], state}
  end

  defp prepare_to_send(segment, state) do
    {tag, previous_tag_size} = Membrane.FLV.Serializer.serialize(segment, state.previous_tag_size)
    {[buffer: {:output, %Buffer{payload: tag}}], %{state | previous_tag_size: previous_tag_size}}
  end

  defp maybe_sub(
         tag,
         prev_tag_size,
         pts,
         %{subtitles: [%Cue{from: from, to: to, text: text} | _]} = state
       )
       when from <= pts and pts <= to do
    Membrane.Logger.debug("pts: #{pts}; [+] #{text}")
    {sub(tag, prev_tag_size, text), state}
  end

  defp maybe_sub(
         tag,
         prev_tag_size,
         pts,
         %{subtitles: [%Cue{to: to, text: text} | tail]} = state
       )
       when to < pts do
    Membrane.Logger.debug("pts: #{pts}; [-] #{text}")
    {sub(tag, prev_tag_size, nil), %{state | subtitles: tail}}
  end

  defp maybe_sub(tag, prev_tag_size, pts, state) do
    Membrane.Logger.debug("pts: #{pts}; [x]")
    {sub(tag, prev_tag_size, nil), state}
  end

  defp sub(tag, previous_tag_size, text) do
    tag = if is_nil(text), do: FLV.Tag.clear_caption(tag), else: FLV.Tag.add_caption(tag, text)

    n = byte_size(tag) - @flv_footer_size
    <<tag::binary-size(n), _footer::binary-size(@flv_footer_size)>> = tag
    tag = <<previous_tag_size::32, tag::binary>>
    {tag, byte_size(tag) - @flv_footer_size}
  end
end
