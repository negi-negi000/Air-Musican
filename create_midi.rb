require 'midilib/sequence'
require 'midilib/consts'

# 新しい MIDI シーケンスの作成
seq = MIDI::Sequence.new

# トラックの追加
track = MIDI::Track.new(seq)
seq.tracks << track

# トラック名と楽器（0: Acoustic Grand Piano）の設定
track.name = 'Do-Re-Mi Scale'
track.events << MIDI::Tempo.new(MIDI::Tempo.bpm_to_mpq(120)) # BPM: 120
track.events << MIDI::ProgramChange.new(0, 0, 0)             # チャンネル0, ピアノ(0)

# ドレミファソラシド の MIDI ノート番号 (C4 ~ C5)
# C4(60), D4(62), E4(64), F4(65), G4(67), A4(69), B4(71), C5(72)
scale_notes = [60, 62, 64, 65, 67, 69, 71, 72]

# 四分音符 = 480 ティック (BPM 120 のとき 480 ティック = 0.5 秒)
# 2 秒 = 1920 ティック
ticks_per_2sec = 1920

puts "MIDI ファイル作成中..."

scale_notes.each do |note|
  # 音を鳴らす (Note On)
  track.events << MIDI::NoteOn.new(0, note, 100, 0)
  
  # 2 秒間維持した後に音を止める (Note Off)
  track.events << MIDI::NoteOff.new(0, note, 64, ticks_per_2sec)
end

# MIDI ファイルとして書き出し (同ディレクトリの sample.mid を作成・上書き)
file_path = File.join(File.expand_path(File.dirname(__FILE__)), 'sample.mid')
File.open(file_path, 'wb') { |file| seq.write(file) }

puts "作成完了! -> #{file_path}"