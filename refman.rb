# -*- coding: utf-8 -*-

builtin_classes = {}
ObjectSpace.each_object do |obj|
  builtin_classes[obj.name] = obj if obj.is_a?(Class)
end
#p builtin_classes


def get_class(name)
  obj = Object
  name.split(/::/).each {|s| obj = obj.const_get(s) }
  return obj
end

def report_error(msg)
  #$stderr.puts "*** #{msg}"
  warn "*** #{msg}"
end

def str_jleft(str, len)
  ## required $KCODE
  return "" if len <= 0
  s = str[0, len]
  s[-1, 1] = '' unless s =~ /.\z/
  return s
end

def url_escape(str)
  return str.gsub(/([^ a-zA-Z0-9_.-]+)/n) {
    '%' + $1.unpack('H2' * $1.size).join('%').upcase
  }.tr(' ', '+')
end

HTML_ESCAPE = {'&'=>'&amp;', '<'=>'&lt;', '>'=>'&gt;'}
def html_escape(str)
  return str.to_s.gsub(/[&<>]/) { HTML_ESCAPE[$&] }
end

def trim_link(str)
  return str.to_s.gsub(/\[\[[a-z]:(.*?)\]\]/, '\1')
end

def text2html(text_str)
  pos = 0
  html = ''
  text_str.scan(/\[\[(\w):(.*?)\]\]/) {
    matched, indicator, label = $&, $1, $2
    html << html_escape(text_str[pos...$~.begin(0)])
    pos = $~.end(0)
    if label =~ /\A([\w:]+)(?:(\.|\#|\.\#)(.*))?\z/
      class_name, sep, method_name = $1, $2, $3
      href = "#{class_name.gsub(/::/, '--')}.html"
      ch = indicator == 's' ? '.' : ''
      href << "##{ch}#{url_escape(method_name)}" if sep
      html << %Q|<a href="#{href}">#{html_escape(label)}</a>|
    else
      #report_error("label=#{label.inspect}")
      html << matched
    end
  }
  rest = pos == 0 ? text_str : text_str[pos..-1]
  html << html_escape(rest)
  return html
end


class Entry

  def initialize
    @rating = 1
  end

  attr_accessor :type, :library, :superclass, :extended, :included
  attr_accessor :content, :name, :filepath, :url, :desc, :klass, :rating

  def [](name)
    return self.instance_variable_get("@#{name}")
  end

  def []=(name, value)
    self.instance_variable_set("@#{name}", value)
  end

  def load_file(filepath)
    str = File.read(filepath)
    header, content = str.split(/\n\n/, 2)
    entry = self
    header.each_line do |line|
      key, val = line.strip.split(/=/, 2)
      self[key] = val
    end
    self.content = content
    return self
  end

  def important?
    return @rating >= 3
  end

  def short_desc(len=80)
    unless @short_desc
      desc = trim_link(self.desc)
      @short_desc = desc.length <= len ? desc : str_jleft(desc, len-3) + '...'
    end
    return @short_desc
  end

  def html_content
    return text2html(@content)
  end

end


class ClassEntry < Entry

  attr_accessor :extended, :included
  attr_accessor :children, :ancestors

  def url
    return @url ||= (@name.nil? ? nil : @name.gsub(/::/, '--') + '.html')
  end

  def desc
    #return @content.to_s.split(/\n\n/, 2).first.gsub(/\n/, '')
    #@content.to_s =~ /\n\n/
    content = @content.to_s
    pos = content.index(/\n\n/)
    return trim_link(pos ? content[0..pos] : content)
  end

end


class MethodEntry < Entry

  attr_accessor :parent

  def url
    name = @name[0] == ?# ? @name[1..-1] : @name
    return "##{url_escape(name)}"
  end

  def desc
    #return @content.to_s.split(/\n\n/, 3)[1].gsub(/\n/, '')
    @content.to_s =~ /\n\n(.*?)\n\n/m
    return trim_link($1.to_s)
  end

end


class Builder

  def initialize(ruby_version, datadir=nil, outdir=nil)
    @ruby_version = ruby_version
    @datadir = datadir || "db-#{ruby_version.gsub(/[-.]/, '_')}"
    @outdir = outdir   || "public/#{ruby_version.gsub(/[-_]/, '.')}"
  end
  attr_accessor :ruby_version, :datadir, :outdir

  IMPORTANT_CLASSES = dict = {}
  %w[
    Object String Array Hash File Dir Struct Class Module Proc Range Regexp Symbol Time
    Enumerable Kernel Math
    Exception StandardError RuntimeError
  ].each {|x| dict[x] = true }

  def important?(name)
    return IMPORTANT_CLASSES.key?(name)
  end

  def load_class_entries
    ## get entries
    entries = {}
    File.open("#{@datadir}/class/=index") do |f|
      f.each_line do |line|
        ## datafile path
        entry_name, class_name = line.strip.split(/\t/, 2)
        filename = entry_name.gsub(/[A-Z]/) { "-#{$&.downcase}" }.gsub(/::/, '=')
        filepath = "#{@datadir}/class/#{filename}"
        unless File.exist?(filepath)
          #report_error "#{filepath}: not found (#{class_name})"
          next
        end
        ## load datafile
        entry = ClassEntry.new.load_file(filepath)
        entry.name = class_name
        entry.filepath = filepath
        ## select only built-in class
        if entry.library == '_builtin'
          entry.rating = 3 if important?(class_name)
          entries[class_name] = entry
        end
      end
    end
    return entries
  end

  def load_method_entries(class_entry)
    s = class_entry.name.gsub(/[A-Z]/) { "-#{$&.downcase}" }
    dir = "#{@datadir}/method/#{s.gsub(/::/, '=')}"
    method_names = {}
    File.open("#{dir}/=index") do |f|
      f.each_line do |line|
        method_name, method_name_with_class = line.chomp.split(/\t/)
        class_name, alias_name = method_name_with_class.split(/(?=[.\#])/, 2)
        if class_name == class_entry.name
          method_names[method_name] = alias_name
        end
      end
    end
    entries = {}
    prefixes = {'.'=>'s.', '#'=>'i.', '.#'=>'m.'}
    method_names.each do |method_name, alias_name|
      prefix = nil
      s = alias_name
      s = s.gsub(/^[.\#]+/) { prefix = prefixes[$&] }
      s = s.gsub(/[^.\w]/) { '=' + $&[0].to_s(16) }
      s = s.gsub(/[A-Z]/) { "-#{$&.downcase}" }
      filepath = "#{dir}/#{s}._builtin"
      unless File.exist?(filepath)
        ! Dir.glob("#{dir}/#{s}.*").empty?  or
          report_error("#{filepath}: not found. (#{method_name})")
        next
      end
      method_name = method_name.sub(/^[.\#]/, '.#') if prefix == 'm.'
      entry = MethodEntry.new.load_file(filepath)
      entry.name = method_name
      entry.parent = class_entry
      entries[method_name] = entry
      #entries << entry
    end
    entry_list = entries.keys.sort.collect {|key| entries[key] }
    return entry_list
  end

  def build_index(entries)
    ## classify entries
    class_entries = {}
    module_entries = {}
    exception_entries = {}
    object_entries = {}
    entries.each do |class_name, entry|
      next if class_name.start_with?('Errno::') && class_name != 'Errno::EXXX'
      next if class_name == "fatal"
      begin
        klass = get_class(class_name)
        dict = entry.type == 'object' ? object_entries    : \
               klass <= Exception     ? exception_entries : \
               klass.class == Class   ? class_entries     : module_entries
      rescue NameError => ex   # when class_name == "Errno::EXXX"
        klass = nil
        dict = exception_entries
      end
      entry.klass = klass
      dict[class_name] = entry
    end
    ## render html
    context = {
      :ruby_version => @ruby_version,
      :library_name => 'builtin',
      :class_entries     => class_entries,
      :module_entries    => module_entries,
      :exception_entries => exception_entries,
    }
    html = render("templates/index.eruby", context)
    return html
  end

  def build_class_html(class_entry)
    class_entry.children ||= load_method_entries(class_entry)
    context = {
      :ruby_version => @ruby_version,
      :library_name => 'builtin',
      :class_entry  => class_entry,
    }
    html = render("templates/class.eruby", context)
    return html
  end

  def build_all
    entries = load_class_entries()
    html = build_index(entries)
    basedir = "#{@outdir}/builtin"
    Dir.mkdir(basedir) unless File.exist?(basedir)
    File.open("#{basedir}/index.html", 'w') {|f| f.write(html) }
    ##
    entries.delete_if {|class_name, class_entry|
      class_entry.klass.nil? || class_entry.type == 'object'
    }
    entries.each do |class_name, class_entry|
      class_entry.children ||= load_method_entries(class_entry)
      ancestor_classes = class_entry.klass.ancestors[1..-1]
      ancestor_classes.delete(Kernel)
      class_entry.ancestors = ancestor_classes.collect {|klass| entries[klass.name] }
    end
    entries.each do |class_name, class_entry|
      html = build_class_html(class_entry)
      filename = "#{basedir}/#{class_entry.url}"
      File.open(filename, 'w') {|f| f.write(html) }
    end
  end

  def render(template_filepath, context)
    require 'erubis'
    eruby = Erubis::Eruby.new(File.read(template_filepath))
    return eruby.evaluate(context)
  end

end


class Main

  def initialize(argv=ARGV, command=nil)
    command ||= File.basename($0)
    @argv = argv
    @command = command
  end

  def parse_argv
    require "optparse"
    parser = OptionParser.new
    options = {}
    parser.on('-h', 'help') {|val| options['-h'] = val }
    parser.on('-r ver', 'ruby version (1_8_7 or 1_9_1)') {|val| options['-r'] = val }
    filenames = parser.parse(@argv)
    if options['-h']
      options['-h'] = parser.help
    end
    return options, filenames
  end

  def call
    options, filenames = parse_argv()
    if options['-h']
      puts "Usage: #{@command} [-h] -r [1.8.7|1.9.1]"
      puts options['-h'].sub(/\A.*?\n/, '')
      return
    end
    errclass = OptionParser::InvalidOption
    options['-r']  or raise errclass.new("'-r ruby-version' is required.")
    ver = options['-r'].gsub(/[-_]/, '.')
    datadir = "db-#{ver.gsub(/\./, '_')}"
    outdir  = "public/#{ver}"
    File.directory?(datadir)  or
      raise errclass.new("-r #{options['-r']}: '#{datadir}' not found.")
    File.directory?(outdir)  or
      raise errclass.new("-r #{options['-r']}: '#{outdir}' not found.")
    builder = Builder.new(ver, datadir, outdir)
    builder.build_all
  end

  def self.main
    begin
      command = File.basename($0)
      self.new(ARGV, command).call
    rescue OptionParser::InvalidOption => ex
      $stderr.puts "#{command}: #{ex.message}"
    end
  end

end


if __FILE__ == $0
  Main.main
end
