# -*- coding: utf-8 -*-

### event.rb
##
## Author:  Yoshinari Nomura <nom@quickhack.net>
##
## Created: 1999/07/16
## Revised: $Date: 2008-10-08 03:22:37 $
##

module Mhc
  # Mhc::Event defines a simple representation of calendar events.
  # It looks like a RFC822 message with some X- headers to represent event properties:
  # * X-SC-Subject:
  # * X-SC-Location:
  # * X-SC-Day:
  # * X-SC-Time:
  # * X-SC-Category:
  # * X-SC-Recurrence-Tag:
  # * X-SC-Mission-Tag:
  # * X-SC-Cond:
  # * X-SC-Duration:
  # * X-SC-Alarm:
  # * X-SC-Record-Id:
  # * X-SC-Sequence:
  #
  class Event
    ################################################################
    ## initializers

    def initialize
      clear
    end

    def self.parse(string)
      return new.parse(string)
    end

    def self.parse_file(path, lazy = true)
      return new.parse_file(path, lazy)
    end

    def parse_file(path, lazy = true)
      clear
      header, body = nil, nil

      File.open(path, "r") do |file|
        header = file.gets("\n\n")
        body   = file.gets(nil) unless lazy
      end

      @path = path if lazy
      parse_header(header)
      self.description = body if body
      return self
    end

    def parse(string)
      clear
      header, body = string.scrub.split(/\n\n/, 2)

      parse_header(header)
      self.description = body
      return self
    end

    def path
      return @path
    end
    ################################################################
    ## access methods to each property.

    ## alarm
    def alarm
      return @alarm ||= Mhc::PropertyValue::Period.new
    end

    def alarm=(string)
      return @alarm = alarm.parse(string)
    end

    ## category
    def categories
      return @categories ||=
        Mhc::PropertyValue::List.new(Mhc::PropertyValue::Text)
    end

    def categories=(string)
      return @categories = categories.parse(string)
    end

    ## description
    def description
      unless @description
        @description = Mhc::PropertyValue::Text.new

        if lazy? && File.file?(@path)
          File.open(@path, "r") do |file|
            file.gets("\n\n") # discard header.
            @description.parse(file.gets(nil))
          end
        end
      end
      return @description
    end
    alias_method :body, :description

    def description=(string)
      return @description = description.parse(string)
    end

    ## location
    def location
      return @location ||= Mhc::PropertyValue::Text.new
    end

    def location=(string)
      return @location = location.parse(string)
    end

    ## record-id
    def record_id
      return @record_id ||= Mhc::PropertyValue::Text.new
    end

    def record_id=(string)
      return @record_id = record_id.parse(string)
    end

    def uid
      record_id.to_s
    end

    ## subject
    def subject
      return @subject ||= Mhc::PropertyValue::Text.new
    end

    def subject=(string)
      return @subject = subject.parse(string)
    end

    ## date list is a list of date range
    def dates
      return @dates ||=
        Mhc::PropertyValue::List.new(Mhc::PropertyValue::Range.new(Mhc::PropertyValue::Date.new))
    end

    def dates=(string)
      string = string.split.select {|s| /^!/ !~ s}.join(" ")
      return @dates = dates.parse(string)
    end

    def obsolete_dates=(string)
      # STDERR.print "Obsolete X-SC-Date: header.\n"
      if /(\d+)\s+([A-Z][a-z][a-z])\s+(\d+)\s+(\d\d:\d\d)/ =~ string
        dd, mm, yy, hhmm = $1.to_i, $2, $3.to_i + 1900, $4
        mm = ("JanFebMarAprMayJunJulAugSepOctNovDec".index(mm)) / 3 + 1
        @dates = dates.parse("%04d%02d%02d" % [yy, mm, dd])
        if hhmm and hhmm != '00:00'
          @time_range = time_range.parse(hhmm)
        end
      end
    end

    def exceptions
      return @exceptions ||=
        Mhc::PropertyValue::List.new(Mhc::PropertyValue::Range.new(Mhc::PropertyValue::Date.new, "!"))
    end

    def exceptions=(string)
      string = string.split.select {|s| /^!/ =~ s}.map{|s| s[1..-1]}.join(" ")
      return @exceptions = exceptions.parse(string)
    end

    ## time
    def time_range
      return @time_range ||=
        Mhc::PropertyValue::Range.new(Mhc::PropertyValue::Time)
    end

    def time_range=(string)
      @time_range = time_range.parse(string)
      return @time_range
    end

    ## duration
    def duration
      return @duration ||=
        Mhc::PropertyValue::Range.new(Mhc::PropertyValue::Date)
    end

    def duration=(string)
      return @duration = duration.parse(string)
    end

    ## recurrence condition
    def recurrence_condition
      return @cond ||= Mhc::PropertyValue::RecurrenceCondition.new
    end

    def recurrence_condition=(string)
      return @cond = recurrence_condition.parse(string)
    end

    ## recurrence-tag
    def recurrence_tag
      return @recurrence_tag ||= Mhc::PropertyValue::Text.new
    end

    def recurrence_tag=(string)
      return @recurrence_tag = recurrence_tag.parse(string)
    end

    ## mission-tag
    def mission_tag
      return @mission_tag ||= Mhc::PropertyValue::Text.new
    end

    def mission_tag=(string)
      return @mission_tag = mission_tag.parse(string)
    end

    ## sequence
    def sequence
      return @sequence ||= Mhc::PropertyValue::Integer.new.parse("0")
    end

    def sequence=(string)
      return @sequence = sequence.parse(string.to_s)
    end

    def occurrences(range:nil)
      Mhc::OccurrenceEnumerator.new(self, dates, exceptions, recurrence_condition, duration, range)
    end

    # DTSTART (RFC5445:iCalendar) has these two meanings:
    # 1) first ocurrence date of recurrence events
    # 2) start date of a single-shot event
    #
    # In MHC, DTSTART should be calculated as:
    #
    # if a MHC article has a Cond: field,
    #   + DTSTART is calculated from Duration: and Cond: field.
    #   + Additional Day: field is recognized as RDATE.
    # else
    #   + DTSTART is calculated from a first entry of Days: field.
    #   + Remains in Day: field is recognized as RDATE.
    # end
    #
    def dtstart
      if self.recurring?
        Mhc::OccurrenceEnumerator.new(self, empty_dates, empty_dates, recurrence_condition, duration).first.dtstart
      else
        Mhc::OccurrenceEnumerator.new(self, dates, empty_dates, empty_condition, empty_duration).first.dtstart
      end
    end

    def dtend
      if self.recurring?
        Mhc::OccurrenceEnumerator.new(self, empty_dates, empty_dates, recurrence_condition, duration).first.dtend
      else
        Mhc::OccurrenceEnumerator.new(self, dates, empty_dates, empty_condition, empty_duration).first.dtend
      end
    end

    def rdates
      return nil if dates.empty?
      ocs = Mhc::OccurrenceEnumerator.new(self, dates, empty_dates, empty_condition, empty_duration).map {|oc| oc.dtstart}
      if recurring?
        ocs
      else
        ocs = ocs[1..-1]
        return nil if ocs.empty?
        return ocs
      end
    end

    def exdates
      return nil if exceptions.empty?
      ocs = Mhc::OccurrenceEnumerator.new(self, exceptions, empty_dates, empty_condition, empty_duration).map {|oc| oc.dtstart }
      return ocs
    end

    def etag
      return "#{uid.to_s}-#{sequence.to_s}"
    end

    def recurring?
      not recurrence_condition.empty?
    end

    def allday?
      time_range.blank?
    end

    ################################################################
    ### dump

    def dump
      non_xsc_header = @non_xsc_header.to_s.sub(/\n+\z/, "")
      non_xsc_header += "\n" if non_xsc_header != ""

      body = description.to_mhc_string
      body += "\n" if body != "" && body !~ /\n\z/

      return dump_header + non_xsc_header + "\n" + body
    end

    def dump_header
      return "X-SC-Subject: #{subject.to_mhc_string}\n"      +
        "X-SC-Location: #{location.to_mhc_string}\n"         +
        "X-SC-Day: " + "#{dates.to_mhc_string} #{exceptions.to_mhc_string}".strip + "\n" +
        "X-SC-Time: #{time_range.to_mhc_string}\n"           +
        "X-SC-Category: #{categories.to_mhc_string}\n"       +
        "X-SC-Mission-Tag: #{mission_tag.to_mhc_string}\n"   +
        "X-SC-Recurrence-Tag: #{recurrence_tag.to_mhc_string}\n"       +
        "X-SC-Cond: #{recurrence_condition.to_mhc_string}\n" +
        "X-SC-Duration: #{duration.to_mhc_string}\n"         +
        "X-SC-Alarm: #{alarm.to_mhc_string}\n"               +
        "X-SC-Record-Id: #{record_id.to_mhc_string}\n"       +
        "X-SC-Sequence: #{sequence.to_mhc_string}\n"
    end

    alias_method :to_mhc_string, :dump

    ################################################################
    ### converter

    def to_ics
      return self.to_icalendar.to_s
    end

    def to_ics_string
      ical = RiCal.Calendar
      ical.prodid = Mhc::PRODID
      ical.events << self.to_icalendar
      return ical.to_s
    end

    def to_icalendar
      icalendar = RiCal.Event do |iev|
        iev.rrule         = recurrence_condition.to_ics(dtstart, duration.last) if recurring?
        iev.exdates       = [exdates] if exdates
        iev.rdates        = [rdates]  if rdates
        iev.created       = created.utc.strftime("%Y%m%dT%H%M%SZ")
        iev.categories    = categories.to_a unless categories.empty?
        iev.location      = location.to_s unless location.to_s.empty?
        iev.last_modified = last_modified.utc.strftime("%Y%m%dT%H%M%SZ")
        iev.uid           = uid.to_s
        iev.dtstart       = dtstart
        iev.dtend         = dtend
        iev.summary       = subject.to_s
        iev.description   = self.description.to_mhc_string
        iev.sequence      = (sequence.to_i || 0)
        iev.dtstamp       = ::Time.now.utc.strftime("%Y%m%dT%H%M%SZ")
      end
      return icalendar
    end

    def self.new_from_ics(ics)
      ical = RiCal.parse_string(ics).first
      return nil unless ical

      iev = ical.events.first
      ev = self.new

      allday = !iev.dtstart.respond_to?(:hour)

      ev.uid           = iev.uid
      ev.created       = iev.created
      ev.last_modified = iev.last_modified
      ev.sequence    = iev.sequence.to_i

      ev.subject     = iev.summary
      ev.location    = iev.location
      ev.description = iev.description

      ev.start_time  = iev.dtstart.to_time
      if allday
        ev.end_time    = (iev.dtend - 1).to_time
      else
        ev.end_time    = iev.dtend.to_time
      end

      return ev
    end

    ################################################################
    private

    def empty_duration
      Mhc::PropertyValue::Range.new(Mhc::PropertyValue::Date)
    end

    def empty_dates
      Mhc::PropertyValue::List.new(Mhc::PropertyValue::Range.new(Mhc::PropertyValue::Date.new))
    end

    def empty_condition
      Mhc::PropertyValue::RecurrenceCondition.new
    end

    def created
      if @path
        File.ctime(@path)
      else
        ::Time.utc(2014, 1, 1)
      end
    end

    def last_modified
      if @path
        File.mtime(@path)
      else
        ::Time.utc(2014, 1, 1)
      end
    end

    def lazy?
      return !@path.nil?
    end

    def clear
      @alarm, @categories, @description, @location = [nil]*4
      @record_id, @subject = [nil]*2
      @dates, @exceptions, @time_range, @duration, @cond, @oc = [nil]*6
      @non_xsc_header, @path = [nil]*2
      return self
    end

    def parse_header(string)
      xsc, @non_xsc_header = separate_header(string)
      parse_xsc_header(xsc)
      return self
    end

    def parse_xsc_header(hash)
      hash.each do |key, val|
        case key
        when "day"       ; self.dates      = val ; self.exceptions = val
        when "date"      ; self.obsolete_dates = val
        when "subject"   ; self.subject    = val
        when "location"  ; self.location   = val
        when "time"      ; self.time_range = val
        when "duration"  ; self.duration   = val
        when "category"  ; self.categories = val
        when "mission-tag"  ; self.mission_tag = val
        when "recurrence-tag"  ; self.recurrence_tag = val
        when "cond"      ; self.recurrence_condition  = val
        when "alarm"     ; self.alarm      = val
        when "record-id" ; self.record_id  = val
        when "sequence"  ; self.sequence   = val
        else
          # raise NotImplementedError, "X-SC-#{key.capitalize}"
          # STDERR.print "Obsolete: X-SC-#{key.capitalize}\n"
        end
      end
      return self
    end

    ## return: X-SC-* headers as a hash and
    ##         non-X-SC-* headers as one string.
    def separate_header(header)
      xsc, non_xsc, xsc_key = {}, "", nil

      header.split("\n").each do |line|
        if line =~ /^X-SC-([^:]+):(.*)/i
          xsc_key = $1.downcase
          xsc[xsc_key] = $2.to_s.strip

        elsif line =~ /^\s/ && xsc_key
          xsc[xsc_key] += " " + line

        else
          xsc_key = nil
          non_xsc += line + "\n"
        end
      end
      return [xsc, non_xsc]
    end

  end # class Event
end # module Mhc