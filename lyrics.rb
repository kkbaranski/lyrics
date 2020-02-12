#!/usr/bin/env ruby
# frozen_string_literal: true

#======================================================================#
#                                                                      #
#              ADD LYRICS TO AUDIO FILES FROM GENIUS.COM               #
#                                                                      #
#======================================================================#
#-------------------- Krzysztof Baranski (c) 2020 ---------------------#
#======================================================================#

require 'cgi'
require 'colorize'
require 'curses'
require 'docopt'
require 'genius'
require 'json'
require 'net/http'
require 'nokogiri'
require 'open-uri'
require 'pry'
require 'shellwords'
require 'taglib'
require 'uri'

$debug_mode = false
doc = <<~DOCOPT
  Usage:
    #{File.basename($PROGRAM_NAME)} [options] <file>...

  Options:
    -p --play           Play audio automatically while processing.
    -s --skip           Automatically skip songs with lyrics. Process only songs without lyrics.
    -d --debug          Enable debug mode.
    -g --genre          Search genre of the song.
    -e --editor=EDITOR  Set editor. [default: nano]
    -h --help           Show this screen.
DOCOPT

Genius.access_token = 'M021UKAwZMYXHGgi8fVrex1hjYa3ALTFU-GCQLnVWiFjccFiXbyL11wXrA8xWEqx'

def debug(msg)
  if $debug_mode
    puts '[DEBUG] '.red + 
         "#{respond_to?(:name) ? name : self.class.name}.#{caller[0][/`.*'/][1..-2]}: ".cyan +
         msg.to_s.lines.first.magenta
  end
end

module Levenshtein
  def self.distance(a, b)
    a = a.downcase.gsub(/f(ea)?t\.?/, '').split.sort.join
    b = b.downcase.gsub(/f(ea)?t\.?/, '').split.sort.join
    costs = Array(0..b.length)
    (1..a.length).each do |i|
      costs[0] = i
      nw = i - 1
      (1..b.length).each do |j|
        costs[j], nw = [costs[j] + 1, costs[j - 1] + 2, a[i - 1] == b[j - 1] ? nw : nw + 3].min, costs[j]
      end
    end
    costs[b.length]
  end
end

Song = Struct.new(:title, :artist, :lyrics) do
  def name
    "#{artist} - #{title}"
  end

  def to_s
    name
  end
end

class SongGenre
  LAST_FM_URL = 'http://ws.audioscrobbler.com/2.0/'
  LAST_FM_API_KEY = 'a0004e6e2ef33fbc734372baa7674a42'

  def self.search(song)
    url = URI(build_url(song))
    response = JSON.parse Net::HTTP.get(url)
    response.dig('toptags', 'tag', 0, 'name')
  end

  private

  def self.build_url(song)
    artist = CGI.escape(song.artist)
    title = CGI.escape(song.title)
    "#{LAST_FM_URL}?method=track.gettoptags&artist=#{artist}&track=#{title}&api_key=#{LAST_FM_API_KEY}&autocorrect=1&format=json"
  end
end

class FileSong < Song
  attr_accessor :file, :filetype

  def self.from_file(file)
    debug('Loading song from file: ' + file.inspect)
    filetype = File.extname(file)
    debug('  filetype: ' + filetype.inspect)

    case filetype
    when '.mp3'
      Mp3.from_file(file)
    when '.m4a'
      Mp4.from_file(file)
    when '.flac'
      Flac.from_file(file)
    else
      debug('Unsupported filetype - raising error')
      raise UnsupportedMediaType, file
    end
  end

  def play
    debug("Play song: #{self}")
    stop
    system("afplay #{Shellwords.shellescape(@file)} &") if @file
  end

  def stop
    debug("Stop playing song: #{self}")
    system('killall afplay 2> /dev/null')
  end

  def filename
    File.basename @file
  end

  def to_s
    "[#{@filetype}] ".yellow + super.to_s + " (#{File.basename(file)})".cyan.italic
  end

  SaveFileError = Class.new(StandardError)
  UnsupportedMediaType = Class.new(StandardError)
end

class Lyrics < Song
  NotFound = Class.new(StandardError)

  def to_s
    "[#{self.class}] ".blue + super.to_s
  end
end

class GeniusSong < Lyrics
  def self.search(song)
    debug("Searching in Genius: #{song}")

    item = search_song(song)
    lyrics = extract_lyrics(item.url)
    debug("  lyrics: #{lyrics}")

    raise NotFound, song if lyrics.nil? || lyrics.empty?

    debug("Creating GeniusSong object: item.title='#{item.title}', item.primary_artist.name='#{item.primary_artist.name}'")
    new(item.title, item.primary_artist.name, lyrics)
  end

  def self.name
    'GENIUS'
  end

  private

  def self.search_song(song)
    debug("Searching song: #{song}")
    debug("  song name: #{song.name}")
    items = Genius::Song.search(song.name).first(5)

    if items.empty?
      debug('No items found!')
      raise(NotFound, song)
    end

    debug('Iterate over results:')
    min_distance = nil
    result_item = nil
    items.each do |item|
      name = Song.new(item.resource['title_with_featured'] || item.title, item.primary_artist.name).name
      debug("- name: '#{name}'")
      distance_title = Levenshtein.distance(item.title, song.title)
      distance_artist = Levenshtein.distance(item.primary_artist.name, song.artist)
      distance = distance_title + distance_artist
      debug("  distance: #{distance_title} + #{distance_artist} = #{distance}")

      if min_distance.nil? || distance < min_distance
        debug('    Updating result!')
        min_distance = distance
        result_item = item
      end

      break if min_distance == 0
    end

    raise NotFound, song unless result_item

    debug("Item selected: min_distance=#{min_distance}, result_item: #{result_item.inspect}")
    result_item
  end

  def self.extract_lyrics(url)
    debug("Extracting lyrics from url: #{url}")
    page = Nokogiri::HTML.parse(open(url))
    lyrics = page.css('div.lyrics')&.text
    lyrics&.strip&.gsub(/\n{3,}/, "\n\n")&.strip
  end
end

class TekstowoSong < Lyrics
  PAGE_URL = 'https://www.tekstowo.pl'

  def self.search(song)
    debug("Searching in Tekstowo: #{song}")
    name, url = search_song(song)
    debug("  name='#{name}', url='#{url}'")
    artist, title = extract_name(name)
    debug("  artist='#{artist}', title='#{title}'")
    lyrics = extract_lyrics(url, song: song) || ''
    debug("  lyrics='#{lyrics}'")
    new(title || '', artist || '', lyrics)
  end

  def self.name
    'TEKSTOWO'
  end

  private

  def self.search_song(song)
    debug("Searching song: #{song}")
    debug("  song name: #{song.name}")
    url = build_url(song)
    debug("  url='#{url}'")
    page = Nokogiri::HTML.parse(open(url))

    debug('Iterate over results:')
    min_distance = nil
    result_name = nil
    result_endpoint = nil
    page.css('div.content > div.box-przeboje')&.first(10)&.each do |element|
      name = element&.css('a.title')&.attribute('title')&.value
      debug("- name: '#{name}'")
      next if name.nil? || name.empty? || !name.include?('-')

      distance = Levenshtein.distance(name, song.name)
      debug("  distance: #{distance}")

      if min_distance.nil? || distance < min_distance
        debug('    Updating result!')
        min_distance = distance
        result_name = name
        result_endpoint = element&.css('a.title')&.attribute('href')&.value
      end

      break if min_distance == 0
    end

    debug("Song selected: min_distance=#{min_distance}, result_name='#{result_name}', result_endpoint='#{result_endpoint}'")

    raise NotFound, song unless result_endpoint

    [result_name.to_s, "#{PAGE_URL}#{result_endpoint}"]
  end

  def self.build_url(song)
    artist = CGI.escape(song.artist)
    title = CGI.escape(song.title)
    "#{PAGE_URL}/szukaj,wykonawca,#{artist},tytul,#{title}"
  end

  def self.extract_lyrics(url, song:)
    debug("Extracting lyrics from url: #{url}")
    page = Nokogiri::HTML.parse(open(url))
    lyrics = page.css('div.song-text > text()')&.text
    debug("  lyrics='#{lyrics&.strip}'")
    raise NotFound, song if lyrics.nil? || lyrics.empty?

    lyrics.strip.gsub(/\n{3,}/, "\n\n").strip
  end

  def self.extract_name(name)
    debug("Extracting name: #{name}")
    name&.split(' - ', 2)
  end
end

class Mp3 < FileSong
  def self.from_file(file)
    song = new
    song.file = File.expand_path(file)
    song.filetype = File.extname(file)
    song.extract_tags
    song
  end

  def extract_tags
    TagLib::MPEG::File.open(file) do |mp3|
      self.artist = mp3&.tag&.artist || ''
      self.title = mp3&.tag&.title || ''
      self.lyrics = mp3&.id3v2_tag&.frame_list('USLT')&.first&.text || ''
    end
  end

  def save_lyrics(text)
    TagLib::MPEG::File.open(file) do |mp3|
      tag = mp3.id3v2_tag(create = true)

      uslt = TagLib::ID3v2::UnsynchronizedLyricsFrame.new
      uslt.text = text
      uslt.text_encoding = TagLib::String::UTF8

      tag.remove_frames('USLT')
      tag.add_frame(uslt)

      raise SaveFileError unless mp3.save

      self.lyrics = mp3&.id3v2_tag&.frame_list('USLT')&.first&.text
    end
  end
end

class Mp4 < FileSong
  def self.from_file(file)
    song = new
    song.file = File.expand_path(file)
    song.filetype = File.extname(file)
    song.extract_tags
    song
  end

  def extract_tags
    TagLib::MP4::File.open(@file) do |mp4|
      item_map = mp4.tag.item_map
      self.artist = item_map["\xC2\xA9ART"]&.to_string_list&.first || ''
      self.title = item_map["\xC2\xA9nam"]&.to_string_list&.first || ''
      self.lyrics = item_map["\xC2\xA9lyr"]&.to_string_list&.first || ''
    end
  end

  def save_lyrics(text)
    TagLib::MP4::File.open(@file) do |mp4|
      item_map = mp4.tag.item_map
      item_map["\xC2\xA9lyr"] = TagLib::MP4::Item.from_string_list [text]
      raise SaveFileError unless mp4.save
    end
  end
end

class Flac < FileSong
  def self.from_file(file)
    song = new
    song.file = File.expand_path(file)
    song.filetype = File.extname(file)
    song.extract_tags
    song
  end

  def extract_tags
    TagLib::FLAC::File.open(@file) do |flac|
      self.artist = flac.tag&.artist || ''
      self.title = flac.tag&.title || ''
      self.lyrics = flac.xiph_comment&.field_list_map&.fetch('LYRICS', [])&.first || ''
    end
  end

  def save_lyrics(text)
    debug("Saving text: #{text}")
    TagLib::FLAC::File.open(@file) do |flac|
      flac.xiph_comment.add_field('LYRICS', text)
      raise SaveFileError unless flac.save
    end
  end
end

class LyricsPicker
  SkipError = Class.new(StandardError)

  COLORS = {
    lyrics1: 1,
    lyrics2: 2,
    lyrics3: 3,
    lyrics4: 4,
    lyrics5: 5
  }.freeze

  module Colors
    LYRICS1 = 1
    LYRICS2 = 2
    LYRICS3 = 3
    LYRICS4 = 4
    LYRICS5 = 5
    LYRICS6 = 6

    SONG = 10
    CONTROL = 20
    INFO = 30

    LYRICS = [LYRICS1, LYRICS2, LYRICS3, LYRICS4, LYRICS5, LYRICS6].shuffle
  end

  def initialize(for_song:, sources:)
    @song = for_song

    unless $debug_mode
      Curses.init_screen
      Curses.start_color
      Curses.stdscr.keypad = true
    end
    configure_colors(sources)

    @margin = 3
    @header_height = 6
    @header_pos_y = 1
    @header_title_pos_y = 2
    @header_artist_pos_y = 3
    @equal_info_pos_y = 8
  end

  def configure_colors(sources)
    @lyrics_colors = sources.zip(Colors::LYRICS.cycle).to_h

    unless $debug_mode
      Curses.init_pair(Colors::LYRICS1, Curses::COLOR_BLUE,    Curses::COLOR_BLACK)
      Curses.init_pair(Colors::LYRICS2, Curses::COLOR_GREEN,   Curses::COLOR_BLACK)
      Curses.init_pair(Colors::LYRICS3, Curses::COLOR_CYAN,    Curses::COLOR_BLACK)
      Curses.init_pair(Colors::LYRICS4, Curses::COLOR_RED,     Curses::COLOR_BLACK)
      Curses.init_pair(Colors::LYRICS5, Curses::COLOR_MAGENTA, Curses::COLOR_BLACK)
      Curses.init_pair(Colors::LYRICS6, Curses::COLOR_YELLOW,  Curses::COLOR_BLACK)

      Curses.init_pair(Colors::SONG,    Curses::COLOR_WHITE,   Curses::COLOR_BLACK)

      Curses.init_pair(Colors::CONTROL, Curses::COLOR_BLACK,   Curses::COLOR_WHITE)
      Curses.init_pair(Colors::INFO,    Curses::COLOR_WHITE,   Curses::COLOR_GREEN)
    end
  end

  def pick(lyrics)
    setup_lyrics(lyrics)
    unless $debug_mode
      loop do
        Curses.clear

        draw_lyrics
        draw_song
        draw_controls
        draw_equal_info if @current_lyrics.lyrics == @song.lyrics

        Curses.refresh
        case Curses.getch
        when Curses::Key::LEFT
          return @current_lyrics_source
        when Curses::Key::RIGHT
          return nil
        when Curses::Key::UP
          raise SkipError
        when Curses::Key::DOWN
          switch_lyrics
        when 'e'
          Curses.close_screen
          edit_current_lyrics
        when 'p'
          @song.play
        when 's'
          @song.stop
        end
      end
    end
  ensure
    Curses.close_screen
  end

  private

  def draw_lyrics
    draw_header(@current_lyrics, @current_lyrics_source.name, pos_x: @margin, color_scheme: @current_lyrics_color)
    draw_lyrics_box(@current_lyrics, pos_x: @margin, color_scheme: @current_lyrics_color)
  end

  def draw_song
    draw_header(@song, @song.filename, pos_x: @margin + col_width, color_scheme: Colors::SONG)
    draw_lyrics_box(@song, pos_x: @margin + col_width, color_scheme: Colors::SONG)
  end

  def draw_equal_info
    equal_info_text = 'LYRICS ARE THE SAME'
    equal_box_width = [equal_info_text.length + 4, Curses.cols / 4].max
    equal = Curses.stdscr.subwin(3, equal_box_width, Curses.lines / 2 - 2, @margin + col_width - equal_box_width / 2 - 1)
    equal.box(0, 0)
    equal.bkgd(Curses.color_pair(Colors::INFO) | Curses::A_BLINK | Curses::A_BOLD)
    equal.setpos(1, center_pos_x(equal_box_width, equal_info_text))
    equal.addstr(equal_info_text)
  end

  def draw_controls
    t1 = "| ◀︎ | ▶︎ | ▲ | ▼ |#{' 🄴  |' if can_edit?} 🄿  | 🅂  |"
    t2 = "| ◀︎ #{@current_lyrics_source.name.capitalize} | ▶︎ Original | ▲ Skip | ▼ Switch |#{' 🄴  |' if can_edit?} 🄿  | 🅂  |"
    t3 = "| ◀︎ #{@current_lyrics_source.name.capitalize} | ▶︎ Original | ▲ Skip | ▼ Switch |#{' 🄴 dit |' if can_edit?} 🄿 lay | 🅂 top |"
    t4 = "| ◀︎ Choose #{@current_lyrics_source.name.capitalize} | ▶︎ Keep Original | ▲ Skip | ▼ Change lyrics source |#{' 🄴  Edit ' + @current_lyrics_source.name.capitalize + ' lyrics |' if can_edit?} 🄿  Play audio | 🅂  Stop playing audio |"

    text = case Curses.cols
    when 0...t2.length
      t1
    when t2.length...t3.length
      t2
    when t3.length...t4.length
      t3
    else
      t4
    end

    control = Curses.stdscr.subwin(1, Curses.cols, Curses.lines - 1, 0)
    control.bkgd(Curses.color_pair(Colors::CONTROL) )
    control.setpos(0, 0)
    control.addstr(text)
  end

  def setup_lyrics(lyrics)
    @lyrics_iterator = lyrics.cycle
    switch_lyrics
  end

  def switch_lyrics
    @current_lyrics_source, @current_lyrics = @lyrics_iterator.next
    @current_lyrics_color = @lyrics_colors[@current_lyrics_source]
  end

  def edit_current_lyrics
    return unless can_edit?

    new_lyrics = `printf #{Shellwords.escape(@current_lyrics.lyrics)} | vipe`.chomp
    @current_lyrics.lyrics = new_lyrics unless new_lyrics.empty?
  end

  def draw_header(song, header_title, pos_x:, color_scheme:)
    header_title = " #{header_title} "
    header = Curses.stdscr.subwin(@header_height, col_width, @header_pos_y, pos_x)
    header.box(0, 0)
    header.bkgd(Curses.color_pair(color_scheme) | Curses::A_REVERSE)
    header.attrset(Curses.color_pair(color_scheme) | Curses::A_BOLD)
    header.setpos(@header_title_pos_y, center_pos_x(col_width, song.title))
    header.addstr(song.title.upcase)
    header.attrset(Curses.color_pair(color_scheme) & ~Curses::A_BOLD)
    header.setpos(@header_artist_pos_y, center_pos_x(col_width, song.artist))
    header.addstr(song.artist)
    header.attrset(Curses.color_pair(color_scheme) | Curses::A_BLINK | Curses::A_BOLD)
    header.setpos(0, center_pos_x(col_width, header_title))
    header.addstr(header_title)
  end

  def draw_lyrics_box(song, pos_x:, color_scheme:)
    lyrics_box_pos_y = @header_height + @header_pos_y
    lyrics_box_height = Curses.lines - lyrics_box_pos_y - 1

    lyrics = Curses.stdscr.subwin(lyrics_box_height, col_width, lyrics_box_pos_y, pos_x)
    lyrics.box(0, 0)
    lyrics.bkgd(Curses.color_pair(color_scheme))
    song.lyrics.split("\n").each_with_index do |line, i|
      break if i > lyrics_box_height - 4

      lyrics.setpos(i + 1, center_pos_x(col_width, line))
      lyrics.addstr(line)
    end
  end

  def center_pos_x(width, text)
    (width - text.length) / 2
  end

  def col_width
    Curses.cols / 2 - @margin
  end

  def can_edit?
    !`which vipe`.strip.empty?
  end
end

class FilesProcessor
  attr_accessor :play_mode, :skip_mode, :genre_mode

  LYRICS_SOURCES = [GeniusSong, TekstowoSong].freeze

  def initialize
    @skipped_files = []
    @broken_files = []
    @level = 0
    @play_mode = false
    @skip_mode = false
  end

  def process(items)
    debug('Start processing items: ' + items.inspect)
    items.each do |item|
      process_item(item)
    end
  end

  def print_skipped_files
    return if @skipped_files.empty?

    puts "\nSkipped files:".yellow.swap
    @skipped_files.each do |f|
      puts '  ' + Shellwords.shellescape(f)
    end
  end

  def print_broken_files
    return if @broken_files.empty?

    puts "\nBroken files:".red.swap
    @broken_files.each do |f|
      puts '  ' + Shellwords.shellescape(f)
    end
  end

  private

  def process_item(item)
    debug("Processing item: #{item}")
    if File.directory? item
      debug("#{item} is a directory.")
      process_directory(item)
    else
      debug("#{item} is NOT a directory.")
      process_audio_file(item)
    end
  end

  def process_directory(dir)
    print dir.blue
    debug("Processing directory: #{dir}")
    Dir.chdir(dir) do
      @level += 1
      Dir.each_child(Dir.pwd) do |item|
        process_item(item)
      end
    ensure
      @level -= 1
    end
  end

  def process_audio_file(file)
    debug("Processing audio file: #{file}")
    song = FileSong.from_file(file)
    debug("  song: #{song}")

    if genre_mode
      debug("Searching genre for song: #{song}")
      genre = SongGenre.search(song)
      label(genre, :magenta) && return
    end

    if @skip_mode && !song.lyrics.nil? && !song.lyrics.empty?
      label(:automatically_skipped, :yellow) && return
    end
    song.play if @play_mode

    debug("Searching lyrics for song: #{song}")
    lyrics = search_lyrics(song)

    selected = LyricsPicker.new(for_song: song, sources: LYRICS_SOURCES).pick(lyrics)

    if selected
      song.save_lyrics(lyrics[selected].lyrics)
      label selected.name, :green
    else
      label :original
    end
  rescue FileSong::UnsupportedMediaType
    label :unsupported_file, :red
  rescue FileSong::SaveFileError
    add_to_broken(song.file)
    label :save_error, :red
  rescue Lyrics::NotFound
    add_to_broken(song.file)
    label :lyrics_not_found, :red
  rescue LyricsPicker::SkipError
    add_to_skipped(song.file)
    label :skipped, :yellow
  ensure
    print song || file
    song&.stop
  end

  def seach_lyrics_in_source(song, source)
    source.search(song)
  rescue Lyrics::NotFound
    nil
  end

  def search_lyrics(song)
    all_lyrics = {}
    LYRICS_SOURCES.each do |source|
      lyrics = seach_lyrics_in_source(song, source)
      all_lyrics[source] = lyrics if lyrics
    end
    raise Lyrics::NotFound, song if all_lyrics.empty?

    all_lyrics
  end

  def add_to_skipped(file)
    @skipped_files << file
  end

  def add_to_broken(file)
    @broken_files << file
  end

  def label(l, color = :white)
    @label = l.to_s.gsub(/_/, ' ').to_s.split.map(&:capitalize).join(' ').send(color).bold
  end

  def print(text)
    prefix = '  ' * @level
    suffix = ' ⟶   '.blue + @label if @label
    @label = nil
    puts "#{prefix}#{text}#{suffix}"
  end
end

def parse_arguments(doc)
  Docopt.docopt(doc)
rescue Docopt::Exit => e
  puts e.message
  exit
end

file_processor = FilesProcessor.new
options = parse_arguments(doc)

$debug_mode = options['--debug']
file_processor.play_mode = options['--play']
file_processor.skip_mode = options['--skip']
file_processor.genre_mode = options['--genre']
ENV['EDITOR'] = options['--editor']
file_processor.process options['<file>']

file_processor.print_skipped_files
file_processor.print_broken_files
