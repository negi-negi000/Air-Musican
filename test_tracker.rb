require 'fiddle'
require 'fiddle/import'
require 'midilib/sequence'
require 'io/console'

SCRIPT_DIR = File.expand_path(File.dirname(__FILE__))
Dir.chdir(SCRIPT_DIR)

module WinMM
  extend Fiddle::Importer
  dlload 'winmm.dll'
  extern 'int midiOutOpen(void*, int, int, int, int)'
  extern 'int midiOutShortMsg(void*, unsigned int)'
  extern 'int midiOutClose(void*)'
  extern 'int mciSendStringA(const char*, char*, unsigned int, void*)'
end

@h_midi = Fiddle::Pointer.malloc(Fiddle::SIZEOF_VOIDP)
WinMM.midiOutOpen(@h_midi, -1, 0, 0, 0)
@midi_handle = @h_midi.ptr

def send_midi_msg(msg)
  safe_msg = [msg & 0xFFFFFFFF].pack('L').unpack1('l')
  WinMM.midiOutShortMsg(@midi_handle, safe_msg)
end

def set_instrument(program_num)
  msg = 0x0000C0 | ((program_num & 0x7F) << 8)
  send_midi_msg(msg)
end

def play_note(note, velocity = 100)
  note_val = [[note, 0].max, 127].min
  vel_val = [[velocity, 0].max, 127].min
  msg = 0x90 | (note_val << 8) | (vel_val << 16)
  send_midi_msg(msg)
end

def stop_note(note)
  note_val = [[note, 0].max, 127].min
  msg = 0x80 | (note_val << 8)
  send_midi_msg(msg)
end

TUNING_PRESETS = {
  'regular'   => { 1 => 64, 2 => 59, 3 => 55, 4 => 50, 5 => 45, 6 => 40 },
  'drop_d'    => { 1 => 64, 2 => 59, 3 => 55, 4 => 50, 5 => 45, 6 => 38 },
  'half_down' => { 1 => 63, 2 => 58, 3 => 54, 4 => 49, 5 => 44, 6 => 39 },
  'full_down' => { 1 => 62, 2 => 57, 3 => 53, 4 => 48, 5 => 43, 6 => 38 }
}

$current_tuning_name = 'regular'
$string_base_notes   = TUNING_PRESETS['regular'].dup

def set_tuning_preset(preset_key)
  if TUNING_PRESETS.key?(preset_key)
    $current_tuning_name = preset_key
    $string_base_notes   = TUNING_PRESETS[preset_key].dup
    puts "\n-> [Tuning] プリセット変更: 【#{preset_key.upcase}】"
    show_current_tuning
  end
end

def adjust_peg(string_num, delta)
  return unless $string_base_notes.key?(string_num)
  $string_base_notes[string_num] += delta
  $current_tuning_name = 'custom'
  puts "\n-> [Peg Adjust] #{string_num}弦 : #{delta > 0 ? '+1' : '-1'} 半音"
  show_current_tuning
end

def show_current_tuning
  puts "   1弦:#{$string_base_notes[1]} | 2弦:#{$string_base_notes[2]} | 3弦:#{$string_base_notes[3]} | 4弦:#{$string_base_notes[4]} | 5弦:#{$string_base_notes[5]} | 6弦:#{$string_base_notes[6]}"
end

VOICE_FILES = []

def load_voice_files
  VOICE_FILES.clear
  voices_dir = File.join(SCRIPT_DIR, 'voices')
  Dir.mkdir(voices_dir) unless Dir.exist?(voices_dir)

  files = Dir.glob(File.join(voices_dir, '*.wav')).sort
  files.each { |f| VOICE_FILES << f }

  puts "\n--- [Custom Voice Mode] ロードされたWAVファイル (#{VOICE_FILES.size}件) ---"
  if VOICE_FILES.empty?
    puts " ※ voices/ フォルダに .wav ファイルが見つかりません。"
  else
    VOICE_FILES.each_with_index do |f, idx|
      file_name = File.basename(f).encode('UTF-8', invalid: :replace, undef: :replace)
      puts "  弦 #{idx + 1} -> #{file_name}"
    end
  end
  puts "-------------------------------------------------------------"
end

load_voice_files

def play_custom_voice(string_idx, fret_idx)
  return if VOICE_FILES.empty?

  file_index = (string_idx - 1) % VOICE_FILES.size
  wav_path = VOICE_FILES[file_index]
  return unless wav_path && File.exist?(wav_path)

  standard_base = TUNING_PRESETS['regular'][string_idx] || 64
  current_base  = $string_base_notes[string_idx] || standard_base
  pitch_shift   = (current_base - standard_base) + fret_idx

  speed = (1000 * (2.0 ** (pitch_shift / 12.0))).to_i
  alias_name = "custom_voice_str#{string_idx}"

  WinMM.mciSendStringA("close #{alias_name}", nil, 0, nil)
  WinMM.mciSendStringA("open \"#{wav_path}\" type waveaudio alias #{alias_name}", nil, 0, nil)
  WinMM.mciSendStringA("set #{alias_name} speed #{speed}", nil, 0, nil)
  WinMM.mciSendStringA("play #{alias_name} from 0", nil, 0, nil)
end

def stop_custom_voice(string_idx)
  alias_name = "custom_voice_str#{string_idx}"
  WinMM.mciSendStringA("stop #{alias_name}", nil, 0, nil)
end

def stop_all_custom_voices
  (1..6).each { |s| stop_custom_voice(s) }
end

module NativeTracker
  extend Fiddle::Importer
  dlload File.join(SCRIPT_DIR, 'tracker.dll')

  FingerData = struct [
    'int x', 'int y', 'int key_index', 'int string_index', 'int midi_note', 'int is_striking'
  ]

  AirMusicianData = struct [
    'int mode',
    'int play_style',
    'int count',
    'int error',
    'int is_strummed',
    'int strum_velocity',
    'int pitch_bend',
    'int score',
    'int combo',
    'int judge_type',
    "char fingers[#{FingerData.size * 10}]"
  ]

  extern 'int init_cameras(int, int, const char*)'
  extern 'void set_mode(int, int)'
  extern 'void clear_guides()'
  extern 'void add_guide(int, int, int, double)'
  extern 'void process_frame(void*)'
  extern 'void cleanup_tracker()'
end

def load_midi_notes(file_path)
  return [] unless File.exist?(file_path)

  seq = MIDI::Sequence.new
  File.open(file_path, 'rb') { |f| seq.read(f) }

  events = []
  seq.each do |track|
    track.each do |event|
      if event.is_a?(MIDI::NoteOn) && event.velocity > 0
        time_sec = seq.pulses_to_seconds(event.time_from_start)
        events << { time: time_sec, note: event.note, hit: false }
      end
    end
  end
  events.sort_by { |e| e[:time] }
end

$cam0_id = 1
$cam1_id = 0

NativeTracker.init_cameras($cam0_id, $cam1_id, "")
buffer = NativeTracker::AirMusicianData.malloc

current_mode = 0
current_play_style = 0
guitar_sound_type = 0

NativeTracker.set_mode(current_mode, current_play_style)
set_instrument(0)

midi_events = load_midi_notes('sample.mid')
start_time = Time.now

score = 0
combo = 0
judge_display_timer = 0
active_piano_notes = {}
active_guitar_notes = []
guitar_last_strum_time = Time.now

def print_help
  puts "\n=========================================================="
  puts " [1] フリーピアノ | [2] フリーギター(MIDI) | [3] フリーギター(Voice)"
  puts " [4] 音ゲーピアノ | [5] 音ゲーギター"
  puts "----------------------------------------------------------"
  puts " [カメラID切替]"
  puts "  Cam0: '[' (減) / ']' (増)   | Cam1: '{' (減) / '}' (増)"
  puts "----------------------------------------------------------"
  puts " [チューニング切替]"
  puts "  [R] Regular  | [D] Drop D  | [H] 半音下げ  | [F] 全音下げ"
  puts " [ペグ調整 (上げる/下げる)]"
  puts "  6弦: [Q]/[A] | 5弦: [W]/[S] | 4弦: [E]/[D]"
  puts "=========================================================="
end

print_help

Thread.new do
  loop do
    key = $stdin.getch rescue nil
    next unless key

    case key
    when '1'
      current_mode = 0; current_play_style = 0
      set_instrument(0)
      puts "\n-> フリーピアノモード"
    when '2'
      current_mode = 1; current_play_style = 0; guitar_sound_type = 0
      set_instrument(30)
      puts "\n-> フリーギターモード (MIDI)"
    when '3'
      load_voice_files
      current_mode = 1; current_play_style = 0; guitar_sound_type = 1
      puts "\n-> フリーギターモード (WAV Voice)"
    when '4'
      current_mode = 0; current_play_style = 1
      start_time = Time.now
      midi_events.each { |e| e[:hit] = false }
      score = 0; combo = 0
      set_instrument(0)
      puts "\n-> 音ゲー (ピアノ) スタート！"
    when '5'
      current_mode = 1; current_play_style = 1; guitar_sound_type = 0
      start_time = Time.now
      midi_events.each { |e| e[:hit] = false }
      score = 0; combo = 0
      set_instrument(30)
      puts "\n-> 音ゲー (ギター) スタート！"
    # カメラID変更
    when '['
      $cam0_id = [$cam0_id - 1, 0].max
      NativeTracker.init_cameras($cam0_id, $cam1_id, "")
      puts "\n-> メインカメラ(Cam 0) ID変更: [#{$cam0_id}]"
    when ']'
      $cam0_id += 1
      NativeTracker.init_cameras($cam0_id, $cam1_id, "")
      puts "\n-> メインカメラ(Cam 0) ID変更: [#{$cam0_id}]"
    when '{'
      $cam1_id = [$cam1_id - 1, 0].max
      NativeTracker.init_cameras($cam0_id, $cam1_id, "")
      puts "\n-> フレットカメラ(Cam 1) ID変更: [#{$cam1_id}]"
    when '}'
      $cam1_id += 1
      NativeTracker.init_cameras($cam0_id, $cam1_id, "")
      puts "\n-> フレットカメラ(Cam 1) ID変更: [#{$cam1_id}]"
    # チューニングプリセット
    when 'r', 'R' then set_tuning_preset('regular')
    when 'd', 'D' then set_tuning_preset('drop_d')
    when 'h', 'H' then set_tuning_preset('half_down')
    when 'f', 'F' then set_tuning_preset('full_down')
    # ペグ調整
    when 'q', 'Q' then adjust_peg(6, 1)
    when 'a', 'A' then adjust_peg(6, -1)
    when 'w', 'W' then adjust_peg(5, 1)
    when 's', 'S' then adjust_peg(5, -1)
    when 'e', 'E' then adjust_peg(4, 1)
    end
    NativeTracker.set_mode(current_mode, current_play_style)
  end
end

begin
  loop do
    current_time = Time.now - start_time
    NativeTracker.clear_guides

    if current_play_style == 1
      upcoming = midi_events.select { |e| !e[:hit] && (e[:time] - current_time).between?(0, 2.0) }
      upcoming.each do |e|
        key_idx = [e[:note] - 36, 0].max % 61
        string_idx = (e[:note] % 6) + 1
        fret_idx = (e[:note] / 6) % 13
        NativeTracker.add_guide(e[:note], key_idx, string_idx, e[:time] - current_time)
      end

      midi_events.each do |e|
        if !e[:hit] && (current_time - e[:time]) > 0.3
          e[:hit] = true
          combo = 0
          buffer.judge_type = 3
          judge_display_timer = 20
        end
      end
    end

    buffer.score = score
    buffer.combo = combo
    NativeTracker.process_frame(buffer)

    if judge_display_timer > 0
      judge_display_timer -= 1
      buffer.judge_type = 0 if judge_display_timer == 0
    end

    if buffer.error == 0
      if buffer.mode == 0
        current_frame_notes = []
        buffer.count.times do |i|
          finger_ptr = Fiddle::Pointer.new(buffer.to_i + 40 + (i * NativeTracker::FingerData.size))
          finger = NativeTracker::FingerData.new(finger_ptr)

          if finger.is_striking == 1
            note = finger.midi_note
            current_frame_notes << note

            unless active_piano_notes[note]
              play_note(note)
              active_piano_notes[note] = true

              if current_play_style == 1
                target = midi_events.find { |e| !e[:hit] && e[:note] == note && (e[:time] - current_time).abs < 0.3 }
                if target
                  target[:hit] = true
                  diff = (target[:time] - current_time).abs
                  if diff < 0.1
                    score += 1000; combo += 1; buffer.judge_type = 1
                  else
                    score += 500; combo += 1; buffer.judge_type = 2
                  end
                  judge_display_timer = 20
                end
              end
            end
          end
        end

        active_piano_notes.keys.each do |note|
          unless current_frame_notes.include?(note)
            stop_note(note)
            active_piano_notes.delete(note)
          end
        end

      elsif buffer.mode == 1
        if buffer.is_strummed == 1
          if guitar_sound_type == 1
            if buffer.count > 0
              buffer.count.times do |i|
                finger_ptr = Fiddle::Pointer.new(buffer.to_i + 40 + (i * NativeTracker::FingerData.size))
                finger = NativeTracker::FingerData.new(finger_ptr)

                string_num = finger.string_index
                fret_num   = finger.key_index

                play_custom_voice(string_num, fret_num)
              end
            else
              play_custom_voice(1, 0)
            end
          else
            active_guitar_notes.each { |n| stop_note(n) }
            active_guitar_notes.clear

            if buffer.count > 0
              buffer.count.times do |i|
                finger_ptr = Fiddle::Pointer.new(buffer.to_i + 40 + (i * NativeTracker::FingerData.size))
                finger = NativeTracker::FingerData.new(finger_ptr)

                base_note = $string_base_notes[finger.string_index] || 64
                note = base_note + finger.key_index

                play_note(note, buffer.strum_velocity)
                active_guitar_notes << note
              end
            end
          end
          guitar_last_strum_time = Time.now
        else
          if Time.now - guitar_last_strum_time > 2.0 || buffer.count == 0
            if guitar_sound_type == 1
              stop_all_custom_voices
            else
              active_guitar_notes.each { |n| stop_note(n) }
              active_guitar_notes.clear
            end
          end
        end
      end
    end

    sleep 0.01
  end
rescue Interrupt
  puts "\n終了します..."
ensure
  stop_all_custom_voices
  WinMM.midiOutClose(@midi_handle) if @midi_handle
  NativeTracker.cleanup_tracker()
end