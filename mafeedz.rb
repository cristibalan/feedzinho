require 'rubygems'
require 'rest_client'
require 'xmlsimple'

require 'pp'
require 'fileutils'

CLIENT = "feedzinho"

class Gr
  class SIDError < StandardError; end

  def initialize(email, pass=nil)
    @email = email
    @pass = pass
  end

  def log(msg)
    puts msg
  end

  def email
    return @email if @email

    puts "Email: "
    @email = gets.chomp
  end

  def pass
    return @pass if @pass

    puts "Password for #{email}: "
    system "stty -echo"
    @pass = gets.chomp
    system "stty echo"

    @pass
  end

  def sid(force=false)
    return @sid if @sid && !force

    response = RestClient.post('https://www.google.com/accounts/ClientLogin', :service => 'reader', :source => FEEDZINHO,
                               :Email => email, :Passwd=> pass)

    if response =~ /SID=(.*)/
      @sid = $1
    else
      raise SIDError
    end

    log "Got new SID"
    log @sid
    @sid
  end

  def get_body(e)
    if e["summary"]
      return e["summary"].first["content"]
    elsif e["content"]
      return e["content"]["content"]
    end
    
    return ""
  end

  def get_source(e)
    raw_source = e["source"][0]["id"].to_s

    MAPPING.find {|k, v| raw_source.index v}[0]
  end


  def token(force=false)
    return @token if @token && !force

    @token ||= RestClient.get("http://www.google.com/reader/api/0/token?ck=#{Time.now().to_i}&client=#{FEEDZINHO}", {:Cookie => "SID=#{sid}"})
  end

  def mark_as_read(id)
    response = RestClient.post("http://www.google.com/reader/api/0/edit-tag?client=#{FEEDZINHO}",
                               {:a => "user/-/state/com.google/read", :ac => "edit", :T => token, :i => id},
                               {:Cookie => "SID=#{sid}"})
    log response
    response
  end

  def fetch_reading_list_xml(force=false)
    if force
      reading_list_url = "http://www.google.com/reader/atom/user/-/state/com.google/reading-list?xt=user/-/state/com.google/read"
      xml = RestClient.get(reading_list_url, {:Cookie=>"SID=#{sid}"}).to_s
      File.open("tmp.xml", "w") do |f|
        f << xml
      end
    else
      xml = File.read('tmp.xml')
    end

    XmlSimple.xml_in(xml)
  end

  def reading_list
    # xml = fetch_reading_list_xml
    xml = fetch_reading_list_xml(true)

    items = []
    if xml["entry"]
      xml["entry"].each do |e|
        items << {
          :source     => get_source(e),
          :id         => e["id"][0]["content"],
          :title      => e["title"][0]["content"],
          :body       => parse_body(e),

          :read       => !!e["category"].find{|c| c["label"] == "read" },
          :fresh      => !!e["category"].find{|c| c["label"] == "fresh" } ,

          :created_at => Date.parse(e["published"].to_s),
        }
      end
    end

    log Time.now
    log items.length
    items
  end
end

class Gr
  MAPPING = {
    'github' => "http://github.com/",
    "xkcd"   => "http://xkcd.com/rss.xml",
    "ichc"   => "http://feeds.feedburner.com/ICanHasCheezburger",
    "fy4c"   => "http://fuckyeah4chan.tumblr.com/rss",
    'epic4c' => "http://epic4chan.feedphoenix.com/epic4chan",
    "lsed"   => "http://cargocollective.com/feed-rss.php?url=learnsomethingeveryday",
    "mfd"    => "http://myfirstdictionary.blogspot.com/feeds/posts/default",
  }

  def get_dir(entry)
    entry[:source] == "github" ? "github" : "fun"
  end

  def parse_body(entry)
    title = entry["title"][0]["content"]
    html = get_body(entry)

    case get_source(entry)
    when "github"
      # only care about followed people, and created/watched/forked repos
      if title !~ / gist: \d+/ && title =~ /\S+\s(?:created repository|started watching|started following|forked).*\s(\S+)$/
        item = $1
        if title =~ /created repository/
          item = "#{title.gsub(/\s.*/, "")}/#{item}"
        end
        clean_html = html.gsub(/.*<blockquote>/m, "").gsub(/<\/blockquote>.*/m, "")
        watch = ""
        # watch = %( (<a href="http://github.com/#{item}/toggle_watch">TOGGLE WATCH</a>)) if item.index('/')

        <<-HTML
          #{title.gsub(/\s\S+$/, "")}
          <a href="http://github.com/#{item}" target="_blank">#{item}</a>
          #{watch}
          <br/>
          <small>#{clean_html}</small>
        HTML
      end

    when "xkcd"
      tagline = html.gsub(/.*title="/, "").gsub(/".*/, "")
      %(#{html} <br/> #{tagline})

    when "ichc"
      %(<img src="#{$1}"/>) if html =~ /src="(http:\/\/icanhascheezburger\.files\.wordpress\.com\/.*?)"/

    when "lsed", "mfd"
      %(<img src="#{$1}"/>) if html =~ /src="(http:.*?)"/

    else
      html
    end
  end
end

FileUtils.cd(File.dirname(__FILE__))

gr = Gr.new(USERNAME, PASSWORD)

gr.reading_list.each do |entry|
  if entry[:body]
    date = entry[:created_at].strftime("%Y-%m-%d")

    month = entry[:created_at].month
    month = "0#{month}" if month < 10
    day = entry[:created_at].day
    day = "0#{day}" if day < 10

    dir = "output/#{gr.get_dir(entry)}/#{entry[:created_at].year}/#{month}"
    FileUtils.mkdir_p(dir)

    File.open("#{dir}/#{day}.html", "a+") do |f|
      html = <<-HTML

        <hr/>
        
        <div data-source="#{entry[:source]}" style="clear: both; padding: 1em; overflow: auto">
          #{entry[:body]}
        </div>
      HTML
      f << html
    end
  end
  gr.mark_as_read(entry[:id])
end
